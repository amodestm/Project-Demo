import XCTest
@testable import AIRunnerCore

/// Codex 运行中额度/会话异常的自动切号门控测试。
///
/// 这些测试直接驱动 monitor.tick，不依赖真实 ChatGPT 窗口；重点锁住两条
/// 安全边界：生成中绝不退出账号，明确异常也必须连续观察两次才轮换。
final class CodexQuotaMonitorTests: XCTestCase {

    actor FakeAccountRotation: CodexAccountRotating {
        private(set) var callCount = 0
        private(set) var taskIDs: [String] = []

        func rotateChatGPTAccount(taskID: String) async throws -> ChatGPTAccountSwitchOutcome {
            callCount += 1
            taskIDs.append(taskID)
            return ChatGPTAccountSwitchOutcome(accountLabel: "下一个账号", pageReloaded: true)
        }
    }

    struct Fixture {
        let services: AppServices
        let driver: FakeCodexUIAutomationDriver
        let rotation: FakeAccountRotation
        let monitor: CodexQuotaMonitor
        let taskID: String
    }

    private func makeFixture(
        issue: CodexAccountIssue? = .quotaExhausted,
        busyState: CodexBusyState = .idle,
        taskStoppedSignal: Bool = false
    ) async throws -> Fixture {
        let services = try TestSupport.makeServices()
        let driver = FakeCodexUIAutomationDriver()
        driver.configureHappyPath()
        driver.accountIssue = issue
        driver.busyState = busyState
        driver.taskStoppedSignal = taskStoppedSignal

        let task = try TestSupport.makeTask(
            services, goal: "Codex 自动切号", steps: 2, executionMode: .chatGPTWeb
        )
        try services.tasks.updateStatus(id: task.id, to: .running)

        let bindings = CodexTaskBindingRepository(db: services.database)
        try bindings.insert(
            CodexTaskBinding(
                taskID: task.id,
                displayTitle: "Codex 自动切号",
                projectName: "airunner",
                repositoryPath: "/Users/dev/airunner",
                applicationBundleIdentifier: "com.openai.chat",
                applicationName: "ChatGPT",
                fingerprint: CodexTaskFingerprint(
                    threadTitle: "Codex 自动切号",
                    projectName: "airunner",
                    repositoryPath: "/Users/dev/airunner",
                    applicationBundleIdentifier: "com.openai.chat"
                )
            )
        )

        let rotation = FakeAccountRotation()
        let monitor = CodexQuotaMonitor(
            driver: driver,
            bindings: bindings,
            tasks: services.tasks,
            accountRotation: rotation,
            logger: services.logger,
            pollInterval: .milliseconds(1)
        )
        await monitor.start(taskID: task.id, autoRun: false)

        return Fixture(
            services: services,
            driver: driver,
            rotation: rotation,
            monitor: monitor,
            taskID: task.id
        )
    }

    func testQuotaRequiresTwoIdleObservationsThenRotates() async throws {
        let fixture = try await makeFixture()

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(first, .observed(.quotaExhausted))
        let callsAfterFirst = await fixture.rotation.callCount
        XCTAssertEqual(callsAfterFirst, 0)
        XCTAssertEqual(try fixture.services.tasks.fetch(id: fixture.taskID)?.status, .running)

        let second = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(second, .rotationCompleted)
        let callsAfterSecond = await fixture.rotation.callCount
        let rotatedTaskIDs = await fixture.rotation.taskIDs
        XCTAssertEqual(callsAfterSecond, 1)
        XCTAssertEqual(rotatedTaskIDs, [fixture.taskID])
        XCTAssertEqual(
            try fixture.services.tasks.fetch(id: fixture.taskID)?.status,
            .waitingForAccount,
            "切号前必须先保存检查点并进入等待账号状态"
        )
    }

    func testWaitingForUserIsStillMonitoredWhileCodexFinishesWork() async throws {
        let fixture = try await makeFixture()
        try fixture.services.tasks.updateStatus(id: fixture.taskID, to: .waitingForUser)

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        let second = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(first, .observed(.quotaExhausted))
        XCTAssertEqual(second, .rotationCompleted)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 1)
    }

    func testGeneratingNeverRotatesEvenWhenQuotaTextIsVisible() async throws {
        let fixture = try await makeFixture(busyState: .generating)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(outcome, .generating)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try fixture.services.tasks.fetch(id: fixture.taskID)?.status, .running)
    }

    func testQuotaCanRotateFromUnknownBusyStateOnlyWithStoppedSignal() async throws {
        let fixture = try await makeFixture(
            busyState: .unknown,
            taskStoppedSignal: true
        )

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        let second = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(first, .observed(.quotaExhausted))
        XCTAssertEqual(second, .rotationCompleted)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 1)
    }

    func testUnknownBusyStateWithoutStoppedSignalWaits() async throws {
        let fixture = try await makeFixture(busyState: .unknown)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(outcome, .waitingForCodex)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try fixture.services.tasks.fetch(id: fixture.taskID)?.status, .running)
    }

    func testSafeSimulationRefusesToLogoutWhileGenerating() async throws {
        let fixture = try await makeFixture(busyState: .generating)

        do {
            _ = try await fixture.monitor.simulateQuotaExhaustion(taskID: fixture.taskID)
            XCTFail("生成中必须拒绝安全模拟")
        } catch {
            XCTAssertTrue(AppError.normalize(error).userMessage.contains("仍在生成中"))
        }

        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try fixture.services.tasks.fetch(id: fixture.taskID)?.status, .running)
    }

    func testTaskStoppedTextIsObservedButDoesNotTriggerRotation() async throws {
        let fixture = try await makeFixture(issue: .taskStopped)

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        let second = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(first, .observed(.taskStopped))
        XCTAssertEqual(second, .observed(.taskStopped))
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try fixture.services.tasks.fetch(id: fixture.taskID)?.status, .running)
    }

    func testLatestIssueClassifierIgnoresQuotaTextOutsideTail() {
        var configuration = CodexDriverConfiguration.default
        configuration.accountIssueTailLimit = 4
        XCTAssertNil(CodexUIAutomationDriver.classifyLatestAccountIssue(
            [
                "Quota exceeded",
                "older assistant reply",
                "new user prompt",
                "working",
                "latest normal response",
            ],
            configuration: configuration
        ))
    }

    func testLatestIssueClassifierFindsQuotaTextInsideTail() {
        var configuration = CodexDriverConfiguration.default
        configuration.accountIssueTailLimit = 4
        XCTAssertEqual(CodexUIAutomationDriver.classifyLatestAccountIssue(
            [
                "old conversation",
                "new user prompt",
                "working",
                "Usage limit reached",
            ],
            configuration: configuration
        ), .quotaExhausted)
    }

    func testCompletedRotationIsLatchedUntilOldIssueDisappears() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        let firstRotation = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(firstRotation, .rotationCompleted)
        try fixture.services.tasks.updateStatus(id: fixture.taskID, to: .waitingForUser)

        let staleIssue = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(staleIssue, .observed(.quotaExhausted))
        let callsWhileLatched = await fixture.rotation.callCount
        XCTAssertEqual(callsWhileLatched, 1)

        fixture.driver.accountIssue = nil
        let cleared = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(cleared, .waitingForCodex)

        fixture.driver.accountIssue = .quotaExhausted
        let nextFirstObservation = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(nextFirstObservation, .observed(.quotaExhausted))
        let nextRotation = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(nextRotation, .rotationCompleted)
        let callsAfterNewIssue = await fixture.rotation.callCount
        XCTAssertEqual(callsAfterNewIssue, 2)
    }

    func testIssueClassifierDoesNotTreatStopButtonAsQuota() {
        XCTAssertEqual(
            CodexUIAutomationDriver.classifyAccountIssue(["Usage limit reached"]),
            .quotaExhausted
        )
        XCTAssertEqual(
            CodexUIAutomationDriver.classifyAccountIssue(["Session expired, sign in to continue"]),
            .authenticationRequired
        )
        XCTAssertEqual(
            CodexUIAutomationDriver.classifyAccountIssue(["Task stopped"]),
            .taskStopped
        )
        XCTAssertNil(
            CodexUIAutomationDriver.classifyAccountIssue(["Stop", "停止", "Generating"]),
            "生成按钮和普通停止按钮不能单独触发账号轮换"
        )
    }
}

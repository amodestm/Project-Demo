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
        driver.configureHappyPath(title: "Codex 自动切号")
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
        let resumeController = CodexResumeController(
            driver: driver,
            bindings: bindings,
            leases: services.codexLeases,
            logger: services.logger
        )
        let monitor = CodexQuotaMonitor(
            driver: driver,
            bindings: bindings,
            tasks: services.tasks,
            resumeController: resumeController,
            accountRotation: rotation,
            logger: services.logger,
            pollInterval: .milliseconds(1),
            retrySettleDelay: 0
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

    func testQuotaRetriesOnceThenRequiresTwoMoreObservationsBeforeRotation() async throws {
        let fixture = try await makeFixture()

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(first, .observed(.quotaExhausted))
        let callsAfterFirst = await fixture.rotation.callCount
        XCTAssertEqual(callsAfterFirst, 0)
        XCTAssertEqual(try fixture.services.tasks.fetch(id: fixture.taskID)?.status, .running)

        let second = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(second, .retrySent)
        XCTAssertEqual(fixture.driver.insertedMessages, ["继续"])
        XCTAssertEqual(fixture.driver.sendCount, 1)
        let callsAfterSecond = await fixture.rotation.callCount
        XCTAssertEqual(callsAfterSecond, 0)

        let third = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(third, .observed(.quotaExhausted))
        let fourth = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(fourth, .rotationCompleted)
        let rotatedTaskIDs = await fixture.rotation.taskIDs
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
        let third = await fixture.monitor.tick(taskID: fixture.taskID)
        let fourth = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(first, .observed(.quotaExhausted))
        XCTAssertEqual(second, .retrySent)
        XCTAssertEqual(third, .observed(.quotaExhausted))
        XCTAssertEqual(fourth, .rotationCompleted)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 1)
    }

    func testQuotaDisappearingAfterRetryCancelsRotation() async throws {
        let fixture = try await makeFixture()

        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        let retry = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(retry, .retrySent)

        fixture.driver.accountIssue = nil
        let firstClear = await fixture.monitor.tick(taskID: fixture.taskID)
        let secondClear = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(firstClear, .waitingForCodex)
        XCTAssertEqual(secondClear, .waitingForCodex)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 0)
    }

    func testSingleEmptyRenderAfterRetryDoesNotAllowSecondRetry() async throws {
        let fixture = try await makeFixture()

        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        let retry = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(retry, .retrySent)

        fixture.driver.accountIssue = nil
        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        fixture.driver.accountIssue = .quotaExhausted
        let observed = await fixture.monitor.tick(taskID: fixture.taskID)
        let rotated = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(observed, .observed(.quotaExhausted))
        XCTAssertEqual(rotated, .rotationCompleted)
        XCTAssertEqual(fixture.driver.sendCount, 1)
    }

    func testAuthenticationFailureStillRotatesWithoutSendingRetry() async throws {
        let fixture = try await makeFixture(issue: .authenticationRequired)

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        let second = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(first, .observed(.authenticationRequired))
        XCTAssertEqual(second, .rotationCompleted)
        XCTAssertEqual(fixture.driver.sendCount, 0)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 1)
    }

    func testConfirmedQuotaRetryBypassesOrdinaryResumeCooldownOnce() async throws {
        let fixture = try await makeFixture()
        let binding = try XCTUnwrap(
            CodexTaskBindingRepository(db: fixture.services.database)
                .fetchByTask(taskID: fixture.taskID)
        )
        try CodexTaskBindingRepository(db: fixture.services.database)
            .markResumeSent(bindingID: binding.id, at: Date())

        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        let retry = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(retry, .retrySent)
        XCTAssertEqual(fixture.driver.insertedMessages, ["继续"])
        XCTAssertEqual(fixture.driver.sendCount, 1)
    }

    func testGeneratingAfterQuotaRetryDoesNotAllowSecondRetry() async throws {
        let fixture = try await makeFixture()

        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        let retry = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(retry, .retrySent)

        fixture.driver.busyState = .generating
        let generating = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(generating, .generating)
        fixture.driver.busyState = .idle
        let postGenerationObservation = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(postGenerationObservation, .observed(.quotaExhausted))
        let rotation = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(rotation, .rotationCompleted)
        XCTAssertEqual(fixture.driver.sendCount, 1)
    }

    func testGeneratingNeverRotatesEvenWhenQuotaTextIsVisible() async throws {
        let fixture = try await makeFixture(busyState: .generating)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(outcome, .generating)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try fixture.services.tasks.fetch(id: fixture.taskID)?.status, .running)
    }

    func testQuotaCanRotateFromUnknownBusyStateWhenQuotaBannerIsTerminal() async throws {
        let fixture = try await makeFixture(
            busyState: .unknown
        )

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        let second = await fixture.monitor.tick(taskID: fixture.taskID)
        let third = await fixture.monitor.tick(taskID: fixture.taskID)
        let fourth = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(first, .observed(.quotaExhausted))
        XCTAssertEqual(second, .retrySent)
        XCTAssertEqual(third, .observed(.quotaExhausted))
        XCTAssertEqual(fourth, .rotationCompleted)
        let calls = await fixture.rotation.callCount
        XCTAssertEqual(calls, 1)
    }

    func testAuthenticationUnknownBusyStateWithoutStoppedSignalWaits() async throws {
        let fixture = try await makeFixture(
            issue: .authenticationRequired,
            busyState: .unknown
        )

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

    func testSafeSimulationContinuesPendingRotationFromWaitingForAccount() async throws {
        let fixture = try await makeFixture(busyState: .generating)
        try fixture.services.tasks.updateStatus(
            id: fixture.taskID,
            to: .waitingForAccount,
            errorMessage: "检查点已保存，准备切换账号",
            errorClass: CodexAccountIssue.quotaExhausted.eventName
        )

        let outcome = try await fixture.monitor.simulateQuotaExhaustion(
            taskID: fixture.taskID
        )

        XCTAssertEqual(outcome, .rotationCompleted)
        let rotationCalls = await fixture.rotation.callCount
        XCTAssertEqual(rotationCalls, 1)
        XCTAssertEqual(
            try fixture.services.tasks.fetch(id: fixture.taskID)?.status,
            .waitingForAccount
        )
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

    func testLatestIssueClassifierKeepsCurrentQuotaBannerOutsideTail() {
        var configuration = CodexDriverConfiguration.default
        configuration.accountIssueTailLimit = 4
        XCTAssertEqual(CodexUIAutomationDriver.classifyLatestAccountIssue(
            [
                "你已达到使用上限。升级套餐或充值额度以继续，或在 2026年9月19日16:15 后重试。",
                "工具栏", "模型", "历史消息", "编辑", "复制", "重试", "随心输入"
            ],
            configuration: configuration
        ), .quotaExhausted)
    }

    func testLatestIssueClassifierRecognizesEnglishOutOfUsageBanner() {
        var configuration = CodexDriverConfiguration.default
        configuration.accountIssueTailLimit = 4
        XCTAssertEqual(CodexUIAutomationDriver.classifyLatestAccountIssue(
            [
                "You’re out of Codex and Work usage",
                "Add credits or upgrade your plan — or wait for usage to reset on 9月19日 20:37",
                "Upgrade", "Add Credits", "继续", "GPT-6 Astra 极高", "随心输入"
            ],
            configuration: configuration
        ), .quotaExhausted)
    }

    func testQuotaBlockedRetryDirectlyRotatesWhenBannerPersists() async throws {
        let fixture = try await makeFixture()
        fixture.driver.sendControlAvailable = false

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        let second = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(first, .observed(.quotaExhausted))
        XCTAssertEqual(second, .rotationCompleted)
        XCTAssertEqual(fixture.driver.sendCount, 0)
        let rotationCalls = await fixture.rotation.callCount
        XCTAssertEqual(rotationCalls, 1)
        XCTAssertEqual(
            try fixture.services.tasks.fetch(id: fixture.taskID)?.status,
            .waitingForAccount
        )
    }

    func testUnconfirmedQuotaRetryDirectlyRotatesWhenBannerPersists() async throws {
        let fixture = try await makeFixture()
        fixture.driver.confirmation = .unconfirmed

        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(outcome, .rotationCompleted)
        XCTAssertEqual(fixture.driver.sendCount, 1)
        let rotationCalls = await fixture.rotation.callCount
        XCTAssertEqual(rotationCalls, 1)
    }

    func testQuotaOnEachNewAccountContinuesRotationUntilAnAccountRecovers() async throws {
        let fixture = try await makeFixture()
        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        _ = await fixture.monitor.tick(taskID: fixture.taskID)
        let firstRotation = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(firstRotation, .rotationCompleted)

        // 模拟 Profile B 登录并恢复目标线程，但这个账号同样没有额度。
        try fixture.services.tasks.updateStatus(id: fixture.taskID, to: .running)
        let profileBFirst = await fixture.monitor.tick(taskID: fixture.taskID)
        let profileBRetry = await fixture.monitor.tick(taskID: fixture.taskID)
        let profileBSecond = await fixture.monitor.tick(taskID: fixture.taskID)
        let profileBRotation = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(profileBFirst, .observed(.quotaExhausted))
        XCTAssertEqual(profileBRetry, .retrySent)
        XCTAssertEqual(profileBSecond, .observed(.quotaExhausted))
        XCTAssertEqual(profileBRotation, .rotationCompleted)

        // 模拟 Profile C 也没有额度，应继续轮换回第三个账号，而不是被旧锁存挡住。
        try fixture.services.tasks.updateStatus(id: fixture.taskID, to: .running)
        let profileCFirst = await fixture.monitor.tick(taskID: fixture.taskID)
        let profileCRetry = await fixture.monitor.tick(taskID: fixture.taskID)
        let profileCSecond = await fixture.monitor.tick(taskID: fixture.taskID)
        let profileCRotation = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(profileCFirst, .observed(.quotaExhausted))
        XCTAssertEqual(profileCRetry, .retrySent)
        XCTAssertEqual(profileCSecond, .observed(.quotaExhausted))
        XCTAssertEqual(profileCRotation, .rotationCompleted)

        let callsAfterFullCycle = await fixture.rotation.callCount
        XCTAssertEqual(callsAfterFullCycle, 3)

        // 回到唯一有额度的账号后，错误横幅消失，轮换自然停止。
        try fixture.services.tasks.updateStatus(id: fixture.taskID, to: .running)
        fixture.driver.accountIssue = nil
        let recovered = await fixture.monitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(recovered, .waitingForCodex)
        let finalCalls = await fixture.rotation.callCount
        XCTAssertEqual(finalCalls, 3)
    }

    func testIssueClassifierDoesNotTreatStopButtonAsQuota() {
        XCTAssertEqual(
            CodexUIAutomationDriver.classifyAccountIssue(["Usage limit reached"]),
            .quotaExhausted
        )
        XCTAssertEqual(
            CodexUIAutomationDriver.classifyAccountIssue([
                "你已达到使用上限。升级套餐或充值额度以继续，或在 2026年9月19日16:15 后重试。"
            ]),
            .quotaExhausted,
            "带具体重试日期的额度横幅必须触发额度识别"
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

    func testWelcomeOverlayMatcherRequiresIntroductionAndActionSemantics() {
        XCTAssertTrue(CodexUIAutomationDriver.isBlockingWelcomeOverlay([
            "GPT-6 Astra 简介", "继续使用当前模型", "立即试用 GPT-6 Astra"
        ]))
        XCTAssertFalse(CodexUIAutomationDriver.isBlockingWelcomeOverlay([
            "GPT-6 Astra 简介", "随心输入"
        ]), "普通页面文本不能触发关闭弹窗")
    }
}

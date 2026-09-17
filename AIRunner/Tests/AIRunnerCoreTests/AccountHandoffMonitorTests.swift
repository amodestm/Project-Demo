import XCTest
@testable import AIRunnerCore

/// 账号交接后自动恢复的测试 —— 逐条覆盖需求里列出的场景。
///
/// 全部用 `FakeCodexUIAutomationDriver` + `tick()` 手动驱动, 不依赖真实计时器。
final class AccountHandoffMonitorTests: XCTestCase {

    actor FakeAccountRotation: CodexAccountRotating {
        private(set) var callCount = 0

        func rotateChatGPTAccount(taskID: String) async throws -> ChatGPTAccountSwitchOutcome {
            callCount += 1
            return ChatGPTAccountSwitchOutcome(accountLabel: "下一个账号", pageReloaded: true)
        }
    }

    // MARK: - 装置

    struct Fixture {
        let services: AppServices
        let driver: FakeCodexUIAutomationDriver
        let controller: CodexResumeController
        let monitor: AccountHandoffResumeMonitor
        let rotation: FakeAccountRotation
        let bindings: CodexTaskBindingRepository
        let leases: CodexResumeLeaseRepository
        let taskID: String
        let bindingID: String
    }

    private func makeFixture(
        steps: Int = 3,
        cooldown: TimeInterval = 60,
        executionPreference: CodexExecutionPreference? = nil,
        configureDriver: (FakeCodexUIAutomationDriver) -> Void = { _ in }
    ) async throws -> Fixture {

        let services = try TestSupport.makeServices()
        let driver = FakeCodexUIAutomationDriver()
        driver.configureHappyPath()
        configureDriver(driver)

        let logger = services.logger
        let bindings = CodexTaskBindingRepository(db: services.database)
        let leases = CodexResumeLeaseRepository(db: services.database)

        let controller = CodexResumeController(
            driver: driver,
            bindings: bindings,
            leases: leases,
            logger: logger,
            configuration: CodexResumeConfiguration(),
            ownerID: "test-owner",
            now: { Date() }
        )
        let rotation = FakeAccountRotation()

        let monitor = AccountHandoffResumeMonitor(
            driver: driver,
            resumeController: controller,
            bindings: bindings,
            tasks: services.tasks,
            accountRotation: rotation,
            logger: logger,
            cooldown: cooldown,
            pollInterval: .milliseconds(10),
            now: { Date() }
        )

        let task = try TestSupport.makeTask(
            services, goal: "长对话任务", steps: steps, executionMode: .chatGPTWeb
        )

        let binding = CodexTaskBinding(
            taskID: task.id,
            displayTitle: "长对话任务",
            projectName: "airunner",
            repositoryPath: "/Users/dev/airunner",
            applicationBundleIdentifier: "com.openai.chat",
            applicationName: "ChatGPT",
            fingerprint: CodexTaskFingerprint(
                threadTitle: "长对话任务",
                projectName: "airunner",
                repositoryPath: "/Users/dev/airunner",
                applicationBundleIdentifier: "com.openai.chat"
            ),
            resumeMessage: "继续",
            executionPreference: executionPreference
        )
        try bindings.insert(binding)

        return Fixture(
            services: services,
            driver: driver,
            controller: controller,
            monitor: monitor,
            rotation: rotation,
            bindings: bindings,
            leases: leases,
            taskID: task.id,
            bindingID: binding.id
        )
    }

    /// 把任务推进到 `waitingForAccount` 并开始监视。
    private func armHandoff(_ fixture: Fixture) async throws {
        try fixture.services.tasks.updateStatus(id: fixture.taskID, to: .running)
        try fixture.services.tasks.updateStatus(id: fixture.taskID, to: .waitingForAccount)
        await fixture.monitor.start(taskID: fixture.taskID, autoRun: false)
    }

    // MARK: - ① 等待认证期间 Codex 不可用 → 不发送

    func testResumeDismissesPostLoginWelcomeOverlayBeforeLocatingThread() async throws {
        let fixture = try await makeFixture { driver in
            driver.blockingWelcomeOverlayPresent = true
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .resumed = outcome else {
            return XCTFail("关闭欢迎弹窗后应继续完成 Resume, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.welcomeOverlayDismissCount, 1)
        XCTAssertEqual(fixture.driver.insertedMessages, ["继续"])
    }

    func testNoSendWhileCodexUnavailable() async throws {
        let fixture = try await makeFixture { driver in
            driver.appRunning = false          // 用户还没完成认证
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .stillWaiting = outcome else {
            return XCTFail("Codex 不可用时应继续等待, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.sendCount, 0, "★ 绝不能发送 ★")
        XCTAssertEqual(fixture.driver.insertedMessages, [])
        let state = await fixture.monitor.state
        XCTAssertEqual(state, .waitingForUserAuthentication)
    }

    func testNoSendWithoutAccessibilityPermission() async throws {
        let fixture = try await makeFixture { driver in
            driver.permission = .denied
        }
        try await armHandoff(fixture)

        _ = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(fixture.driver.sendCount, 0)
        XCTAssertEqual(fixture.driver.probeCount, 0, "没有权限时连探测都不该做")
    }

    // MARK: - ② Codex 恢复可用 → 唯一目标 → 恰好发送一次

    func testSendsExactlyOnceWhenTargetBecomesAvailable() async throws {
        let fixture = try await makeFixture()
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .resumed(let bindingID) = outcome else {
            return XCTFail("应当自动恢复, 实际: \(outcome)")
        }
        XCTAssertEqual(bindingID, fixture.bindingID)
        XCTAssertEqual(fixture.driver.sendCount, 1, "★ 恰好发送一次 ★")
        XCTAssertEqual(fixture.driver.insertedMessages, ["继续"])
        XCTAssertEqual(fixture.driver.openedThreads, ["长对话任务"])

        // 任务应恢复为 running
        XCTAssertEqual(
            try fixture.services.tasks.fetch(id: fixture.taskID)?.status, .running
        )
        // 监视应已停止
        let stillMonitoring = await fixture.monitor.isMonitoring(taskID: fixture.taskID)
        XCTAssertFalse(stillMonitoring)
    }

    func testSendIsRecordedInBindingForCooldown() async throws {
        let fixture = try await makeFixture()
        try await armHandoff(fixture)

        _ = await fixture.monitor.tick(taskID: fixture.taskID)

        let updated = try XCTUnwrap(fixture.bindings.fetch(id: fixture.bindingID))
        XCTAssertNotNil(updated.lastResumeSentAt, "必须落盘发送时间, 这是冷却的依据")
        XCTAssertNotNil(updated.lastVerifiedAt)
    }

    // MARK: - ③ 目标歧义 → 不发送

    func testNoSendWhenTargetIsAmbiguous() async throws {
        let fixture = try await makeFixture { driver in
            driver.candidates = [
                CodexThreadCandidate(title: "长对话任务", projectName: "airunner"),
                CodexThreadCandidate(title: "长对话任务", projectName: "airunner"),
            ]
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .failed = outcome else {
            return XCTFail("歧义目标必须停止并报错, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.sendCount, 0, "★ 歧义时绝不发送 ★")
        XCTAssertEqual(fixture.driver.openedThreads, [], "连打开都不该做")
    }

    // MARK: - ④ 目标暂时找不到 → 继续等

    func testKeepsWaitingWhenTargetNotFound() async throws {
        let fixture = try await makeFixture { driver in
            driver.candidates = []
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .stillWaiting = outcome else {
            return XCTFail("找不到目标应继续等, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.sendCount, 0)
        let monitoring = await fixture.monitor.isMonitoring(taskID: fixture.taskID)
        XCTAssertTrue(monitoring, "应当继续监视, 给用户切号的时间")
    }

    // MARK: - ⑤ 线程正在生成 → 不发送

    func testNoSendWhenThreadIsAlreadyRunning() async throws {
        let fixture = try await makeFixture { driver in
            driver.busyState = .generating
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .availableButNotActionable = outcome else {
            return XCTFail("线程忙时应等待而不是发送, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.sendCount, 0, "★ 不给正在跑的线程发「继续」★")
        XCTAssertEqual(fixture.driver.insertedMessages, [], "连输入都不该做")
    }

    func testNoSendWhenBusyStateUnknown() async throws {
        let fixture = try await makeFixture { driver in
            driver.busyState = .unknown
        }
        try await armHandoff(fixture)

        _ = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(fixture.driver.sendCount, 0, "读取不到忙碌状态时按不确定处理 —— 不发送")
    }

    // MARK: - ⑥ 两次 tick → 只发送一次

    func testTwoTicksProduceOnlyOneSend() async throws {
        let fixture = try await makeFixture()
        try await armHandoff(fixture)

        let first = await fixture.monitor.tick(taskID: fixture.taskID)
        let second = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .resumed = first else {
            return XCTFail("第一次 tick 应当成功, 实际: \(first)")
        }
        XCTAssertEqual(second, .idle, "成功后监视已停止, 第二次 tick 应当直接返回 idle")
        XCTAssertEqual(fixture.driver.sendCount, 1, "★ 只允许一次发送 ★")
    }

    func testSecondTickIsBlockedByCooldownWhenMonitorStillActive() async throws {
        // 构造一个"第一次成功后监视仍在"的情形: 直接在 controller 层验证冷却
        let fixture = try await makeFixture()

        _ = try await fixture.controller.resume(bindingID: fixture.bindingID)
        XCTAssertEqual(fixture.driver.sendCount, 1)

        do {
            _ = try await fixture.controller.resume(bindingID: fixture.bindingID)
            XCTFail("冷却期内第二次 Resume 必须被拒绝")
        } catch let error as CodexAutomationError {
            guard case .duplicateResumePrevented = error else {
                return XCTFail("错误类型应为 duplicateResumePrevented, 实际: \(error)")
            }
        }
        XCTAssertEqual(fixture.driver.sendCount, 1, "★ 仍然只发送了一次 ★")
    }

    func testAccountHandoffResumeIsNotBlockedByPreviousAccountCooldown() async throws {
        let fixture = try await makeFixture()
        try fixture.bindings.markResumeSent(bindingID: fixture.bindingID, at: Date())
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .resumed = outcome else {
            return XCTFail("切换账号后的恢复不能被旧账号的冷却记录拦截, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.sendCount, 1)
    }

    // MARK: - ⑦ App 重启后监视被恢复

    func testMonitorIsRestoredAfterRestart() async throws {
        let fixture = try await makeFixture { driver in
            driver.appRunning = false
        }
        try await armHandoff(fixture)

        // 模拟 App 重启: 新建一套 monitor (数据库不变)
        let restartedMonitor = AccountHandoffResumeMonitor(
            driver: fixture.driver,
            resumeController: fixture.controller,
            bindings: fixture.bindings,
            tasks: fixture.services.tasks,
            logger: fixture.services.logger,
            cooldown: 60,
            pollInterval: .milliseconds(10),
            now: { Date() }
        )

        let restored = await restartedMonitor.restoreFromDatabase()

        XCTAssertEqual(restored, [fixture.taskID], "waitingForAccount 的任务应被重新纳入监视")
        let monitoring = await restartedMonitor.isMonitoring(taskID: fixture.taskID)
        XCTAssertTrue(monitoring)

        // 恢复后依然不发送 (Codex 仍不可用)
        _ = await restartedMonitor.tick(taskID: fixture.taskID)
        XCTAssertEqual(fixture.driver.sendCount, 0)
    }

    func testRestoreSkipsTasksWithoutBinding() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(
            services, goal: "无绑定任务", steps: 2, executionMode: .chatGPTWeb
        )
        try services.tasks.updateStatus(id: task.id, to: .running)
        try services.tasks.updateStatus(id: task.id, to: .waitingForAccount)

        let driver = FakeCodexUIAutomationDriver()
        let bindings = CodexTaskBindingRepository(db: services.database)
        let leases = CodexResumeLeaseRepository(db: services.database)
        let controller = CodexResumeController(
            driver: driver, bindings: bindings, leases: leases, logger: services.logger
        )
        let monitor = AccountHandoffResumeMonitor(
            driver: driver,
            resumeController: controller,
            bindings: bindings,
            tasks: services.tasks,
            logger: services.logger
        )

        let restored = await monitor.restoreFromDatabase()

        XCTAssertEqual(restored, [], "没有绑定的任务无法自动恢复, 不该被纳入监视")
    }

    // MARK: - ⑧ 跨 AppServices 实例租约阻止重复

    func testLeasePreventsDuplicateResumeAcrossTwoControllers() async throws {
        let services = try TestSupport.makeServices()
        let driverA = FakeCodexUIAutomationDriver()
        driverA.configureHappyPath()
        let driverB = FakeCodexUIAutomationDriver()
        driverB.configureHappyPath()

        let bindings = CodexTaskBindingRepository(db: services.database)
        let leases = CodexResumeLeaseRepository(db: services.database)

        let controllerA = CodexResumeController(
            driver: driverA, bindings: bindings, leases: leases,
            logger: services.logger, ownerID: "instance-A"
        )
        let controllerB = CodexResumeController(
            driver: driverB, bindings: bindings, leases: leases,
            logger: services.logger, ownerID: "instance-B"
        )

        let task = try TestSupport.makeTask(
            services, goal: "g", steps: 2, executionMode: .chatGPTWeb
        )
        let binding = CodexTaskBinding(
            taskID: task.id,
            displayTitle: "长对话任务",
            projectName: "airunner",
            applicationBundleIdentifier: "com.openai.chat",
            fingerprint: CodexTaskFingerprint(
                threadTitle: "长对话任务", projectName: "airunner"
            )
        )
        try bindings.insert(binding)

        // 先占住租约 (模拟实例 A 正在发送中)
        _ = try leases.claim(
            bindingID: binding.id, ownerID: "instance-A", ttl: 120
        )

        // 实例 B 尝试 → 必须被挡住
        do {
            _ = try await controllerB.resume(bindingID: binding.id)
            XCTFail("另一个实例必须在租约被占用时被拒绝")
        } catch let error as CodexAutomationError {
            guard case .resumeLeaseBusy = error else {
                return XCTFail("错误类型应为 resumeLeaseBusy, 实际: \(error)")
            }
        }

        XCTAssertEqual(driverB.sendCount, 0, "★ 第二个实例绝不能发送 ★")
    }

    // MARK: - 边界: 发送未确认

    func testAppliesConfiguredModelBeforeSendingPrompt() async throws {
        let preference = CodexExecutionPreference.gpt56SolHigh
        let fixture = try await makeFixture(executionPreference: preference) { driver in
            driver.executionSelection = CodexExecutionSelection(visibleTitle: "GPT-6 Astra 极高")
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .resumed = outcome else {
            return XCTFail("设置模型后应完成发送, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.appliedPreferences, [preference])
        XCTAssertEqual(fixture.driver.modelApplyCount, 1)
        XCTAssertEqual(fixture.driver.insertedMessages, ["继续"])
        XCTAssertEqual(fixture.driver.sendCount, 1)
    }

    func testPrepareExecutionSetsModelWithoutInsertingOrSending() async throws {
        let preference = CodexExecutionPreference.gpt56SolHigh
        let fixture = try await makeFixture(executionPreference: preference) { driver in
            driver.executionSelection = CodexExecutionSelection(visibleTitle: "GPT-6 Astra 极高")
        }

        let verification = try await fixture.controller.prepareExecution(
            bindingID: fixture.bindingID
        )

        XCTAssertTrue(verification.passesLocateGate)
        XCTAssertTrue(verification.executionPreferenceMatched)
        XCTAssertTrue(verification.composerFound)
        XCTAssertTrue(verification.composerEditable)
        XCTAssertEqual(fixture.driver.appliedPreferences, [preference])
        XCTAssertEqual(fixture.driver.insertedMessages, [])
        XCTAssertEqual(fixture.driver.sendCount, 0)
    }

    func testModelVerificationFailureDoesNotInsertOrSendPrompt() async throws {
        let preference = CodexExecutionPreference.gpt56SolHigh
        let fixture = try await makeFixture(executionPreference: preference) { driver in
            driver.executionSelection = CodexExecutionSelection(visibleTitle: "GPT-6 Astra 极高")
            driver.modelSelectionSucceeds = false
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .failed = outcome else {
            return XCTFail("模型回读不匹配时应停止, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.modelApplyCount, 1)
        XCTAssertEqual(fixture.driver.insertedMessages, [])
        XCTAssertEqual(fixture.driver.sendCount, 0)
    }

    func testUnconfirmedSendIsNotReportedAsConfirmed() async throws {
        let fixture = try await makeFixture { driver in
            driver.confirmation = .unconfirmed
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        // 仍然算"已恢复"(确实发了一次), 但内部必须标为未确认
        guard case .resumed = outcome else {
            return XCTFail("发送已触发, 应当记为 resumed, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.sendCount, 1)

        let events = try fixture.services.events.list(limit: 200)
        XCTAssertTrue(
            events.contains { $0.eventType == .codexResumeUnconfirmed },
            "无法确认时必须留下 CODEX_RESUME_UNCONFIRMED 事件, 不能谎报成功"
        )
    }

    func testQuotaBlockedSendAfterHandoffRotatesToNextAccount() async throws {
        let fixture = try await makeFixture { driver in
            driver.accountIssue = .quotaExhausted
            driver.sendControlAvailable = false
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .stillWaiting = outcome else {
            return XCTFail("明确额度耗尽且无法发送时应继续轮换, 实际: \(outcome)")
        }
        let rotationCalls = await fixture.rotation.callCount
        let stillMonitoring = await fixture.monitor.isMonitoring(taskID: fixture.taskID)
        XCTAssertEqual(rotationCalls, 1)
        XCTAssertEqual(fixture.driver.sendCount, 0)
        XCTAssertTrue(stillMonitoring)
        XCTAssertEqual(
            try fixture.services.tasks.fetch(id: fixture.taskID)?.status,
            .waitingForAccount
        )
    }

    func testUnconfirmedSendWithPersistentQuotaRotatesToNextAccount() async throws {
        let fixture = try await makeFixture { driver in
            driver.accountIssue = .quotaExhausted
            driver.confirmation = .unconfirmed
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .stillWaiting = outcome else {
            return XCTFail("发送未确认且额度横幅仍在时应继续轮换, 实际: \(outcome)")
        }
        XCTAssertEqual(fixture.driver.sendCount, 1)
        let rotationCalls = await fixture.rotation.callCount
        let stillMonitoring = await fixture.monitor.isMonitoring(taskID: fixture.taskID)
        XCTAssertEqual(rotationCalls, 1)
        XCTAssertTrue(stillMonitoring)
    }

    func testSendFailureWithoutQuotaStillFailsClosed() async throws {
        let fixture = try await makeFixture { driver in
            driver.sendControlAvailable = false
            driver.accountIssue = nil
        }
        try await armHandoff(fixture)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        guard case .failed = outcome else {
            return XCTFail("没有额度横幅时不得把发送错误解释为切号, 实际: \(outcome)")
        }
        let rotationCalls = await fixture.rotation.callCount
        XCTAssertEqual(rotationCalls, 0)
    }

    // MARK: - 边界: 任务状态变化后自动停止监视

    func testMonitorStopsWhenTaskLeavesWaitingState() async throws {
        let fixture = try await makeFixture()
        try await armHandoff(fixture)

        // 用户手动取消了任务
        try fixture.services.tasks.updateStatus(id: fixture.taskID, to: .cancelled)

        let outcome = await fixture.monitor.tick(taskID: fixture.taskID)

        XCTAssertEqual(outcome, .idle)
        XCTAssertEqual(fixture.driver.sendCount, 0, "任务已取消, 不该再发送")
        let monitoring = await fixture.monitor.isMonitoring(taskID: fixture.taskID)
        XCTAssertFalse(monitoring)
    }
}

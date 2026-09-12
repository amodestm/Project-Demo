import XCTest
@testable import AIRunnerCore

/// JobRunner 端到端测试 —— 覆盖需求文档里要求的 5 个运行场景。
final class JobRunnerTests: XCTestCase {

    // MARK: - 装置

    private func installMock(
        _ services: AppServices,
        _ mock: MockAIProvider,
        providerID: String = TestSupport.mockProviderID,
        model: String = TestSupport.mockModel
    ) {
        services.factory.registerOverride(mock, providerID: providerID, model: model)
    }

    /// 手动把一个步骤"做完" (用于构造崩溃前的历史)。
    private func completeStep(
        _ services: AppServices,
        taskID: String,
        index: Int,
        text: String
    ) throws {
        let step = try XCTUnwrap(services.steps.fetch(taskID: taskID, index: index))
        try services.steps.markRunning(stepID: step.id, provider: "mock", model: TestSupport.mockModel)
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step.id,
                taskID: taskID,
                output: .object(["text": .string(text)]),
                provider: "mock",
                model: TestSupport.mockModel,
                durationMs: 1,
                checkpoint: Checkpoint(taskID: taskID, completedStep: index, nextStep: index + 1),
                newCurrentStep: index + 1
            )
        )
    }

    // MARK: - 场景 A: 全部成功

    func testScenarioA_allStepsSucceedAndTaskCompletes() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)

        let mock = MockAIProvider(id: "mock", model: TestSupport.mockModel)
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(settled.currentStep, 5)
        XCTAssertEqual(mock.calls, 5, "每个步骤恰好调用一次")

        let steps = try services.steps.fetchAll(taskID: task.id)
        XCTAssertEqual(steps.count, 5)
        XCTAssertTrue(steps.allSatisfy { $0.status == .completed })

        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 5)
        // 6 条 = 创建任务时的初始检查点 + 5 次成功提交
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), 6)
    }

    // MARK: - 场景 B: 一次超时后重试成功

    func testScenarioB_timeoutIsRetriedThenContinues() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        // 第 1、2 步成功, 第 3 步第一次超时, 之后成功
        let mock = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            script: [.ok, .ok, .timeout],
            fallback: .ok
        )
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(mock.calls, 4, "第 3 步应重试一次 (3 次正常 + 1 次重试)")

        let third = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 2))
        XCTAssertEqual(third.status, .completed)
        XCTAssertGreaterThanOrEqual(third.retryCount, 1)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 3)
    }

    func testTimeoutBeyondBudgetStillFallsBackToBackup() async throws {
        var settings = TestSupport.mockSettings(
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ],
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ]
        )
        settings.retry.maxRetries = 1

        let services = try TestSupport.makeServices(settings: settings)
        let task = try TestSupport.makeTask(
            services, steps: 1, primaryProvider: "p1", primaryModel: "m1"
        )

        let alwaysTimeout = MockAIProvider(id: "p1", model: "m1", fallback: .timeout)
        let healthy = MockAIProvider(id: "p2", model: "m2", fallback: .success(text: "backup result"))
        installMock(services, alwaysTimeout, providerID: "p1", model: "m1")
        installMock(services, healthy, providerID: "p2", model: "m2")

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(
            try services.steps.fetch(taskID: task.id, index: 0)?.provider, "p2",
            "p1 重试预算耗尽后应切到 p2"
        )
    }

    // MARK: - 场景 C: 崩溃后从断点恢复

    func testScenarioC_crashRecoveryResumesFromInterruptedStep() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 4)

        // 崩溃前: 前两步已提交, 第 3 步处于 running
        try completeStep(services, taskID: task.id, index: 0, text: "pre-crash step 0")
        try completeStep(services, taskID: task.id, index: 1, text: "pre-crash step 1")
        let third = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 2))
        try services.steps.markRunning(stepID: third.id, provider: "mock", model: TestSupport.mockModel)
        try services.tasks.updateStatus(id: task.id, to: .running)

        // --- 进程重启 ---
        let report = try services.recovery.recover()
        XCTAssertEqual(report.interruptedSteps, 1)
        XCTAssertTrue(report.recoverableTaskIDs.contains(task.id))
        XCTAssertEqual(try services.steps.fetch(id: third.id)?.status, .interrupted)

        let mock = MockAIProvider(id: "mock", model: TestSupport.mockModel)
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)

        // ★ 关键断言: 只重跑了中断的第 3 步与第 4 步, 前两步绝不重跑 ★
        XCTAssertEqual(mock.calls, 2, "只应执行 index 2 和 3 两步")

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        XCTAssertEqual(step0.output?["text"]?.stringValue, "pre-crash step 0",
                       "崩溃前的结果必须原封不动")
        XCTAssertEqual(try services.steps.fetch(taskID: task.id, index: 1)?.status, .completed)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 4)
    }

    // MARK: - 场景 D: Primary 不可用 → Backup

    func testScenarioD_fallsBackToBackupWhenPrimaryIsUnavailable() async throws {
        let settings = TestSupport.mockSettings(
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ],
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ]
        )
        let services = try TestSupport.makeServices(settings: settings)
        let task = try TestSupport.makeTask(
            services, steps: 2, primaryProvider: "p1", primaryModel: "m1"
        )

        let broken = MockAIProvider(id: "p1", model: "m1", fallback: .serverError)
        let backup = MockAIProvider(id: "p2", model: "m2", fallback: .success(text: "backup ok"))
        installMock(services, broken, providerID: "p1", model: "m1")
        installMock(services, backup, providerID: "p2", model: "m2")

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertGreaterThan(broken.calls, 0, "应先尝试 primary")
        XCTAssertGreaterThan(backup.calls, 0, "primary 不可用后必须切到 backup")

        let steps = try services.steps.fetchAll(taskID: task.id)
        XCTAssertTrue(steps.allSatisfy { $0.provider == "p2" }, "最终都应由 backup 完成")
    }

    func testFallbackDoesNotOscillateBetweenBackends() async throws {
        let settings = TestSupport.mockSettings(
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ],
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ]
        )
        let services = try TestSupport.makeServices(settings: settings)
        let task = try TestSupport.makeTask(
            services, steps: 1, primaryProvider: "p1", primaryModel: "m1"
        )

        let broken1 = MockAIProvider(id: "p1", model: "m1", fallback: .serverError)
        let broken2 = MockAIProvider(id: "p2", model: "m2", fallback: .serverError)
        installMock(services, broken1, providerID: "p1", model: "m1")
        installMock(services, broken2, providerID: "p2", model: "m2")

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .failed)
        // 每个 backend 只应被尝试有限次 —— 不允许 A→B→A→B 无限打转
        XCTAssertLessThanOrEqual(broken1.calls, 3, "p1 不得被反复回头重试")
        XCTAssertLessThanOrEqual(broken2.calls, 3, "p2 不得被反复回头重试")
    }

    // MARK: - 场景 E: 认证失败 → 暂停, 绝不重试

    func testScenarioE_authenticationPausesTaskImmediately() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        let mock = MockAIProvider(id: "mock", model: TestSupport.mockModel, fallback: .authError)
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .paused, "认证失败必须暂停等用户处理")
        XCTAssertEqual(mock.calls, 1, "认证失败绝不能被重试")
        XCTAssertEqual(settled.errorClass, AppError.authentication.eventName)
        XCTAssertNotNil(settled.errorMessage)
    }

    func testBillingRequiredPausesInsteadOfRetrying() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        let mock = MockAIProvider(id: "mock", model: TestSupport.mockModel, fallback: .billingError)
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .paused)
        XCTAssertEqual(mock.calls, 1, "余额耗尽不该重试")
        XCTAssertEqual(settled.errorClass, AppError.billingRequired.eventName)
    }

    // MARK: - 幂等与并发

    func testRepeatedStartDoesNotDuplicateExecution() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        let mock = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            fallback: .latency(seconds: 0.08)
        )
        installMock(services, mock)

        // 连点三次 Start
        await services.runner.start(taskID: task.id)
        await services.runner.start(taskID: task.id)
        await services.runner.start(taskID: task.id)

        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(mock.calls, 3, "重复启动不得让步骤被执行两次")
    }

    func testResumeAfterPauseDoesNotRerunCompletedSteps() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 4)

        let mock = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            fallback: .latency(seconds: 0.06)
        )
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        _ = try await TestSupport.waitUntil { mock.calls >= 2 }
        await services.runner.pause(taskID: task.id)

        let paused = try await TestSupport.waitUntilSettled(services, taskID: task.id)
        XCTAssertEqual(paused.status, .paused)
        let callsAtPause = mock.calls
        XCTAssertLessThan(callsAtPause, 4, "应当还没跑完")

        // 恢复
        await services.runner.start(taskID: task.id)
        let resumed = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(mock.calls, 4, "总共只应有 4 次调用 —— 已完成步骤未重跑")
        XCTAssertEqual(resumed.currentStep, 4)
    }

    // MARK: - 取消

    func testCancelPreservesHistoryAndCheckpoints() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 8)

        let mock = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            fallback: .latency(seconds: 0.05)
        )
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        _ = try await TestSupport.waitUntil { mock.calls >= 2 }
        await services.runner.cancel(taskID: task.id)

        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        XCTAssertEqual(settled.status, .cancelled)
        XCTAssertLessThan(settled.currentStep, 8)

        // 历史必须保留
        let completedCount = try services.steps
            .fetchAll(taskID: task.id)
            .filter { $0.status == .completed }
            .count
        XCTAssertGreaterThan(completedCount, 0, "取消不得删除已完成结果")
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), completedCount + 1)
        // +1 是初始检查点
    }

    // MARK: - 完整生命周期 (需求第 45 节的验收场景)

    func testFullLifecycleWithInterruptionAndRecovery() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "Long Research", steps: 10)

        // 阶段 1: 正常跑 4 步
        let phase1 = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            fallback: .latency(seconds: 0.03)
        )
        installMock(services, phase1)

        await services.runner.start(taskID: task.id)
        _ = try await TestSupport.waitUntil { phase1.calls >= 4 }
        // 用「暂停」而不是「取消」: 取消现在是终态、不可恢复 (A7 统一了语义)。
        await services.runner.pause(taskID: task.id)
        _ = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        let afterInterruption = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(afterInterruption.status, .paused)

        let completedBefore = try services.steps
            .fetchAll(taskID: task.id)
            .filter { $0.status == .completed }
            .count
        XCTAssertGreaterThan(completedBefore, 0)
        // 中断不得吞掉未完成的步骤: 所有未完成步骤必须仍然可执行
        XCTAssertEqual(
            try services.steps.executableCount(taskID: task.id),
            10 - completedBefore,
            "中断后未完成步骤必须保持可执行, 不能有步骤被误标成 failed"
        )

        // 阶段 2: 从断点继续
        try services.tasks.updateStatus(id: task.id, to: .running)
        let phase2 = MockAIProvider(id: "mock", model: TestSupport.mockModel)
        installMock(services, phase2)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(settled.currentStep, 10)
        XCTAssertEqual(phase2.calls, 10 - completedBefore, "第二阶段只补跑剩余步骤")
        XCTAssertEqual(afterInterruption.currentStep, completedBefore)

        // 日志可查
        let events = try services.events.list(taskID: task.id, limit: 200)
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.contains { $0.eventType == .stepCompleted })
        XCTAssertTrue(events.contains { $0.eventType == .checkpointSaved })
    }
}

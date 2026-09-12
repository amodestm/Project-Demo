import XCTest
@testable import AIRunnerCore

/// PHASE A 正确性回归测试。
///
/// 每个测试对应一个**已确认存在**的缺陷。修复前它们必须失败 —— 这是
/// "先复现、再修" 的证据，而不是事后补写的装饰性测试。
final class WebExecutionRegressionTests: XCTestCase {

    // MARK: - 装置

    private func makeWebServices(
        clipboard: (any ClipboardServicing)? = nil
    ) throws -> AppServices {
        var settings = TestSupport.mockSettings()
        settings.defaultExecutionMode = .chatGPTWeb
        return try AppServices(
            database: try Database.inMemory(),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: settings,
            clipboard: clipboard ?? InMemoryClipboard(),
            browser: RecordingBrowserLauncher(),
            echoLogsToConsole: false
        )
    }

    @discardableResult
    private func makeWebTask(_ services: AppServices, steps: Int) throws -> AITask {
        try TestSupport.makeTask(
            services, goal: "3 步长任务", steps: steps, executionMode: .chatGPTWeb
        )
    }

    /// 走完一轮完整的 Web 步骤: prepare → 写剪贴板 → import。
    @discardableResult
    private func runOneRound(
        _ services: AppServices,
        taskID: String,
        clipboard: InMemoryClipboard,
        result: String
    ) async throws -> ImportedResult {
        _ = try await services.web.prepareStep(taskID: taskID)
        clipboard.writeString(result)
        return try await services.web.importClipboardResult(taskID: taskID)
    }

    // MARK: - A1: 重复 Paste 绝不能推进下一步

    func testSecondPasteDoesNotCompleteNextPendingStep() async throws {
        let clipboard = InMemoryClipboard()
        let services = try makeWebServices(clipboard: clipboard)
        let task = try makeWebTask(services, steps: 3)

        // 第 1 步: 正常走完一轮
        let first = try await runOneRound(
            services, taskID: task.id, clipboard: clipboard, result: "result-1"
        )
        XCTAssertEqual(first.stepIndex, 0)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1)

        // 用户忘了已经提交过, 又点了一次「粘贴结果」。
        // 剪贴板里还是 result-1。
        // ★ 必须失败 —— 绝不能把它当成第 2 步的结果 ★
        do {
            _ = try await services.web.importClipboardResult(taskID: task.id)
            XCTFail("没有 prepared 步骤时导入结果必须被拒绝, 否则 result-1 会污染第 2 步")
        } catch let error as WebExecutionError {
            guard case .noStepAwaitingResult = error else {
                return XCTFail("错误类型应为 noStepAwaitingResult, 实际: \(error)")
            }
        } catch {
            XCTFail("抛出了非 WebExecutionError: \(error)")
        }

        // ---- 第 2 步必须完好无损 ----
        let step2 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        XCTAssertEqual(step2.status, .pending, "第 2 步不得被污染")
        XCTAssertNil(step2.output)
        XCTAssertNil(step2.preparedAt)

        // ---- 第 3 步同样不能被动 ----
        XCTAssertEqual(try services.steps.fetch(taskID: task.id, index: 2)?.status, .pending)

        // ---- 进度与检查点不得前进 ----
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 1)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.completedStep, 0)

        // 只有 2 条检查点: 初始 + 第 1 步
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), 2)
    }

    func testImportWithoutAnyPreparedStepIsRejected() async throws {
        let services = try makeWebServices(clipboard: InMemoryClipboard(seed: "stale"))
        let task = try makeWebTask(services, steps: 2)

        // 从未 prepare 过任何步骤
        do {
            _ = try await services.web.importClipboardResult(taskID: task.id)
            XCTFail("没有任何 prepared 步骤时, 导入必须被拒绝")
        } catch let error as WebExecutionError {
            guard case .noStepAwaitingResult = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 0)
        XCTAssertEqual(try services.steps.fetch(taskID: task.id, index: 0)?.status, .pending)
    }

    // MARK: - A2: acceptResult 必须校验步骤状态

    func testAcceptResultRejectsPendingStep() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 2)
        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        XCTAssertEqual(step0.status, .pending)

        do {
            _ = try await services.web.acceptResult(
                taskID: task.id, stepID: step0.id, result: "绕过 prepare 直接提交"
            )
            XCTFail("pending 步骤不得被直接标记完成")
        } catch let error as WebExecutionError {
            guard case .stepNotInExpectedState = error else {
                return XCTFail("错误类型应为 stepNotInExpectedState, 实际: \(error)")
            }
        } catch {
            XCTFail("抛出了非 WebExecutionError: \(error)")
        }

        XCTAssertEqual(try services.steps.fetch(id: step0.id)?.status, .pending)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 0)
    }

    func testAcceptResultRejectsCompletedStep() async throws {
        let clipboard = InMemoryClipboard()
        let services = try makeWebServices(clipboard: clipboard)
        let task = try makeWebTask(services, steps: 2)

        let prepared = try await services.web.prepareStep(taskID: task.id)
        _ = try await services.web.acceptResult(
            taskID: task.id, stepID: prepared.stepID, result: "first"
        )

        let checkpointsAfterFirst = try services.checkpoints.count(taskID: task.id)

        // 对同一个已完成的步骤再提交一次
        do {
            _ = try await services.web.acceptResult(
                taskID: task.id, stepID: prepared.stepID, result: "second"
            )
            XCTFail("已完成步骤不得被重复提交")
        } catch let error as WebExecutionError {
            guard case .stepNotInExpectedState = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }

        // 输出必须保持第一次的内容
        XCTAssertEqual(try services.steps.fetch(id: prepared.stepID)?.output?["text"]?.stringValue,
                       "first")
        // 且不得产生新检查点
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), checkpointsAfterFirst)
    }

    func testAcceptResultRejectsInterruptedStep() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 2)

        // 手工造一个 interrupted 步骤
        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step0.id, provider: nil, model: nil)
        _ = try services.recovery.recover()
        XCTAssertEqual(try services.steps.fetch(id: step0.id)?.status, .interrupted)

        do {
            _ = try await services.web.acceptResult(
                taskID: task.id, stepID: step0.id, result: "不该被接受"
            )
            XCTFail("interrupted 步骤不得被直接标记完成")
        } catch let error as WebExecutionError {
            guard case .stepNotInExpectedState = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }

        XCTAssertEqual(try services.steps.fetch(id: step0.id)?.status, .interrupted)
    }

    // MARK: - A3: commitSuccessfulStep 必须是 CAS

    func testDuplicateCommitDoesNotCreateSecondCheckpoint() throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 2)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))

        // 第一次: 正常提交 (running → completed)
        try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step.id, taskID: task.id,
                output: .object(["text": .string("first")]),
                provider: "p", model: "m", durationMs: 1,
                checkpoint: Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1),
                newCurrentStep: 1,
                expectedStatuses: [.running]
            )
        )
        let checkpointCount = try services.checkpoints.count(taskID: task.id)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1)

        // 第二次: 对同一个已完成的步骤再提交一次 (stale result)
        XCTAssertThrowsError(
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("second")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1),
                    newCurrentStep: 1,
                    expectedStatuses: [.running]
                )
            ),
            "对已 completed 的步骤提交必须抛错"
        )

        // ★ 关键: stale 提交绝不能产生新检查点 ★
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), checkpointCount)
        // 输出保持第一次的
        XCTAssertEqual(try services.steps.fetch(id: step.id)?.output?["text"]?.stringValue, "first")
    }

    func testStaleCommitDoesNotAdvanceTaskProgress() throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        // 完成第 1 步
        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step0.id, provider: "p", model: "m")
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step0.id, taskID: task.id,
                output: .object(["text": .string("s0")]),
                provider: "p", model: "m", durationMs: 1,
                checkpoint: Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1),
                newCurrentStep: 1,
                expectedStatuses: [.running]
            )
        )
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1)

        // 试图用一个陈旧结果把进度推回去 (或推到错误位置)
        let step1 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        XCTAssertThrowsError(
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step1.id, taskID: task.id,
                    output: .object(["text": .string("跳步")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: 1, nextStep: 2),
                    newCurrentStep: 2,
                    expectedStatuses: [.running]   // step1 还是 pending, 不满足
                )
            ),
            "pending 步骤不得被直接提交"
        )

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1,
                       "current_step 不得被非法提交推进")
    }

    func testCommitRejectsCurrentStepMismatch() throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step0.id, provider: "p", model: "m")

        // step.index(0) 与 newCurrentStep(5) 不自洽 —— 必须报错而不是静默写入
        XCTAssertThrowsError(
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step0.id, taskID: task.id,
                    output: .object(["text": .string("x")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1),
                    newCurrentStep: 5,
                    expectedStatuses: [.running]
                )
            ),
            "newCurrentStep 与步骤序号不自洽时必须拒绝"
        )
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 0)
        XCTAssertEqual(try services.steps.fetch(id: step0.id)?.status, .running,
                       "事务必须整体回滚")
    }

    // MARK: - A5: 迁移只推进自己的版本号

    func testMigrationReachesCurrentVersion() throws {
        let db = try Database.inMemory()

        // 模拟"只走到 V1"的旧库
        try DatabaseMigrator.migrate(db)
        XCTAssertEqual(try db.scalarInt("PRAGMA user_version;"),
                       DatabaseMigrator.currentVersion)

        // 再跑一次必须幂等
        try DatabaseMigrator.migrate(db)
        XCTAssertEqual(try db.scalarInt("PRAGMA user_version;"),
                       DatabaseMigrator.currentVersion)
    }

    func testMigrationBackfillsMissingV3TablesAfterVersionRollback() throws {
        let db = try Database.inMemory()
        try DatabaseMigrator.migrate(db)
        XCTAssertTrue(try DatabaseMigrator.tableExists(db, table: "codex_task_bindings"))

        // 模拟"版本回退到 2 且 V3 的表缺失" —— 如果 migration 写的是 currentVersion
        // 而不是自己的版本号, 这种情况就再也补不回来了。
        try db.execute("DROP TABLE codex_resume_leases;")
        try db.execute("DROP TABLE codex_task_bindings;")
        try db.execute("PRAGMA user_version = 2;")

        try DatabaseMigrator.migrate(db)

        XCTAssertTrue(try DatabaseMigrator.tableExists(db, table: "codex_task_bindings"))
        XCTAssertTrue(try DatabaseMigrator.tableExists(db, table: "codex_resume_leases"))
        XCTAssertTrue(try DatabaseMigrator.tableExists(db, table: "account_rotation_state"))
        XCTAssertEqual(try db.scalarInt("PRAGMA user_version;"), DatabaseMigrator.currentVersion)
    }

    func testV3MigrationPreservesExistingTaskData() throws {
        let db = try Database.inMemory()
        // 先建 V1/V2 并存一些数据, 再跑完整迁移
        try DatabaseMigrator.migrate(db)

        let tasks = TaskRepository(db: db)
        let steps = StepRepository(db: db)
        let task = AITask(name: "旧任务", goal: "旧目标", executionMode: .chatGPTWeb,
                          totalSteps: 1)
        try tasks.insert(task)
        try steps.insertBatch(
            TaskPlanner.defaultPlan(taskID: task.id, numberOfSteps: 1, goal: "旧目标")
        )

        // 再跑迁移 (相当于"从 v2 升级") 不得破坏既有行
        try DatabaseMigrator.migrate(db)

        XCTAssertEqual(try tasks.fetch(id: task.id)?.name, "旧任务")
        XCTAssertEqual(try steps.count(taskID: task.id), 1)
        XCTAssertTrue(try DatabaseMigrator.tableExists(db, table: "codex_task_bindings"))
    }

    // MARK: - A6: 崩溃窗口 —— failed 步骤 + 任务仍是 running

    func testRecoveryStopsTaskWhenFailedStepExists() throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        // 模拟: step 被 markFailed → App 被 kill → task 仍停在 running
        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markFailed(
            stepID: step0.id, error: "上游超时", errorClass: "TIMEOUT"
        )
        try services.tasks.updateStatus(id: task.id, to: .running)

        let report = try services.recovery.recover()

        XCTAssertEqual(report.reconciledFailedTasks, 1)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .failed,
                       "存在失败步骤时必须把任务置为 failed, 而不是继续往后跑")
        XCTAssertFalse(report.recoverableTaskIDs.contains(task.id),
                       "该任务不得被列为可自动继续")
        XCTAssertEqual(try services.steps.fetch(id: step0.id)?.status, .failed,
                       "失败步骤必须原样保留, 便于用户查看原因")
    }

    func testRecoveryDoesNotRunLaterStepsPastAFailure() throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 4)

        // step0 completed → step1 failed → step2/3 pending, task running
        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step0.id, provider: "p", model: "m")
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step0.id, taskID: task.id,
                output: .object(["text": .string("ok")]),
                provider: "p", model: "m", durationMs: 1,
                checkpoint: Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1),
                newCurrentStep: 1,
                expectedStatuses: [.running]
            )
        )
        let step1 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        try services.steps.markFailed(stepID: step1.id, error: "boom", errorClass: "FATAL_ERROR")
        try services.tasks.updateStatus(id: task.id, to: .running)

        let report = try services.recovery.recover()

        XCTAssertEqual(report.reconciledFailedTasks, 1)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .failed)
        // ★ 后面的 pending 步骤绝不能被自动执行 ★
        XCTAssertEqual(try services.steps.fetch(taskID: task.id, index: 2)?.status, .pending)
        XCTAssertEqual(try services.steps.fetch(taskID: task.id, index: 3)?.status, .pending)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1,
                       "进度不得越过失败的那一步")
    }

    // MARK: - A7: failed / cancelled 的恢复语义

    func testCancelledIsATrueTerminalState() {
        XCTAssertFalse(TaskStatus.cancelled.canTransition(to: .running),
                       "取消是用户的明确决定, 不该被「继续」直接复活")
        XCTAssertTrue(TaskStatus.cancelled.allowedTransitions.isEmpty)
        XCTAssertTrue(TaskStatus.cancelled.isTerminal)
    }

    func testFailedOnlyTransitionsToRunning() {
        XCTAssertTrue(TaskStatus.failed.canTransition(to: .running),
                      "failed → running 合法, 但必须经由 retryFailedTask")
        XCTAssertFalse(TaskStatus.failed.canTransition(to: .completed))
        XCTAssertFalse(TaskStatus.failed.canTransition(to: .paused))
    }

    func testRunnerRefusesToStartFailedTaskWithoutReset() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 2)

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markFailed(stepID: step0.id, error: "boom", errorClass: "FATAL_ERROR")
        try services.tasks.updateStatus(id: task.id, to: .running)
        try services.tasks.updateStatus(id: task.id, to: .failed)

        let mock = MockAIProvider(id: TestSupport.mockProviderID, model: TestSupport.mockModel)
        services.factory.registerOverride(
            mock, providerID: TestSupport.mockProviderID, model: TestSupport.mockModel
        )

        await services.runner.start(taskID: task.id)
        try await Task.sleep(nanoseconds: 250_000_000)   // 给 runner 一点时间

        XCTAssertEqual(mock.calls, 0, "failed 任务不得被直接启动")
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .failed)
        XCTAssertEqual(try services.steps.fetch(id: step0.id)?.status, .failed,
                       "失败步骤不得被跳过或改写")
        XCTAssertEqual(try services.steps.fetch(taskID: task.id, index: 1)?.status, .pending)
    }

    func testResetFailedStepsMakesThemRunnableAgain() throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        let step1 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        try services.steps.markFailed(stepID: step0.id, error: "boom", errorClass: "FATAL_ERROR")
        try services.steps.markFailed(stepID: step1.id, error: "boom", errorClass: "FATAL_ERROR")

        XCTAssertEqual(try services.steps.failedCount(taskID: task.id), 2)
        XCTAssertEqual(try services.steps.firstFailedStep(taskID: task.id)?.index, 0)

        let reset = try services.steps.resetFailedSteps(taskID: task.id)

        XCTAssertEqual(reset, 2)
        XCTAssertEqual(try services.steps.failedCount(taskID: task.id), 0)
        XCTAssertEqual(try services.steps.fetch(id: step0.id)?.status, .pending)
        XCTAssertNil(try services.steps.fetch(id: step0.id)?.lastError)
        XCTAssertEqual(
            try services.steps.executableCount(taskID: task.id), 3,
            "重置后三步都重新可执行"
        )
    }
}

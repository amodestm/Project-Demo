import XCTest
@testable import AIRunnerCore

final class CrashRecoveryTests: XCTestCase {

    // MARK: - 步骤状态恢复

    func testRunningStepBecomesInterrupted() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)

        // 模拟: 第 2 步已开始执行, 此时进程被强杀 (checkpoint 从未提交)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        try services.steps.markRunning(stepID: step.id, provider: "p1", model: "m1")

        let report = try services.recovery.recover()

        XCTAssertEqual(report.interruptedSteps, 1)
        XCTAssertEqual(try services.steps.fetch(id: step.id)?.status, .interrupted)
        XCTAssertEqual(try services.steps.fetch(id: step.id)?.errorClass, "INTERRUPTED")
    }

    func testRunningTaskRemainsRunningAfterRecovery() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)
        try services.tasks.updateStatus(id: task.id, to: .running)

        let report = try services.recovery.recover()

        XCTAssertEqual(
            try services.tasks.fetch(id: task.id)?.status, .running,
            "任务必须保持 running —— 它本来就该继续跑"
        )
        XCTAssertTrue(report.recoverableTaskIDs.contains(task.id))
    }

    func testInterruptedStepIsStillExecutable() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        try services.steps.markRunning(stepID: step.id, provider: "p1", model: "m1")

        _ = try services.recovery.recover()

        let next = try services.steps.nextExecutableStep(taskID: task.id)
        XCTAssertEqual(next?.index, 0, "前面的 pending 步骤先执行")

        // 把第 0 步标完成, 第 1 步 (interrupted) 就应成为下一个可执行步骤
        try services.steps.markFailed(stepID: step.id, error: "", errorClass: "")
        try services.steps.markPending(stepID: step.id)
        XCTAssertEqual(try services.steps.nextExecutableStep(taskID: task.id)?.index, 0)

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markFailed(stepID: step0.id, error: "", errorClass: "")
        try services.steps.markPending(stepID: step0.id)

        let following = try services.steps.nextExecutableStep(taskID: task.id)
        XCTAssertEqual(following?.index, 0)
    }

    func testInterruptedStepIsReturnedByNextExecutableQuery() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        // 前两步正常完成
        for index in 0..<2 {
            let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: index))
            try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("done \(index)")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: index, nextStep: index + 1),
                    newCurrentStep: index + 1
                )
            )
        }

        // 第 3 步被中断
        let third = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 2))
        try services.steps.markRunning(stepID: third.id, provider: "p", model: "m")
        _ = try services.recovery.recover()

        let next = try services.steps.nextExecutableStep(taskID: task.id)
        XCTAssertEqual(next?.index, 2, "interrupted 步骤必须被视为可执行")
    }

    // MARK: - ★ 幂等性 ★

    func testCompletedStepsAreNeverReturnedAsExecutable() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)

        for index in 0..<3 {
            let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: index))
            try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("output \(index)")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: index, nextStep: index + 1),
                    newCurrentStep: index + 1
                )
            )
        }

        let next = try services.steps.nextExecutableStep(taskID: task.id)
        XCTAssertEqual(next?.index, 3, "必须从第 4 步继续, 不能回头重跑前 3 步")
    }

    func testExecutableQueryNeverYieldsCompletedOrFailedSteps() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 4)

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step0.id, provider: "p", model: "m")
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step0.id, taskID: task.id,
                output: .object(["text": .string("ok")]),
                provider: "p", model: "m", durationMs: 1,
                checkpoint: Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1),
                newCurrentStep: 1
            )
        )

        let step1 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        try services.steps.markFailed(stepID: step1.id, error: "boom", errorClass: "FATAL_ERROR")

        let executable = try services.steps.fetchAll(taskID: task.id).filter { $0.status.isExecutable }
        XCTAssertEqual(executable.map(\.index), [2, 3])
        XCTAssertFalse(executable.contains { $0.index <= 1 })
    }

    // MARK: - 卡死任务修正

    func testTaskWithNoRemainingStepsIsCorrectedToCompleted() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 2)

        for index in 0..<2 {
            let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: index))
            try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("ok")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: index, nextStep: index + 1),
                    newCurrentStep: index + 1
                )
            )
        }

        // 全部步骤完成但状态还停在 running (退出时没来得及写)
        try services.tasks.updateStatus(id: task.id, to: .running)

        let report = try services.recovery.recover()

        XCTAssertEqual(report.completedButStuckTasks, 1)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .completed)
        XCTAssertFalse(report.recoverableTaskIDs.contains(task.id))
    }

    // MARK: - 边界与幂等

    func testPausedTaskIsNotAutoRecovered() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)
        try services.tasks.updateStatus(id: task.id, to: .paused)

        let report = try services.recovery.recover()

        XCTAssertFalse(
            report.recoverableTaskIDs.contains(task.id),
            "用户主动暂停的任务不该被自动拉起"
        )
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .paused)
    }

    func testRecoveryIsIdempotent() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
        try services.tasks.updateStatus(id: task.id, to: .running)

        let first = try services.recovery.recover()
        let second = try services.recovery.recover()

        XCTAssertEqual(first.interruptedSteps, 1)
        XCTAssertEqual(second.interruptedSteps, 0, "第二次恢复不应再发现 running 步骤")
        XCTAssertEqual(second.recoverableTaskIDs, first.recoverableTaskIDs, "可恢复任务集合应稳定")
        XCTAssertEqual(try services.steps.fetch(id: step.id)?.status, .interrupted)
    }

    func testRecoveryWorksWithNothingToDo() throws {
        let services = try TestSupport.makeServices()
        let report = try services.recovery.recover()

        XCTAssertEqual(report.interruptedSteps, 0)
        XCTAssertTrue(report.recoverableTaskIDs.isEmpty)
        XCTAssertFalse(report.didRecoverAnything)
        XCTAssertTrue(report.summary.contains("无需恢复"))
    }

    // MARK: - 事件留痕

    func testRecoveryEmitsAppCrashRecoveryEvent() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")

        _ = try services.recovery.recover()

        let events = try services.events.list(taskID: nil, limit: 50)
        XCTAssertTrue(
            events.contains { $0.eventType == .appCrashRecovery },
            "必须留下 APP_CRASH_RECOVERY 事件"
        )
    }

    func testRecoveryEmitsCompletionEventWhenTasksRecovered() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)
        try services.tasks.updateStatus(id: task.id, to: .running)

        _ = try services.recovery.recover()

        let events = try services.events.list(limit: 50)
        XCTAssertTrue(events.contains { $0.eventType == .recoveryCompleted })
    }
}

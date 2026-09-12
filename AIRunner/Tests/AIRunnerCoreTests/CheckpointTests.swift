import XCTest
@testable import AIRunnerCore

final class CheckpointTests: XCTestCase {

    // MARK: - 模型层

    func testInitialCheckpointStartsBeforeFirstStep() {
        let checkpoint = Checkpoint.initial(taskID: "t1")
        XCTAssertEqual(checkpoint.completedStep, -1, "尚未完成任何步骤")
        XCTAssertEqual(checkpoint.nextStep, 0, "应当从第 0 步开始")
    }

    func testCheckpointNextStepIsCompletedPlusOne() async throws {
        let services = try TestSupport.makeServices()

        let checkpoint = await services.checkpointManager.makeCheckpoint(
            taskID: "t1",
            completedStep: 0,
            previous: nil,
            output: .object(["text": .string("first result")]),
            provider: "p1",
            model: "m1"
        )

        XCTAssertEqual(checkpoint.completedStep, 0)
        XCTAssertEqual(checkpoint.nextStep, 1)
    }

    func testWorkingSummaryAccumulatesAcrossSteps() async throws {
        let services = try TestSupport.makeServices()
        let manager = services.checkpointManager

        let first = await manager.makeCheckpoint(
            taskID: "t1", completedStep: 0, previous: nil,
            output: .object(["text": .string("alpha findings")]),
            provider: "p1", model: "m1"
        )
        let second = await manager.makeCheckpoint(
            taskID: "t1", completedStep: 1, previous: first,
            output: .object(["text": .string("beta findings")]),
            provider: "p1", model: "m1"
        )

        let summary = try XCTUnwrap(second.workingSummary)
        XCTAssertTrue(summary.contains("alpha findings"), "摘要应累积上一步的内容")
        XCTAssertTrue(summary.contains("beta findings"), "摘要应包含本步内容")
    }

    func testWorkingSummaryIsTruncatedToBound() async throws {
        let services = try TestSupport.makeServices()
        let manager = services.checkpointManager

        var previous: Checkpoint? = nil
        let longText = String(repeating: "X", count: 900)

        for index in 0..<6 {
            previous = await manager.makeCheckpoint(
                taskID: "t1", completedStep: index, previous: previous,
                output: .object(["text": .string(longText)]),
                provider: "p1", model: "m1"
            )
        }

        let summary = try XCTUnwrap(previous?.workingSummary)
        XCTAssertLessThanOrEqual(summary.count, 1400, "摘要必须有上限, 否则会撑爆上下文窗口")
        XCTAssertTrue(summary.hasPrefix("[前文已截断]"), "超限时应保留尾部并标记")
    }

    func testStateTracksRecentStepsAndCount() async throws {
        let services = try TestSupport.makeServices()
        let manager = services.checkpointManager

        var previous: Checkpoint? = nil
        for index in 0..<3 {
            previous = await manager.makeCheckpoint(
                taskID: "t1", completedStep: index, previous: previous,
                output: .object(["text": .string("step \(index)")]),
                provider: "p1", model: "m1"
            )
        }

        let state = try XCTUnwrap(previous?.state)
        XCTAssertEqual(state["completedCount"]?.intValue, 3)
        XCTAssertEqual(state["recentSteps"]?.arrayValue?.count, 3)
        XCTAssertEqual(state["lastProvider"]?.stringValue, "p1")
    }

    // MARK: - 持久化层

    func testLatestCheckpointReturnsHighestCompletedStep() async throws {
        let services = try TestSupport.makeServices()
        // checkpoints.task_id 有外键约束, 必须挂到真实任务上
        let task = try TestSupport.makeTask(services, steps: 3)

        try services.checkpoints.insert(
            Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1, workingSummary: "one")
        )
        try services.checkpoints.insert(
            Checkpoint(taskID: task.id, completedStep: 1, nextStep: 2, workingSummary: "two")
        )
        try services.checkpoints.insert(
            Checkpoint(taskID: task.id, completedStep: 2, nextStep: 3, workingSummary: "three")
        )

        let latest = try services.checkpoints.latest(taskID: task.id)
        XCTAssertEqual(latest?.completedStep, 2)
        XCTAssertEqual(latest?.nextStep, 3)
        XCTAssertEqual(latest?.workingSummary, "three")
    }

    func testLatestReturnsNilWhenNeverCheckpointed() throws {
        let services = try TestSupport.makeServices()
        XCTAssertNil(try services.checkpoints.latest(taskID: "nonexistent"))
    }

    func testInitialCheckpointDoesNotShadowRealProgress() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        // 起始检查点 completedStep = -1
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.completedStep, -1)

        try services.checkpoints.insert(
            Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1)
        )

        XCTAssertEqual(
            try services.checkpoints.latest(taskID: task.id)?.completedStep, 0,
            "真实进度必须盖过起始检查点"
        )
    }

    // MARK: - ★ 原子提交 ★

    func testCommitSuccessfulStepWritesStepCheckpointAndProgressTogether() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))

        try services.steps.markRunning(stepID: step.id, provider: "p1", model: "m1")

        let checkpoint = Checkpoint(
            taskID: task.id, completedStep: 0, nextStep: 1, workingSummary: "done step 1"
        )
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step.id,
                taskID: task.id,
                output: .object(["text": .string("step one output")]),
                provider: "p1",
                model: "m1",
                durationMs: 42,
                checkpoint: checkpoint,
                newCurrentStep: 1
            )
        )

        // 1) 步骤标记完成并写入输出
        let reloadedStep = try XCTUnwrap(services.steps.fetch(id: step.id))
        XCTAssertEqual(reloadedStep.status, .completed)
        XCTAssertEqual(reloadedStep.output?["text"]?.stringValue, "step one output")
        XCTAssertEqual(reloadedStep.durationMs, 42)

        // 2) 检查点已落库
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 1)

        // 3) 任务进度已推进
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1)

        // 4) 三者一致: 完成步骤数 == checkpoint 数
        let completedSteps = try services.steps.fetchAll(taskID: task.id).filter { $0.status == .completed }
        XCTAssertEqual(completedSteps.count, 1)
        // 共 2 条: 创建任务时的初始检查点 + 本次提交
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), 2)
    }

    func testCommitFailureLeavesNoPartialState() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 2)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))

        try services.steps.markRunning(stepID: step.id, provider: "p1", model: "m1")

        // 先占掉 checkpoint 的主键, 让事务内的 INSERT 必然失败
        let duplicatedID = "duplicate-checkpoint-id"
        try services.checkpoints.insert(
            Checkpoint(id: duplicatedID, taskID: task.id, completedStep: 0, nextStep: 1)
        )

        let colliding = Checkpoint(
            id: duplicatedID, taskID: task.id, completedStep: 0, nextStep: 1
        )

        XCTAssertThrowsError(
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("x")]),
                    provider: "p1", model: "m1", durationMs: 1,
                    checkpoint: colliding, newCurrentStep: 1
                )
            ),
            "主键冲突必须让整个事务失败"
        )

        // 事务回滚: 步骤不得被标为 completed
        XCTAssertEqual(
            try services.steps.fetch(id: step.id)?.status, .running,
            "事务失败后步骤状态必须回滚"
        )
        XCTAssertEqual(
            try services.tasks.fetch(id: task.id)?.currentStep, 0,
            "事务失败后任务进度必须回滚"
        )
    }
}

import Foundation

/// 恢复结果报告。
public struct RecoveryReport: Sendable, Equatable {

    /// 被标记为 interrupted 的步骤数。
    public var interruptedSteps: Int
    /// 需要继续执行的任务 ID。
    public var recoverableTaskIDs: [String]
    /// 对应任务名 (给 UI 显示)。
    public var recoverableTaskNames: [String]
    /// 检测到"实际已完成但状态未推进"并已修正的任务数。
    public var completedButStuckTasks: Int
    /// 恢复时被判定为"存在失败步骤"并置为 failed 的任务数。
    public var reconciledFailedTasks: Int = 0
    /// 正在等待用户手动操作的任务 (waitingForAccount / waitingForBrowser / waitingForUser)。
    ///
    /// 这些任务 **不会** 被自动恢复 —— 必须由用户点击 Resume。
    /// 尤其是 `waitingForAccount`: 只有当用户真的在浏览器里换好账号之后才有意义。
    public var awaitingUserTaskIDs: [String] = []
    public var summary: String

    public var didRecoverAnything: Bool {
        interruptedSteps > 0 || !recoverableTaskIDs.isEmpty
    }
}

/// 崩溃恢复。
///
/// App 启动时调用一次。处理三类残留状态:
///
/// 1. `task_steps.status = 'running'`
///    上一次运行在 HTTP 请求途中被杀。该步的 checkpoint 从未提交, 结果不可信 →
///    标记为 `interrupted` (可执行状态), 恢复后会重新执行。
///
/// 2. `tasks.status = 'running'`
///    保持 running 不变 (它本来就该继续跑), 交由 TaskManager 重新挂上 Runner。
///
/// 3. `tasks.status = 'running'` 但已无任何可执行步骤
///    说明任务其实已经跑完, 只是退出时没来得及写状态 → 修正为 `completed`。
///
/// 关于"避免同时启动两个 Runner": 恢复流程本身只改数据库状态, 不直接起 Runner;
/// 实际启动统一走 `JobRunner.start`, 而它受 `TaskExecutionRegistry` 保护。
public struct RecoveryManager: Sendable {

    private let tasks: TaskRepository
    private let steps: StepRepository
    private let checkpoints: CheckpointRepository
    private let logger: LoggerService

    public init(
        tasks: TaskRepository,
        steps: StepRepository,
        checkpoints: CheckpointRepository,
        logger: LoggerService
    ) {
        self.tasks = tasks
        self.steps = steps
        self.checkpoints = checkpoints
        self.logger = logger
    }

    public func recover() throws -> RecoveryReport {
        // 1) 收集非终态任务
        let unfinished = try tasks.fetchUnfinished()

        // 2) running step -> interrupted
        let interrupted = try steps.markRunningInterrupted()

        // 3) 决定哪些任务需要继续
        var recoverable: [AITask] = []
        var awaitingUser: [AITask] = []
        var stuckCompleted = 0
        var reconciledFailed = 0

        for task in unfinished {
            switch task.status {

            case .running, .queued:
                // ★ A6: 先看有没有失败步骤 ★
                //
                // 存在这样一个崩溃窗口: `markFailed(step)` → App 被 kill → task 仍是 running。
                // 如果只看 executableCount, 会得出"后面还有 pending 步骤, 继续跑"的结论,
                // 于是**跳过失败的那一步**接着往后执行 —— 后续结果全部建立在
                // 缺失的前置输入上, 而且不会报任何错。
                //
                // 正确做法: 停下来, 把任务如实标为 failed, 让用户决定是否重试。
                if let failedStep = try steps.firstFailedStep(taskID: task.id) {
                    let remainingAfterFailure =
                        (try? steps.executableCount(taskID: task.id)) ?? 0
                    do {
                        _ = try tasks.updateStatus(
                            id: task.id, to: .failed,
                            errorMessage: "步骤 \(failedStep.index + 1) 失败: "
                                + (failedStep.lastError ?? "未知原因"),
                            errorClass: failedStep.errorClass ?? "STEP_FAILED"
                        )
                        reconciledFailed += 1
                        logger.error(
                            .recoveryReconciledFailedTask,
                            "任务「\(task.name)」卡在失败步骤 (第 \(failedStep.index + 1) 步)。"
                            + "已把任务置为 failed 并停止自动推进 —— 后续 \(remainingAfterFailure) "
                            + "个步骤不会被跳过执行。如需继续请使用「重试失败步骤」。",
                            taskID: task.id, stepIndex: failedStep.index
                        )
                    } catch {
                        logger.record(error, eventType: .taskFailed, taskID: task.id)
                    }
                    continue
                }

                let remaining = try steps.executableCount(taskID: task.id)
                if remaining > 0 {
                    recoverable.append(task)
                } else {
                    // 没有待执行步骤了 —— 补一次状态推进, 避免任务永远卡在 running。
                    do {
                        _ = try tasks.updateStatus(id: task.id, to: .completed)
                        stuckCompleted += 1
                        logger.warning(
                            .appCrashRecovery,
                            "任务「\(task.name)」已无可执行步骤, 状态修正为 completed",
                            taskID: task.id
                        )
                    } catch {
                        logger.record(error, eventType: .taskFailed, taskID: task.id)
                    }
                }

            case .waitingForAccount, .waitingForBrowser, .waitingForUser:
                // 等用户态: 必须由用户手动 Resume, 绝不自动拉起。
                // 这里只做记录 —— 让用户知道有任务在等自己 (尤其是"等待切换账号")。
                awaitingUser.append(task)
                logger.info(
                    .recoveryCompleted,
                    "任务「\(task.name)」正在等待用户操作 (\(task.status.displayName)), 不会自动恢复",
                    taskID: task.id
                )

            case .paused, .waiting:
                // 用户主动暂停 / 程序内部等待: 不自动恢复。
                break

            case .completed, .failed, .cancelled:
                // 终态任务不会出现在 fetchUnfinished 的结果里; 这里只是保持 switch 穷尽。
                break
            }
        }

        // 4) 事件留痕
        if interrupted > 0 {
            logger.warning(
                .appCrashRecovery,
                "检测到上次运行被强制中断: \(interrupted) 个步骤处于 running 状态, "
                + "已标记为 interrupted 并将重新执行 (已完成步骤不受影响)",
                metadata: .object(["interruptedSteps": .int(interrupted)])
            )
        }

        if !recoverable.isEmpty {
            logger.info(
                .recoveryCompleted,
                "恢复完成: \(recoverable.count) 个任务将从未完成步骤继续 — "
                + recoverable.map(\.name).joined(separator: ", "),
                metadata: .object(["taskCount": .int(recoverable.count)])
            )
        }

        let summary: String
        if interrupted == 0 && recoverable.isEmpty
            && stuckCompleted == 0 && reconciledFailed == 0 {
            summary = awaitingUser.isEmpty
                ? "无需恢复: 没有检测到中断的任务或步骤"
                : "无中断任务; 另有 \(awaitingUser.count) 个任务正在等待你手动操作"
        } else {
            var parts: [String] = []
            if interrupted > 0 { parts.append("\(interrupted) 个中断步骤待重跑") }
            if !recoverable.isEmpty { parts.append("\(recoverable.count) 个任务待继续") }
            if stuckCompleted > 0 { parts.append("\(stuckCompleted) 个任务状态已修正为完成") }
            if reconciledFailed > 0 {
                parts.append("\(reconciledFailed) 个任务因存在失败步骤已停止推进")
            }
            if !awaitingUser.isEmpty { parts.append("\(awaitingUser.count) 个任务等待你手动操作") }
            summary = parts.joined(separator: ", ")
        }

        return RecoveryReport(
            interruptedSteps: interrupted,
            recoverableTaskIDs: recoverable.map(\.id),
            recoverableTaskNames: recoverable.map(\.name),
            completedButStuckTasks: stuckCompleted,
            reconciledFailedTasks: reconciledFailed,
            awaitingUserTaskIDs: awaitingUser.map(\.id),
            summary: summary
        )
    }
}

import Foundation

/// 任务规划器。
///
/// MVP 阶段刻意保持"笨" —— 目标是把 Runner / Checkpoint / Retry / Recovery 跑通,
/// 而不是做智能任务分解。用户给 N 步, 就生成 N 个顺序步骤。
public struct TaskPlanner: Sendable {

    public static let systemPrompt = """
    You are a disciplined executor of a long-running task.
    You complete exactly ONE step at a time and return a concise, self-contained result.
    Never ask clarifying questions. Never claim to have done work you did not do.
    Reply in the same language as the goal.
    """

    /// 生成 N 个顺序步骤。最后一步标记为 `.final`。
    public static func defaultPlan(
        taskID: String,
        numberOfSteps: Int,
        goal: String
    ) -> [TaskStep] {
        guard numberOfSteps > 0 else { return [] }
        return (0..<numberOfSteps).map { index in
            let isLast = (index == numberOfSteps - 1)
            return TaskStep(
                taskID: taskID,
                index: index,
                type: isLast ? .final : .map,
                status: .pending,
                input: .object([
                    "stepIndex": .int(index),
                    "totalSteps": .int(numberOfSteps),
                    "goal": .string(goal),
                    "responseFormat": .string(ResponseFormat.text.rawValue),
                ])
            )
        }
    }

    /// 构造某一步的模型请求。
    ///
    /// 上下文策略 (MVP): **只** 用 `latest checkpoint workingSummary` + 当前步骤 + 目标,
    /// 不把历史全部原始输出塞进 prompt。300 步的任务若每步都带上全部历史,
    /// 到第 50 步就会爆上下文窗口且费用失控。
    public static func buildRequest(
        task: AITask,
        step: TaskStep,
        checkpoint: Checkpoint?,
        responseFormat: ResponseFormat = .text,
        maxOutputTokens: Int = 2048,
        temperature: Double = 0.2,
        timeout: TimeInterval = 180,
        contextShrinkFactor: Double? = nil
    ) -> AIRequest {

        let ordinal = step.index + 1
        let total = max(task.totalSteps, ordinal)

        let progressSection: String
        if let summary = checkpoint?.workingSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            progressSection = """
            Progress so far (from the last checkpoint):
            \(summary)
            """
        } else {
            progressSection = "Progress so far: this is the first step, nothing has been completed yet."
        }

        let stepInstruction: String
        switch step.type {
        case .final:
            stepInstruction = """
            This is the FINAL step. Produce the deliverable for the overall goal, \
            synthesizing everything completed so far. Be concrete and complete.
            """
        case .reduce:
            stepInstruction = """
            This is a REDUCE step. Aggregate the results produced so far into a \
            consolidated intermediate result.
            """
        default:
            stepInstruction = """
            Complete this step and return a concise, self-contained result. \
            Assume the result will be read later without access to this conversation.
            """
        }

        let userPrompt = """
        You are working on step \(ordinal) of \(total).

        Overall goal:
        \(task.goal)

        \(progressSection)

        \(stepInstruction)
        """

        var request = AIRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            responseFormat: responseFormat,
            timeout: timeout
        )

        // contextTooLong 的降级路径: 按比例裁剪 prompt 后重试。
        if let factor = contextShrinkFactor, factor > 0, factor < 1 {
            request = request.shrinkingUserPrompt(factor: factor)
        }

        return request
    }

    /// 从步骤输入里解析期望的响应格式。
    public static func responseFormat(for step: TaskStep) -> ResponseFormat {
        guard let raw = step.input["responseFormat"]?.stringValue else { return .text }
        return ResponseFormat(rawValue: raw) ?? .text
    }
}

import Foundation

/// 检查点 —— 整个续跑机制的核心记录。
///
/// 每成功完成一个 Step 就写入一条。`nextStep` 是恢复时唯一的权威依据:
/// 崩溃重启后只需要读最新 checkpoint 的 `nextStep`, 就不用重跑之前的步骤。
public struct Checkpoint: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public let taskID: String

    /// 最后一个成功完成的 step index (从 0 开始)。
    public var completedStep: Int
    /// 下一个应该执行的 step index。== completedStep + 1。
    public var nextStep: Int

    /// 滚动摘要 (MVP: 取最近若干步输出的截断拼接)。
    public var workingSummary: String?

    /// 结构化状态 (全局发现、计数、自定义数据)。
    public var state: JSONValue

    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        completedStep: Int,
        nextStep: Int,
        workingSummary: String? = nil,
        state: JSONValue = .emptyObject,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.completedStep = completedStep
        self.nextStep = nextStep
        self.workingSummary = workingSummary
        self.state = state
        self.createdAt = createdAt
    }

    /// 起始检查点 (尚未执行任何步骤)。
    public static func initial(taskID: String) -> Checkpoint {
        Checkpoint(
            taskID: taskID,
            completedStep: -1,
            nextStep: 0,
            workingSummary: "任务已创建, 尚未开始",
            state: .object(["completedSteps": .array([])])
        )
    }

    public var summaryPreview: String {
        let s = workingSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "(无摘要)" : s
    }
}

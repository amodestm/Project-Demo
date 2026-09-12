import Foundation

/// 检查点管理。
///
/// 每个 Step 成功后产出一条 Checkpoint。它承载两件事:
/// 1. **恢复依据** — `nextStep` 告诉重启后的 Runner 该从哪继续
/// 2. **上下文摘要** — `workingSummary` 是下一步 prompt 的输入, 避免把全部历史输出塞进请求
public actor CheckpointManager {

    private let repo: CheckpointRepository
    private let maxSummaryCharacters: Int
    private let maxTrackedStepIndexes: Int

    public init(
        repo: CheckpointRepository,
        maxSummaryCharacters: Int = 1200,
        maxTrackedStepIndexes: Int = 20
    ) {
        self.repo = repo
        self.maxSummaryCharacters = maxSummaryCharacters
        self.maxTrackedStepIndexes = maxTrackedStepIndexes
    }

    // MARK: - 读取

    public func latest(taskID: String) throws -> Checkpoint? {
        try repo.latest(taskID: taskID)
    }

    public func list(taskID: String, limit: Int = 100) throws -> [Checkpoint] {
        try repo.list(taskID: taskID, limit: limit)
    }

    public func count(taskID: String) throws -> Int {
        try repo.count(taskID: taskID)
    }

    /// 取最新检查点; 若从未有过则返回 nil (调用方回退到"从头开始")。
    public func latestOrNil(taskID: String) -> Checkpoint? {
        try? repo.latest(taskID: taskID)
    }

    // MARK: - 构造

    /// 为一个刚成功完成的步骤构造检查点。
    ///
    /// `workingSummary` 是**累积**的: 它把上一步的摘要与本次输出拼接, 并截断到
    /// `maxSummaryCharacters`。刻意保留尾部而非头部 —— 对长任务而言, 最近发生的事
    /// 比早期内容更影响下一步。
    public func makeCheckpoint(
        taskID: String,
        completedStep: Int,
        previous: Checkpoint?,
        output: JSONValue,
        provider: String,
        model: String
    ) -> Checkpoint {
        let summary = makeSummary(
            previous: previous,
            completedStep: completedStep,
            output: output
        )
        let state = makeState(
            previous: previous,
            completedStep: completedStep,
            output: output,
            provider: provider,
            model: model
        )

        return Checkpoint(
            taskID: taskID,
            completedStep: completedStep,
            nextStep: completedStep + 1,
            workingSummary: summary,
            state: state
        )
    }

    private func makeSummary(
        previous: Checkpoint?,
        completedStep: Int,
        output: JSONValue
    ) -> String {
        let snippet = Self.outputSnippet(output)
        let addition = "Step \(completedStep + 1): \(snippet)"

        let previousText = (previous?.workingSummary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var combined = previousText.isEmpty ? addition : previousText + "\n" + addition

        if combined.count > maxSummaryCharacters {
            combined = "[前文已截断]\n" + String(combined.suffix(maxSummaryCharacters))
        }
        return combined
    }

    private func makeState(
        previous: Checkpoint?,
        completedStep: Int,
        output: JSONValue,
        provider: String,
        model: String
    ) -> JSONValue {
        var state: [String: JSONValue] = previous?.state.objectValue ?? [:]

        var indexes = state["recentSteps"]?.arrayValue ?? []
        indexes.append(.int(completedStep))
        if indexes.count > maxTrackedStepIndexes {
            indexes.removeFirst(indexes.count - maxTrackedStepIndexes)
        }

        let previousCount = state["completedCount"]?.intValue ?? 0
        let previousChars = state["totalOutputCharacters"]?.intValue ?? 0

        state["recentSteps"] = .array(indexes)
        state["completedCount"] = .int(max(previousCount, completedStep + 1))
        state["totalOutputCharacters"] = .int(previousChars + Self.outputSnippet(output).count)
        state["lastProvider"] = .string(provider)
        state["lastModel"] = .string(model)
        state["lastCompletedAt"] = .string(DateCoding.string(from: Date()))

        return .object(state)
    }

    /// 从模型输出中提取一段人类可读的摘要文本。
    static func outputSnippet(_ output: JSONValue, limit: Int = 260) -> String {
        let raw: String
        if let text = output["text"]?.stringValue {
            raw = text
        } else if let summary = output["summary"]?.stringValue {
            raw = summary
        } else {
            raw = output.prettyDescription
        }

        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}

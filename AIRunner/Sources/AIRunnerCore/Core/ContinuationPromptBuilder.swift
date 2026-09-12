import Foundation

/// 续跑 prompt 生成器。
///
/// ## 核心要求
///
/// 生成的 prompt 必须是**完全自包含**的: 用户切换到另一个 ChatGPT 会话后,
/// 那个会话**没有任何之前的聊天历史**, 仅凭这段文本就能准确接着做第 N 步。
///
/// 因此这里刻意**不引用** conversation ID、不引用"上一条消息"、
/// 不假设模型记得任何东西。所有必要上下文 (目标 / 已完成范围 / 检查点摘要 /
/// 已确立事实 / 本次任务) 都内联在文本里。
///
/// ## 确定性
///
/// 这是**纯函数** —— 相同输入必然产出逐字相同的输出。
/// 这条性质是崩溃恢复能成立的前提: 若 App 在"prompt 已生成、结果未回填"时被杀,
/// 重启后重新生成同一个 prompt 是安全的, 不会让用户看到前后不一致的任务描述。
/// **因此这里绝不使用 `Date()` / 随机数 / 任何环境相关的值。**
public struct ContinuationPromptBuilder: Sendable {

    public struct Input: Sendable {
        /// 任务的总体目标。
        public var goal: String
        /// 当前步骤下标 (0-based)。
        public var stepIndex: Int
        public var totalSteps: Int
        public var stepType: StepType
        /// 最新检查点。nil 表示这是第一步。
        public var checkpoint: Checkpoint?
        /// 已完成的步骤下标 (用于生成 "1...63" 这样的范围)。
        public var completedStepIndexes: [Int]
        /// 从检查点 state 里提炼出的关键事实 (每行一条)。
        public var structuredFacts: [String]
        /// 期望的输出格式说明, 例如 "Return a JSON object with keys: findings[], confidence"。
        public var outputSchema: String?

        public init(
            goal: String,
            stepIndex: Int,
            totalSteps: Int,
            stepType: StepType = .llm,
            checkpoint: Checkpoint? = nil,
            completedStepIndexes: [Int] = [],
            structuredFacts: [String] = [],
            outputSchema: String? = nil
        ) {
            self.goal = goal
            self.stepIndex = stepIndex
            self.totalSteps = totalSteps
            self.stepType = stepType
            self.checkpoint = checkpoint
            self.completedStepIndexes = completedStepIndexes
            self.structuredFacts = structuredFacts
            self.outputSchema = outputSchema
        }
    }

    public init() {}

    // MARK: - 生成

    public func build(_ input: Input) -> String {
        var sections: [String] = []

        // 1) 角色与硬性约束 —— 放在最前面, 因为这是最容易被忽略的部分
        sections.append("""
        You are continuing an existing long-running task that was interrupted.

        IMPORTANT RULES:
        - Do NOT restart the task from the beginning.
        - Do NOT redo any step listed as already completed.
        - Rely ONLY on the information in this message.
          You do NOT have access to any previous conversation, so nothing may be assumed
          from prior context.
        - Do NOT ask clarifying questions. Produce the result for this turn directly.
        """)

        // 2) 总体目标
        sections.append("""
        OVERALL GOAL:
        \(input.goal.trimmingCharacters(in: .whitespacesAndNewlines))
        """)

        // 3) 进度
        let ordinal = input.stepIndex + 1
        let total = max(input.totalSteps, ordinal)
        sections.append("""
        PROGRESS:
        Completed steps: \(Self.compressRanges(input.completedStepIndexes))
        Current step: \(ordinal)
        Total steps: \(total)
        """)

        // 4) 检查点 —— 跨会话唯一的状态载体
        sections.append("""
        CURRENT CHECKPOINT:
        \(checkpointText(input.checkpoint))
        """)

        // 5) 已确立的事实
        if !input.structuredFacts.isEmpty {
            let bullets = input.structuredFacts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { "- \($0)" }
                .joined(separator: "\n")
            sections.append("""
            IMPORTANT ESTABLISHED FACTS:
            \(bullets)
            """)
        }

        // 6) 本轮任务
        sections.append("""
        TASK FOR THIS TURN:
        \(instruction(for: input))
        """)

        // 7) 输出格式
        sections.append("""
        OUTPUT REQUIREMENTS:
        \(outputRequirements(input))
        """)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - 片段

    private func checkpointText(_ checkpoint: Checkpoint?) -> String {
        guard let checkpoint else {
            return "No prior progress has been recorded. This is the first step."
        }
        let summary = checkpoint.workingSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else {
            return "Checkpoint recorded at step \(checkpoint.completedStep + 1), "
                 + "but no summary text was captured."
        }
        return summary
    }

    private func instruction(for input: Input) -> String {
        let ordinal = input.stepIndex + 1
        switch input.stepType {
        case .final:
            return """
            This is the FINAL step (\(ordinal) of \(input.totalSteps)).
            Produce the finished deliverable for the overall goal, synthesizing everything
            completed so far. Be concrete and complete — this is what the user will read.
            """
        case .reduce:
            return """
            This is the AGGREGATION step (\(ordinal) of \(input.totalSteps)).
            Consolidate the results produced in the completed steps into one coherent
            intermediate result. Resolve contradictions explicitly rather than listing them.
            """
        case .tool:
            return """
            This step (\(ordinal) of \(input.totalSteps)) requires local processing.
            Perform the operation described by the goal and report the outcome.
            """
        case .map, .llm:
            return """
            Complete step \(ordinal) of \(input.totalSteps).
            Return a concise, self-contained result for this step alone.
            Assume the result will be read later by someone who cannot see this conversation,
            so include any concrete specifics (numbers, names, decisions) that the next step
            will need.
            """
        }
    }

    private func outputRequirements(_ input: Input) -> String {
        if let schema = input.outputSchema?.trimmingCharacters(in: .whitespacesAndNewlines),
           !schema.isEmpty {
            return """
            \(schema)

            Do not redo completed steps. Do not wrap the answer in commentary about what you
            are about to do — return the result itself.
            """
        }
        return """
        Return only the result for this single step — no preamble, no restatement of the goal,
        no commentary about the process. Plain text, or JSON if the task calls for it.
        Do not redo completed steps.
        """
    }

    // MARK: - 范围压缩

    /// 把 `[0,1,2,3,7,8,20]` 压缩成 `"1...4, 8...9, 21"`。
    ///
    /// 一个 300 步的任务如果逐个列举已完成步骤, 光这一行就会占掉几百个 token。
    static func compressRanges(_ indexes: [Int]) -> String {
        let sorted = Array(Set(indexes)).sorted()
        guard !sorted.isEmpty else {
            return "(none — this is the first step)"
        }

        var parts: [String] = []
        var rangeStart = sorted[0]
        var previous = sorted[0]

        func flush() {
            if rangeStart == previous {
                parts.append("\(rangeStart + 1)")           // 转成 1-based 显示
            } else {
                parts.append("\(rangeStart + 1)...\(previous + 1)")
            }
        }

        for value in sorted.dropFirst() {
            if value == previous + 1 {
                previous = value
                continue
            }
            flush()
            rangeStart = value
            previous = value
        }
        flush()

        return parts.joined(separator: ", ")
    }

    /// 从检查点的 `state` 提炼人类可读的关键事实。
    static func facts(from checkpoint: Checkpoint?) -> [String] {
        guard let state = checkpoint?.state.objectValue else { return [] }

        var facts: [String] = []

        if let count = state["completedCount"]?.intValue {
            facts.append("Steps completed so far: \(count)")
        }
        if let recent = state["recentSteps"]?.arrayValue, !recent.isEmpty {
            let indexes = recent.compactMap { $0.intValue }.sorted()
            facts.append("Recently completed step indexes: \(compressRanges(indexes))")
        }
        if let characters = state["totalOutputCharacters"]?.intValue, characters > 0 {
            facts.append("Cumulative output size: ~\(characters) characters")
        }

        // 其余由上层写入的自定义标量字段一并带出
        let internalKeys: Set<String> = [
            "completedCount", "recentSteps", "totalOutputCharacters",
            "lastProvider", "lastModel", "lastCompletedAt",
        ]
        for (key, value) in state.sorted(by: { $0.key < $1.key })
        where !internalKeys.contains(key) {
            switch value {
            case .string(let text):
                facts.append("\(key): \(text)")
            case .int(let number):
                facts.append("\(key): \(number)")
            case .double(let number):
                facts.append("\(key): \(number)")
            case .bool(let flag):
                facts.append("\(key): \(flag)")
            case .array(let items):
                let rendered = items.compactMap(\.stringValue).prefix(8).joined(separator: "; ")
                if !rendered.isEmpty { facts.append("\(key): \(rendered)") }
            case .object, .null:
                continue
            }
        }

        return facts
    }
}

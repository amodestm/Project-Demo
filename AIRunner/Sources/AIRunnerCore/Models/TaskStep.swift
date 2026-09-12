import Foundation

public enum StepStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case running

    /// ★ Web 模式专用: 续跑 prompt 已生成并交付给用户, 但结果尚未回填。
    ///
    /// 这个状态必须**可被 Runner 重新取走** —— 否则 App 在"prompt 已生成之后、
    /// 用户回填之前"崩溃, 该步骤就会永远卡死。
    /// 重新取走时会用同样的输入重新生成**完全相同**的 prompt
    /// (`ContinuationPromptBuilder` 是纯函数), 所以重复执行是安全的。
    case prepared

    case completed
    case failed
    case skipped
    /// 进程被杀时留下的中间态。
    case interrupted

    /// 终态: 不会被再次执行。
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .skipped: return true
        case .pending, .prepared, .running, .interrupted: return false
        }
    }

    /// 是否应当被 Runner 取走执行。
    ///
    /// ★ 注意: 只有 pending / interrupted / prepared 可执行。
    /// completed 永远不在其中 —— 这是"绝不重跑已完成步骤"的第一道防线。
    public var isExecutable: Bool {
        switch self {
        case .pending, .interrupted, .prepared: return true
        case .running, .completed, .failed, .skipped: return false
        }
    }

    /// 是否已交付给用户、正在等待回填结果。
    public var isAwaitingResult: Bool { self == .prepared }

    public var displayName: String {
        switch self {
        case .pending:     return "待执行"
        case .prepared:    return "已就绪"
        case .running:     return "执行中"
        case .completed:   return "已完成"
        case .failed:      return "失败"
        case .skipped:     return "已跳过"
        case .interrupted: return "已中断"
        }
    }
}

public enum StepType: String, Codable, Sendable, CaseIterable {
    case llm
    case map
    case reduce
    case final
    case tool

    public var displayName: String {
        switch self {
        case .llm:    return "LLM 调用"
        case .map:    return "分片处理"
        case .reduce: return "汇总"
        case .final:  return "最终产出"
        case .tool:   return "本地工具"
        }
    }
}

/// 一个任务步骤。
public struct TaskStep: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public let taskID: String
    public var index: Int
    public var type: StepType
    public var status: StepStatus

    public var input: JSONValue
    public var output: JSONValue?

    public var provider: String?
    public var model: String?

    public var retryCount: Int

    public var startedAt: Date?
    public var finishedAt: Date?
    public var createdAt: Date

    // MARK: 扩展字段

    public var lastError: String?
    public var errorClass: String?
    public var durationMs: Int
    /// 每次失败尝试的审计轨迹 (错误类型 / 等待时长 / backend)。
    public var attemptLog: [JSONValue]

    // MARK: Web 执行模式

    /// 续跑 prompt 生成并交付给用户的时间 (Web 模式)。
    public var preparedAt: Date?
    /// 用户把该 prompt 提交给 ChatGPT 的时间 (Web 模式, 可选)。
    public var submittedAt: Date?

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        index: Int,
        type: StepType = .llm,
        status: StepStatus = .pending,
        input: JSONValue = .emptyObject,
        output: JSONValue? = nil,
        provider: String? = nil,
        model: String? = nil,
        retryCount: Int = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        createdAt: Date = Date(),
        lastError: String? = nil,
        errorClass: String? = nil,
        durationMs: Int = 0,
        attemptLog: [JSONValue] = [],
        preparedAt: Date? = nil,
        submittedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.index = index
        self.type = type
        self.status = status
        self.input = input
        self.output = output
        self.provider = provider
        self.model = model
        self.retryCount = retryCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.createdAt = createdAt
        self.lastError = lastError
        self.errorClass = errorClass
        self.durationMs = durationMs
        self.attemptLog = attemptLog
        self.preparedAt = preparedAt
        self.submittedAt = submittedAt
    }

    public var backendLabel: String {
        switch (provider, model) {
        case let (p?, m?): return "\(p) / \(m)"
        case let (p?, nil): return p
        case let (nil, m?): return m
        default: return "—"
        }
    }

    /// 提取输出文本 (供 checkpoint 的 workingSummary 使用)。
    public var outputText: String? {
        guard let output else { return nil }
        if let direct = output["text"]?.stringValue { return direct }
        return output.stringValue
    }
}

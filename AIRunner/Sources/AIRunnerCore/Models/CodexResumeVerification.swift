import Foundation

/// 候选线程的匹配强度。
public enum CodexMatchStrength: String, Codable, Sendable, CaseIterable {
    /// 标题 + 至少一个辅助信号全部相等。
    case exact
    /// 标题相等，但没有任何辅助信号可以佐证。
    case strong
    /// 只有部分信号对上，或仅靠辅助信号。
    case weak

    public var rank: Int {
        switch self {
        case .exact:  return 2
        case .strong: return 1
        case .weak:   return 0
        }
    }

    public var displayName: String {
        switch self {
        case .exact:  return "精确匹配"
        case .strong: return "强匹配"
        case .weak:   return "弱匹配"
        }
    }
}

/// 一个候选线程 —— 由 UI 遍历产出的**原始信息**。
///
/// 这里刻意**不带**"匹配强度": 强度由 `CodexTaskMatcher` 统一计算。
/// 否则判定逻辑会散落到 Driver 里, 而 Driver 恰恰是随 UI 变化最频繁的一层。
public struct CodexThreadCandidate: Sendable, Equatable {
    public let title: String
    public let projectName: String?
    public let repositoryPath: String?
    public let worktreePath: String?
    /// 脱敏后的 AX 路径, 仅用于诊断。
    /// **绝不包含消息正文** —— 只保留 role 与层级。
    public let debugPath: String?

    public init(
        title: String,
        projectName: String? = nil,
        repositoryPath: String? = nil,
        worktreePath: String? = nil,
        debugPath: String? = nil
    ) {
        self.title = title
        self.projectName = projectName
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.debugPath = debugPath
    }

    public var label: String { title }
}

/// matcher 的输出: 候选 + 被评定的匹配强度。
public struct CodexScoredCandidate: Sendable, Equatable {
    public let candidate: CodexThreadCandidate
    public let strength: CodexMatchStrength

    public init(candidate: CodexThreadCandidate, strength: CodexMatchStrength) {
        self.candidate = candidate
        self.strength = strength
    }

    public var label: String { candidate.title }
}

/// 打开线程后从**主会话区**重新读到的上下文 —— 用于二次验证。
///
/// 这是整个自动化最关键的一道安全 Gate: 点了 sidebar 上的候选项之后，
/// 必须回到主区域重新确认"打开的确实是那一个线程"，而不是立刻输入消息。
public struct CodexOpenThreadContext: Sendable, Equatable {
    public let threadTitle: String?
    public let projectName: String?
    public let repositoryPath: String?
    public let worktreePath: String?

    public init(
        threadTitle: String? = nil,
        projectName: String? = nil,
        repositoryPath: String? = nil,
        worktreePath: String? = nil
    ) {
        self.threadTitle = threadTitle
        self.projectName = projectName
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
    }
}

/// 线程当前是否正在生成。
public enum CodexBusyState: String, Sendable, Equatable, CaseIterable {
    case idle
    case generating
    /// 读取不到明确信号。生产路径按"不确定"处理 —— 不发送。
    case unknown

    public var isSafeToSend: Bool { self == .idle }
}

/// Codex 当前会话里需要账号交接的明确异常信号。
///
/// 只有额度耗尽或登录会话失效才允许上层进入账号轮换；普通的“任务已停止”
/// 只记录并等待下一次明确的额度/认证信号，避免把用户主动停止误当成切号条件。
public enum CodexAccountIssue: String, Sendable, Equatable, CaseIterable {
    case quotaExhausted
    case authenticationRequired
    case taskStopped

    public var displayName: String {
        switch self {
        case .quotaExhausted: return "额度或用量上限"
        case .authenticationRequired: return "登录会话失效"
        case .taskStopped: return "任务已停止"
        }
    }

    public var eventName: String {
        switch self {
        case .quotaExhausted: return "CODEX_QUOTA_EXHAUSTED"
        case .authenticationRequired: return "CODEX_AUTHENTICATION_REQUIRED"
        case .taskStopped: return "CODEX_TASK_STOPPED"
        }
    }

    public var requiresAccountRotation: Bool {
        switch self {
        case .quotaExhausted, .authenticationRequired: return true
        case .taskStopped: return false
        }
    }
}

/// 发送之后观察到的确认信号。
public enum SendConfirmation: String, Sendable, Equatable {
    case composerCleared
    case newUserMessageAppeared
    case conversationRunning
    case sendControlStateChanged
    /// 观察不到任何信号 —— 状态必须记为 `sentUnconfirmed`, 不能谎报成功。
    case unconfirmed
}

/// 多信号验证报告。
///
/// 分成两档门槛是刻意的:
/// * `passesLocateGate` —— Test Locate / Dry Run 用。只要求"能唯一确定目标"。
/// * `passesSendGate`   —— 真正发送前用。要求 9 个信号全部通过。
///
/// 用户明确要求: 如果只能取得一个弱信号, Test Locate 可以提示,
/// 但 **Production Auto Send 默认必须拒绝**。
public struct CodexResumeVerification: Sendable, Equatable {

    public var applicationMatched = false
    public var codexViewMatched = false
    public var threadMatched = false
    public var secondaryContextMatched = false
    /// 候选集合里恰有一个可用匹配 (不是 0 个, 也不是 2 个以上)。
    public var uniqueTargetConfirmed = false
    public var notCurrentlyGenerating = false

    public var composerFound = false
    public var composerEditable = false
    public var composerFocused = false
    public var messageInserted = false
    public var sendControlFound = false
    public var sendConfirmed = false

    /// 不通过时的原因 (写日志 / 显示给用户)。
    public var failureReason: String?

    public init() {}

    /// 定位门槛: 能唯一确定目标线程。
    public var passesLocateGate: Bool {
        applicationMatched && codexViewMatched && threadMatched && uniqueTargetConfirmed
    }

    /// 发送门槛: 比定位更严, 且要求两个**独立**信号。
    public var passesSendGate: Bool {
        passesLocateGate
            && secondaryContextMatched
            && notCurrentlyGenerating
            && composerFound
            && composerEditable
            && composerFocused
            && messageInserted
            && sendControlFound
    }

    /// 通过的条件数 (用于日志与 UI 展示)。
    public var passedGateCount: Int {
        [
            applicationMatched, codexViewMatched, threadMatched,
            secondaryContextMatched, uniqueTargetConfirmed, notCurrentlyGenerating,
            composerFound, composerEditable, composerFocused,
            messageInserted, sendControlFound, sendConfirmed,
        ].filter { $0 }.count
    }

    public var report: String {
        func mark(_ value: Bool) -> String { value ? "✓" : "✗" }
        var lines = [
            "\(mark(applicationMatched)) applicationMatched",
            "\(mark(codexViewMatched)) codexViewMatched",
            "\(mark(threadMatched)) threadMatched",
            "\(mark(secondaryContextMatched)) secondaryContextMatched",
            "\(mark(uniqueTargetConfirmed)) uniqueTargetConfirmed",
            "\(mark(notCurrentlyGenerating)) notCurrentlyGenerating",
            "\(mark(composerFound)) composerFound",
            "\(mark(composerEditable)) composerEditable",
            "\(mark(composerFocused)) composerFocused",
            "\(mark(messageInserted)) messageInserted",
            "\(mark(sendControlFound)) sendControlFound",
            "\(mark(sendConfirmed)) sendConfirmed",
        ]
        if let failureReason {
            lines.append("!")
            lines.append("失败原因: \(failureReason)")
        }
        return lines.joined(separator: "\n")
    }

    /// 一句话摘要 (日志用)。
    public var compactSummary: String {
        if let failureReason { return "未通过 (\(passedGateCount)/12): \(failureReason)" }
        return "通过 (\(passedGateCount)/12)"
    }
}

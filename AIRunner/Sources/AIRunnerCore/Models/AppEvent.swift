import Foundation

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error
    case critical

    public var sortOrder: Int {
        switch self {
        case .debug:    return 0
        case .info:     return 1
        case .warning:  return 2
        case .error:    return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    public var displayName: String {
        rawValue.uppercased()
    }

    public var symbolName: String {
        switch self {
        case .debug:    return "ladybug"
        case .info:     return "info.circle"
        case .warning:  return "exclamationmark.triangle"
        case .error:    return "xmark.octagon"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

/// 事件类型。存库时使用 rawValue (字符串), 便于将来扩展而不破坏旧数据。
public enum EventType: String, Codable, Sendable, CaseIterable {

    // 任务生命周期
    case taskCreated      = "TASK_CREATED"
    case taskStarted      = "TASK_STARTED"
    case taskPaused       = "TASK_PAUSED"
    case taskResumed      = "TASK_RESUMED"
    case taskCancelled    = "TASK_CANCELLED"
    case taskCompleted    = "TASK_COMPLETED"
    case taskFailed       = "TASK_FAILED"
    case taskWaiting      = "TASK_WAITING"

    // 步骤生命周期
    case stepStarted      = "STEP_STARTED"
    case stepCompleted    = "STEP_COMPLETED"
    case stepFailed       = "STEP_FAILED"
    case stepSkipped      = "STEP_SKIPPED"
    case stepRetry        = "STEP_RETRY"

    // 检查点
    case checkpointSaved  = "CHECKPOINT_SAVED"

    // 路由与 Provider
    case backendSelected  = "BACKEND_SELECTED"
    case backendSwitched  = "BACKEND_SWITCHED"
    case backendExhausted = "BACKEND_EXHAUSTED"
    case providerDegraded = "PROVIDER_DEGRADED"
    case providerUnavailable = "PROVIDER_UNAVAILABLE"
    case providerRecovered = "PROVIDER_RECOVERED"
    case rateLimited      = "RATE_LIMITED"
    case billingBlocked   = "BILLING_BLOCKED"

    // 运行器
    case runnerStarted    = "RUNNER_STARTED"
    case runnerStopped    = "RUNNER_STOPPED"
    case runnerRejectedDuplicate = "RUNNER_REJECTED_DUPLICATE"

    // ChatGPT Web 执行（兼容通道）
    case webStepPrepared         = "WEB_STEP_PREPARED"
    case webStepSubmitted        = "WEB_STEP_SUBMITTED"
    case webPromptCopied         = "WEB_PROMPT_COPIED"
    case resultImported          = "RESULT_IMPORTED"
    case resultImportRejected    = "RESULT_IMPORT_REJECTED"
    case accountHandoffRequested = "ACCOUNT_HANDOFF_REQUESTED"
    case accountHandoffCompleted = "ACCOUNT_HANDOFF_COMPLETED"
    case browserOpened           = "BROWSER_OPENED"

    // 崩溃恢复
    case appCrashRecovery = "APP_CRASH_RECOVERY"
    case recoveryCompleted = "RECOVERY_COMPLETED"
    /// 恢复时发现任务里卡着失败步骤 —— 已把任务置为 failed, **不**继续往后跑。
    case recoveryReconciledFailedTask = "RECOVERY_RECONCILED_FAILED_TASK"

    // Codex Existing Thread Resume
    case codexBindingCreated         = "CODEX_BINDING_CREATED"
    case codexBindingVerified        = "CODEX_BINDING_VERIFIED"
    case codexLocateStarted          = "CODEX_LOCATE_STARTED"
    case codexTargetFound            = "CODEX_TARGET_FOUND"
    case codexTargetAmbiguous        = "CODEX_TARGET_AMBIGUOUS"
    case codexTargetOpened           = "CODEX_TARGET_OPENED"
    case codexTargetVerified         = "CODEX_TARGET_VERIFIED"
    case codexComposerFound          = "CODEX_COMPOSER_FOUND"
    case codexMessageInserted        = "CODEX_MESSAGE_INSERTED"
    case codexResumeSent             = "CODEX_RESUME_SENT"
    case codexResumeUnconfirmed      = "CODEX_RESUME_UNCONFIRMED"
    case codexResumeCompleted        = "CODEX_RESUME_COMPLETED"
    case codexResumeAborted          = "CODEX_RESUME_ABORTED"
    case codexResumeDuplicateBlocked = "CODEX_RESUME_DUPLICATE_BLOCKED"

    // 人工认证后自动恢复
    case accountHandoffMonitoring    = "ACCOUNT_HANDOFF_MONITORING"
    case accountHandoffDetected      = "ACCOUNT_HANDOFF_DETECTED"
    case accountHandoffAutoResumed   = "ACCOUNT_HANDOFF_AUTO_RESUMED"

    // Chrome Profile 自动账号轮换
    case accountRotationStarted          = "ACCOUNT_ROTATION_STARTED"
    case accountRotationCompleted         = "ACCOUNT_ROTATION_COMPLETED"
    case accountRotationFailed            = "ACCOUNT_ROTATION_FAILED"
    case accountRotationWindowFocusFailed = "ACCOUNT_ROTATION_WINDOW_FOCUS_FAILED"

    // 额度快照（实时查询官方用量接口）
    case quotaSnapshotCaptured   = "QUOTA_SNAPSHOT_CAPTURED"
    case quotaSnapshotFailed     = "QUOTA_SNAPSHOT_FAILED"

    // Codex 经 MCP 主动上报 / 请求
    case mcpRequestReceived      = "MCP_REQUEST_RECEIVED"
    case mcpRequestCompleted     = "MCP_REQUEST_COMPLETED"
    case mcpRequestFailed        = "MCP_REQUEST_FAILED"

    // 配置与安全
    case configChanged    = "CONFIG_CHANGED"
    case keychainUpdated  = "KEYCHAIN_UPDATED"

    // 多账号 AI 讨论组
    case discussionStarted        = "DISCUSSION_STARTED"
    case discussionRoundStarted   = "DISCUSSION_ROUND_STARTED"
    case discussionUtteranceSent  = "DISCUSSION_UTTERANCE_SENT"
    case discussionIdentityFailed = "DISCUSSION_IDENTITY_FAILED"
    case discussionConverged      = "DISCUSSION_CONVERGED"
    case discussionFailed         = "DISCUSSION_FAILED"
    case discussionCancelled      = "DISCUSSION_CANCELLED"

    case unknown          = "UNKNOWN"

    public var displayName: String { rawValue }
}

/// 一条事件/日志记录。
public struct AppEvent: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public var taskID: String?
    public var stepIndex: Int?
    public var level: LogLevel
    public var eventType: EventType
    public var message: String
    public var metadata: JSONValue?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        taskID: String? = nil,
        stepIndex: Int? = nil,
        level: LogLevel = .info,
        eventType: EventType,
        message: String,
        metadata: JSONValue? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.stepIndex = stepIndex
        self.level = level
        self.eventType = eventType
        self.message = message
        self.metadata = metadata
        self.createdAt = createdAt
    }

    public var timestampText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f.string(from: createdAt)
    }

    public var fullTimestampText: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f.string(from: createdAt)
    }
}

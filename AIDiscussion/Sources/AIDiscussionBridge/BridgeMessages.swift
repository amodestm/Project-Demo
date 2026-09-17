import Foundation

// MARK: - 错误

public enum BridgeErrorCode: String, Codable, Sendable {
    /// 参数缺失/类型不对/取值非法
    case invalidRequest = "invalid_request"
    /// token 不匹配（本机其它程序试图驱动讨论）
    case unauthenticated = "unauthenticated"
    /// 查不到讨论组 / 任务 / Profile
    case notFound = "not_found"
    /// 同名讨论任务已在跑
    case busy = "busy"
    /// 未授予辅助功能权限
    case accessibility = "accessibility"
    /// 某个成员未登录（附一键登录信息）
    case loginRequired = "login_required"
    case timeout = "timeout"
    case cancelled = "cancelled"
    case internalError = "internal"
}

public struct BridgeError: Codable, Sendable, Error, Equatable {
    public var code: BridgeErrorCode
    public var message: String
    /// 给调用方（通常是模型）的下一步建议。
    public var hint: String?

    public init(code: BridgeErrorCode, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}

// MARK: - 操作与封套

public enum BridgeOp: String, Codable, Sendable, CaseIterable {
    /// 握手：版本、能力、权限状态
    case ping
    /// 内置角色模板列表
    case roles
    /// 本机可用 Chrome Profile 列表
    case profiles
    /// 已保存的讨论组列表
    case groups
    /// 阻塞式跑完一场讨论，直接返回结论
    case run
    /// 异步起一场讨论，立即返回 jobId
    case start
    /// 查询任务进度
    case status
    /// 取任务结论（未完成则报错）
    case result
    /// 取消任务
    case cancel
}

public struct BridgeRequest: Codable, Sendable {
    public var token: String
    public var op: BridgeOp
    /// 与该 op 对应的请求体；无参数操作可为空。
    public var payload: JSONValue?

    public init(token: String, op: BridgeOp, payload: JSONValue? = nil) {
        self.token = token
        self.op = op
        self.payload = payload
    }
}

public struct BridgeResponse: Codable, Sendable {
    public var ok: Bool
    public var result: JSONValue?
    public var error: BridgeError?

    public init(ok: Bool, result: JSONValue? = nil, error: BridgeError? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(_ result: JSONValue) -> BridgeResponse {
        BridgeResponse(ok: true, result: result)
    }

    public static func failure(_ error: BridgeError) -> BridgeResponse {
        BridgeResponse(ok: false, error: error)
    }

    /// 把某个 Codable 结果装进封套。
    ///
    /// 刻意不叫 `success` —— 与上面的 `success(_ result: JSONValue)` 重载会让
    /// 调用点产生歧义（`JSONValue` 自身也是 `Encodable`）。
    public static func encoding<T: Encodable>(_ value: T) -> BridgeResponse {
        guard let data = try? BridgeJSON.encode(value),
              let json = try? BridgeJSON.decode(JSONValue.self, from: data) else {
            return .failure(BridgeError(code: .internalError, message: "结果无法序列化"))
        }
        return BridgeResponse(ok: true, result: json)
    }

    /// 取出结果并解码成指定类型。
    public func decodedResult<T: Decodable>(_ type: T.Type) throws -> T {
        guard ok, let result else {
            throw error ?? BridgeError(code: .internalError, message: "桥接返回了空结果")
        }
        let data = try BridgeJSON.encode(result)
        return try BridgeJSON.decode(type, from: data)
    }
}

// MARK: - 握手

/// 线协议版本。**加字段不算破坏**，删字段/改语义才需要 +1。
public enum BridgeProtocol {
    public static let version = 1
    /// `~/Library/Application Support/AIDiscussion/` 下的固定文件名
    public static let socketFileName = "bridge.sock"
    public static let tokenFileName = "bridge.token"
    public static let metaFileName = "bridge.json"
}

public struct BridgeCapabilities: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var appVersion: String
    public var operations: [String]
    public var accessibilityGranted: Bool
    /// 已保存讨论组数量
    public var groups: Int
    /// 可用的 Chrome Profile 数量
    public var profiles: Int
    /// 正在跑的任务数（含 MCP 起的与界面起的）
    public var activeJobs: Int

    public init(
        protocolVersion: Int,
        appVersion: String,
        operations: [String],
        accessibilityGranted: Bool,
        groups: Int,
        profiles: Int,
        activeJobs: Int
    ) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.operations = operations
        self.accessibilityGranted = accessibilityGranted
        self.groups = groups
        self.profiles = profiles
        self.activeJobs = activeJobs
    }
}

// MARK: - 目录类 DTO

public struct BridgeRoleTemplate: Codable, Sendable, Equatable {
    public var name: String
    public var rolePrompt: String
    public var avatarSymbol: String
    public var accentHex: String

    public init(name: String, rolePrompt: String, avatarSymbol: String, accentHex: String) {
        self.name = name
        self.rolePrompt = rolePrompt
        self.avatarSymbol = avatarSymbol
        self.accentHex = accentHex
    }
}

public struct BridgeProfile: Codable, Sendable, Equatable {
    /// Chrome 内部目录名，如 `Profile 3`
    public var directory: String
    /// 用户在 Chrome 里起的名字
    public var displayName: String
    /// 建议用于身份校验的账号标识（优先用户设置的别名）
    public var suggestedIdentity: String
    /// 用户为该 Profile 设置的邮箱别名
    public var alias: String?

    public init(directory: String, displayName: String, suggestedIdentity: String, alias: String?) {
        self.directory = directory
        self.displayName = displayName
        self.suggestedIdentity = suggestedIdentity
        self.alias = alias
    }
}

public struct BridgeGroupSummary: Codable, Sendable, Equatable {
    public var name: String
    public var topic: String
    public var participants: [String]
    public var rounds: [String]
    public var consensus: String
    public var moderator: String?

    public init(
        name: String,
        topic: String,
        participants: [String],
        rounds: [String],
        consensus: String,
        moderator: String?
    ) {
        self.name = name
        self.topic = topic
        self.participants = participants
        self.rounds = rounds
        self.consensus = consensus
        self.moderator = moderator
    }
}

// MARK: - 讨论规格（调用方 → app）

public struct BridgeParticipantSpec: Codable, Sendable, Equatable {
    /// 显示名，也是轮次里引用发言人的键
    public var name: String
    /// 角色设定。与 `preset` 二选一；两者都给时以 `role` 为准。
    public var role: String?
    /// 内置角色模板名（`roles` 操作返回的 name）
    public var preset: String?
    /// Chrome Profile 目录名，如 `Profile 3`。省略时由 app 自动分配未占用的 Profile。
    public var profile: String?
    /// 身份校验标识（邮箱或显示名）。省略时取 Profile 的显示名。
    public var account: String?
    public var enabled: Bool?

    public init(
        name: String,
        role: String? = nil,
        preset: String? = nil,
        profile: String? = nil,
        account: String? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.role = role
        self.preset = preset
        self.profile = profile
        self.account = account
        self.enabled = enabled
    }
}

public struct BridgeRoundSpec: Codable, Sendable, Equatable {
    /// independentOpinion | crossExamination | convergence
    public var kind: String?
    public var title: String?
    public var instruction: String?
    /// none | others | all
    public var visibility: String?
    /// 发言人（按成员显示名或成员 id）
    public var speakers: [String]?

    public init(
        kind: String? = nil,
        title: String? = nil,
        instruction: String? = nil,
        visibility: String? = nil,
        speakers: [String]? = nil
    ) {
        self.kind = kind
        self.title = title
        self.instruction = instruction
        self.visibility = visibility
        self.speakers = speakers
    }
}

public struct BridgeDiscussionSpec: Codable, Sendable, Equatable {
    /// 议题（要决策的问题）。用 `group` 时可选。
    public var topic: String?
    /// 讨论组显示名，缺省自动生成
    public var name: String?
    /// 复用已保存的讨论组（按名字，忽略大小写）。给了它就只需再给 `topic` 覆盖议题。
    public var group: String?
    public var participants: [BridgeParticipantSpec]?
    public var rounds: [BridgeRoundSpec]?
    /// moderatorSummary | majorityVote | unanimous | chairmanDecides
    public var consensus: String?
    /// 主席的成员名，省略则取第一个启用成员
    public var moderator: String?
    /// 阻塞式 `run` 的最长等待秒数，超时返回 timeout 错误
    public var timeoutSeconds: Int?
    /// 是否把结果写进分子档案库（默认 true）
    public var persist: Bool?

    public init(
        topic: String? = nil,
        name: String? = nil,
        group: String? = nil,
        participants: [BridgeParticipantSpec]? = nil,
        rounds: [BridgeRoundSpec]? = nil,
        consensus: String? = nil,
        moderator: String? = nil,
        timeoutSeconds: Int? = nil,
        persist: Bool? = nil
    ) {
        self.topic = topic
        self.name = name
        self.group = group
        self.participants = participants
        self.rounds = rounds
        self.consensus = consensus
        self.moderator = moderator
        self.timeoutSeconds = timeoutSeconds
        self.persist = persist
    }
}

// MARK: - 讨论结果（app → 调用方）

public struct BridgeUtterance: Codable, Sendable, Equatable {
    public var roundIndex: Int
    public var roundTitle: String
    public var participant: String
    /// pending | sent | received | failed
    public var status: String
    public var prompt: String
    public var response: String?
    /// 实际使用的账号（审计：防止发错人）
    public var accountUsed: String?

    public init(
        roundIndex: Int,
        roundTitle: String,
        participant: String,
        status: String,
        prompt: String,
        response: String?,
        accountUsed: String?
    ) {
        self.roundIndex = roundIndex
        self.roundTitle = roundTitle
        self.participant = participant
        self.status = status
        self.prompt = prompt
        self.response = response
        self.accountUsed = accountUsed
    }
}

public struct BridgeAuditEntry: Codable, Sendable, Equatable {
    public var participant: String
    public var profile: String
    public var account: String
    public var utterances: Int

    public init(participant: String, profile: String, account: String, utterances: Int) {
        self.participant = participant
        self.profile = profile
        self.account = account
        self.utterances = utterances
    }
}

public struct BridgeOutcome: Codable, Sendable, Equatable {
    public var runId: String
    public var jobId: String?
    public var groupName: String
    public var topic: String
    /// converged | failed | cancelled
    public var state: String
    public var finalDecision: String?
    public var errorMessage: String?
    public var utterances: [BridgeUtterance]
    public var audit: [BridgeAuditEntry]
    public var startedAt: String?
    public var finishedAt: String?

    public init(
        runId: String,
        jobId: String? = nil,
        groupName: String,
        topic: String,
        state: String,
        finalDecision: String?,
        errorMessage: String?,
        utterances: [BridgeUtterance],
        audit: [BridgeAuditEntry],
        startedAt: String? = nil,
        finishedAt: String? = nil
    ) {
        self.runId = runId
        self.jobId = jobId
        self.groupName = groupName
        self.topic = topic
        self.state = state
        self.finalDecision = finalDecision
        self.errorMessage = errorMessage
        self.utterances = utterances
        self.audit = audit
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct BridgeLoginIssue: Codable, Sendable, Equatable {
    public var participant: String
    public var profile: String
    public var accountHint: String
    public var loginURL: String

    public init(participant: String, profile: String, accountHint: String, loginURL: String) {
        self.participant = participant
        self.profile = profile
        self.accountHint = accountHint
        self.loginURL = loginURL
    }
}

public struct BridgeJobSnapshot: Codable, Sendable, Equatable {
    public var jobId: String
    public var runId: String
    public var groupName: String
    public var topic: String
    public var state: String
    public var isFinished: Bool
    public var currentRound: Int
    public var totalRounds: Int
    public var currentParticipant: String?
    public var completedUtterances: Int
    public var expectedUtterances: Int
    /// 一句人话进度，方便模型直接转述
    public var progressText: String
    public var errorMessage: String?
    public var loginIssue: BridgeLoginIssue?
    public var startedAt: String?

    public init(
        jobId: String,
        runId: String,
        groupName: String,
        topic: String,
        state: String,
        isFinished: Bool,
        currentRound: Int,
        totalRounds: Int,
        currentParticipant: String?,
        completedUtterances: Int,
        expectedUtterances: Int,
        progressText: String,
        errorMessage: String?,
        loginIssue: BridgeLoginIssue?,
        startedAt: String?
    ) {
        self.jobId = jobId
        self.runId = runId
        self.groupName = groupName
        self.topic = topic
        self.state = state
        self.isFinished = isFinished
        self.currentRound = currentRound
        self.totalRounds = totalRounds
        self.currentParticipant = currentParticipant
        self.completedUtterances = completedUtterances
        self.expectedUtterances = expectedUtterances
        self.progressText = progressText
        self.errorMessage = errorMessage
        self.loginIssue = loginIssue
        self.startedAt = startedAt
    }
}

public struct BridgeStartedJob: Codable, Sendable, Equatable {
    public var jobId: String
    public var runId: String
    public var groupName: String
    public var topic: String
    public var totalRounds: Int
    public var expectedUtterances: Int

    public init(
        jobId: String,
        runId: String,
        groupName: String,
        topic: String,
        totalRounds: Int,
        expectedUtterances: Int
    ) {
        self.jobId = jobId
        self.runId = runId
        self.groupName = groupName
        self.topic = topic
        self.totalRounds = totalRounds
        self.expectedUtterances = expectedUtterances
    }
}

// MARK: - 任务引用与状态

/// `status` / `result` / `cancel` 的请求体。
public struct BridgeJobRef: Codable, Sendable, Equatable {
    public var jobId: String?

    public init(jobId: String? = nil) {
        self.jobId = jobId
    }
}

public struct BridgeCancelResult: Codable, Sendable, Equatable {
    public var jobId: String
    /// 取消时任务其实已经结束（幂等：不算错误）
    public var alreadyFinished: Bool

    public init(jobId: String, alreadyFinished: Bool) {
        self.jobId = jobId
        self.alreadyFinished = alreadyFinished
    }
}

/// `status` 不带 jobId 时的返回：桥接自身状态 + 所有在跑的任务。
public struct BridgeBridgeStatus: Codable, Sendable, Equatable {
    public var capabilities: BridgeCapabilities
    public var activeJobs: [BridgeJobSnapshot]

    public init(capabilities: BridgeCapabilities, activeJobs: [BridgeJobSnapshot]) {
        self.capabilities = capabilities
        self.activeJobs = activeJobs
    }
}

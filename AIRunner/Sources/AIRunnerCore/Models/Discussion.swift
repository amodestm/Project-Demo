import Foundation

// MARK: - 参与者

/// 讨论组里的一个"成员"。
///
/// ## ★ 差异化是唯一的质量来源 ★
///
/// 所有账号背后都是同一个 ChatGPT —— 如果 `rolePrompt` 不给出**互斥的立场**,
/// 讨论会退化成互相附和(回声室)。配置界面必须引导用户写清楚"这个角色专门负责挑什么毛病"。
public struct DiscussionParticipant: Codable, Sendable, Equatable, Identifiable {

    public let id: String
    /// 显示名, 如「批判者」「成本专家」。
    public var displayName: String
    /// 角色设定 (system prompt)。决定这个成员看问题的角度。
    public var rolePrompt: String
    /// 聊天头像用的 SF Symbol。
    public var avatarSymbol: String
    /// 头像主色 (hex, 如 "#FF6B9D")。
    public var accentHex: String
    /// 绑定的 Chrome Profile 目录名, 如 "Profile 3"。
    public var profileDirectory: String
    /// 账号校验标识。默认采用 Chrome Profile 显示名称；实际邮箱与其不一致时
    /// 保存用户输入的邮箱，用于校验“当前窗口确实是这个账号”(S2)。
    public var emailHint: String
    public var enabled: Bool

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        rolePrompt: String,
        avatarSymbol: String = "person.crop.circle.fill",
        accentHex: String = DiscussionPalette.defaultHex,
        profileDirectory: String = "",
        emailHint: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.rolePrompt = rolePrompt
        self.avatarSymbol = avatarSymbol
        self.accentHex = accentHex
        self.profileDirectory = profileDirectory
        self.emailHint = emailHint
        self.enabled = enabled
    }
}

// MARK: - 轮次

/// 一轮讨论的性质。
public enum DiscussionRoundKind: String, Codable, Sendable, CaseIterable {
    /// 独立论述: 看不到任何人的发言, 避免被带节奏。
    case independentOpinion
    /// 交叉质询: 能看到其他人的发言并反驳。
    case crossExamination
    /// 收敛: 主席汇总, 产出最终决策。
    case convergence

    public var displayName: String {
        switch self {
        case .independentOpinion: return "独立论述"
        case .crossExamination:   return "交叉质询"
        case .convergence:        return "收敛决策"
        }
    }

    public var defaultTitle: String {
        switch self {
        case .independentOpinion: return "第 1 轮 · 各自表态"
        case .crossExamination:   return "交叉质询"
        case .convergence:        return "主席收敛"
        }
    }
}

/// 本轮发言人能看到谁的输出。
public enum RoundVisibility: String, Codable, Sendable, CaseIterable {
    /// 谁都看不到 (独立论述)。
    case none
    /// 只能看到其他人 (不含自己上一轮)。
    case others
    /// 全部可见。
    case all

    public var displayName: String {
        switch self {
        case .none:   return "不看他人"
        case .others: return "看他人"
        case .all:    return "看全部"
        }
    }
}

public struct DiscussionRoundConfig: Codable, Sendable, Equatable, Identifiable {

    public let id: String
    public var kind: DiscussionRoundKind
    public var title: String
    /// 本轮额外指令 (如"请指出他人方案里成本最高的部分")。
    public var instruction: String
    /// 发言人顺序; 空 = 全部启用成员按配置顺序。
    public var speakerIDs: [String]
    public var visibility: RoundVisibility

    public init(
        id: String = UUID().uuidString,
        kind: DiscussionRoundKind,
        title: String? = nil,
        instruction: String = "",
        speakerIDs: [String] = [],
        visibility: RoundVisibility? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.defaultTitle
        self.instruction = instruction
        self.speakerIDs = speakerIDs
        // 默认可见性由轮次性质决定: 独立论述天然不该看到别人
        self.visibility = visibility ?? (kind == .independentOpinion ? .none : .others)
    }
}

// MARK: - 收敛规则

public enum ConsensusRule: String, Codable, Sendable, CaseIterable {
    /// 主席汇总各方观点给出决策。
    case moderatorSummary
    /// 多数投票。
    case majorityVote
    /// 一致同意, 否则再来一轮。
    case unanimous
    /// 主席独裁 (不解释)。
    case chairmanDecides

    public var displayName: String {
        switch self {
        case .moderatorSummary:  return "主席汇总"
        case .majorityVote:      return "多数投票"
        case .unanimous:         return "一致同意"
        case .chairmanDecides:   return "主席独裁"
        }
    }

    public var detail: String {
        switch self {
        case .moderatorSummary:  return "由主席读完所有发言后给出最终决策与理由。"
        case .majorityVote:      return "各成员独立投票, 取多数; 平票时由主席裁决。"
        case .unanimous:         return "必须全部同意, 否则自动追加一轮质询。"
        case .chairmanDecides:   return "主席直接拍板, 不要求汇总理由。"
        }
    }
}

// MARK: - 讨论组配置

/// 一次讨论的**配置** (可复用、可持久化)。
public struct DiscussionGroup: Codable, Sendable, Equatable, Identifiable {

    public let id: String
    public var name: String
    /// 议题 / 要决策的问题。
    public var topic: String
    /// 讨论输入附带的本地文件。文件内容不进配置 JSON，运行时由会话上传。
    public var attachments: [DiscussionAttachment]
    public var participants: [DiscussionParticipant]
    public var rounds: [DiscussionRoundConfig]
    public var consensus: ConsensusRule
    /// 主席成员 id; nil = 取第一个启用成员。
    public var moderatorParticipantID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        topic: String = "",
        attachments: [DiscussionAttachment] = [],
        participants: [DiscussionParticipant] = [],
        rounds: [DiscussionRoundConfig]? = nil,
        consensus: ConsensusRule = .moderatorSummary,
        moderatorParticipantID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.topic = topic
        self.attachments = attachments
        self.participants = participants
        self.rounds = rounds ?? Self.defaultRounds
        self.consensus = consensus
        self.moderatorParticipantID = moderatorParticipantID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, topic, attachments, participants, rounds, consensus
        case moderatorParticipantID, createdAt, updatedAt
    }

    /// 附件字段是后加的，旧版讨论组没有该 key 时按空数组兼容读取。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.topic = try container.decode(String.self, forKey: .topic)
        self.attachments = try container.decodeIfPresent(
            [DiscussionAttachment].self, forKey: .attachments
        ) ?? []
        self.participants = try container.decode([DiscussionParticipant].self, forKey: .participants)
        self.rounds = try container.decode([DiscussionRoundConfig].self, forKey: .rounds)
        self.consensus = try container.decode(ConsensusRule.self, forKey: .consensus)
        self.moderatorParticipantID = try container.decodeIfPresent(
            String.self, forKey: .moderatorParticipantID
        )
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(topic, forKey: .topic)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(participants, forKey: .participants)
        try container.encode(rounds, forKey: .rounds)
        try container.encode(consensus, forKey: .consensus)
        try container.encodeIfPresent(moderatorParticipantID, forKey: .moderatorParticipantID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// 默认议程: 独立论述 → 交叉质询 → 主席收敛。
    public static var defaultRounds: [DiscussionRoundConfig] {
        [
            DiscussionRoundConfig(
                kind: .independentOpinion,
                title: "第 1 轮 · 各自表态",
                instruction: "请独立给出你的判断和理由, 不要迎合任何人。"
            ),
            DiscussionRoundConfig(
                kind: .crossExamination,
                title: "第 2 轮 · 交叉质询",
                instruction: "请指出他人方案中你最不认同的一点, 并给出替代方案。"
            ),
            DiscussionRoundConfig(
                kind: .convergence,
                title: "收敛 · 最终决策",
                instruction: "综合所有发言, 给出最终决策、理由与主要风险。"
            ),
        ]
    }

    public var enabledParticipants: [DiscussionParticipant] {
        participants.filter(\.enabled)
    }

    /// 主席: 显式指定优先, 否则取第一个启用成员。
    public func moderator() -> DiscussionParticipant? {
        if let id = moderatorParticipantID,
           let hit = enabledParticipants.first(where: { $0.id == id }) {
            return hit
        }
        return enabledParticipants.first
    }
}

// MARK: - 发言与运行

public enum UtteranceStatus: String, Codable, Sendable {
    case pending
    case sent
    case received
    case failed

    public var displayName: String {
        switch self {
        case .pending:  return "待发言"
        case .sent:     return "已发送"
        case .received: return "已收到"
        case .failed:   return "失败"
        }
    }
}

/// 一条发言 (完整留痕, 可审计)。
public struct DiscussionUtterance: Codable, Sendable, Equatable, Identifiable {

    public let id: String
    public var runID: String
    public var roundIndex: Int
    public var participantID: String
    /// 实际发出的完整 prompt。
    public var promptSent: String
    public var responseText: String?
    /// 实际使用的账号 (审计: 防止发错人)。
    public var accountEmailUsed: String?
    public var status: UtteranceStatus
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        runID: String,
        roundIndex: Int,
        participantID: String,
        promptSent: String,
        responseText: String? = nil,
        accountEmailUsed: String? = nil,
        status: UtteranceStatus = .pending,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.roundIndex = roundIndex
        self.participantID = participantID
        self.promptSent = promptSent
        self.responseText = responseText
        self.accountEmailUsed = accountEmailUsed
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public enum DiscussionRunState: String, Codable, Sendable {
    case idle
    case running
    /// 已发出, 正在等对方回复 (UI 显示"正在思考")。
    case waitingForResponse
    case converged
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .idle:                return "待开始"
        case .running:             return "进行中"
        case .waitingForResponse:  return "等待回复"
        case .converged:           return "已收敛"
        case .failed:              return "失败"
        case .cancelled:           return "已取消"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .converged, .failed, .cancelled: return true
        case .idle, .running, .waitingForResponse: return false
        }
    }
}

/// 一次讨论的**运行时** (落盘, 崩溃可恢复)。
public struct DiscussionRun: Codable, Sendable, Equatable, Identifiable {

    public let id: String
    public var groupID: String
    public var state: DiscussionRunState
    public var currentRound: Int
    public var currentParticipantID: String?
    public var finalDecision: String?
    public var errorMessage: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: String = UUID().uuidString,
        groupID: String,
        state: DiscussionRunState = .idle,
        currentRound: Int = 0,
        currentParticipantID: String? = nil,
        finalDecision: String? = nil,
        errorMessage: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.state = state
        self.currentRound = currentRound
        self.currentParticipantID = currentParticipantID
        self.finalDecision = finalDecision
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

// MARK: - 头像配色

/// 预设头像色 —— 保证多个成员在界面上**一眼可分**。
public enum DiscussionPalette: Sendable {

    public static let defaultHex = "#7C9CFF"

    public static let options: [(name: String, hex: String)] = [
        ("蓝",   "#7C9CFF"),
        ("粉",   "#FF6B9D"),
        ("绿",   "#4CD4A0"),
        ("橙",   "#FFA94D"),
        ("紫",   "#B48CFF"),
        ("青",   "#4ECDC4"),
        ("红",   "#FF7B72"),
        ("黄",   "#FFD166"),
    ]

    public static let avatarSymbols: [String] = [
        "person.crop.circle.fill",
        "brain.head.profile",
        "flame.fill",
        "leaf.fill",
        "bolt.fill",
        "scope",
        "hammer.fill",
        "lightbulb.fill",
        "shield.fill",
        "sparkles",
    ]

    /// 按顺序给成员分配互不相同的颜色。
    public static func hex(for index: Int) -> String {
        options[index % options.count].hex
    }

    public static func symbol(for index: Int) -> String {
        avatarSymbols[index % avatarSymbols.count]
    }
}

// MARK: - 预设角色

/// 开箱即用的角色模板。
///
/// ## ★ 为什么必须有这个 ★
///
/// 所有账号背后都是同一个 ChatGPT —— 如果角色设定不互斥, 讨论必然退化成
/// 互相附和的回声室。这些模板的 `rolePrompt` **刻意只给一个维度并禁止越界**
/// (批判者不许提建设意见、成本专家不许谈体验), 用强制片面换取观点差异。
public enum DiscussionPresets: Sendable {

    public struct RoleTemplate: Sendable {
        public let displayName: String
        public let rolePrompt: String
        public let avatarSymbol: String
        public let accentHex: String

        public init(
            displayName: String,
            rolePrompt: String,
            avatarSymbol: String,
            accentHex: String
        ) {
            self.displayName = displayName
            self.rolePrompt = rolePrompt
            self.avatarSymbol = avatarSymbol
            self.accentHex = accentHex
        }
    }

    public static let roles: [RoleTemplate] = [
        RoleTemplate(
            displayName: "批判者",
            rolePrompt: """
            你专门负责挑毛病。请找出方案中的逻辑漏洞、未经验证的假设、
            以及可能被忽略的失败场景。不要提出建设性意见, 也不要肯定任何人 —— 只负责质疑。
            """,
            avatarSymbol: "flame.fill",
            accentHex: "#FF7B72"
        ),
        RoleTemplate(
            displayName: "成本专家",
            rolePrompt: """
            你只从成本角度看待一切。请估算方案的时间、金钱与人力开销,
            并指出性价比最低的部分。忽略体验与技术优雅性 —— 那不是你的职责。
            """,
            avatarSymbol: "dollarsign.circle.fill",
            accentHex: "#4CD4A0"
        ),
        RoleTemplate(
            displayName: "乐观派",
            rolePrompt: """
            你负责寻找机会与上行空间。请指出这个方案可能带来的最大收益与意外惊喜。
            不要讨论风险 —— 有别人负责。
            """,
            avatarSymbol: "sun.max.fill",
            accentHex: "#FFD166"
        ),
        RoleTemplate(
            displayName: "用户代言人",
            rolePrompt: """
            你只代表最终用户。请从使用体验、学习成本与真实需求出发评价方案,
            完全忽略技术实现难度与内部成本。
            """,
            avatarSymbol: "person.fill",
            accentHex: "#B48CFF"
        ),
        RoleTemplate(
            displayName: "风险官",
            rolePrompt: """
            你只关注最坏情况。请列出可能导致彻底失败的因素,
            以及一旦失败的最大损失与不可逆后果。
            """,
            avatarSymbol: "shield.fill",
            accentHex: "#FF6B9D"
        ),
        RoleTemplate(
            displayName: "执行者",
            rolePrompt: """
            你只关心能不能落地。请评估可执行性、前置依赖与明确的第一个动作。
            不要评价方案好坏, 只回答"明天能不能开始做"。
            """,
            avatarSymbol: "hammer.fill",
            accentHex: "#4ECDC4"
        ),
    ]

    /// 生成一个默认讨论组 (3 个互斥角色 + 默认议程), 用于"新建讨论组"。
    public static func starterGroup(name: String = "新的讨论") -> DiscussionGroup {
        let picks = [roles[0], roles[1], roles[4]]
        let participants = picks.enumerated().map { index, role in
            DiscussionParticipant(
                displayName: role.displayName,
                rolePrompt: role.rolePrompt,
                avatarSymbol: role.avatarSymbol,
                accentHex: role.accentHex
            )
        }
        return DiscussionGroup(name: name, participants: participants)
    }
}

import Foundation

// MARK: - 会话抽象

/// 一个 ChatGPT 会话窗口 —— 讨论组里"某个成员的那张嘴"。
///
/// ## 为什么要有这层抽象
///
/// 真实实现需要 AX 驱动 Chrome 里的某个具体窗口: 定位窗口 → 校验账号身份 →
/// 写 Composer → 点发送 → 轮询读回。这些在单元测试里**根本无法执行**
/// (需要真机 + 辅助功能权限 + 已登录窗口)。
///
/// 抽象出来之后, 编排逻辑(轮次推进/上下文注入/收敛/断点续跑)可以
/// 用脚本化假实现**完整跑通并回归**, 真实驱动只替换这一个对象。
public protocol DiscussionSessionDriving: Sendable {

    /// 校验这个会话确实属于 `emailHint` 对应的账号标识。
    /// 标识默认是 Chrome Profile 显示名称，也可以是用户单独填写的实际邮箱。
    ///
    /// ★ 这是"不许发错人"的唯一防线 ★
    ///
    /// 校验失败必须 **fail closed** —— 宁可这一轮不发言(并报错停下),
    /// 也绝不能把成员 A 的观点发进成员 B 的窗口。发错人等于整场讨论作废。
    func verifyIdentity(emailHint: String) async throws -> Bool

    /// 当前窗口实际登录的账号标识 (审计留痕)。
    func currentAccount() async throws -> String?

    /// 发送 prompt 并等待完整回复。
    /// - Returns: 读回的完整回复文本。
    func send(prompt: String) async throws -> String
}

/// 按成员提供会话。
public protocol DiscussionSessionProviding: Sendable {
    func session(for participant: DiscussionParticipant) async throws -> DiscussionSessionDriving
}

// MARK: - 脚本化实现 (跑通逻辑 / 单元测试 / UI 演示)

/// 按预设规则生成回复的会话 —— 不碰任何真实窗口。
///
/// 用途:
/// - 单元测试里验证编排逻辑(轮次顺序、上下文注入、收敛、续跑)
/// - 没有真实窗口时演示 UI(多个 agent 轮流"说话")
///
/// 绝不用于生产真实讨论。
public struct ScriptedDiscussionSession: DiscussionSessionDriving {

    /// 该会话"登录"的账号标识。
    public let account: String
    /// 模拟思考耗时 (UI 的加载动画靠它才有东西可看)。
    public let replyDelay: Duration
    private let reply: @Sendable (String) -> String

    public init(
        account: String,
        replyDelay: Duration = .zero,
        reply: @escaping @Sendable (String) -> String = { prompt in
            "（脚本回复）已收到 \(prompt.count) 字的发言。"
        }
    ) {
        self.account = account
        self.replyDelay = replyDelay
        self.reply = reply
    }

    public func verifyIdentity(emailHint: String) async throws -> Bool {
        // 未配置 emailHint 时无法校验 —— 放行但审计仍记录实际账号
        guard !emailHint.isEmpty else { return true }
        return account.localizedCaseInsensitiveContains(emailHint)
            || emailHint.localizedCaseInsensitiveContains(account)
    }

    public func currentAccount() async throws -> String? { account }

    public func send(prompt: String) async throws -> String {
        if replyDelay > .zero {
            try? await Task.sleep(for: replyDelay)
        }
        return reply(prompt)
    }
}

/// 按 participantID 提供脚本化会话。
public struct ScriptedSessionProvider: DiscussionSessionProviding {

    private let sessions: [String: any DiscussionSessionDriving]

    public init(sessions: [String: any DiscussionSessionDriving]) {
        self.sessions = sessions
    }

    /// 便捷构造: 给每个成员按名字自动生成"能复述自己立场"的假会话。
    public init(group: DiscussionGroup, replyDelay: Duration = .milliseconds(300)) {
        var map: [String: any DiscussionSessionDriving] = [:]
        for participant in group.participants {
            let name = participant.displayName
            let role = participant.rolePrompt
            map[participant.id] = ScriptedDiscussionSession(
                account: participant.emailHint.isEmpty
                    ? participant.displayName
                    : participant.emailHint,
                replyDelay: replyDelay,
                reply: { prompt in
                    """
                    [\(name) 的观点]
                    我的立场: \(role.prefix(60))
                    针对本轮议题, 我认为需要重点关注风险与落地成本。
                    (收到提示词 \(prompt.count) 字)
                    """
                }
            )
        }
        self.sessions = map
    }

    public func session(for participant: DiscussionParticipant) async throws -> DiscussionSessionDriving {
        guard let session = sessions[participant.id] else {
            throw AppError.invalidRequest(
                "成员「\(participant.displayName)」没有可用的 ChatGPT 会话。"
                + "请先在设置里为该成员绑定已登录的 Chrome Profile。"
            )
        }
        return session
    }
}

// MARK: - 会话模式路由提供方

/// 统一管理真实 Chrome 会话与演示会话的路由提供方。
///
/// 避免系统在未完整配置 Profile 时静默冒充真实讨论，保证用户对“真实 vs 演示”有完全清晰的掌控。
public final class RoutingDiscussionSessionProvider: DiscussionSessionProviding, @unchecked Sendable {

    public enum Mode: String, Sendable, CaseIterable {
        case realChrome = "realChrome"
        case demo = "demo"

        public var displayName: String {
            switch self {
            case .realChrome: return "真实 Chrome 会话"
            case .demo:       return "演示模式（脚本假回复）"
            }
        }
    }

    private let lock = NSLock()
    private var _mode: Mode
    private let realProvider: any DiscussionSessionProviding
    private var scriptedProvider: any DiscussionSessionProviding

    public var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); defer { lock.unlock() }; _mode = newValue }
    }

    public init(
        mode: Mode = .realChrome,
        realProvider: any DiscussionSessionProviding,
        scriptedProvider: any DiscussionSessionProviding
    ) {
        self._mode = mode
        self.realProvider = realProvider
        self.scriptedProvider = scriptedProvider
    }

    public func updateScriptedGroup(_ group: DiscussionGroup) {
        lock.lock(); defer { lock.unlock() }
        self.scriptedProvider = ScriptedSessionProvider(group: group)
    }

    public func session(for participant: DiscussionParticipant) async throws -> any DiscussionSessionDriving {
        let currentMode = self.mode
        switch currentMode {
        case .realChrome:
            let profile = participant.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.isEmpty else {
                throw AppError.invalidRequest(
                    "成员「\(participant.displayName)」未绑定 Chrome Profile。请先在「配置」中选择已登录的账号。"
                )
            }
            return try await realProvider.session(for: participant)
        case .demo:
            return try await scriptedProvider.session(for: participant)
        }
    }
}


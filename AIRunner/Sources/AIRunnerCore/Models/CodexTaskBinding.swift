import Foundation

/// 用户手动绑定的一个"已存在的 Codex 长任务线程"。
///
/// ## ★ 这个模型里不存在任何认证信息 ★
///
/// 没有 email、没有 password、没有 cookie、没有 session token、
/// 没有 authentication storage。存的全是"如何在自己的 UI 里重新找到那个线程"
/// 的可重建定位信息。
///
/// 之所以强调这点: 程序要能在用户**自己**完成登录之后接着干活,
/// 但它永远不需要、也不应该知道"当前是哪个账号"。
public struct CodexTaskBinding: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    /// 关联的 AIRunner 任务。可为空 —— 允许先绑定再建任务。
    public var taskID: String?

    /// 线程标题 (UI 上可见的那个)。
    public var displayTitle: String
    public var projectName: String?
    public var repositoryPath: String?
    public var worktreePath: String?

    /// 目标 App 的 bundle id —— **绑定那一刻从真实 App 读取**, 不硬编码。
    public var applicationBundleIdentifier: String
    public var applicationName: String?
    public var windowTitleHint: String?

    /// 该绑定使用的 Chrome Profile 目录名 (如 "Default" / "Profile 1")。
    ///
    /// ## 为什么用它实现"自动切换账号"
    ///
    /// 每个 Chrome Profile 是**独立的登录环境**。用户在每个 profile 里手动登录一次后,
    /// session 长期有效。切换账号 = 用另一个 profile 打开 ChatGPT ——
    /// **不读密码、不读 Cookie、不碰 token**, 只调用 Chrome 自己的 `--profile-directory`。
    public var chromeProfileDirectory: String?

    /// 重新识别同一线程所需的信号集合。
    public var fingerprint: CodexTaskFingerprint

    /// 自动恢复时发送的内容。默认「继续」。
    public var resumeMessage: String

    public var lastVerifiedAt: Date?
    public var lastResumeSentAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        taskID: String? = nil,
        displayTitle: String,
        projectName: String? = nil,
        repositoryPath: String? = nil,
        worktreePath: String? = nil,
        applicationBundleIdentifier: String,
        applicationName: String? = nil,
        windowTitleHint: String? = nil,
        chromeProfileDirectory: String? = nil,
        fingerprint: CodexTaskFingerprint,
        resumeMessage: String = "继续",
        lastVerifiedAt: Date? = nil,
        lastResumeSentAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.displayTitle = displayTitle
        self.projectName = projectName
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationName = applicationName
        self.windowTitleHint = windowTitleHint
        self.chromeProfileDirectory = chromeProfileDirectory
        self.fingerprint = fingerprint
        self.resumeMessage = resumeMessage
        self.lastVerifiedAt = lastVerifiedAt
        self.lastResumeSentAt = lastResumeSentAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 距离上次发送是否已经超过冷却期。
    public func isCoolingDown(cooldown: TimeInterval, at now: Date = Date()) -> Bool {
        guard let last = lastResumeSentAt else { return false }
        return now.timeIntervalSince(last) < cooldown
    }

    /// 冷却剩余时间。返回 nil 表示不在冷却中。
    public func cooldownRemaining(cooldown: TimeInterval, at now: Date = Date()) -> TimeInterval? {
        guard let last = lastResumeSentAt else { return nil }
        let remaining = cooldown - now.timeIntervalSince(last)
        return remaining > 0 ? remaining : nil
    }

    public var displayTarget: String {
        applicationName ?? applicationBundleIdentifier
    }
}

/// 用于**重新识别同一个线程**的信号集合。
///
/// ## 两条硬规则
///
/// 1. **拿不到就不填。** 绝不用猜测值或占位值填充 ——
///    一个假信号会让匹配错误地"成功", 而错误地把消息发给别的线程是本项目
///    最不可接受的失败模式。
/// 2. **匹配分档。** `exact` / `strong` / `weak` 三档, 只有唯一且非 weak 的匹配
///    才允许自动发送; 其余一律 fail closed。
public struct CodexTaskFingerprint: Codable, Sendable, Equatable, Hashable {

    /// 线程标题 —— 最可靠的单一信号。
    public var threadTitle: String?
    /// 项目 / 工作区名称。
    public var projectName: String?
    public var repositoryPath: String?
    public var worktreePath: String?
    /// 目标 App bundle id。
    public var applicationBundleIdentifier: String?
    /// 辅助信号: 会话开头的一段摘要 (仅当 UI 上确实能读到才填)。
    public var conversationPreview: String?

    public init(
        threadTitle: String? = nil,
        projectName: String? = nil,
        repositoryPath: String? = nil,
        worktreePath: String? = nil,
        applicationBundleIdentifier: String? = nil,
        conversationPreview: String? = nil
    ) {
        self.threadTitle = threadTitle
        self.projectName = projectName
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.conversationPreview = conversationPreview
    }

    /// 主信号 (标题) 是否可用。
    public var hasPrimarySignal: Bool {
        !(threadTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 除标题外的辅助信号数量。
    public var secondarySignalCount: Int {
        secondarySignals.count
    }

    /// 辅助信号键值对 (非空项)。
    public var secondarySignals: [(key: String, value: String)] {
        var result: [(String, String)] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            result.append((key, value))
        }
        add("projectName", projectName)
        add("repositoryPath", repositoryPath)
        add("worktreePath", worktreePath)
        add("applicationBundleIdentifier", applicationBundleIdentifier)
        add("conversationPreview", conversationPreview)
        return result
    }

    /// 是否具备足以做自动发送判定的信号。
    ///
    /// 只有标题是不够的 —— 标题相同的线程完全可能存在两个。
    /// 因此要求至少 1 个辅助信号, 否则即使匹配上也只能算 weak。
    public var isSufficientForAutoResume: Bool {
        hasPrimarySignal && secondarySignalCount >= 1
    }

    public var summary: String {
        var parts: [String] = []
        if let threadTitle, !threadTitle.isEmpty { parts.append("title=\(threadTitle)") }
        for signal in secondarySignals { parts.append("\(signal.key)=\(signal.value)") }
        return parts.isEmpty ? "(无信号)" : parts.joined(separator: " · ")
    }
}

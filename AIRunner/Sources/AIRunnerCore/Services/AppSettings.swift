import Foundation

/// 应用级设置。
///
/// ★ 安全红线 ★
/// 这里**绝不**包含 API Key。Key 只存在 macOS Keychain, 由 `ProviderFactory` 读取。
/// 本结构只存非敏感配置, 因此可以安全地放进 UserDefaults。
public struct AppSettings: Codable, Sendable, Equatable {

    public var providers: [ProviderConfig]
    public var routes: [RouteEntry]
    /// 全局最多同时运行的任务数。
    public var concurrency: Int
    public var retry: RetryConfiguration

    // MARK: Web 执行通道

    /// 新建任务默认使用的执行通道。默认走 Codex 桌面自动执行；旧 Web
    /// 剪贴板流程仍可在设置中显式选择。
    public var defaultExecutionMode: ExecutionMode
    /// ChatGPT Web 地址 (可改成自建网关或区域域名)。
    public var chatGPTURL: String
    /// 生成续跑 prompt 后是否自动打开浏览器。
    public var openBrowserOnPrepare: Bool
    /// 生成续跑 prompt 后是否自动写入剪贴板。
    public var copyPromptToClipboard: Bool

    // MARK: Codex Existing Thread 自动恢复

    /// 账号认证完成后, 自动恢复绑定的 Codex 任务。
    public var autoResumeAfterManualAuthentication: Bool

    /// Web 任务进入账号交接状态时, 是否立即用 Keychain 中的下一个账号自动登录。
    public var autoLoginNextChatGPTAccountOnHandoff: Bool

    /// 使用独立 Chrome Profile 的网页会话，通过 Codex 官方浏览器 OAuth 切换账号。
    /// 关闭时保留旧的钥匙串邮箱密码自动登录流程。
    public var useCodexBrowserOAuthRotation: Bool

    /// 同一绑定两次 Resume 之间的冷却 (秒)。
    public var codexResumeCooldown: TimeInterval

    /// 等待认证期间, Monitor 多久检查一次 (秒)。
    public var codexMonitorPollInterval: TimeInterval

    /// 自动恢复时发送的内容。
    public var codexResumeMessage: String

    /// 绑定的目标 App bundle id (首次绑定时从真实 App 读取后记下, 便于下次直接定位)。
    public var codexPreferredApplicationBundleIdentifier: String?

    // MARK: Chrome Profile 自动账号轮换

    /// 参与自动轮换的 Chrome profile 目录名 (有序)。
    ///
    /// 存的是目录名 ("Profile 1"), 不是凭据 —— 用户事先在每个 profile 里登录好
    /// 不同的 ChatGPT 账号。留空 = 使用浏览器里全部可用 profile。
    public var accountRotationProfileDirectories: [String]

    /// ChatGPT 网页内自动轮换的账号列表 (菜单条目文本, 通常是邮箱)。
    ///
    /// 用户事先在**同一个浏览器**里登录多个 ChatGPT 账号 (网页右上角头像 → 添加账号),
    /// 然后把它们的标识记在这里。存的只是显示名, 不是密码。
    /// 留空 = 尝试用菜单里读到的全部账号。
    public var chatGPTAccountList: [String]

    /// ChatGPT 凭据自动登录的账号 ID 有序表 (指向 Keychain 里的 `CodexAccountRecord`)。
    ///
    /// 这是"凭据为主"轮换模式的账号来源: 每个 ID 对应一条 label+email+password 记录
    /// (密码只在 macOS Keychain)。这里只存非敏感的 ID 顺序, 不存任何凭据。
    /// 留空 = 尚未配置自动登录。
    public var codexAccountRotationIDs: [String]

    /// Chrome Profile 对应的账号显示邮箱。
    ///
    /// 这是用户确认后的显示别名，只存目录名 → 邮箱映射；不从 Chrome
    /// Cookie、Google 账号信息或 ChatGPT session 中读取。
    public var accountRotationProfileAliases: [String: String]

    public init(
        providers: [ProviderConfig],
        routes: [RouteEntry],
        concurrency: Int = 3,
        retry: RetryConfiguration = .default,
        defaultExecutionMode: ExecutionMode = .codexDesktop,
        chatGPTURL: String = ChatGPTWebTarget.defaultURLString,
        openBrowserOnPrepare: Bool = true,
        copyPromptToClipboard: Bool = true,
        autoResumeAfterManualAuthentication: Bool = true,
        autoLoginNextChatGPTAccountOnHandoff: Bool = true,
        useCodexBrowserOAuthRotation: Bool = true,
        codexResumeCooldown: TimeInterval = 60,
        codexMonitorPollInterval: TimeInterval = 15,
        codexResumeMessage: String = "继续",
        codexPreferredApplicationBundleIdentifier: String? = nil,
        accountRotationProfileDirectories: [String] = [],
        chatGPTAccountList: [String] = [],
        codexAccountRotationIDs: [String] = [],
        accountRotationProfileAliases: [String: String] = [:]
    ) {
        self.providers = providers
        self.routes = routes
        self.concurrency = concurrency
        self.retry = retry
        self.defaultExecutionMode = defaultExecutionMode
        self.chatGPTURL = chatGPTURL
        self.openBrowserOnPrepare = openBrowserOnPrepare
        self.copyPromptToClipboard = copyPromptToClipboard
        self.autoResumeAfterManualAuthentication = autoResumeAfterManualAuthentication
        self.autoLoginNextChatGPTAccountOnHandoff = autoLoginNextChatGPTAccountOnHandoff
        self.useCodexBrowserOAuthRotation = useCodexBrowserOAuthRotation
        self.codexResumeCooldown = codexResumeCooldown
        self.codexMonitorPollInterval = codexMonitorPollInterval
        self.codexResumeMessage = codexResumeMessage
        self.codexPreferredApplicationBundleIdentifier =
            codexPreferredApplicationBundleIdentifier
        self.accountRotationProfileDirectories = accountRotationProfileDirectories
        self.chatGPTAccountList = chatGPTAccountList
        self.codexAccountRotationIDs = codexAccountRotationIDs
        self.accountRotationProfileAliases = accountRotationProfileAliases
    }

    /// 手写解码, 让**老版本存下的配置能平滑升级**。
    ///
    /// 合成的 `init(from:)` 会要求每个非可选字段都存在 —— 那样一旦新增字段,
    /// 用户已有的路由表与 Provider 设置就会整份失效并被打回出厂值。
    /// 这里全部用 `decodeIfPresent` + 默认值兜底。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        providers = try container.decodeIfPresent([ProviderConfig].self, forKey: .providers)
            ?? ProviderConfig.defaults
        routes = try container.decodeIfPresent([RouteEntry].self, forKey: .routes)
            ?? RouteEntry.defaults
        concurrency = try container.decodeIfPresent(Int.self, forKey: .concurrency) ?? 3
        retry = try container.decodeIfPresent(RetryConfiguration.self, forKey: .retry) ?? .default

        defaultExecutionMode = try container
            .decodeIfPresent(ExecutionMode.self, forKey: .defaultExecutionMode) ?? .codexDesktop
        chatGPTURL = try container
            .decodeIfPresent(String.self, forKey: .chatGPTURL)
            ?? ChatGPTWebTarget.defaultURLString
        openBrowserOnPrepare = try container
            .decodeIfPresent(Bool.self, forKey: .openBrowserOnPrepare) ?? true
        copyPromptToClipboard = try container
            .decodeIfPresent(Bool.self, forKey: .copyPromptToClipboard) ?? true

        autoResumeAfterManualAuthentication = try container
            .decodeIfPresent(Bool.self, forKey: .autoResumeAfterManualAuthentication) ?? true
        autoLoginNextChatGPTAccountOnHandoff = try container
            .decodeIfPresent(Bool.self, forKey: .autoLoginNextChatGPTAccountOnHandoff) ?? true
        useCodexBrowserOAuthRotation = try container
            .decodeIfPresent(Bool.self, forKey: .useCodexBrowserOAuthRotation) ?? false
        codexResumeCooldown = try container
            .decodeIfPresent(TimeInterval.self, forKey: .codexResumeCooldown) ?? 60
        codexMonitorPollInterval = try container
            .decodeIfPresent(TimeInterval.self, forKey: .codexMonitorPollInterval) ?? 15
        codexResumeMessage = try container
            .decodeIfPresent(String.self, forKey: .codexResumeMessage) ?? "继续"
        codexPreferredApplicationBundleIdentifier = try container
            .decodeIfPresent(String.self, forKey: .codexPreferredApplicationBundleIdentifier)
        accountRotationProfileDirectories = try container
            .decodeIfPresent([String].self, forKey: .accountRotationProfileDirectories) ?? []
        chatGPTAccountList = try container
            .decodeIfPresent([String].self, forKey: .chatGPTAccountList) ?? []
        codexAccountRotationIDs = try container
            .decodeIfPresent([String].self, forKey: .codexAccountRotationIDs) ?? []
        accountRotationProfileAliases = try container
            .decodeIfPresent([String: String].self, forKey: .accountRotationProfileAliases) ?? [:]
    }

    public static let `default` = AppSettings(
        providers: ProviderConfig.defaults,
        routes: RouteEntry.defaults
    )

    public var sortedRoutes: [RouteEntry] {
        routes.sorted { $0.priority < $1.priority }
    }

    public var enabledRoutes: [RouteEntry] {
        sortedRoutes.filter(\.enabled)
    }

    public var primaryRoute: RouteEntry? {
        enabledRoutes.first
    }

    /// 把 priority 重新编号为 1...n, 保持列表紧凑。
    public func renumbered() -> AppSettings {
        var copy = self
        copy.routes = sortedRoutes.enumerated().map { index, route in
            var r = route
            r.priority = index + 1
            return r
        }
        return copy
    }
}

// RetryConfiguration 的 Codable 合成必须在它自己的声明文件里完成,
// 因此 conformance 写在 RetryManager.swift 的定义处, 不在此处扩展。

/// 设置的持久化。
public struct SettingsStore: @unchecked Sendable {

    private let defaults: UserDefaults
    private let storageKey: String
    /// 只把已有安装从旧的 Web 默认值迁移一次。这样用户后来显式选择
    /// 兼容 Web 模式时，不会在每次启动时又被强行改回 Codex。
    private let codexDefaultMigrationKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "com.airunner.settings.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.codexDefaultMigrationKey = "\(storageKey).codexDesktopDefault.v1"
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONCoding.makeDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        // 防御: 老版本配置可能缺少新增的 Provider
        var settings = Self.mergingMissingProviders(decoded)

        // 1.5.44 之前默认是手动 Web 回填。已有配置只迁移一次，避免用户
        // 明确选择兼容模式后再次启动被覆盖；没有配置的全新安装直接使用
        // AppSettings.default 中的 Codex 自动执行。
        if !defaults.bool(forKey: codexDefaultMigrationKey) {
            // 只对仍停留在旧默认值的已有配置做一次迁移；同时立刻写入
            // 标记，避免用户之后手动选择兼容 Web 模式又被覆盖。
            if settings.defaultExecutionMode == .chatGPTWeb {
                settings.defaultExecutionMode = .codexDesktop
                try? save(settings)
            }
            defaults.set(true, forKey: codexDefaultMigrationKey)
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        let data = try JSONCoding.makeEncoder(pretty: true).encode(settings)
        defaults.set(data, forKey: storageKey)
    }

    public func reset() {
        defaults.removeObject(forKey: storageKey)
    }

    /// 补齐缺失的出厂 Provider, 保证升级后老配置仍能显示新 Provider。
    static func mergingMissingProviders(_ settings: AppSettings) -> AppSettings {
        var copy = settings
        let existing = Set(settings.providers.map(\.id))
        for provider in ProviderConfig.defaults where !existing.contains(provider.id) {
            copy.providers.append(provider)
        }
        if copy.routes.isEmpty {
            copy.routes = RouteEntry.defaults
        }
        if copy.concurrency <= 0 {
            copy.concurrency = 3
        }
        return copy
    }
}

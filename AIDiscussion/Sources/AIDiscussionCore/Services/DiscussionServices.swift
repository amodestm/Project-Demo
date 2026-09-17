import Foundation
import Combine

/// 独立 AI 讨论组应用的服务定位器。
@MainActor
public final class DiscussionServices: ObservableObject {

    public let db: Database
    public let discussionRepo: DiscussionRepository
    public let chromeProfiles: ChromeProfileScanner
    public let discussionSessions: ChromeDiscussionSessionProvider
    public let logger: DiscussionLogger
    public let settings: DiscussionSettings

    /// 本地桥接（供 MCP 客户端调用）。`nil` 表示未启用或启动失败。
    @Published public private(set) var bridgeHub: DiscussionBridgeHub?
    @Published public private(set) var bridgeServer: DiscussionBridgeServer?
    /// 桥接启动失败原因（仅用于界面提示，不影响 app 主功能）。
    @Published public private(set) var bridgeError: String?

    public var isBridgeServing: Bool { bridgeServer?.isServing ?? false }

    public init(
        db: Database,
        logger: DiscussionLogger = DiscussionLogger(),
        configuration: ChromeDiscussionSessionConfiguration = .default,
        chromeProfiles: ChromeProfileScanner = ChromeProfileScanner()
    ) throws {
        self.db = db
        self.discussionRepo = DiscussionRepository(db: db)
        try self.discussionRepo.ensureSchema()
        self.chromeProfiles = chromeProfiles
        self.discussionSessions = ChromeDiscussionSessionProvider(configuration: configuration)
        self.logger = logger
        self.settings = DiscussionSettings()
    }

    // MARK: - 本地桥接

    /// 启动本地桥接服务。失败不抛出 —— 桥接只是**附加能力**，
    /// 不该因为它起不来就让整个 app 无法使用；失败原因留在 `bridgeError` 供界面展示。
    @discardableResult
    public func startBridge(appVersion: String? = nil) -> Bool {
        guard bridgeServer == nil else { return bridgeServer?.isServing ?? false }

        let hub = DiscussionBridgeHub(services: self, appVersion: appVersion)
        let server = DiscussionBridgeServer(hub: hub, appVersion: appVersion)
        do {
            try server.start()
            bridgeHub = hub
            bridgeServer = server
            bridgeError = nil
            logger.info("MCP 桥接已启动，可供外部客户端调用")
            return true
        } catch {
            bridgeError = error.localizedDescription
            logger.error("MCP 桥接启动失败：\(error.localizedDescription)")
            return false
        }
    }

    public func stopBridge() {
        bridgeServer?.stop()
        bridgeServer = nil
        bridgeHub = nil
    }

    /// 生产环境标准单例/默认服务，持久化到 ~/Library/Application Support/AIDiscussion/aidiscussion.sqlite
    ///
    /// 顺带启动本地桥接，让外部 MCP 客户端（如 Codex）能立即调用讨论组。
    /// 桥接起不来不影响 app 本身 —— 只是外部调不动而已。
    public static func makeDefault() throws -> DiscussionServices {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let baseDir = appSupport.appendingPathComponent("AIDiscussion", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let dbPath = baseDir.appendingPathComponent("aidiscussion.sqlite").path

        let db = try Database(path: dbPath)
        let services = try DiscussionServices(db: db)
        services.startBridge()
        return services
    }

    /// 纯内存服务（供单元测试使用，绝不污染真实磁盘与数据）
    public static func inMemory() throws -> DiscussionServices {
        let db = try Database.inMemory()
        return try DiscussionServices(db: db)
    }
}

/// 讨论组通用设置（如 Chrome Profile 的账号/邮箱映射）。
@MainActor
public final class DiscussionSettings: ObservableObject {
    private let defaults: UserDefaults
    private let profileAliasesKey = "ai_discussion_profile_aliases"

    @Published public var accountRotationProfileAliases: [String: String] = [:] {
        didSet {
            defaults.set(accountRotationProfileAliases, forKey: profileAliasesKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: profileAliasesKey) as? [String: String] {
            self.accountRotationProfileAliases = stored
        }
    }

    public func setAlias(_ alias: String, for directory: String) {
        accountRotationProfileAliases[directory] = alias
    }
}

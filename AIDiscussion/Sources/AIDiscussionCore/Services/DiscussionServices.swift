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

    public init(
        db: Database,
        logger: DiscussionLogger = DiscussionLogger(),
        configuration: ChromeDiscussionSessionConfiguration = .default
    ) throws {
        self.db = db
        self.discussionRepo = DiscussionRepository(db: db)
        try self.discussionRepo.ensureSchema()
        self.chromeProfiles = ChromeProfileScanner()
        self.discussionSessions = ChromeDiscussionSessionProvider(configuration: configuration)
        self.logger = logger
        self.settings = DiscussionSettings()
    }

    /// 生产环境标准单例/默认服务，持久化到 ~/Library/Application Support/AIDiscussion/aidiscussion.sqlite
    public static func makeDefault() throws -> DiscussionServices {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let baseDir = appSupport.appendingPathComponent("AIDiscussion", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let dbPath = baseDir.appendingPathComponent("aidiscussion.sqlite").path

        let db = try Database(path: dbPath)
        return try DiscussionServices(db: db)
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

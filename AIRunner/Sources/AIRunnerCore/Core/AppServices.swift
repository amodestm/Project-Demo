import Foundation

/// 依赖装配容器。
///
/// 全项目只有这里做"new 对象"。其他类型一律通过构造参数接收依赖 ——
/// 这样单元测试可以直接塞入内存数据库 + MockAIProvider, 不需要任何全局状态。
public final class AppServices: @unchecked Sendable {

    // 持久化
    public let database: Database
    public let tasks: TaskRepository
    public let steps: StepRepository
    public let checkpoints: CheckpointRepository
    public let events: EventRepository
    public let providerHealth: ProviderHealthRepository

    // 安全与日志
    public let keychain: any KeychainManaging
    public let logger: LoggerService

    // 执行核心
    public let retry: RetryManager
    public let checkpointManager: CheckpointManager
    public let factory: ProviderFactory
    public let router: ModelRouter
    public let registry: TaskExecutionRegistry
    public let runner: JobRunner
    public let recovery: RecoveryManager

    /// ChatGPT Web 执行通道（兼容旧版）。
    public let web: WebExecutionCoordinator
    /// 剪贴板与浏览器桥接 —— 具体实现由 App 层注入, Core 不依赖 AppKit。
    public let clipboard: any ClipboardServicing
    public let browser: any BrowserLaunching

    // Codex Existing Thread 自动恢复
    public let accessibilityPermission: AccessibilityPermissionManaging
    public let codexBindings: CodexTaskBindingRepository
    public let codexLeases: CodexResumeLeaseRepository
    /// 真实 UI 驱动。默认是基于 AXUIElement 的实现; 测试可注入替身。
    public let codexDriver: any CodexUIAutomationDriving
    public let codexController: CodexResumeController
    /// 账号交接后自动恢复的监视器。
    public let codexMonitor: AccountHandoffResumeMonitor
    /// Codex 运行中额度/登录异常监视器。
    public let codexQuotaMonitor: CodexQuotaMonitor
    /// 设置页中独立于任务的一键退出/重新登录测试。
    public let codexOAuthSafetyTester: CodexOAuthSafetyTester
    public let chromeProfiles: ChromeProfileScanner

    // Chrome Profile 自动账号轮换
    public let accountRotationRepo: AccountRotationRepository
    public let accountRotation: AccountRotationManager
    public let browserWindows: BrowserWindowLocating

    // Codex 凭据自动登录 (登出当前账号 → 账号密码重新登录)
    public let codexAccountVault: CodexAccountVaulting
    public let codexLogin: CodexLoginAutomating
    public let codexBrowserOAuth: CodexBrowserOAuthAuthenticating

    // 设置
    private let settingsStore: SettingsStore
    /// 线程安全的当前设置快照。WebExecutionCoordinator 通过它读取最新的 ChatGPT 地址。
    private let settingsBox: SettingsBox

    public var settings: AppSettings { settingsBox.value }

    // MARK: - 构造

    public init(
        database: Database,
        keychain: any KeychainManaging,
        settingsStore: SettingsStore,
        settingsOverride: AppSettings? = nil,
        clipboard: (any ClipboardServicing)? = nil,
        browser: (any BrowserLaunching)? = nil,
        codexDriver: (any CodexUIAutomationDriving)? = nil,
        accessibilityPermission: AccessibilityPermissionManaging? = nil,
        codexAccountVault: CodexAccountVaulting? = nil,
        codexLogin: CodexLoginAutomating? = nil,
        codexBrowserOAuth: CodexBrowserOAuthAuthenticating? = nil,
        echoLogsToConsole: Bool = true
    ) throws {
        self.database = database
        self.keychain = keychain
        self.settingsStore = settingsStore

        let loaded = settingsOverride ?? settingsStore.load()
        let box = SettingsBox(loaded)
        self.settingsBox = box

        try DatabaseMigrator.migrate(database)

        let tasks = TaskRepository(db: database)
        let steps = StepRepository(db: database)
        let checkpoints = CheckpointRepository(db: database)
        let events = EventRepository(db: database)
        let providerHealth = ProviderHealthRepository(db: database)

        let logger = LoggerService(events: events, echoToConsole: echoLogsToConsole)
        let factory = ProviderFactory(providers: loaded.providers, keychain: keychain)
        factory.registerAllSecrets()

        let retry = RetryManager(config: loaded.retry)
        let registry = TaskExecutionRegistry()
        let checkpointManager = CheckpointManager(repo: checkpoints)

        // 剪贴板 / 浏览器实现由 App 层注入; 测试与无 UI 环境用内存替身。
        let resolvedClipboard = clipboard ?? InMemoryClipboard()
        let resolvedBrowser = browser ?? NoopBrowserLauncher()

        // 路由器的"是否已配置"判断直接绑定到 factory 实例,
        // 因此 Settings 里填完 Key 后, Router 立刻就能选中该 Provider。
        let router = ModelRouter(
            routes: loaded.routes,
            providers: loaded.providers,
            healthRepository: providerHealth,
            logger: logger,
            config: loaded.retry,
            isProviderConfigured: { [factory] providerID in
                factory.isConfigured(providerID: providerID)
            }
        )

        // ★ ChatGPT Web 兼容通道 ★
        let web = WebExecutionCoordinator(
            tasks: tasks,
            steps: steps,
            checkpoints: checkpoints,
            checkpointManager: checkpointManager,
            logger: logger,
            clipboard: resolvedClipboard,
            browser: resolvedBrowser,
            chatGPTURLOverride: { box.value.chatGPTURL }
        )

        // ★ Codex Existing Thread 自动恢复 ★
        //
        // 驱动与权限管理器都可注入 —— 测试用替身, 生产用真实的 AXUIElement 实现。
        let permission = accessibilityPermission ?? AccessibilityPermissionManager()
        let driver = codexDriver ?? CodexUIAutomationDriver(permission: permission)
        let codexBindingRepo = CodexTaskBindingRepository(db: database)
        let codexLeaseRepo = CodexResumeLeaseRepository(db: database)

        // 上次异常退出可能留下过期租约 —— 先清干净, 但**不**静默释放未过期的。
        _ = try? codexLeaseRepo.purgeExpired()

        var codexConfig = CodexResumeConfiguration()
        codexConfig.cooldown = loaded.codexResumeCooldown
        codexConfig.defaultMessage = loaded.codexResumeMessage

        let codexController = CodexResumeController(
            driver: driver,
            bindings: codexBindingRepo,
            leases: codexLeaseRepo,
            logger: logger,
            configuration: codexConfig
        )

        let codexMonitor = AccountHandoffResumeMonitor(
            driver: driver,
            resumeController: codexController,
            bindings: codexBindingRepo,
            tasks: tasks,
            logger: logger,
            cooldown: loaded.codexResumeCooldown,
            pollInterval: .seconds(max(2, loaded.codexMonitorPollInterval))
        )

        let chromeProfiles = ChromeProfileScanner()

        // ★ Chrome Profile 自动账号轮换 ★
        let accountRotationRepo = AccountRotationRepository(db: database)
        let resolvedCodexVault = codexAccountVault
            ?? CodexKeychainVault(keychain: keychain)
        let resolvedCodexLogin = codexLogin
            ?? CodexLoginAutomator(
                configuration: .default,
                windows: BrowserWindowLocator(),
                settings: { box.value }
            )
        let resolvedCodexBrowserOAuth = codexBrowserOAuth
            ?? CodexBrowserOAuthAuthenticator(profiles: chromeProfiles)
        let accountRotation = AccountRotationManager(
            profiles: chromeProfiles,
            windows: BrowserWindowLocator(),
            repository: accountRotationRepo,
            logger: logger,
            settings: { box.value },
            chatGPTSwitcher: ChatGPTAccountSwitcher(),
            codexLogin: resolvedCodexLogin,
            codexAccountVault: resolvedCodexVault,
            codexBrowserOAuth: resolvedCodexBrowserOAuth,
            settleDelay: .seconds(2)
        )

        let codexQuotaMonitor = CodexQuotaMonitor(
            driver: driver,
            bindings: codexBindingRepo,
            tasks: tasks,
            resumeController: codexController,
            accountRotation: accountRotation,
            logger: logger,
            pollInterval: .seconds(max(2, loaded.codexMonitorPollInterval)),
            onRotationComplete: { taskID in
                await codexMonitor.start(taskID: taskID)
            }
        )
        let codexOAuthSafetyTester = CodexOAuthSafetyTester(
            driver: driver,
            accountTesting: accountRotation
        )

        let runner = JobRunner(
            dependencies: JobRunnerDependencies(
                tasks: tasks,
                steps: steps,
                router: router,
                retry: retry,
                checkpoints: checkpointManager,
                factory: factory,
                logger: logger,
                registry: registry,
                web: web,
                config: loaded.retry,
                concurrency: max(1, loaded.concurrency)
            )
        )

        let recovery = RecoveryManager(
            tasks: tasks,
            steps: steps,
            checkpoints: checkpoints,
            logger: logger
        )

        self.tasks = tasks
        self.steps = steps
        self.checkpoints = checkpoints
        self.events = events
        self.providerHealth = providerHealth
        self.logger = logger
        self.factory = factory
        self.retry = retry
        self.checkpointManager = checkpointManager
        self.router = router
        self.registry = registry
        self.runner = runner
        self.recovery = recovery
        self.web = web
        self.clipboard = resolvedClipboard
        self.browser = resolvedBrowser

        // Codex Existing Thread 自动恢复
        self.accessibilityPermission = permission
        self.codexBindings = codexBindingRepo
        self.codexLeases = codexLeaseRepo
        self.codexDriver = driver
        self.codexController = codexController
        self.codexMonitor = codexMonitor
        self.codexQuotaMonitor = codexQuotaMonitor
        self.codexOAuthSafetyTester = codexOAuthSafetyTester
        self.chromeProfiles = chromeProfiles
        self.accountRotationRepo = accountRotationRepo
        self.accountRotation = accountRotation
        self.browserWindows = BrowserWindowLocator()
        self.codexAccountVault = resolvedCodexVault
        self.codexLogin = resolvedCodexLogin
        self.codexBrowserOAuth = resolvedCodexBrowserOAuth
    }

    /// 一行启动。生产代码用默认路径, 测试用 `inMemory: true`。
    public static func bootstrap(
        databasePath: String? = nil,
        inMemory: Bool = false,
        keychain: (any KeychainManaging)? = nil,
        settingsStore: SettingsStore? = nil,
        clipboard: (any ClipboardServicing)? = nil,
        browser: (any BrowserLaunching)? = nil,
        echoLogsToConsole: Bool = true
    ) throws -> AppServices {

        let db: Database
        if inMemory {
            db = try Database.inMemory()
        } else if let databasePath {
            db = try Database(path: databasePath)
        } else {
            db = try Database.openDefault()
        }

        // 测试默认用内存 Keychain, 避免污染真实 Keychain
        let store = settingsStore ?? SettingsStore(
            defaults: inMemory ? Self.ephemeralDefaults() : .standard
        )
        let kc = keychain ?? (inMemory ? InMemoryKeychain() : KeychainManager())

        return try AppServices(
            database: db,
            keychain: kc,
            settingsStore: store,
            clipboard: clipboard,
            browser: browser,
            echoLogsToConsole: echoLogsToConsole
        )
    }

    /// 每个实例独立的一套内存 UserDefaults, 防止测试之间互相污染。
    public static func ephemeralDefaults(suiteName: String = "com.airunner.tests.\(UUID().uuidString)") -> UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - 设置变更

    public func saveSettings(_ newSettings: AppSettings) async {
        let normalized = newSettings.renumbered()

        storeSettings(normalized)

        try? settingsStore.save(normalized)
        factory.update(providers: normalized.providers)
        await router.updateRoutes(normalized.routes)
    }

    /// 锁操作必须封装在同步函数里 —— `NSLock.lock()` 在 async 上下文中会被
    /// Swift 6 标记为不可用 (阻塞线程可能导致线程饥饿)。
    private func storeSettings(_ value: AppSettings) {
        settingsBox.value = value
    }

    public func resetSettings() async {
        settingsStore.reset()
        await saveSettings(.default)
    }

    // MARK: - 诊断

    public func healthSnapshot() async -> [ProviderHealth] {
        await router.healthSnapshot()
    }

    public func resetProviderHealth(provider: String? = nil) async {
        await router.resetHealth(provider: provider)
    }

    public func databaseDiagnostics() throws -> Database.Diagnostics {
        try database.diagnostics()
    }

    public func shutdown() {
        database.close()
    }
}

/// 设置的可变快照盒子。
///
/// 存在的理由: `WebExecutionCoordinator` 需要在"生成 prompt 的那一刻"读到**最新**的
/// ChatGPT 地址, 但它在 `AppServices.init` 期间就被构造出来了 —— 那时 `self`
/// 尚未完整、不能被闭包捕获。用一个独立的锁保护盒子绕开这个先有鸡还是先有蛋的问题。
final class SettingsBox: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: AppSettings

    init(_ value: AppSettings) {
        self.storage = value
    }

    var value: AppSettings {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }
}

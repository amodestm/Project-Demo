import Foundation

/// 一次自动账号轮换的结果。
public struct AccountRotationOutcome: Sendable, Equatable {
    /// 轮换前使用的 profile (nil = 第一次, 尚未记录)。
    public let fromProfile: String?
    /// 轮换到的 profile 目录名。
    public let toProfile: String
    /// 该 profile 的显示名 (用户起的名字)。
    public let toProfileDisplayName: String
    /// 浏览器是否成功打开。
    public let browserOpened: Bool
    /// 是否成功把 ChatGPT 窗口调到前台。
    public let windowFocused: Bool
    /// 窗口聚焦失败的原因 (供日志/提示)。
    public let focusFailureReason: String?

    public var summary: String {
        var text = "账号已切换: \(toProfileDisplayName.isEmpty ? toProfile : toProfileDisplayName)"
        if let from = fromProfile { text += " (原 \(from))" }
        if browserOpened { text += " · 已打开 ChatGPT" }
        if windowFocused {
            text += " · 窗口已前台"
        } else if let reason = focusFailureReason {
            text += " · 窗口聚焦失败: \(reason)"
        }
        return text
    }
}

/// Codex 额度/登录异常监视器需要的最小轮换接口，便于无 UI 单测注入替身。
public protocol CodexAccountRotating: Sendable {
    func rotateChatGPTAccount(taskID: String) async throws -> ChatGPTAccountSwitchOutcome
    /// 记录当前账号额度耗尽后，跳过冷却中的账号并切换到下一个可用账号。
    func rotateChatGPTAccountAfterQuotaExhaustion(taskID: String) async throws -> ChatGPTAccountSwitchOutcome
}

public extension CodexAccountRotating {
    func rotateChatGPTAccountAfterQuotaExhaustion(taskID: String) async throws -> ChatGPTAccountSwitchOutcome {
        try await rotateChatGPTAccount(taskID: taskID)
    }
}

/// 设置页的一键 OAuth 测试只验证账号退出和重新登录，不依赖 AIRunner 任务。
public protocol CodexOAuthAccountTesting: Sendable {
    func testCodexBrowserOAuthRotation() async throws -> ChatGPTAccountSwitchOutcome
}

/// Chrome Profile 自动轮换器。
///
/// ## 工作原理
///
/// ChatGPT Web 账号启动与轮换管理器。
///
/// 新路径把每个 ChatGPT 网页账号隔离在独立 Chrome Profile 中，并通过 Codex
/// 官方 Codex 原生退出和浏览器 OAuth 切换认证。旧的钥匙串邮箱密码与头像菜单路径继续
/// 保留为可关闭 OAuth 后使用的兼容回退。
public actor AccountRotationManager {

    private let profiles: ChromeProfileScanner
    private let windows: BrowserWindowLocating
    private let repository: AccountRotationRepository
    private let logger: LoggerService
    private let settingsBox: () -> AppSettings

    /// 打开浏览器后等待窗口出现的秒数。
    /// Chrome 冷启动慢, 留足余量。
    private let settleDelay: Duration

    private let chatGPTSwitcher: ChatGPTAccountSwitching

    /// 凭据自动登录: 登出当前账号 → 账号密码重新登录。
    private let codexLogin: CodexLoginAutomating
    /// 凭据仓库: label+email 在设置 ID 表里, password 只在 Keychain。
    private let codexAccountVault: CodexAccountVaulting
    /// 使用独立 Chrome Profile 完成 Codex 官方浏览器 OAuth。
    private let codexBrowserOAuth: CodexBrowserOAuthAuthenticating
    /// 设置页连续测试时使用的进程内指针。
    private var settingsTestCurrentProfileDirectory: String?
    /// 测试指针需要跨 AIRunner 重启保存，否则每次都会重新选中 Default。
    private let loadSettingsTestProfileDirectory: @Sendable () -> String?
    private let saveSettingsTestProfileDirectory: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let quotaWindow: TimeInterval
    private let quotaRecoveryBuffer: TimeInterval

    public init(
        profiles: ChromeProfileScanner = ChromeProfileScanner(),
        windows: BrowserWindowLocating = BrowserWindowLocator(),
        repository: AccountRotationRepository,
        logger: LoggerService,
        settings: @escaping @Sendable () -> AppSettings,
        chatGPTSwitcher: ChatGPTAccountSwitching = ChatGPTAccountSwitcher(),
        codexLogin: CodexLoginAutomating = CodexLoginAutomator(),
        codexAccountVault: CodexAccountVaulting = InMemoryCodexAccountVault(),
        codexBrowserOAuth: CodexBrowserOAuthAuthenticating = FakeCodexBrowserOAuthAuthenticator(),
        settleDelay: Duration = .seconds(2),
        loadSettingsTestProfileDirectory: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(
                forKey: "AIRunnerOAuthSettingsTestLastProfileDirectory"
            )
        },
        saveSettingsTestProfileDirectory: @escaping @Sendable (String) -> Void = { directory in
            UserDefaults.standard.set(
                directory, forKey: "AIRunnerOAuthSettingsTestLastProfileDirectory"
            )
        },
        now: @escaping @Sendable () -> Date = { Date() },
        quotaWindow: TimeInterval = 5 * 60 * 60,
        quotaRecoveryBuffer: TimeInterval = 2 * 60
    ) {
        self.profiles = profiles
        self.windows = windows
        self.repository = repository
        self.logger = logger
        self.settingsBox = settings
        self.chatGPTSwitcher = chatGPTSwitcher
        self.codexLogin = codexLogin
        self.codexAccountVault = codexAccountVault
        self.codexBrowserOAuth = codexBrowserOAuth
        self.settleDelay = settleDelay
        self.loadSettingsTestProfileDirectory = loadSettingsTestProfileDirectory
        self.saveSettingsTestProfileDirectory = saveSettingsTestProfileDirectory
        self.now = now
        self.quotaWindow = quotaWindow
        self.quotaRecoveryBuffer = quotaRecoveryBuffer
    }

    // MARK: - 查询

    /// 轮换池: 用户配置的有序 profile 列表; 未配置时 = 全部可用 profile。
    public func rotationPool() -> [ChromeProfile] {
        let configured = settingsBox().accountRotationProfileDirectories
        let available = (try? profiles.availableProfiles()) ?? []

        if configured.isEmpty {
            return available
        }
        // 按用户配置的顺序过滤出实际存在的
        return configured.compactMap { directory in
            available.first { $0.directoryName == directory }
        }
    }

    /// OAuth 模式必须显式选择 Profile；空列表不能解释成“所有”，避免把个人或
    /// 无关的浏览器 Profile 意外加入账号轮换。
    private func oauthRotationPool() -> [ChromeProfile] {
        let configured = settingsBox().accountRotationProfileDirectories
        guard !configured.isEmpty else { return [] }
        let available = (try? profiles.availableProfiles()) ?? []
        return configured.compactMap { directory in
            available.first { $0.directoryName == directory }
        }
    }

    /// 某任务当前使用的 profile。
    public func currentProfile(taskID: String) -> ChromeProfile? {
        guard let directory = (try? repository.currentProfile(taskID: taskID)) ?? nil else {
            return nil
        }
        return rotationPool().first { $0.directoryName == directory }
    }

    /// 某任务当前已轮换的次数。
    public func rotationCount(taskID: String) -> Int {
        (try? repository.rotationCount(taskID: taskID)) ?? 0
    }

    // MARK: - 设定初始 profile

    /// 为任务绑定初始 profile (不触发轮换)。用于任务创建时。
    public func setInitialProfile(taskID: String, profileDirectory: String?) {
        try? repository.setInitial(taskID: taskID, profile: profileDirectory)
    }

    // MARK: - 自动轮换

    /// 切换到轮换池中的**下一个** profile, 打开 ChatGPT, 并把窗口调到前台。
    public func rotate(taskID: String) async throws -> AccountRotationOutcome {

        let pool = rotationPool()
        guard !pool.isEmpty else {
            logger.warning(
                .accountRotationFailed,
                "没有可用的 Chrome profile —— 请先在 Chrome 里创建至少两个 profile 并各自登录 ChatGPT"
            )
            throw AppError.invalidRequest(
                "没有可用的 Chrome profile。请在 Chrome 里创建 profile (右上角头像 → 添加), "
                + "并在每个 profile 里登录一个 ChatGPT 账号, 然后回来重试。"
            )
        }

        // 池里只有一个 profile → 无从轮换, 但仍可打开 + 聚焦
        let current = currentProfile(taskID: taskID)?.directoryName
        guard let next = Self.nextProfile(after: current, in: pool) else {
            throw AppError.invalidRequest("轮换池为空")
        }

        logger.info(
            .accountRotationStarted,
            "自动切换账号: \(current ?? "(未记录)") → \(next.label)",
            taskID: taskID
        )

        // 用下一个 profile 打开 ChatGPT
        let urlText = settingsBox().chatGPTURL
        let url = URL(string: urlText) ?? URL(string: "https://chatgpt.com/")!
        let opened = profiles.open(url: url, profile: next)

        guard opened else {
            logger.error(
                .accountRotationFailed,
                "无法用 profile「\(next.label)」打开 Chrome —— 请确认已安装 Google Chrome",
                taskID: taskID
            )
            throw AppError.invalidRequest("无法打开 Chrome (profile: \(next.label))")
        }

        // 等窗口出现
        try? await Task.sleep(for: settleDelay)

        // 把 ChatGPT 窗口调到前台 (失败不致命 —— 窗口仍已打开, 只是没前置)
        var focused = false
        var focusReason: String?
        do {
            _ = try windows.focusWindow(
                bundleIdentifier: ChromeProfileScanner.ChromeKind.chrome.rawValue,
                titleFragment: "ChatGPT",
                activateApp: true
            )
            focused = true
        } catch {
            focusReason = AppError.normalize(error).userMessage
            logger.warning(
                .accountRotationWindowFocusFailed,
                "ChatGPT 窗口未能自动前置: \(focusReason ?? "未知") —— 窗口本身已打开, 可手动切换",
                taskID: taskID
            )
        }

        // 落盘
        try? repository.update(taskID: taskID, currentProfile: next.directoryName)

        let outcome = AccountRotationOutcome(
            fromProfile: current,
            toProfile: next.directoryName,
            toProfileDisplayName: accountDisplayLabel(for: next),
            browserOpened: true,
            windowFocused: focused,
            focusFailureReason: focusReason
        )

        logger.info(
            .accountRotationCompleted,
            outcome.summary,
            taskID: taskID,
            metadata: .object([
                "fromProfile": .string(current ?? ""),
                "toProfile": .string(next.directoryName),
                "windowFocused": .bool(focused),
            ])
        )

        return outcome
    }

    /// 纯函数: 从轮换池选择下一个 profile。
    ///
    /// 抽成静态纯函数是为了可测试 —— 不开浏览器、不碰 DB:
    /// * 池为空 → nil (由调用方报错)
    /// * 当前不在池中 / 无记录 → 第一个
    /// * 当前是最后一个 → 回到第一个 (循环)
    public static func nextProfile(
        after current: String?,
        in pool: [ChromeProfile]
    ) -> ChromeProfile? {
        guard !pool.isEmpty else { return nil }
        guard let current,
              let index = pool.firstIndex(where: { $0.directoryName == current }),
              pool.count > 1 else {
            return pool[0]
        }
        return pool[(index + 1) % pool.count]
    }

    /// 从指定起点开始按轮换顺序列出候选 Profile。
    ///
    /// 某个 Profile 可能只创建了浏览器环境，却没有登录 ChatGPT。OAuth 自动机
    /// 能明确识别这种情况，因此这里允许安全地跳过该 Profile，继续尝试池中的
    /// 下一个已配置环境；只有最终成功才推进任务/测试指针。
    public static func oauthCandidates(
        startingWith first: ChromeProfile?,
        in pool: [ChromeProfile]
    ) -> [ChromeProfile] {
        guard !pool.isEmpty else { return [] }
        let startIndex = first.flatMap { candidate in
            pool.firstIndex { $0.directoryName == candidate.directoryName }
        } ?? 0
        return (0..<pool.count).map { offset in
            pool[(startIndex + offset) % pool.count]
        }
    }

    /// 从轮换顺序中选出第一个没有处于额度冷却的 Profile。
    ///
    /// `activeAccountKeys` 使用 repository 的稳定键 (`profile:<目录名>`)，
    /// 这样“额度耗尽的账号暂不轮换”规则可以脱离浏览器和时间进行单测。
    public static func nextQuotaEligibleProfile(
        startingWith first: ChromeProfile?,
        in pool: [ChromeProfile],
        activeAccountKeys: Set<String>
    ) -> ChromeProfile? {
        oauthCandidates(startingWith: first, in: pool).first {
            !activeAccountKeys.contains("profile:\($0.directoryName)")
        }
    }

    /// 列出所有浏览器里的 profile (设置页展示用)。
    public func availableProfiles() -> [(browser: ChromeProfileScanner.ChromeKind, profiles: [ChromeProfile])] {
        profiles.availableProfilesAcrossBrowsers()
    }

    // MARK: - ChatGPT 网页内账号轮换

    /// ChatGPT 网页账号轮换池: 设置里注册的账号; 留空则现场枚举菜单。
    public func chatGPTAccountPool() async -> [String] {
        let configured = settingsBox().chatGPTAccountList
        if !configured.isEmpty { return configured }
        // 未配置 → 从网页菜单现场枚举 (需要 Chrome 开着 ChatGPT)
        let entries = (try? await chatGPTSwitcher.listAccounts()) ?? []
        return entries.map { $0.label }
    }

    /// 新任务首次启动前确保 ChatGPT 已登录。
    ///
    /// - 已登录: 不打断现有会话。
    /// - 未登录且配置了凭据: 用轮换表第一条账号完成登录并记录非敏感 ID。
    /// - 未配置凭据: 保持历史行为，让 Web 通道只打开登录页。
    @discardableResult
    public func ensureInitialChatGPTLogin(taskID: String) async throws -> String? {
        if settingsBox().useCodexBrowserOAuthRotation {
            if await codexBrowserOAuth.isLoggedIn() { return nil }
            let pool = oauthRotationPool()
            let currentDirectory = (try? repository.currentProfile(taskID: taskID)) ?? nil
            guard let selected = currentDirectory.flatMap({ directory in
                pool.first { $0.directoryName == directory }
            }) ?? pool.first else {
                throw AppError.invalidRequest(
                    "浏览器 OAuth 轮换需要至少一个已登录 ChatGPT 的 Chrome Profile。"
                )
            }
            var lastProfileError: CodexBrowserOAuthError?
            for candidate in Self.oauthCandidates(startingWith: selected, in: pool) {
                do {
                    try await codexBrowserOAuth.reauthenticate(using: candidate)
                    return candidate.displayName.isEmpty
                        ? candidate.directoryName : candidate.displayName
                } catch let error as CodexBrowserOAuthError {
                    guard case .profileNotLoggedIn = error else { throw error }
                    lastProfileError = error
                    logger.warning(
                        .accountRotationFailed,
                        "Chrome Profile「\(candidate.label)」没有 ChatGPT 会话，继续尝试下一个 Profile"
                    )
                }
            }
            if let lastProfileError { throw lastProfileError }
            throw AppError.invalidRequest("浏览器 OAuth 轮换池为空")
        }

        let ids = settingsBox().codexAccountRotationIDs
        guard !ids.isEmpty else { return nil }

        var records: [CodexAccountRecord] = []
        for id in ids {
            if let record = try codexAccountVault.fetch(id: id) {
                records.append(record)
            }
        }
        guard let first = records.first else {
            throw AppError.invalidRequest(
                "设置中有 ChatGPT 账号 ID，但 macOS 钥匙串里找不到对应凭据。"
                + "请在设置 → Codex 自动恢复中重新保存账号。"
            )
        }

        let current = (try? repository.currentChatGPTAccount(taskID: taskID)) ?? nil
        let selected = current.flatMap { pointer in
            records.first { Self.matches(pointer: pointer, record: $0) }
        } ?? first

        logger.info(
            .accountRotationStarted,
            "Runner 启动前检查 ChatGPT 登录状态，候选账号: \(selected.label)",
            taskID: taskID
        )

        let didLogin = try await codexLogin.loginIfRequired(
            email: selected.email,
            password: selected.password
        )
        guard didLogin else {
            logger.info(
                .accountRotationCompleted,
                "浏览器已有可用的 ChatGPT 登录会话，继续执行任务",
                taskID: taskID
            )
            return nil
        }

        try repository.recordChatGPTAccount(taskID: taskID, account: selected.id)
        logger.info(
            .accountRotationCompleted,
            "已自动登录 ChatGPT 账号: \(selected.label)",
            taskID: taskID,
            metadata: .object([
                "kind": .string("chatgpt_initial_credential_login"),
                "accountID": .string(selected.id),
            ])
        )
        return selected.label
    }

    /// ★ 用 Keychain 凭据自动切换 ChatGPT 账号 ★
    ///
    /// 登出当前账号 → 读取下一个账号 → 输入 email+password 登录。只有登录成功后
    /// 才更新数据库里的轮换指针。密码不进入设置、数据库或日志。
    public func rotateChatGPTAccount(taskID: String) async throws -> ChatGPTAccountSwitchOutcome {
        if settingsBox().useCodexBrowserOAuthRotation {
            return try await rotateCodexViaBrowserOAuth(taskID: taskID)
        }

        let ids = settingsBox().codexAccountRotationIDs

        // ★ 凭据为主: 配置了凭据 ID 列表 → 登出 + 账号密码重新登录 ★
        if !ids.isEmpty {
            var records: [CodexAccountRecord] = []
            for id in ids {
                if let record = try codexAccountVault.fetch(id: id) {
                    records.append(record)
                }
            }
            guard records.count >= 2 else {
                throw AppError.invalidRequest(
                    "凭据自动登录至少需要两个可用账号 (当前有效 \(records.count) 个)。"
                    + "请先在「设置 → Codex 自动恢复 → ChatGPT 账号凭据」录入至少两个账号和密码；"
                    + "或清空该列表以回退到旧头像菜单切换。"
                )
            }

            let taskCurrent = (try? repository.currentChatGPTAccount(taskID: taskID)) ?? nil
            let current = taskCurrent
                ?? ((try? repository.mostRecentChatGPTAccount()) ?? nil)
            let currentRecord = current.flatMap { pointer in
                records.first { Self.matches(pointer: pointer, record: $0) }
            }
            let next = Self.nextAccountRecord(after: current, in: records)

            logger.info(
                .accountRotationStarted,
                "自动登录下一个 ChatGPT 账号: \(currentRecord?.label ?? "未记录") → \(next.label)",
                taskID: taskID
            )

            try await codexLogin.logout(currentAccountEmail: currentRecord?.email)
            try await codexLogin.login(email: next.email, password: next.password)

            try repository.recordChatGPTAccount(taskID: taskID, account: next.id)

            logger.info(
                .accountRotationCompleted,
                "已自动登录 ChatGPT 账号: \(next.label)",
                taskID: taskID,
                metadata: .object([
                    "kind": .string("chatgpt_credential_login"),
                    "fromAccountID": .string(currentRecord?.id ?? ""),
                    "toAccountID": .string(next.id),
                ])
            )

            return ChatGPTAccountSwitchOutcome(accountLabel: next.label, pageReloaded: true)
        }

        // ★ 头像菜单兜底 (旧): 未配置凭据 → 用网页右上角头像菜单切换 ★
        return try await rotateViaAvatarMenu(taskID: taskID)
    }

    /// 额度专用轮换：当前账号记入五小时冷却（额外两分钟网络缓冲），
    /// 后续只选择冷却已结束的账号；全部冷却时抛出可持久化的等待时间。
    public func rotateChatGPTAccountAfterQuotaExhaustion(taskID: String) async throws -> ChatGPTAccountSwitchOutcome {
        let currentKey = quotaAccountKey(taskID: taskID)
        if let currentKey {
            let at = now()
            if (try? repository.activeQuotaCooldown(accountKey: currentKey, at: at)) == nil {
                let availableAt = at.addingTimeInterval(quotaWindow + quotaRecoveryBuffer)
                try repository.recordQuotaExhaustion(
                    accountKey: currentKey,
                    exhaustedAt: at,
                    availableAt: availableAt
                )
                logger.info(
                    .accountHandoffDetected,
                    "记录账号额度耗尽时间 (DateCoding.string(from: at))；预计恢复 (DateCoding.string(from: availableAt))（含两分钟网络缓冲）",
                    taskID: taskID,
                    metadata: .object([
                        "kind": .string("quota_cooldown_recorded"),
                        "accountKey": .string(currentKey),
                        "exhaustedAt": .string(DateCoding.string(from: at)),
                        "availableAt": .string(DateCoding.string(from: availableAt)),
                    ])
                )
            }
        }

        let at = now()
        if let next = try nextQuotaEligibleProfile(taskID: taskID, at: at) {
            return try await switchCodexAccount(taskID: taskID, to: next.directoryName)
        }
        let configuredPool = oauthRotationPool()
        let activeRecoveryTimes = try configuredPool.compactMap { profile in
            try repository.activeQuotaCooldown(
                accountKey: "profile:\(profile.directoryName)",
                at: at
            )
        }
        if let earliest = activeRecoveryTimes.min() {
            throw CodexQuotaRotationError.allAccountsCoolingDown(until: earliest)
        }
        throw AppError.invalidRequest("没有可用的账号轮换目标")
    }

    private func quotaAccountKey(taskID: String) -> String? {
        if settingsBox().useCodexBrowserOAuthRotation {
            if let profile = currentProfile(taskID: taskID)?.directoryName {
                return "profile:\(profile)"
            }
            let pointer = (try? repository.currentChatGPTAccount(taskID: taskID)) ?? nil
            if let pointer, pointer.hasPrefix("profile:") { return pointer }
            return nil
        }
        let pointer = (try? repository.currentChatGPTAccount(taskID: taskID)) ?? nil
        if !settingsBox().codexAccountRotationIDs.isEmpty, let pointer {
            return "credential:\(pointer)"
        }
        if let pointer {
            return "web:\(pointer)"
        }
        return nil
    }

    private func nextQuotaEligibleProfile(taskID: String, at: Date) throws -> ChromeProfile? {
        let pool = oauthRotationPool()
        guard pool.count >= 2 else { return nil }
        let pointer = (try? repository.currentChatGPTAccount(taskID: taskID)) ?? nil
        let pointerDirectory = pointer.flatMap(Self.profileDirectory(fromAccountPointer:))
        let current = currentProfile(taskID: taskID)
            ?? pointerDirectory.flatMap { directory in
                pool.first { $0.directoryName == directory }
            }
        let first = Self.nextProfile(after: current?.directoryName, in: pool)
        let active = try repository.activeQuotaAccountKeys(at: at)
        return Self.nextQuotaEligibleProfile(
            startingWith: first,
            in: pool,
            activeAccountKeys: active
        )
    }

    /// 设置页的一键安全测试：退出当前 Codex 账号并通过下一个 Profile 重新登录。
    /// 这里只验证登录闭环，不写任务状态、不改检查点，也不会发送“继续”。
    public func testCodexBrowserOAuthRotation() async throws -> ChatGPTAccountSwitchOutcome {
        guard settingsBox().useCodexBrowserOAuthRotation else {
            throw AppError.invalidRequest(
                "请先开启“使用 Chrome Profile + Codex 浏览器授权切换”并保存设置。"
            )
        }
        let pool = oauthRotationPool()
        guard pool.count >= 2 else {
            throw AppError.invalidRequest(
                "一键登录测试至少需要两个已勾选的 Chrome Profile。"
            )
        }

        let recentAccount = (try? repository.mostRecentChatGPTAccount()) ?? nil
        let recentDirectory = recentAccount.flatMap(Self.profileDirectory(fromAccountPointer:))
        let current = settingsTestCurrentProfileDirectory
            ?? loadSettingsTestProfileDirectory()
            ?? recentDirectory
        guard let next = Self.nextProfile(after: current, in: pool) else {
            throw AppError.invalidRequest("Chrome Profile 轮换池为空")
        }

        logger.info(
            .accountRotationStarted,
            "设置页安全测试：准备安全退出 Codex 并通过 Chrome Profile「\(next.label)」重新登录",
            metadata: .object([
                "kind": .string("codex_oauth_settings_test"),
                "profile": .string(next.directoryName),
            ])
        )

        var lastProfileError: CodexBrowserOAuthError?
        let candidates = Self.oauthCandidates(startingWith: next, in: pool)
            .filter { candidate in
                guard let current else { return true }
                return candidate.directoryName != current
            }
        for candidate in candidates {
            // 保存“本次已经尝试过”的 Profile。即使测试中途失败或 AIRunner 更新
            // 重启，下一次也会继续轮换，不会永远回到 Default。
            settingsTestCurrentProfileDirectory = candidate.directoryName
            saveSettingsTestProfileDirectory(candidate.directoryName)
            do {
                try await codexBrowserOAuth.reauthenticate(using: candidate)

                logger.info(
                    .accountRotationCompleted,
                    "设置页安全测试成功：Codex 已通过 Chrome Profile「\(candidate.label)」重新登录；未发送任务消息",
                    metadata: .object([
                        "kind": .string("codex_oauth_settings_test"),
                        "profile": .string(candidate.directoryName),
                    ])
                )
                return ChatGPTAccountSwitchOutcome(
                    accountLabel: accountDisplayLabel(for: candidate),
                    pageReloaded: true
                )
            } catch let error as CodexBrowserOAuthError {
                guard case .profileNotLoggedIn = error else { throw error }
                lastProfileError = error
                logger.warning(
                    .accountRotationFailed,
                    "设置页安全测试跳过没有 ChatGPT 会话的 Profile「\(candidate.label)" 
                    + "」，继续尝试下一个 Profile",
                    metadata: .object([
                        "kind": .string("codex_oauth_settings_test"),
                        "profile": .string(candidate.directoryName),
                    ])
                )
            }
        }
        if let lastProfileError { throw lastProfileError }
        throw AppError.invalidRequest("Chrome Profile 轮换池为空")
    }

    /// 手动指定一个已配置的 Chrome Profile 完成 Codex 账号切换。
    ///
    /// 与自动轮换共用完全相同的安全链路：Codex 原生退出确认 → 登录入口 →
    /// 指定 Profile 的官方 OAuth。不会修改任务检查点，也不会发送任务消息。
    public func switchCodexAccount(to profileDirectory: String) async throws -> ChatGPTAccountSwitchOutcome {
        guard settingsBox().useCodexBrowserOAuthRotation else {
            throw AppError.invalidRequest(
                "请先开启“使用 Chrome Profile + Codex 浏览器授权切换”并保存设置。"
            )
        }
        let pool = oauthRotationPool()
        guard let profile = pool.first(where: { $0.directoryName == profileDirectory }) else {
            throw AppError.invalidRequest(
                "指定的 Chrome Profile 不在当前轮换列表中，请先重新检测并勾选它。"
            )
        }

        logger.info(
            .accountRotationStarted,
            "手动指定 Chrome Profile 切换 Codex 账号: \(profile.label)",
            metadata: .object([
                "kind": .string("codex_oauth_manual_profile_switch"),
                "profile": .string(profile.directoryName),
            ])
        )

        try await codexBrowserOAuth.reauthenticate(using: profile)

        logger.info(
            .accountRotationCompleted,
            "Codex 已通过指定 Chrome Profile 完成账号切换: \(profile.label)",
            metadata: .object([
                "kind": .string("codex_oauth_manual_profile_switch"),
                "profile": .string(profile.directoryName),
            ])
        )

        return ChatGPTAccountSwitchOutcome(
            accountLabel: accountDisplayLabel(for: profile),
            pageReloaded: true
        )
    }

    /// 为指定任务切换 Codex 账号。
    ///
    /// 账号认证成功后才写入任务的当前 Profile 和非敏感账号指针。这样主界面
    /// 的手动选择与额度监视器的自动轮换共享同一条认证链路，失败时不会把任务
    /// 错误地标记成已经切换。
    public func switchCodexAccount(
        taskID: String,
        to profileDirectory: String
    ) async throws -> ChatGPTAccountSwitchOutcome {
        let outcome = try await switchCodexAccount(to: profileDirectory)
        try repository.update(taskID: taskID, currentProfile: profileDirectory)
        try repository.recordChatGPTAccount(
            taskID: taskID,
            account: "profile:\(profileDirectory)"
        )
        return outcome
    }

    /// 返回一个 Profile 的用户可读名称（邮箱别名优先）。
    public func profileDisplayName(directory: String) -> String? {
        guard let profile = rotationPool().first(where: { $0.directoryName == directory }) else {
            return nil
        }
        return accountDisplayLabel(for: profile)
    }

    private static func profileDirectory(fromAccountPointer pointer: String) -> String? {
        let prefix = "profile:"
        guard pointer.hasPrefix(prefix) else { return nil }
        let directory = String(pointer.dropFirst(prefix.count))
        return directory.isEmpty ? nil : directory
    }

    /// 用户在设置页确认的邮箱别名优先用于状态和结果展示；没有别名时回退到
    /// Chrome Profile 名称或目录名。别名只影响显示，不参与认证或账号选择。
    private func accountDisplayLabel(for profile: ChromeProfile) -> String {
        let alias = settingsBox().accountRotationProfileAliases[profile.directoryName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !alias.isEmpty { return alias }
        return profile.displayName.isEmpty ? profile.directoryName : profile.displayName
    }

    /// 选择下一个独立 Chrome Profile，再用 Codex 官方浏览器 OAuth 重新认证。
    /// 只有 OAuth 命令退出 0 且登录状态确认成功后才推进轮换指针。
    private func rotateCodexViaBrowserOAuth(
        taskID: String
    ) async throws -> ChatGPTAccountSwitchOutcome {
        let pool = oauthRotationPool()
        guard pool.count >= 2 else {
            throw AppError.invalidRequest(
                "浏览器 OAuth 轮换至少需要两个独立 Chrome Profile。"
                + "请先在 Chrome 中为每个 ChatGPT 账号建立一个 Profile，并各自登录一次。"
            )
        }

        let current = currentProfile(taskID: taskID)?.directoryName
        guard let next = Self.nextProfile(after: current, in: pool) else {
            throw AppError.invalidRequest("Chrome Profile 轮换池为空")
        }

        logger.info(
            .accountRotationStarted,
            "正在通过浏览器 OAuth 切换 Codex 账号: \(next.label)",
            taskID: taskID,
            metadata: .object(["kind": .string("codex_browser_oauth")])
        )

        // 不在退出前额外打开普通 ChatGPT 标签页。那会制造一个无法确认归属的
        // Chrome 窗口，并可能让系统把 OAuth 链接送到错误的 Profile。真正的目标
        // 窗口由 CodexNativeLoginStarter 在“继续登录”之前创建、标记并聚焦。
        var lastProfileError: CodexBrowserOAuthError?
        let candidates = Self.oauthCandidates(startingWith: next, in: pool)
            .filter { candidate in
                guard let current else { return true }
                return candidate.directoryName != current
            }
        for candidate in candidates {
            do {
                try await codexBrowserOAuth.reauthenticate(using: candidate)

                try repository.update(taskID: taskID, currentProfile: candidate.directoryName)
                try repository.recordChatGPTAccount(
                    taskID: taskID, account: "profile:\(candidate.directoryName)"
                )

                logger.info(
                    .accountRotationCompleted,
                    "Codex 已通过 Chrome Profile「\(candidate.label)」完成浏览器授权",
                    taskID: taskID,
                    metadata: .object([
                        "kind": .string("codex_browser_oauth"),
                        "profile": .string(candidate.directoryName),
                    ])
                )
                return ChatGPTAccountSwitchOutcome(
                    accountLabel: accountDisplayLabel(for: candidate),
                    pageReloaded: true
                )
            } catch let error as CodexBrowserOAuthError {
                guard case .profileNotLoggedIn = error else { throw error }
                lastProfileError = error
                logger.warning(
                    .accountRotationFailed,
                    "跳过没有 ChatGPT 会话的 Profile「\(candidate.label)」，继续尝试下一个 Profile",
                    taskID: taskID,
                    metadata: .object([
                        "kind": .string("codex_browser_oauth"),
                        "profile": .string(candidate.directoryName),
                    ])
                )
            }
        }
        if let lastProfileError { throw lastProfileError }
        throw AppError.invalidRequest("Chrome Profile 轮换池为空")
    }

    /// 旧头像菜单模式的账号切换 (兜底): 从配置列表或网页菜单枚举账号, 选下一个, 调 switcher。
    ///
    /// 仅在 `codexAccountRotationIDs` 为空时进入 —— 即用户尚未录入任何凭据,
    /// 走「凭据为主 + 头像兜底」里的头像兜底分支。
    private func rotateViaAvatarMenu(taskID: String) async throws -> ChatGPTAccountSwitchOutcome {
        let pool = await chatGPTAccountPool()
        guard !pool.isEmpty else {
            throw AppError.invalidRequest(
                "未配置凭据账号, 也没在网页菜单里检测到 ChatGPT 账号。"
                + "请先在「设置 → Codex 自动恢复 → ChatGPT 账号凭据」录入账号密码, "
                + "或在浏览器里登录至少两个 ChatGPT 账号。"
            )
        }
        let current = (try? repository.currentChatGPTAccount(taskID: taskID)) ?? nil
        let next = Self.nextAccount(after: current, in: pool)
        let outcome = try await chatGPTSwitcher.switchAccount(to: next)
        try repository.recordChatGPTAccount(taskID: taskID, account: next)
        return outcome
    }

    /// 纯函数: ChatGPT 账号池里选下一个 (循环)。
    public static func nextAccount(after current: String?, in pool: [String]) -> String {
        guard !pool.isEmpty else { return "" }
        guard let current, let index = pool.firstIndex(of: current), pool.count > 1 else {
            return pool[0]
        }
        return pool[(index + 1) % pool.count]
    }

    /// 纯函数: 凭据记录池里选下一个 (循环)。兼容历史 email/label 指针。
    public static func nextAccountRecord(
        after current: String?, in records: [CodexAccountRecord]
    ) -> CodexAccountRecord {
        guard !records.isEmpty else { return CodexAccountRecord(label: "", email: "", password: "") }
        guard let current,
              let index = records.firstIndex(where: { matches(pointer: current, record: $0) }),
              records.count > 1 else {
            return records[0]
        }
        return records[(index + 1) % records.count]
    }

    private static func matches(pointer: String, record: CodexAccountRecord) -> Bool {
        record.id == pointer
            || record.email.caseInsensitiveCompare(pointer) == .orderedSame
            || record.label.caseInsensitiveCompare(pointer) == .orderedSame
    }

    /// 枚举浏览器里当前登录的全部 ChatGPT 账号 (设置页「扫描」用)。
    public func listChatGPTAccounts() async throws -> [ChatGPTAccountEntry] {
        try await chatGPTSwitcher.listAccounts()
    }
}

extension AccountRotationManager: CodexOAuthAccountTesting {}

extension AccountRotationManager: CodexAccountRotating {}

import XCTest
@testable import AIRunnerCore

private actor OAuthFlowRecorder {
    private var callsStorage: [String] = []
    func append(_ value: String) { callsStorage.append(value) }
    var calls: [String] { callsStorage }
}

private struct RecordingNativeLogout: CodexNativeLogoutConfirming {
    let recorder: OAuthFlowRecorder
    func logoutAndWaitForLoginScreen() async throws {
        await recorder.append("logout-confirmed")
    }
}

private struct RecordingNativeLogin: CodexNativeLoginStarting {
    let recorder: OAuthFlowRecorder
    func startChatGPTLogin(using profile: ChromeProfile) async throws {
        await recorder.append("login:\(profile.directoryName)")
    }
}

private actor ImmediateOAuthBrowserAutomation: CodexOAuthBrowserAutomating {
    func reset() async {}
    func advance() async throws -> Bool { false }
}

/// ChatGPT 网页内账号自动切换的核心逻辑测试。
///
/// AX 真实点击不在单测范围 (需真机 + 辅助功能权限 + Chrome 开着 ChatGPT);
/// 这里锁死**轮换数学**、**指针落盘**、**迁移**、**switcher 编排**。
final class ChatGPTAccountSwitchTests: XCTestCase {

    func testOAuthAuthenticatorCompletesNativeLogoutBeforeStartingLogin() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-oauth-flow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true
        )
        let executable = temporaryDirectory.appendingPathComponent("codex-status")
        try "#!/bin/sh\necho 'Logged in using ChatGPT'\nexit 0\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )

        let recorder = OAuthFlowRecorder()
        let authenticator = CodexBrowserOAuthAuthenticator(
            executableURL: executable,
            timeout: 2,
            relaunchCodexApplication: false,
            browserAutomation: ImmediateOAuthBrowserAutomation(),
            nativeLogout: RecordingNativeLogout(recorder: recorder),
            nativeLogin: RecordingNativeLogin(recorder: recorder)
        )
        let profile = ChromeProfile(
            directoryName: "Profile 2", displayName: "测试账号"
        )

        try await authenticator.reauthenticate(using: profile)

        let calls = await recorder.calls
        XCTAssertEqual(calls, ["logout-confirmed", "login:Profile 2"])
    }

    func testNativeCodexLoginMatcherAcceptsObservedAccountLabels() {
        XCTAssertTrue(CodexNativeLoginStarter.isChatGPTLoginControl(
            role: "AXButton", text: "继续登录"
        ))
        XCTAssertTrue(CodexNativeLoginStarter.isChatGPTLoginControl(
            role: "AXButton", text: "使用 ChatGPT 账号进行登录"
        ))
        XCTAssertTrue(CodexNativeLoginStarter.isChatGPTLoginControl(
            role: "AXStaticText", text: "使用 GPT 账号进行登录"
        ))
        XCTAssertTrue(CodexNativeLoginStarter.isChatGPTLoginControl(
            role: "AXLink", text: "Continue with ChatGPT"
        ))
        XCTAssertFalse(CodexNativeLoginStarter.isChatGPTLoginControl(
            role: "AXButton", text: "使用 API Key 登录"
        ))
        XCTAssertFalse(CodexNativeLoginStarter.isChatGPTLoginControl(
            role: "AXMenuItem", text: "使用 ChatGPT 账号进行登录"
        ))
    }

    func testNativeCodexLoginMatcherRejectsConversationTextContainingLoginPhrase() {
        XCTAssertFalse(CodexNativeLoginStarter.isChatGPTLoginControl(
            role: "AXStaticText", text: "退出后点击使用 GPT 账号进行登录就行了"
        ))
    }

    func testFakeNativeCodexLoginStarterRecordsTargetProfile() async throws {
        let starter = FakeCodexNativeLoginStarter()
        let profile = ChromeProfile(
            directoryName: "Profile 2", displayName: "测试账号"
        )

        try await starter.startChatGPTLogin(using: profile)

        let usedProfiles = await starter.usedProfiles
        XCTAssertEqual(usedProfiles, [profile])
    }

    func testChromeProfileProbeURLUsesLocalPageAndKeepsMarker() throws {
        let marker = "airunner-(UUID().uuidString.lowercased())"
        let url = try XCTUnwrap(
            ChromeProfileScanner.profileProbeURL(marker: marker)
        )

        XCTAssertTrue(url.isFileURL)
        XCTAssertNil(url.host)
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
            "airunner_profile_probe=\(marker)"
        )
    }

    func testOAuthErrorsIdentifyTheProfileOrStalledLoginEntry() {
        let profileMessage = CodexBrowserOAuthError
            .profileNotLoggedIn("测试账号 (Profile 2)").errorDescription ?? ""
        XCTAssertTrue(profileMessage.contains("测试账号 (Profile 2)"))

        let stalledMessage = CodexBrowserOAuthError
            .codexLoginControlDidNotDismiss.errorDescription ?? ""
        XCTAssertTrue(stalledMessage.contains("30 秒"))
        XCTAssertTrue(stalledMessage.contains("未继续路由"))
    }

    func testPasswordLoginMethodHintsCoverOpenAIOTPFallback() {
        XCTAssertTrue(CodexLoginAutomator.matchesPasswordMethodText("使用密码登录"))
        XCTAssertTrue(CodexLoginAutomator.matchesPasswordMethodText("Continue with password"))
        XCTAssertFalse(CodexLoginAutomator.matchesPasswordMethodText("发送验证码"))
    }

    func testCodexOAuthParserAcceptsOnlyOfficialAuthorizationURL() {
        let official = "https://auth.openai.com/oauth/authorize?client_id=test&state=short-lived"
        XCTAssertEqual(
            CodexBrowserOAuthAuthenticator.authorizationURL(
                in: "If the browser did not open, use \(official)"
            )?.host,
            "auth.openai.com"
        )
        XCTAssertNil(
            CodexBrowserOAuthAuthenticator.authorizationURL(
                in: "https://example.com/oauth/authorize?state=wrong"
            )
        )
        XCTAssertEqual(
            CodexBrowserOAuthAuthenticator.authorizationURL(
                in: "https://chatgpt.com/codex/desktop-auth?state=short-lived"
            )?.host,
            "chatgpt.com"
        )
        XCTAssertNil(
            CodexBrowserOAuthAuthenticator.authorizationURL(
                in: "https://evil.chatgpt.com/codex/desktop-auth?state=wrong"
            )
        )
        XCTAssertNil(
            CodexBrowserOAuthAuthenticator.authorizationURL(
                in: "http://auth.openai.com/oauth/authorize?state=insecure"
            )
        )
    }

    func testOAuthBrowserAutomatorChoosesTheOnlyCachedAccount() throws {
        let url = try XCTUnwrap(URL(string: "https://auth.openai.com/choose-an-account"))
        let controls = [
            CodexOAuthBrowserAutomator.Control(text: "选择账户 Example User"),
            CodexOAuthBrowserAutomator.Control(text: "移除账户 Example User"),
        ]

        XCTAssertEqual(
            CodexOAuthBrowserAutomator.intendedAction(
                url: url, controls: controls, pageText: "欢迎回来"
            ),
            .chooseAccount(0)
        )
    }

    func testOAuthBrowserAutomatorRefusesAmbiguousAccounts() throws {
        let url = try XCTUnwrap(URL(string: "https://auth.openai.com/choose-an-account"))
        let controls = [
            CodexOAuthBrowserAutomator.Control(text: "Select account A"),
            CodexOAuthBrowserAutomator.Control(text: "Select account B"),
        ]

        XCTAssertEqual(
            CodexOAuthBrowserAutomator.intendedAction(
                url: url, controls: controls, pageText: "Welcome back"
            ),
            .ambiguousAccounts
        )
    }

    func testOAuthBrowserAutomatorWaitsWhileAccountChooserIsRendering() throws {
        let url = try XCTUnwrap(URL(string: "https://auth.openai.com/choose-an-account"))
        XCTAssertEqual(
            CodexOAuthBrowserAutomator.intendedAction(
                url: url, controls: [], pageText: "欢迎回来"
            ),
            .wait
        )
    }

    func testOAuthBrowserAutomatorContinuesCodexConsent() throws {
        let url = try XCTUnwrap(
            URL(string: "https://auth.openai.com/sign-in-with-chatgpt/codex/consent")
        )
        let controls = [
            CodexOAuthBrowserAutomator.Control(text: "取消"),
            CodexOAuthBrowserAutomator.Control(text: "继续"),
        ]

        XCTAssertEqual(
            CodexOAuthBrowserAutomator.intendedAction(
                url: url, controls: controls, pageText: "使用 ChatGPT 登录到 Codex"
            ),
            .continueConsent(1)
        )
    }

    func testOAuthBrowserAutomatorStopsForLoginOrSecurityChallenge() throws {
        let loginURL = try XCTUnwrap(
            URL(string: "https://auth.openai.com/log-in-or-create-account")
        )
        XCTAssertEqual(
            CodexOAuthBrowserAutomator.intendedAction(
                url: loginURL,
                controls: [.init(role: "AXTextField", text: "Email address")],
                pageText: "Log in"
            ),
            .profileNotLoggedIn
        )

        let consentURL = try XCTUnwrap(
            URL(string: "https://auth.openai.com/sign-in-with-chatgpt/codex/consent")
        )
        XCTAssertEqual(
            CodexOAuthBrowserAutomator.intendedAction(
                url: consentURL,
                controls: [.init(text: "Continue")],
                pageText: "Verify you are human"
            ),
            .securityChallenge
        )
    }

    // MARK: - 纯函数: nextAccount

    func testNextAccountWrapsAround() {
        let pool = ["a@test.com", "b@test.com", "c@test.com"]

        XCTAssertEqual(AccountRotationManager.nextAccount(after: nil, in: pool), "a@test.com")
        XCTAssertEqual(AccountRotationManager.nextAccount(after: "a@test.com", in: pool), "b@test.com")
        XCTAssertEqual(AccountRotationManager.nextAccount(after: "b@test.com", in: pool), "c@test.com")
        // 最后一个 → 回到第一个 (循环)
        XCTAssertEqual(AccountRotationManager.nextAccount(after: "c@test.com", in: pool), "a@test.com")
    }

    func testNextAccountSingleElementReturnsItself() {
        XCTAssertEqual(AccountRotationManager.nextAccount(after: nil, in: ["a@x.com"]), "a@x.com")
        XCTAssertEqual(AccountRotationManager.nextAccount(after: "a@x.com", in: ["a@x.com"]), "a@x.com")
    }

    func testNextAccountUnknownCurrentFallsToFirst() {
        // "当前"账号已不在池里 (被移除) → 从头开始
        XCTAssertEqual(
            AccountRotationManager.nextAccount(after: "deleted@x.com", in: ["a@x.com", "b@x.com"]),
            "a@x.com"
        )
    }

    // MARK: - Repository: ChatGPT 账号指针

    func testRepositoryRecordsAndReadsChatGPTAccount() throws {
        let services = try TestSupport.makeServices()
        let repo = services.accountRotationRepo
        let task = try TestSupport.makeTask(services, name: "账号", steps: 2)

        XCTAssertNil(try repo.currentChatGPTAccount(taskID: task.id))

        try repo.recordChatGPTAccount(taskID: task.id, account: "a@x.com")
        XCTAssertEqual(try repo.currentChatGPTAccount(taskID: task.id), "a@x.com")

        try repo.recordChatGPTAccount(taskID: task.id, account: "b@x.com")
        XCTAssertEqual(try repo.currentChatGPTAccount(taskID: task.id), "b@x.com")
        XCTAssertEqual(try repo.mostRecentChatGPTAccount(), "b@x.com")
    }

    func testRepositoryChatGPTPointerSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-cgacct-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let services = try AppServices.bootstrap(
            databasePath: url.path, echoLogsToConsole: false
        )
        let task = try TestSupport.makeTask(services, name: "账号", steps: 2)
        try services.accountRotationRepo.recordChatGPTAccount(taskID: task.id, account: "me@x.com")
        services.shutdown()

        let reopened = try AppServices.bootstrap(
            databasePath: url.path, echoLogsToConsole: false
        )
        XCTAssertEqual(
            try reopened.accountRotationRepo.currentChatGPTAccount(taskID: task.id),
            "me@x.com"
        )
    }

    // MARK: - 迁移

    func testV5MigrationAddsChatGPTAccountColumn() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-v5-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let services = try AppServices.bootstrap(
            databasePath: url.path, echoLogsToConsole: false
        )
        XCTAssertEqual(try services.database.scalarInt("PRAGMA user_version;") ?? 0, 5)

        // 新列可用
        let task = try TestSupport.makeTask(services, name: "迁移", steps: 1)
        try services.accountRotationRepo.recordChatGPTAccount(taskID: task.id, account: "v5@x.com")
        XCTAssertEqual(
            try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id),
            "v5@x.com"
        )
    }

    // MARK: - 设置

    func testSettingsRoundTripCredentialIDsAndAutomaticHandoff() throws {
        var settings = AppSettings.default
        settings.codexAccountRotationIDs = ["account-id-a", "account-id-b"]
        settings.autoLoginNextChatGPTAccountOnHandoff = false
        settings.useCodexBrowserOAuthRotation = true

        let text = try JSONCoding.encodeToString(settings)
        let decoded = try JSONCoding.decode(AppSettings.self, from: text)
        XCTAssertEqual(decoded.codexAccountRotationIDs, ["account-id-a", "account-id-b"])
        XCTAssertFalse(decoded.autoLoginNextChatGPTAccountOnHandoff)
        XCTAssertTrue(decoded.useCodexBrowserOAuthRotation)
    }

    func testLegacySettingsDecodeWithoutAccountList() throws {
        let legacy = """
        {"providers":[],"routes":[],"concurrency":3}
        """
        let decoded = try JSONCoding.decode(AppSettings.self, from: legacy)
        XCTAssertEqual(decoded.chatGPTAccountList, [])
        XCTAssertEqual(decoded.codexAccountRotationIDs, [])
        XCTAssertTrue(decoded.autoLoginNextChatGPTAccountOnHandoff)
        XCTAssertFalse(decoded.useCodexBrowserOAuthRotation)
    }

    func testCredentialVaultRoundTripUpdateAndDelete() throws {
        let keychain = InMemoryKeychain()
        let vault = CodexKeychainVault(keychain: keychain)
        let saved = try vault.save(label: "账号 A", email: "a@x.com", password: "secret-a")

        XCTAssertEqual(try vault.fetch(id: saved.id), saved)
        var updated = saved
        updated.label = "账号 A2"
        updated.password = "secret-a2"
        try vault.update(updated)
        XCTAssertEqual(try vault.fetch(id: saved.id), updated)
        XCTAssertTrue(try vault.delete(id: saved.id))
        XCTAssertNil(try vault.fetch(id: saved.id))
    }

    // MARK: - significantFragment

    func testSignificantFragmentPrefersEmailLocalPart() {
        XCTAssertEqual(ChatGPTAccountSwitcher.significantFragment(of: "user@example.com"), "user")
        XCTAssertEqual(ChatGPTAccountSwitcher.significantFragment(of: "张三"), "张三")
    }

    // MARK: - Fake switcher

    func testFakeSwitcherSwitchesAndRecords() async throws {
        let fake = FakeChatGPTAccountSwitcher(accounts: ["a@x.com", "b@x.com"])
        let accounts = try await fake.listAccounts()
        XCTAssertEqual(accounts.count, 2)

        let outcome = try await fake.switchAccount(to: "b@x.com")
        XCTAssertEqual(outcome.accountLabel, "b@x.com")
        XCTAssertTrue(outcome.pageReloaded)
        XCTAssertEqual(fake.switchCalls, ["b@x.com"])
        XCTAssertEqual(fake.currentAccount, "b@x.com")

        // 未知账号 → fail closed
        do {
            _ = try await fake.switchAccount(to: "ghost@x.com")
            XCTFail("不应切换到不存在的账号")
        } catch let error as ChatGPTAccountError {
            guard case .targetAccountNotFound = error else {
                return XCTFail("错误的错误类型: \(error)")
            }
        }
    }

    func testFakeSwitcherMarksCurrentAccount() async throws {
        let fake = FakeChatGPTAccountSwitcher(accounts: ["a@x.com", "b@x.com"], current: "a@x.com")
        let accounts = try await fake.listAccounts()
        XCTAssertTrue(accounts.first { $0.label == "a@x.com" }!.isCurrent)
        XCTAssertFalse(accounts.first { $0.label == "b@x.com" }!.isCurrent)
    }

    // MARK: - AccountRotationManager 编排

    func testManagerLogsInWithKeychainCredentialsAndPersistsOnlyRecordID() async throws {
        let vault = InMemoryCodexAccountVault()
        let a = try vault.save(label: "账号 A", email: "a@x.com", password: "secret-a")
        let b = try vault.save(label: "账号 B", email: "b@x.com", password: "secret-b")
        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = [a.id, b.id]
        let configuredSettings = settings
        let services = try TestSupport.makeServices(settings: settings)
        let task = try TestSupport.makeTask(services, name: "网页账号编排", steps: 1)
        let login = FakeCodexLoginAutomator()

        let manager = AccountRotationManager(
            profiles: ChromeProfileScanner(),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { configuredSettings },
            codexLogin: login,
            codexAccountVault: vault,
            settleDelay: .seconds(0)
        )

        let first = try await manager.rotateChatGPTAccount(taskID: task.id)
        XCTAssertEqual(first.accountLabel, "账号 A")
        XCTAssertEqual(try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id), a.id)

        let second = try await manager.rotateChatGPTAccount(taskID: task.id)
        XCTAssertEqual(second.accountLabel, "账号 B")
        XCTAssertEqual(try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id), b.id)
        XCTAssertEqual(login.logoutCalls, 2)
        XCTAssertEqual(login.logins.map(\.email), ["a@x.com", "b@x.com"])
        XCTAssertEqual(login.logins.map(\.password), ["secret-a", "secret-b"])
    }

    func testFailedCredentialLoginLeavesRotationPointerUnchanged() async throws {
        let vault = InMemoryCodexAccountVault()
        let a = try vault.save(label: "账号 A", email: "a@x.com", password: "secret-a")
        let b = try vault.save(label: "账号 B", email: "b@x.com", password: "secret-b")
        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = [a.id, b.id]
        let configuredSettings = settings
        let services = try TestSupport.makeServices(settings: settings)
        let task = try TestSupport.makeTask(services, name: "登录失败不推进", steps: 1)
        let login = FakeCodexLoginAutomator()

        let manager = AccountRotationManager(
            profiles: ChromeProfileScanner(),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { configuredSettings },
            codexLogin: login,
            codexAccountVault: vault,
            settleDelay: .seconds(0)
        )

        _ = try await manager.rotateChatGPTAccount(taskID: task.id)
        login.failNextLogin(with: .loginDidNotComplete("测试失败"))
        do {
            _ = try await manager.rotateChatGPTAccount(taskID: task.id)
            XCTFail("登录失败时不应推进账号指针")
        } catch {
            XCTAssertEqual(try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id), a.id)
        }
    }

    @MainActor
    func testTaskHandoffAutomaticallyLogsInAndResumesFromCheckpoint() async throws {
        let vault = InMemoryCodexAccountVault()
        let a = try vault.save(label: "账号 A", email: "a@x.com", password: "secret-a")
        let b = try vault.save(label: "账号 B", email: "b@x.com", password: "secret-b")
        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = [a.id, b.id]
        settings.autoLoginNextChatGPTAccountOnHandoff = true
        let login = FakeCodexLoginAutomator()
        let services = try AppServices(
            database: try Database.inMemory(),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: settings,
            codexAccountVault: vault,
            codexLogin: login,
            echoLogsToConsole: false
        )
        let task = try TestSupport.makeTask(
            services, name: "自动账号交接", steps: 2, executionMode: .chatGPTWeb
        )
        await services.runner.start(taskID: task.id)
        let waiting = try await TestSupport.waitUntilSettled(services, taskID: task.id)
        XCTAssertEqual(waiting.status, .waitingForUser)
        let checkpointBefore = try services.checkpoints.latest(taskID: task.id)

        let manager = TaskManager(services: services)
        manager.pauseForAccountSwitch(waiting)

        var completed = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let current = try services.tasks.fetch(id: task.id)
            let pointer = try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id)
            completed = login.logins.count == 1
                && current?.status == .waitingForUser
                && pointer == a.id
            if completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(login.logins.first?.email, "a@x.com")
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id), checkpointBefore)
    }

    @MainActor
    func testCreatingWebTaskOnlyQueuesUntilUserStartsIt() async throws {
        let vault = InMemoryCodexAccountVault()
        let account = try vault.save(
            label: "待命账号", email: "queued@x.com", password: "queued-secret"
        )
        var settings = TestSupport.mockSettings()
        settings.defaultExecutionMode = .chatGPTWeb
        settings.codexAccountRotationIDs = [account.id]
        let login = FakeCodexLoginAutomator()
        let services = try AppServices(
            database: try Database.inMemory(),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: settings,
            codexAccountVault: vault,
            codexLogin: login,
            echoLogsToConsole: false
        )
        let manager = TaskManager(services: services)

        let task = try manager.createTask(
            name: "只创建不启动", goal: "等待用户点击开始", numberOfSteps: 1
        )
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .queued)
        XCTAssertEqual(login.logoutCalls, 0)
        XCTAssertTrue(login.logins.isEmpty)
        XCTAssertNil(try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id))
        XCTAssertNil(try services.steps.awaitingResultStep(taskID: task.id))
    }

    @MainActor
    func testNewWebTaskLogsInBeforeOpeningPromptWorkflow() async throws {
        let vault = InMemoryCodexAccountVault()
        let first = try vault.save(
            label: "首次账号", email: "first@x.com", password: "first-secret"
        )
        let backup = try vault.save(
            label: "备用账号", email: "backup@x.com", password: "backup-secret"
        )
        var settings = TestSupport.mockSettings()
        settings.defaultExecutionMode = .chatGPTWeb
        settings.codexAccountRotationIDs = [first.id, backup.id]
        let login = FakeCodexLoginAutomator()
        let services = try AppServices(
            database: try Database.inMemory(),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: settings,
            codexAccountVault: vault,
            codexLogin: login,
            echoLogsToConsole: false
        )
        let manager = TaskManager(services: services)
        let task = try manager.createTask(name: "首次自动登录", goal: "验证首次登录", numberOfSteps: 1)

        manager.start(task)

        var ready = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let current = try services.tasks.fetch(id: task.id)
            ready = login.logins.count == 1 && current?.status == .waitingForUser
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(login.logoutCalls, 1)
        XCTAssertEqual(login.logins.first?.email, "first@x.com")
        XCTAssertEqual(login.logins.first?.password, "first-secret")
        XCTAssertEqual(
            try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id), first.id
        )
        XCTAssertNotNil(try services.steps.awaitingResultStep(taskID: task.id))
    }

    // MARK: - 错误文案

    func testErrorMessagesAreActionable() {
        // 每个错误都必须告诉用户"怎么办" —— 而不是抛个术语。
        let cases: [(ChatGPTAccountError, String)] = [
            (.chromeNotFound, "Chrome"),
            (.chatGPTWindowNotFound, "ChatGPT"),
            (.avatarButtonNotFound, "头像"),
            (.noAccountEntriesFound, "账号"),
            (.targetAccountNotFound("x@y.com"), "x@y.com"),
        ]
        for (error, keyword) in cases {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(
                message.contains(keyword),
                "「\(message)」应包含可操作关键词「\(keyword)」"
            )
        }
    }
}

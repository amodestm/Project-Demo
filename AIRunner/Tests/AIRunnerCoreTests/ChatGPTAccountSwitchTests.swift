import XCTest
@testable import AIRunnerCore

/// ChatGPT 网页内账号自动切换的核心逻辑测试。
///
/// AX 真实点击不在单测范围 (需真机 + 辅助功能权限 + Chrome 开着 ChatGPT);
/// 这里锁死**轮换数学**、**指针落盘**、**迁移**、**switcher 编排**。
final class ChatGPTAccountSwitchTests: XCTestCase {

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

        let text = try JSONCoding.encodeToString(settings)
        let decoded = try JSONCoding.decode(AppSettings.self, from: text)
        XCTAssertEqual(decoded.codexAccountRotationIDs, ["account-id-a", "account-id-b"])
        XCTAssertFalse(decoded.autoLoginNextChatGPTAccountOnHandoff)
    }

    func testLegacySettingsDecodeWithoutAccountList() throws {
        let legacy = """
        {"providers":[],"routes":[],"concurrency":3}
        """
        let decoded = try JSONCoding.decode(AppSettings.self, from: legacy)
        XCTAssertEqual(decoded.chatGPTAccountList, [])
        XCTAssertEqual(decoded.codexAccountRotationIDs, [])
        XCTAssertTrue(decoded.autoLoginNextChatGPTAccountOnHandoff)
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

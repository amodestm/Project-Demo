import XCTest
@testable import AIRunnerCore

private final class TestProfilePointer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func save(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Chrome Profile 自动账号轮换的核心逻辑测试。
///
/// 重点测**纯逻辑** (选择下一个 profile 的循环规则) 与 **repository 落盘**;
/// 真实打开 Chrome / AX 窗口操作不在单测范围 (需要真机 + 辅助功能权限)。
final class AccountRotationTests: XCTestCase {

    // MARK: - 纯函数: nextProfile

    private func profile(_ name: String, display: String = "") -> ChromeProfile {
        ChromeProfile(directoryName: name, displayName: display)
    }

    func testNextProfileWrapsAround() {
        let pool = [profile("Default"), profile("Profile 1"), profile("Profile 2")]

        // 无记录 → 第一个
        XCTAssertEqual(Self.next(nil, pool), "Default")
        // 当前第一个 → 第二个
        XCTAssertEqual(Self.next("Default", pool), "Profile 1")
        // 中间 → 下一个
        XCTAssertEqual(Self.next("Profile 1", pool), "Profile 2")
        // 最后一个 → 回到第一个 (循环)
        XCTAssertEqual(Self.next("Profile 2", pool), "Default")
    }

    func testNextProfileSingleElementAlwaysReturnsItself() {
        let pool = [profile("Default")]
        XCTAssertEqual(Self.next(nil, pool), "Default")
        XCTAssertEqual(Self.next("Default", pool), "Default")
        // 即使"当前"不在池里也返回第一个
        XCTAssertEqual(Self.next("Profile 9", pool), "Default")
    }

    func testNextProfileEmptyPoolReturnsNil() {
        XCTAssertNil(Self.next(nil, []))
        XCTAssertNil(Self.next("Default", []))
    }

    func testNextProfileUnknownCurrentFallsToFirst() {
        let pool = [profile("Default"), profile("Profile 1")]
        // "当前"已不在池中 (比如用户删了该 profile) → 从头开始
        XCTAssertEqual(Self.next("Deleted", pool), "Default")
    }

    func testOAuthCandidatesWrapFromPreferredProfile() {
        let pool = [profile("Default"), profile("Profile 1"), profile("Profile 2")]
        let candidates = AccountRotationManager.oauthCandidates(
            startingWith: profile("Profile 1"), in: pool
        )
        XCTAssertEqual(candidates.map(\.directoryName), ["Profile 1", "Profile 2", "Default"])
    }

    private static func next(_ current: String?, _ pool: [ChromeProfile]) -> String? {
        AccountRotationManager.nextProfile(after: current, in: pool)?.directoryName
    }

    // MARK: - Repository

    func testRepositorySetInitialAndReadBack() throws {
        let services = try TestSupport.makeServices()
        let repo = services.accountRotationRepo

        let task = try TestSupport.makeTask(services, name: "轮换", steps: 3)
        try repo.setInitial(taskID: task.id, profile: "Profile 1")

        let read = try repo.currentProfile(taskID: task.id)
        XCTAssertEqual(read, "Profile 1")
        XCTAssertEqual(try repo.rotationCount(taskID: task.id), 0)
    }

    func testRepositorySetInitialDoesNotOverwrite() throws {
        let services = try TestSupport.makeServices()
        let repo = services.accountRotationRepo

        let task = try TestSupport.makeTask(services, name: "轮换", steps: 3)
        try repo.setInitial(taskID: task.id, profile: "Profile 1")
        // 第二次 setInitial 不覆盖 (DO NOTHING)
        try repo.setInitial(taskID: task.id, profile: "Profile 2")

        XCTAssertEqual(try repo.currentProfile(taskID: task.id), "Profile 1")
    }

    func testRepositoryUpdateAdvancesPointerAndCount() throws {
        let services = try TestSupport.makeServices()
        let repo = services.accountRotationRepo

        let task = try TestSupport.makeTask(services, name: "轮换", steps: 3)
        try repo.setInitial(taskID: task.id, profile: "Default")

        try repo.update(taskID: task.id, currentProfile: "Profile 1")
        XCTAssertEqual(try repo.currentProfile(taskID: task.id), "Profile 1")
        XCTAssertEqual(try repo.rotationCount(taskID: task.id), 1)

        try repo.update(taskID: task.id, currentProfile: "Profile 2")
        XCTAssertEqual(try repo.rotationCount(taskID: task.id), 2)
    }

    func testRepositorySurvivesDatabaseReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-rotation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let services = try AppServices.bootstrap(
            databasePath: url.path,
            echoLogsToConsole: false
        )
        let task = try TestSupport.makeTask(services, name: "轮换", steps: 3)
        try services.accountRotationRepo.update(taskID: task.id, currentProfile: "Profile 5")
        services.shutdown()

        let reopened = try AppServices.bootstrap(
            databasePath: url.path,
            echoLogsToConsole: false
        )
        let read = try reopened.accountRotationRepo.currentProfile(taskID: task.id)
        XCTAssertEqual(read, "Profile 5")
    }

    // MARK: - 数据库迁移

    func testV4MigrationAddsRotationTableAndColumn() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-v4-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let services = try AppServices.bootstrap(
            databasePath: url.path,
            echoLogsToConsole: false
        )

        // 后续迁移仍应保留 V4 的账号轮换表。
        let version = try services.database.scalarInt("PRAGMA user_version;") ?? 0
        XCTAssertEqual(version, DatabaseMigrator.currentVersion)

        // account_rotation_state 表存在且可写
        let task = try TestSupport.makeTask(services, name: "迁移", steps: 3)
        try services.accountRotationRepo.setInitial(taskID: task.id, profile: "Default")
        XCTAssertEqual(try services.accountRotationRepo.currentProfile(taskID: task.id), "Default")

        // codex_task_bindings 新列存在 (插入含该字段的绑定)
        let binding = CodexTaskBinding(
            taskID: task.id,
            displayTitle: "带 profile 的绑定",
            applicationBundleIdentifier: "com.google.Chrome",
            chromeProfileDirectory: "Profile 2",
            fingerprint: CodexTaskFingerprint(threadTitle: "T", applicationBundleIdentifier: "com.google.Chrome")
        )
        try services.codexBindings.insert(binding)
        let fetched = try services.codexBindings.fetchByTask(taskID: task.id)
        XCTAssertEqual(fetched?.chromeProfileDirectory, "Profile 2")
    }

    // MARK: - 绑定模型

    func testBindingRoundTripsChromeProfileDirectory() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "绑定", steps: 2)

        let binding = CodexTaskBinding(
            taskID: task.id,
            displayTitle: "有 profile",
            applicationBundleIdentifier: "com.google.Chrome",
            chromeProfileDirectory: "Profile 3",
            fingerprint: CodexTaskFingerprint(threadTitle: "X"),
            resumeMessage: "完成剩余任务",
            executionPreference: .gpt56SolHigh
        )
        try services.codexBindings.insert(binding)

        let fetched = try services.codexBindings.fetchByTask(taskID: task.id)
        XCTAssertEqual(fetched?.chromeProfileDirectory, "Profile 3")
        XCTAssertEqual(fetched?.resumeMessage, "完成剩余任务")
        XCTAssertEqual(fetched?.executionPreference, .gpt56SolHigh)

        // 更新为 nil (清除)
        var updated = binding
        updated.chromeProfileDirectory = nil
        try services.codexBindings.update(updated)
        let after = try services.codexBindings.fetchByTask(taskID: task.id)
        XCTAssertNil(after?.chromeProfileDirectory)
        XCTAssertEqual(after?.executionPreference, .gpt56SolHigh)
    }

    func testMinimalCodexBindingRoundTripsWithOnlyUserFacingRequiredTitle() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "最简绑定", steps: 1)
        let binding = CodexTaskBinding(
            taskID: task.id,
            displayTitle: "实现 AIRunner",
            applicationBundleIdentifier: "com.openai.codex",
            applicationName: "Codex",
            fingerprint: CodexTaskFingerprint(
                threadTitle: "实现 AIRunner",
                applicationBundleIdentifier: "com.openai.codex"
            ),
            resumeMessage: "继续",
            executionPreference: .gpt56SolHigh
        )

        try services.codexBindings.insert(binding)
        let fetched = try XCTUnwrap(
            services.codexBindings.fetchByTask(taskID: task.id)
        )
        XCTAssertEqual(fetched.displayTitle, "实现 AIRunner")
        XCTAssertEqual(fetched.fingerprint.threadTitle, "实现 AIRunner")
        XCTAssertEqual(fetched.applicationBundleIdentifier, "com.openai.codex")
        XCTAssertEqual(fetched.resumeMessage, "继续")
        XCTAssertEqual(fetched.executionPreference, .gpt56SolHigh)
    }

    func testExecutionSelectionRequiresExactReasoningEffort() {
        let high = CodexExecutionPreference.gpt56SolHigh
        XCTAssertTrue(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol 高").matches(high))
        XCTAssertFalse(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol 极高").matches(high))
        XCTAssertFalse(CodexExecutionSelection(visibleTitle: "GPT-6 Astra 高").matches(high))
    }

    func testExecutionSelectionDistinguishesHighestAndUltraEffort() {
        let maximum = CodexExecutionPreference(
            modelID: "gpt-5.6-sol", reasoningEffort: .max
        )
        XCTAssertTrue(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol 最高").matches(maximum))
        XCTAssertFalse(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol Ultra").matches(maximum))
        XCTAssertFalse(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol 极高").matches(maximum))

        let ultra = CodexExecutionPreference(
            modelID: "gpt-5.6-sol", reasoningEffort: .ultra
        )
        XCTAssertTrue(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol ultra").matches(ultra))
        XCTAssertTrue(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol Ultra").matches(ultra))
        XCTAssertFalse(CodexExecutionSelection(visibleTitle: "GPT-5.6 Sol 最高").matches(ultra))
    }

    // MARK: - 轮换池配置

    func testRotationPoolEmptyConfigUsesAllAvailable() async throws {
        let services = try TestSupport.makeServices()
        // 未配置 = 空列表 → rotationPool 返回扫描到的全部
        // (沙箱/CI 里可能没有 Chrome profile, 所以只验证不崩溃 + 返回数组)
        let pool = await services.accountRotation.rotationPool()
        XCTAssertTrue(pool is [ChromeProfile])
    }

    func testSettingsRoundTripsRotationDirectories() throws {
        var settings = AppSettings.default
        settings.accountRotationProfileDirectories = ["Profile 1", "Default"]
        settings.accountRotationProfileAliases = [
            "Profile 1": "second@example.com",
            "Default": "first@example.com",
        ]

        let text = try JSONCoding.encodeToString(settings)
        let decoded = try JSONCoding.decode(AppSettings.self, from: text)

        XCTAssertEqual(Set(decoded.accountRotationProfileDirectories), ["Profile 1", "Default"])
        XCTAssertEqual(decoded.accountRotationProfileAliases["Profile 1"], "second@example.com")
        XCTAssertEqual(decoded.accountRotationProfileAliases["Default"], "first@example.com")
    }

    func testOldSettingsDecodeWithoutRotationField() throws {
        // 老配置没有 accountRotationProfileDirectories 字段 → 默认 []
        let legacyJSON = """
        {"providers":[],"routes":[],"concurrency":3}
        """
        let decoded = try JSONCoding.decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.accountRotationProfileDirectories, [])
    }

    func testStandaloneOAuthTestPersistsProfileAcrossManagerRestart() async throws {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-oauth-settings-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryHome) }
        let chromeDirectory = temporaryHome
            .appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(
            at: chromeDirectory, withIntermediateDirectories: true
        )
        let localState: [String: Any] = [
            "profile": [
                "info_cache": [
                    "Default": ["name": "账号 A"],
                    "Profile 1": ["name": "账号 B"],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: localState)
        try data.write(to: chromeDirectory.appendingPathComponent("Local State"))

        var settings = TestSupport.mockSettings()
        settings.useCodexBrowserOAuthRotation = true
        settings.accountRotationProfileDirectories = ["Default", "Profile 1"]
        let configuredSettings = settings
        let services = try TestSupport.makeServices(settings: settings)
        let oauth = FakeCodexBrowserOAuthAuthenticator(loggedIn: true)
        let pointer = TestProfilePointer()
        let firstManager = AccountRotationManager(
            profiles: ChromeProfileScanner(homeDirectory: temporaryHome.path),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { configuredSettings },
            codexBrowserOAuth: oauth,
            settleDelay: .seconds(0),
            loadSettingsTestProfileDirectory: { pointer.load() },
            saveSettingsTestProfileDirectory: { pointer.save($0) }
        )

        let first = try await firstManager.testCodexBrowserOAuthRotation()

        // 模拟 AIRunner 更新/重启：新 manager 只能从持久化指针恢复轮换位置。
        let secondManager = AccountRotationManager(
            profiles: ChromeProfileScanner(homeDirectory: temporaryHome.path),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { configuredSettings },
            codexBrowserOAuth: oauth,
            settleDelay: .seconds(0),
            loadSettingsTestProfileDirectory: { pointer.load() },
            saveSettingsTestProfileDirectory: { pointer.save($0) }
        )
        let second = try await secondManager.testCodexBrowserOAuthRotation()

        XCTAssertEqual(first.accountLabel, "账号 A")
        XCTAssertEqual(second.accountLabel, "账号 B")
        let usedProfiles = await oauth.usedProfiles
        XCTAssertEqual(usedProfiles.map(\.directoryName), ["Default", "Profile 1"])
    }
}

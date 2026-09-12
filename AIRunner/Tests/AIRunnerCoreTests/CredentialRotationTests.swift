import XCTest
@testable import AIRunnerCore

/// 凭据自动登录 (登出 → 账号密码重新登录) 轮换逻辑测试。
///
/// 覆盖:
/// 1. `nextAccountRecord` 纯函数 (按 id/email/label 循环, 未知→第一个)
/// 2. 凭据模式编排: logout→login 顺序、指针落盘、循环回绕
/// 3. 配置不足 (有效账号 < 2) → 清晰报错
/// 4. 登录/登出出错 → fail closed (不落盘指针)
/// 5. 未配置凭据 (`codexAccountRotationIDs` 为空) → 兼容旧头像菜单配置
///
/// 真实 Chrome / AX 窗口操作不在单测范围内 (需真机 + 辅助功能权限)。
final class CredentialRotationTests: XCTestCase {

    // MARK: - 纯函数: nextAccountRecord

    private func record(id: String, label: String, email: String) -> CodexAccountRecord {
        CodexAccountRecord(id: id, label: label, email: email, password: "p-\(id)")
    }

    func testNextAccountRecordCyclesByIdEmailAndLabel() {
        let a = record(id: "1", label: "账号A", email: "a@x.com")
        let b = record(id: "2", label: "账号B", email: "b@x.com")
        let pool = [a, b]

        // 当前=第一个 → 第二个 (按 id / email / label 三种指针都能匹配)
        XCTAssertEqual(AccountRotationManager.nextAccountRecord(after: "1", in: pool).id, "2")
        XCTAssertEqual(AccountRotationManager.nextAccountRecord(after: "a@x.com", in: pool).id, "2")
        XCTAssertEqual(AccountRotationManager.nextAccountRecord(after: "账号A", in: pool).id, "2")

        // 最后一个 → 回到第一个 (循环)
        XCTAssertEqual(AccountRotationManager.nextAccountRecord(after: "2", in: pool).id, "1")

        // 无当前 / 未知 / 单元素 → 返回第一个
        XCTAssertEqual(AccountRotationManager.nextAccountRecord(after: nil, in: pool).id, "1")
        XCTAssertEqual(AccountRotationManager.nextAccountRecord(after: "ghost", in: pool).id, "1")
        XCTAssertEqual(
            AccountRotationManager.nextAccountRecord(after: nil, in: [a]).id, "1"
        )
    }

    func testNextAccountRecordEmptyPoolReturnsEmptyRecord() {
        let rec = AccountRotationManager.nextAccountRecord(after: nil, in: [])
        // 空池: 返回一个无意义的占位记录 (id 是新 UUID, 但 label/email 为空)
        XCTAssertEqual(rec.label, "")
        XCTAssertEqual(rec.email, "")
    }

    func testOpenAIAccountChooserTextIsRecognized() {
        XCTAssertTrue(CodexLoginAutomator.matchesOtherAccountText("登录其他账户"))
        XCTAssertTrue(CodexLoginAutomator.matchesOtherAccountText("使用另一个账号"))
        XCTAssertTrue(CodexLoginAutomator.matchesOtherAccountText("Use another account"))
        XCTAssertTrue(CodexLoginAutomator.matchesOtherAccountText("Log in with another account"))
        XCTAssertFalse(CodexLoginAutomator.matchesOtherAccountText("Continue"))
    }

    // MARK: - 凭据模式编排

    func testCredentialRotationLogsOutAndLogsInWithNextAccount() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "凭据轮换", steps: 1)

        let vault = InMemoryCodexAccountVault()
        let a = try vault.save(label: "账号A", email: "a@x.com", password: "pwA")
        let b = try vault.save(label: "账号B", email: "b@x.com", password: "pwB")

        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = [a.id, b.id]

        let fakeLogin = FakeCodexLoginAutomator()
        let manager = AccountRotationManager(
            profiles: ChromeProfileScanner(),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { [settings] in settings },
            chatGPTSwitcher: FakeChatGPTAccountSwitcher(accounts: []),
            codexLogin: fakeLogin,
            codexAccountVault: vault,
            settleDelay: .seconds(0)
        )

        // 未记录当前 → 从第一个开始; 顺序必须是 先 logout 再 login
        let first = try await manager.rotateChatGPTAccount(taskID: task.id)
        XCTAssertEqual(first.accountLabel, "账号A")
        XCTAssertEqual(fakeLogin.logoutCalls, 1)
        XCTAssertEqual(fakeLogin.logins.count, 1)
        XCTAssertEqual(fakeLogin.logins.first?.email, "a@x.com")
        XCTAssertEqual(fakeLogin.logins.first?.password, "pwA")
        XCTAssertEqual(try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id), a.id)

        // 下一个 → 账号B
        let second = try await manager.rotateChatGPTAccount(taskID: task.id)
        XCTAssertEqual(second.accountLabel, "账号B")
        XCTAssertEqual(fakeLogin.logins.last?.email, "b@x.com")
        XCTAssertEqual(fakeLogin.logins.last?.password, "pwB")
        XCTAssertEqual(try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id), b.id)

        // 再下一个 → 循环回账号A
        let third = try await manager.rotateChatGPTAccount(taskID: task.id)
        XCTAssertEqual(third.accountLabel, "账号A")
        XCTAssertEqual(fakeLogin.logins.last?.email, "a@x.com")
    }

    func testCredentialRotationRequiresAtLeastTwoValidAccounts() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "不足两个", steps: 1)

        let vault = InMemoryCodexAccountVault()
        let only = try vault.save(label: "只有我", email: "solo@x.com", password: "p")
        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = [only.id]

        let fakeLogin = FakeCodexLoginAutomator()
        let manager = AccountRotationManager(
            profiles: ChromeProfileScanner(),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { [settings] in settings },
            chatGPTSwitcher: FakeChatGPTAccountSwitcher(accounts: []),
            codexLogin: fakeLogin,
            codexAccountVault: vault,
            settleDelay: .seconds(0)
        )

        do {
            _ = try await manager.rotateChatGPTAccount(taskID: task.id)
            XCTFail("只有一个有效凭据时应抛错")
        } catch {
            let message = AppError.normalize(error).userMessage
            XCTAssertTrue(message.contains("至少两个"), "错误信息应说明至少需要两个账号: \(message)")
        }
        // 没有落盘任何指针, 也没有真正去登出/登录
        XCTAssertEqual(fakeLogin.logoutCalls, 0)
        XCTAssertEqual(fakeLogin.logins.count, 0)
        XCTAssertNil(try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id))
    }

    func testInitialLoginUsesFirstKeychainAccountWithoutLoggingOut() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "首次登录", steps: 1)
        let vault = InMemoryCodexAccountVault()
        let first = try vault.save(label: "账号A", email: "a@x.com", password: "pwA")
        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = [first.id]
        let fakeLogin = FakeCodexLoginAutomator()
        let manager = AccountRotationManager(
            profiles: ChromeProfileScanner(),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { [settings] in settings },
            chatGPTSwitcher: FakeChatGPTAccountSwitcher(accounts: []),
            codexLogin: fakeLogin,
            codexAccountVault: vault,
            settleDelay: .seconds(0)
        )

        let label = try await manager.ensureInitialChatGPTLogin(taskID: task.id)
        XCTAssertEqual(label, "账号A")
        XCTAssertEqual(fakeLogin.logoutCalls, 0)
        XCTAssertEqual(fakeLogin.logins.map(\.email), ["a@x.com"])
        XCTAssertEqual(fakeLogin.logins.map(\.password), ["pwA"])
        XCTAssertEqual(
            try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id), first.id
        )
    }

    func testNewTaskRotatesAfterMostRecentlyUsedAccount() async throws {
        let services = try TestSupport.makeServices()
        let previousTask = try TestSupport.makeTask(services, name: "上一任务", steps: 1)
        let newTask = try TestSupport.makeTask(services, name: "新任务", steps: 1)
        let vault = InMemoryCodexAccountVault()
        let first = try vault.save(label: "账号A", email: "a@x.com", password: "pwA")
        let second = try vault.save(label: "账号B", email: "b@x.com", password: "pwB")
        try services.accountRotationRepo.recordChatGPTAccount(
            taskID: previousTask.id, account: first.id
        )
        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = [first.id, second.id]
        let fakeLogin = FakeCodexLoginAutomator()
        let manager = AccountRotationManager(
            profiles: ChromeProfileScanner(),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { [settings] in settings },
            chatGPTSwitcher: FakeChatGPTAccountSwitcher(accounts: []),
            codexLogin: fakeLogin,
            codexAccountVault: vault,
            settleDelay: .seconds(0)
        )

        let outcome = try await manager.rotateChatGPTAccount(taskID: newTask.id)

        XCTAssertEqual(outcome.accountLabel, "账号B")
        XCTAssertEqual(fakeLogin.logoutCalls, 1)
        XCTAssertEqual(fakeLogin.logins.map(\.email), ["b@x.com"])
        XCTAssertEqual(
            try services.accountRotationRepo.currentChatGPTAccount(taskID: newTask.id), second.id
        )
    }

    func testCredentialRotationErrorDoesNotUpdatePointer() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "出错", steps: 1)

        let vault = InMemoryCodexAccountVault()
        let a = try vault.save(label: "账号A", email: "a@x.com", password: "pwA")
        let b = try vault.save(label: "账号B", email: "b@x.com", password: "pwB")
        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = [a.id, b.id]

        let fakeLogin = FakeCodexLoginAutomator()
        fakeLogin.failNextLogin(with: .humanVerificationRequired("人机验证信号 (测试)"))
        let manager = AccountRotationManager(
            profiles: ChromeProfileScanner(),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { [settings] in settings },
            chatGPTSwitcher: FakeChatGPTAccountSwitcher(accounts: []),
            codexLogin: fakeLogin,
            codexAccountVault: vault,
            settleDelay: .seconds(0)
        )

        do {
            _ = try await manager.rotateChatGPTAccount(taskID: task.id)
            XCTFail("应把人机验证错误抛回给调用方")
        } catch {
            // 不论 logout 还是 login 阶段抛错, 最终都是 humanVerification 信号
            XCTAssertTrue(error is CodexLoginError)
        }
        // ★ fail closed: 没有成功登录, 也没有落盘指针 ★
        XCTAssertEqual(fakeLogin.logins.count, 0)
        XCTAssertNil(try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id))
    }

    // MARK: - 历史配置兼容

    func testEmptyCredentialListFallsBackToAvatarSwitcher() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "兜底", steps: 1)

        let vault = InMemoryCodexAccountVault()  // 空仓库
        var settings = TestSupport.mockSettings()
        settings.codexAccountRotationIDs = []                  // 未配置凭据
        settings.chatGPTAccountList = ["av-a@x.com", "av-b@x.com"]

        let fakeLogin = FakeCodexLoginAutomator()
        let fakeSwitcher = FakeChatGPTAccountSwitcher(accounts: settings.chatGPTAccountList)
        let manager = AccountRotationManager(
            profiles: ChromeProfileScanner(),
            windows: FakeBrowserWindowLocator(),
            repository: services.accountRotationRepo,
            logger: services.logger,
            settings: { [settings] in settings },
            chatGPTSwitcher: fakeSwitcher,
            codexLogin: fakeLogin,
            codexAccountVault: vault,
            settleDelay: .seconds(0)
        )

        let outcome = try await manager.rotateChatGPTAccount(taskID: task.id)
        XCTAssertEqual(outcome.accountLabel, "av-a@x.com")
        XCTAssertEqual(fakeLogin.logoutCalls, 0)
        XCTAssertEqual(fakeLogin.logins.count, 0)
        XCTAssertEqual(fakeSwitcher.switchCalls, ["av-a@x.com"])
        XCTAssertEqual(
            try services.accountRotationRepo.currentChatGPTAccount(taskID: task.id),
            "av-a@x.com"
        )
    }
}

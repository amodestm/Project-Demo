import XCTest
@testable import AIRunnerCore

final class CodexOAuthSafetyTesterTests: XCTestCase {
    actor FakeAccountTesting: CodexOAuthAccountTesting {
        private(set) var callCount = 0

        func testCodexBrowserOAuthRotation() async throws -> ChatGPTAccountSwitchOutcome {
            callCount += 1
            return ChatGPTAccountSwitchOutcome(
                accountLabel: "测试 Profile", pageReloaded: true
            )
        }
    }

    func testIdleCodexRunsStandaloneOAuthTestWithoutSendingMessage() async throws {
        let driver = FakeCodexUIAutomationDriver()
        driver.configureHappyPath()
        let accountTesting = FakeAccountTesting()
        let tester = CodexOAuthSafetyTester(
            driver: driver, accountTesting: accountTesting
        )

        let outcome = try await tester.run()

        XCTAssertEqual(outcome.accountLabel, "测试 Profile")
        let calls = await accountTesting.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(driver.sendCount, 0)
        XCTAssertTrue(driver.insertedMessages.isEmpty)
    }

    func testGeneratingCodexRefusesBeforeAccountLogout() async throws {
        let driver = FakeCodexUIAutomationDriver()
        driver.configureHappyPath()
        driver.busyState = .generating
        let accountTesting = FakeAccountTesting()
        let tester = CodexOAuthSafetyTester(
            driver: driver, accountTesting: accountTesting
        )

        do {
            _ = try await tester.run()
            XCTFail("Codex 生成中不应进入账号退出流程")
        } catch {
            XCTAssertTrue(AppError.normalize(error).userMessage.contains("正在生成"))
        }
        let calls = await accountTesting.callCount
        XCTAssertEqual(calls, 0)
    }

    func testBackgroundGeneratingCodexRefusesBeforeAccountLogout() async throws {
        let driver = FakeCodexUIAutomationDriver()
        driver.configureHappyPath()
        driver.busyState = .idle
        driver.anyTaskGenerating = true
        let accountTesting = FakeAccountTesting()
        let tester = CodexOAuthSafetyTester(
            driver: driver, accountTesting: accountTesting
        )

        do {
            _ = try await tester.run()
            XCTFail("其他窗口生成中不应进入账号退出流程")
        } catch {
            XCTAssertTrue(AppError.normalize(error).userMessage.contains("仍有任务正在生成"))
        }
        let calls = await accountTesting.callCount
        XCTAssertEqual(calls, 0)
    }

    func testUnknownBusyStateWithoutStoppedSignalRefusesLogout() async throws {
        let driver = FakeCodexUIAutomationDriver()
        driver.configureHappyPath()
        driver.busyState = .unknown
        driver.taskStoppedSignal = false
        let accountTesting = FakeAccountTesting()
        let tester = CodexOAuthSafetyTester(
            driver: driver, accountTesting: accountTesting
        )

        do {
            _ = try await tester.run()
            XCTFail("状态不明时不应退出账号")
        } catch {
            XCTAssertTrue(AppError.normalize(error).userMessage.contains("无法确认"))
        }
        let calls = await accountTesting.callCount
        XCTAssertEqual(calls, 0)
    }

    func testUnknownBusyStateWithStoppedSignalCanRunTest() async throws {
        let driver = FakeCodexUIAutomationDriver()
        driver.configureHappyPath()
        driver.busyState = .unknown
        driver.taskStoppedSignal = true
        let accountTesting = FakeAccountTesting()
        let tester = CodexOAuthSafetyTester(
            driver: driver, accountTesting: accountTesting
        )

        _ = try await tester.run()

        let calls = await accountTesting.callCount
        XCTAssertEqual(calls, 1)
    }

}

import Foundation

/// 设置页“一键测试安全退出并登录”的结果。
public struct CodexOAuthSafetyTestOutcome: Sendable, Equatable {
    public let accountLabel: String

    public init(accountLabel: String) {
        self.accountLabel = accountLabel
    }
}

/// 独立于任务的登录闭环测试器。
///
/// 它先确认当前 Codex 窗口已经停止生成，再执行真实 OAuth 轮换。整个过程不绑定
/// 线程、不修改任务状态、不发送消息；任何无法确认的状态都会停止在退出之前。
public actor CodexOAuthSafetyTester {
    private let driver: any CodexUIAutomationDriving
    private let accountTesting: any CodexOAuthAccountTesting
    private let bundleIdentifier: String
    private var isRunning = false

    public init(
        driver: any CodexUIAutomationDriving,
        accountTesting: any CodexOAuthAccountTesting,
        bundleIdentifier: String = "com.openai.codex"
    ) {
        self.driver = driver
        self.accountTesting = accountTesting
        self.bundleIdentifier = bundleIdentifier
    }

    public func run() async throws -> CodexOAuthSafetyTestOutcome {
        guard !isRunning else {
            throw AppError.invalidRequest("账号退出登录测试已经在进行中，请等待本轮完成。")
        }
        isRunning = true
        defer { isRunning = false }

        guard (await driver.checkAccessibilityPermission()).isUsable else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }
        let probe = await driver.probeAvailability(bundleIdentifier: bundleIdentifier)
        guard probe.isUsable else {
            throw AppError.invalidRequest("Codex 当前不可用：\(probe.summary)")
        }

        let app = try await driver.locateApplication(bundleIdentifier: bundleIdentifier)
        guard try await !driver.detectAnyTaskGenerating(app) else {
            throw AppError.invalidRequest(
                "检测到 Codex 仍有任务正在生成，安全测试已在退出前停止；请等所有任务结束后再试。"
            )
        }
        let busy = try await driver.detectBusyState(app)
        switch busy {
        case .generating:
            throw AppError.invalidRequest(
                "Codex 仍在生成中，安全测试已拒绝退出账号；请等所有任务停止后再试。"
            )
        case .idle:
            break
        case .unknown:
            guard try await driver.detectTaskStopped(app) else {
                throw AppError.invalidRequest(
                    "无法确认 Codex 已停止生成，安全测试没有退出账号；请打开一个已经空闲、输入框可用的 Codex 任务。"
                )
            }
        }
        let outcome = try await accountTesting.testCodexBrowserOAuthRotation()
        return CodexOAuthSafetyTestOutcome(accountLabel: outcome.accountLabel)
    }
}

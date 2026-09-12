import AppKit
import Foundation

public protocol CodexBrowserOAuthAuthenticating: Sendable {
    func isLoggedIn() async -> Bool
    func reauthenticate(using profile: ChromeProfile) async throws
}

public enum CodexBrowserOAuthError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound
    case commandFailed(String)
    case authorizationURLNotFound
    case browserOpenFailed
    case loginTimedOut
    case loginNotConfirmed
    case codexRelaunchFailed
    case accessibilityPermissionMissing
    case codexLoginControlNotFound
    case codexLoginControlAmbiguous
    case codexLoginControlPressFailed
    case codexLogoutConfirmationNotFound
    case codexLogoutConfirmationAmbiguous
    case codexLogoutConfirmationPressFailed
    case codexLogoutDidNotComplete
    case codexLogoutCommandNotFound
    case codexLogoutCommandAmbiguous
    case codexLogoutCommandPressFailed

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 Codex 登录程序。请确认 /Applications/ChatGPT.app 已安装。"
        case .commandFailed(let command):
            return "Codex \(command)执行失败。"
        case .authorizationURLNotFound:
            return "Codex 没有生成浏览器授权地址。"
        case .browserOpenFailed:
            return "无法在目标 Chrome Profile 中打开 Codex 授权页。"
        case .loginTimedOut:
            return "Codex 浏览器授权在规定时间内没有完成。请检查目标 Profile 的 ChatGPT 登录状态。"
        case .loginNotConfirmed:
            return "浏览器授权结束，但 Codex 没有确认登录成功。"
        case .codexRelaunchFailed:
            return "账号已授权，但 Codex 未能自动重新打开。请手动重新打开 Codex。"
        case .accessibilityPermissionMissing:
            return "AIRunner 缺少辅助功能权限，无法操作 Codex 登录入口。"
        case .codexLoginControlNotFound:
            return "Codex 已退出账号，但没有找到“使用 ChatGPT 账号登录”入口。"
        case .codexLoginControlAmbiguous:
            return "Codex 登录界面出现多个“使用 ChatGPT 账号登录”候选，已停止以避免误点。"
        case .codexLoginControlPressFailed:
            return "已经找到 Codex 的“使用 ChatGPT 账号登录”，但没有成功按下。"
        case .codexLogoutConfirmationNotFound:
            return "Codex 收到退出请求，但没有出现唯一的“退出登录？”确认框。账号未切换。"
        case .codexLogoutConfirmationAmbiguous:
            return "Codex 出现多个退出确认候选，AIRunner 已停止以避免误点。"
        case .codexLogoutConfirmationPressFailed:
            return "已经找到 Codex 的“退出登录”确认按钮，但没有成功按下。"
        case .codexLogoutDidNotComplete:
            return "已确认退出 Codex，但没有在规定时间内看到登录界面。"
        case .codexLogoutCommandNotFound:
            return "没有在 Codex 原生菜单中找到唯一的“注销/Log Out”命令。账号未切换。"
        case .codexLogoutCommandAmbiguous:
            return "Codex 原生菜单出现多个退出命令候选，AIRunner 已停止以避免误点。"
        case .codexLogoutCommandPressFailed:
            return "已经找到 Codex 原生“注销/Log Out”命令，但没有成功发起退出。"
        }
    }
}

/// 用 Codex 原生登录入口和官方浏览器 OAuth 完成账号切换。
///
/// AIRunner 通过 Codex 原生菜单发起注销并处理确认框。退出完成后从 Codex 窗口
/// 按下“使用 ChatGPT 账号登录”，让官方流程在目标 Chrome Profile 中继续。
/// AIRunner 不读取、不复制 ChatGPT Cookie，也不注入 session token。
public actor CodexBrowserOAuthAuthenticator: CodexBrowserOAuthAuthenticating {
    private let executableURL: URL
    private let timeout: TimeInterval
    private let environment: [String: String]?
    private let relaunchCodexApplication: Bool
    private let browserAutomation: any CodexOAuthBrowserAutomating
    private let nativeLogout: any CodexNativeLogoutConfirming
    private let nativeLogin: any CodexNativeLoginStarting

    public init(
        executableURL: URL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        ),
        profiles: ChromeProfileScanner = ChromeProfileScanner(),
        timeout: TimeInterval = 180,
        environment: [String: String]? = nil,
        relaunchCodexApplication: Bool = true,
        browserAutomation: any CodexOAuthBrowserAutomating = CodexOAuthBrowserAutomator(),
        nativeLogout: (any CodexNativeLogoutConfirming)? = nil,
        nativeLogin: (any CodexNativeLoginStarting)? = nil
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.environment = environment
        self.relaunchCodexApplication = relaunchCodexApplication
        self.browserAutomation = browserAutomation
        self.nativeLogout = nativeLogout ?? CodexNativeLogoutConfirmer()
        self.nativeLogin = nativeLogin ?? CodexNativeLoginStarter(profiles: profiles)
    }

    public func isLoggedIn() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }
        guard let result = try? await runAndCapture(arguments: ["login", "status"], timeout: 15)
        else { return false }
        return result.status == 0 && result.output.lowercased().contains("logged in using chatgpt")
    }

    public func reauthenticate(using profile: ChromeProfile) async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexBrowserOAuthError.executableNotFound
        }
        await browserAutomation.reset()

        // 退出完全走 Codex 桌面原生 UI：注销命令 → 确认框 → 登录页。独立
        // app-server 的 auth 状态可能与桌面窗口不同步，因此不再用它发起退出。
        try await nativeLogout.logoutAndWaitForLoginScreen()

        // 确认框完成且登录页已经出现后，按真实 UI 流程从“使用 ChatGPT
        // 账号登录”开始；目标 Profile 由 nativeLogin 激活。
        try await nativeLogin.startChatGPTLogin(using: profile)

        let completion = try await waitForNativeLoginCompletion(timeout: timeout)
        guard completion else {
            throw CodexBrowserOAuthError.loginNotConfirmed
        }

        if relaunchCodexApplication {
            try await relaunchCodex()
        }
    }

    private func waitForNativeLoginCompletion(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            _ = try await browserAutomation.advance()
            if await isLoggedIn() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw CodexBrowserOAuthError.loginTimedOut
    }

    private func relaunchCodex() async throws {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        )
        for application in applications {
            _ = application.terminate()
        }

        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline,
              NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.openai.codex"
              ).contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(250))
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                configuration: configuration
            )
        } catch {
            throw CodexBrowserOAuthError.codexRelaunchFailed
        }
    }

    private func runAndCapture(
        arguments: [String], timeout: TimeInterval
    ) async throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
            throw CodexBrowserOAuthError.commandFailed(arguments.joined(separator: " "))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 只接受 Codex 官方认证站点，拒绝把任意命令输出中的 URL 交给浏览器。
    static func authorizationURL(in output: String) -> URL? {
        let separators = CharacterSet.whitespacesAndNewlines
        for token in output.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(
                in: CharacterSet(charactersIn: "()[]{}<>\"',")
            )
            guard let url = URL(string: trimmed), url.scheme == "https",
                  let host = url.host?.lowercased(),
                  host == "auth.openai.com" || host == "chatgpt.com",
                  url.query != nil else { continue }
            return url
        }
        return nil
    }
}

public actor FakeCodexBrowserOAuthAuthenticator: CodexBrowserOAuthAuthenticating {
    private var loggedIn: Bool
    private var usedProfilesStorage: [ChromeProfile] = []
    public var failure: Error?

    public init(loggedIn: Bool = true) {
        self.loggedIn = loggedIn
    }

    public var usedProfiles: [ChromeProfile] {
        usedProfilesStorage
    }

    public func isLoggedIn() async -> Bool {
        loggedIn
    }

    public func reauthenticate(using profile: ChromeProfile) async throws {
        if let failure { throw failure }
        usedProfilesStorage.append(profile)
        loggedIn = true
    }
}

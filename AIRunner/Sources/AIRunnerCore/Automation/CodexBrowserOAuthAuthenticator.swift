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
    case accessibilityPermissionMissing
    case codexLoginControlNotFound
    case codexLoginControlAmbiguous
    case codexLoginWindowFocusFailed
    case codexLoginControlPressFailed
    case codexLoginControlDidNotDismiss
    case profileNotLoggedIn(String)
    case codexLogoutConfirmationNotFound
    case codexLogoutConfirmationAmbiguous
    case codexLogoutConfirmationPressFailed
    case codexLogoutConfirmationDidNotDismiss
    case codexLogoutDidNotComplete
    case codexProfileMenuNotFound
    case codexSidebarLogoutNotFound
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
        case .accessibilityPermissionMissing:
            return "AIRunner 缺少辅助功能权限，无法操作 Codex 登录入口。"
        case .codexLoginControlNotFound:
            return "Codex 已退出账号，但没有找到“使用 ChatGPT 账号登录”入口。"
        case .codexLoginControlAmbiguous:
            return "Codex 登录界面出现多个“使用 ChatGPT 账号登录”候选，已停止以避免误点。"
        case .codexLoginWindowFocusFailed:
            return "已经找到 Codex 的“继续登录”，但无法把它所在的登录窗口切到前台，因此没有点击。"
        case .codexLoginControlPressFailed:
            return "已经找到 Codex 的“使用 ChatGPT 账号登录”，但没有成功按下。"
        case .codexLoginControlDidNotDismiss:
            return "已经点击 Codex 的“继续登录”，但登录入口在 30 秒内仍未消失；未继续路由，账号未切换。"
        case .profileNotLoggedIn(let profileLabel):
            return "Chrome Profile「\(profileLabel)」没有可用的 ChatGPT 登录会话。请先在这个 Profile 登录 chatgpt.com，或在设置中取消选择它。"
        case .codexLogoutConfirmationNotFound:
            return "AIRunner 已尝试点击账号菜单中的“退出登录”，但没有出现唯一的“退出登录？”确认框。账号未切换。"
        case .codexLogoutConfirmationAmbiguous:
            return "Codex 出现多个退出确认候选，AIRunner 已停止以避免误点。"
        case .codexLogoutConfirmationPressFailed:
            return "已经找到 Codex 的“退出登录”确认按钮，但没有成功按下。"
        case .codexLogoutConfirmationDidNotDismiss:
            return "已经找到“要退出登录？”确认框，但点击红色“退出登录”后确认框仍然可见。账号尚未退出，也没有开始切换。"
        case .codexLogoutDidNotComplete:
            return "Codex 的退出确认框已经消失，但没有在规定时间内看到登录界面。账号切换没有开始。"
        case .codexProfileMenuNotFound:
            return "Codex 已切到前台并等待 20 秒，但没有找到左下角个人资料菜单。账号未切换。"
        case .codexSidebarLogoutNotFound:
            return "AIRunner 已打开 Codex 个人资料菜单，但没有找到唯一的“退出登录/Log Out”。账号未切换。"
        case .codexLogoutCommandNotFound:
            return "没有在 Codex 左下角个人资料菜单或兼容菜单中找到唯一的“退出登录/Log Out”。账号未切换。"
        case .codexLogoutCommandAmbiguous:
            return "Codex 出现多个退出入口候选，AIRunner 已停止以避免误点。"
        case .codexLogoutCommandPressFailed:
            return "已经找到 Codex 的“退出登录/Log Out”，但没有成功发起退出。"
        }
    }
}

/// 用 Codex 原生登录入口和官方浏览器 OAuth 完成账号切换。
///
/// AIRunner 通过 Codex 左下角个人资料菜单发起退出并处理确认框。退出完成后从 Codex 窗口
/// 按下“使用 ChatGPT 账号登录”，让官方流程在目标 Chrome Profile 中继续。
public actor CodexBrowserOAuthAuthenticator: CodexBrowserOAuthAuthenticating {
    private let executableURL: URL
    private let timeout: TimeInterval
    private let environment: [String: String]?
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
        browserAutomation: any CodexOAuthBrowserAutomating = CodexOAuthBrowserAutomator(),
        nativeLogout: (any CodexNativeLogoutConfirming)? = nil,
        nativeLogin: (any CodexNativeLoginStarting)? = nil
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.environment = environment
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

        // 退出完全走 Codex 桌面 UI：个人资料菜单 → 退出登录 → 确认框 → 登录页。独立
        // app-server 的 auth 状态可能与桌面窗口不同步，因此不再用它发起退出。
        try await nativeLogout.logoutAndWaitForLoginScreen()

        // 确认框完成且登录页已经出现后，按真实 UI 流程从“继续登录”开始；
        // 目标 Profile 由 nativeLogin 激活。
        try await nativeLogin.startChatGPTLogin(using: profile)

        let completion: Bool
        do {
            completion = try await waitForNativeLoginCompletion(timeout: timeout)
        } catch CodexOAuthBrowserAutomationError.profileNotLoggedIn {
            // 把失败的目标 profile 带回设置页，避免只显示“当前 Profile”这种
            // 无法定位的提示；也让用户知道应修正的是哪一个 profile。
            throw CodexBrowserOAuthError.profileNotLoggedIn(profile.label)
        }
        guard completion else {
            throw CodexBrowserOAuthError.loginNotConfirmed
        }

        // OAuth 回调会直接恢复当前 Codex 进程的登录状态。此时终止并重启桌面
        // 应用会触发“退出 ChatGPT？”保护弹窗，并中断本地聊天与计划任务。
        // 登录成功后只把现有窗口带回前台，不关闭或重启 Codex。
        if let codex = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first(where: { !$0.isTerminated }) {
            _ = codex.activate(options: [.activateAllWindows])
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

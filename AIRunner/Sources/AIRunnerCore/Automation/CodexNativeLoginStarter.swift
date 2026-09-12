import AppKit
import ApplicationServices
import Foundation

/// Codex 登出后，在原生登录界面按下“使用 ChatGPT 账号登录”。
public protocol CodexNativeLoginStarting: Sendable {
    func startChatGPTLogin(using profile: ChromeProfile) async throws
}

/// 先等待 Codex 原生登录入口真实出现，再把目标 Chrome Profile 置于前台并点击。
/// 随后由 Codex 自己打开官方授权地址，已有的浏览器 OAuth 自动机继续处理。
public struct CodexNativeLoginStarter: CodexNativeLoginStarting {
    private let profiles: ChromeProfileScanner
    private let timeout: TimeInterval

    public init(
        profiles: ChromeProfileScanner = ChromeProfileScanner(),
        timeout: TimeInterval = 25
    ) {
        self.profiles = profiles
        self.timeout = timeout
    }

    public func startChatGPTLogin(using profile: ChromeProfile) async throws {
        guard AXIsProcessTrusted() else {
            throw CodexBrowserOAuthError.accessibilityPermissionMissing
        }
        guard let codex = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first(where: { !$0.isTerminated }) else {
            throw CodexBrowserOAuthError.codexLoginControlNotFound
        }

        // 必须先确认退出确实使 Codex 进入原生登录页。否则提前打开 Profile 只会
        // 留下 about:blank，并把“没有退出成功”伪装成浏览器授权卡住。
        let loginDeadline = Date().addingTimeInterval(timeout)
        while Date() < loginDeadline {
            try Task.checkCancellation()
            let root = AXUIElementCreateApplication(codex.processIdentifier)
            let controls = Self.loginControls(in: root)
            if controls.count > 1 {
                throw CodexBrowserOAuthError.codexLoginControlAmbiguous
            }
            if controls.count == 1 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let loginRoot = AXUIElementCreateApplication(codex.processIdentifier)
        guard Self.loginControls(in: loginRoot).count == 1 else {
            throw CodexBrowserOAuthError.codexLoginControlNotFound
        }

        // Chrome 会把外部链接交给最近激活的 Profile。此时才创建并激活目标
        // Profile 的窗口，再回到 Codex 按登录入口，避免授权落进上一个账号。
        guard let blank = URL(string: "about:blank"), profiles.open(
            url: blank, profile: profile, kind: .chrome, newWindow: true
        ) else {
            throw CodexBrowserOAuthError.browserOpenFailed
        }
        try? await Task.sleep(for: .milliseconds(800))
        if let chrome = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.google.Chrome"
        ).first(where: { !$0.isTerminated }) {
            _ = chrome.activate(options: [.activateAllWindows])
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = codex.activate(options: [.activateAllWindows])

        // 切换前台应用后重新读取控件，不能复用之前的 AX 句柄。
        let pressDeadline = Date().addingTimeInterval(8)
        while Date() < pressDeadline {
            try Task.checkCancellation()
            let root = AXUIElementCreateApplication(codex.processIdentifier)
            let controls = Self.loginControls(in: root)
            if controls.count > 1 {
                throw CodexBrowserOAuthError.codexLoginControlAmbiguous
            }
            if let control = controls.first {
                _ = codex.activate(options: [.activateAllWindows])
                guard CodexLoginAutomator.press(control)
                        || CodexLoginAutomator.clickCenter(control) else {
                    throw CodexBrowserOAuthError.codexLoginControlPressFailed
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw CodexBrowserOAuthError.codexLoginControlNotFound
    }

    static func isChatGPTLoginControl(role: String, text: String) -> Bool {
        guard role == kAXButtonRole || role == "AXLink"
                || role == kAXStaticTextRole else { return false }
        let normalized = text.lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        let compactHints = [
            "使用chatgpt账号登录", "使用chatgpt账户登录", "使用chatgpt账号进行登录",
            "使用chatgpt登录", "使用gpt账号登录", "使用gpt账号进行登录",
        ]
        if compactHints.contains(compact) { return true }
        let englishHints = [
            "log in with chatgpt", "login with chatgpt", "sign in with chatgpt",
            "continue with chatgpt", "use chatgpt account", "continue with chatgpt account",
        ]
        return englishHints.contains(normalized)
    }

    static func loginControls(in root: AXUIElement) -> [AXUIElement] {
        var matches: [AXUIElement] = []
        let budget = ChatGPTAccountSwitcher.Box(5_000)
        ChatGPTAccountSwitcher.walkElements(
            in: root,
            depth: 0,
            budget: budget,
            deadline: Date().addingTimeInterval(8),
            maxDepth: 22
        ) { element in
            let role = CodexLoginAutomator.role(of: element)
            let text = CodexLoginAutomator.matchingText(of: element)
            if isChatGPTLoginControl(role: role, text: text),
               let actionable = actionableControl(for: element) {
                matches.append(actionable)
            }
        }

        // 同一个按钮的静态文字和父按钮可能同时命中。上面先把文字节点提升到
        // 实际支持 AXPress 的父控件，再按真实 AXFrame 去重。
        var seen: Set<String> = []
        return matches.filter { element in
            let key: String
            if let frame = CodexLoginAutomator.frame(of: element) {
                key = "\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width)):\(Int(frame.height))"
            } else {
                key = "\(CodexLoginAutomator.role(of: element)):\(CodexLoginAutomator.matchingText(of: element))"
            }
            return seen.insert(key).inserted
        }
    }

    private static func actionableControl(for element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<5 {
            let role = CodexLoginAutomator.role(of: current)
            if role == kAXButtonRole || role == "AXLink" {
                return current
            }
            guard let rawParent = CodexLoginAutomator.rawAttribute(
                current, kAXParentAttribute
            ) else { break }
            current = unsafeDowncast(rawParent, to: AXUIElement.self)
        }
        return nil
    }
}

public actor FakeCodexNativeLoginStarter: CodexNativeLoginStarting {
    private var profilesStorage: [ChromeProfile] = []
    public var failure: Error?

    public init() {}

    public var usedProfiles: [ChromeProfile] { profilesStorage }

    public func startChatGPTLogin(using profile: ChromeProfile) async throws {
        if let failure { throw failure }
        profilesStorage.append(profile)
    }
}

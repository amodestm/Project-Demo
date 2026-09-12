import AppKit
import ApplicationServices
import Foundation

/// 从 Codex 原生菜单发起退出，处理二次确认框并等待登录页出现。
public protocol CodexNativeLogoutConfirming: Sendable {
    func logoutAndWaitForLoginScreen() async throws
}

/// 只识别 Codex 官方确认框的精确标题和确认按钮，不使用坐标或正文模糊匹配。
public struct CodexNativeLogoutConfirmer: CodexNativeLogoutConfirming {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 25) {
        self.timeout = timeout
    }

    public func logoutAndWaitForLoginScreen() async throws {
        guard AXIsProcessTrusted() else {
            throw CodexBrowserOAuthError.accessibilityPermissionMissing
        }
        guard let codex = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first(where: { !$0.isTerminated }) else {
            throw CodexBrowserOAuthError.codexLogoutCommandNotFound
        }

        // 登录页已经可见时，退出动作是幂等的；继续后续登录即可。
        var root = AXUIElementCreateApplication(codex.processIdentifier)
        let existingLoginControls = CodexNativeLoginStarter.loginControls(in: root)
        if existingLoginControls.count == 1 { return }
        if existingLoginControls.count > 1 {
            throw CodexBrowserOAuthError.codexLoginControlAmbiguous
        }

        // 当前 Codex 的 macOS 应用菜单中提供原生“注销/Log Out”命令。使用精确
        // 菜单项匹配发起退出，避免独立 CLI app-server 与桌面会话状态不同步。
        let commandDeadline = Date().addingTimeInterval(8)
        var didPressLogoutCommand = false
        while Date() < commandDeadline {
            try Task.checkCancellation()
            root = AXUIElementCreateApplication(codex.processIdentifier)
            let commands = Self.logoutCommandControls(in: root)
            if commands.count > 1 {
                throw CodexBrowserOAuthError.codexLogoutCommandAmbiguous
            }
            if let command = commands.first {
                _ = codex.activate(options: [.activateAllWindows])
                guard CodexLoginAutomator.press(command) else {
                    throw CodexBrowserOAuthError.codexLogoutCommandPressFailed
                }
                didPressLogoutCommand = true
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard didPressLogoutCommand else {
            throw CodexBrowserOAuthError.codexLogoutCommandNotFound
        }

        let confirmationDeadline = Date().addingTimeInterval(timeout)
        var didPressConfirmation = false
        while Date() < confirmationDeadline {
            try Task.checkCancellation()
            let root = AXUIElementCreateApplication(codex.processIdentifier)
            let loginControls = CodexNativeLoginStarter.loginControls(in: root)
            if loginControls.count == 1 {
                return // account/logout 已直接完成，无需二次确认。
            }
            if loginControls.count > 1 {
                throw CodexBrowserOAuthError.codexLoginControlAmbiguous
            }

            let confirmations = Self.logoutConfirmationControls(in: root)
            if confirmations.count > 1 {
                throw CodexBrowserOAuthError.codexLogoutConfirmationAmbiguous
            }
            if let confirmation = confirmations.first {
                _ = codex.activate(options: [.activateAllWindows])
                guard CodexLoginAutomator.press(confirmation)
                        || CodexLoginAutomator.clickCenter(confirmation) else {
                    throw CodexBrowserOAuthError.codexLogoutConfirmationPressFailed
                }
                didPressConfirmation = true
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard didPressConfirmation else {
            throw CodexBrowserOAuthError.codexLogoutConfirmationNotFound
        }

        // 点击确认后等待 Codex 完成清理，并以原生登录按钮作为退出完成证据。
        let completionDeadline = Date().addingTimeInterval(timeout)
        while Date() < completionDeadline {
            try Task.checkCancellation()
            let root = AXUIElementCreateApplication(codex.processIdentifier)
            let loginControls = CodexNativeLoginStarter.loginControls(in: root)
            if loginControls.count == 1 { return }
            if loginControls.count > 1 {
                throw CodexBrowserOAuthError.codexLoginControlAmbiguous
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw CodexBrowserOAuthError.codexLogoutDidNotComplete
    }

    static func isLogoutConfirmationTitle(_ text: String) -> Bool {
        let normalized = normalize(text)
        let exactTitles: Set<String> = [
            "退出登录?", "登出?", "要登出吗?", "log out?", "sign out?",
        ]
        return exactTitles.contains(normalized)
    }

    static func isLogoutCommand(role: String, text: String) -> Bool {
        guard role == kAXMenuItemRole else { return false }
        let exactLabels: Set<String> = [
            "注销", "退出登录", "登出", "log out", "sign out",
        ]
        return exactLabels.contains(normalize(text))
    }

    static func isLogoutConfirmationButton(role: String, text: String) -> Bool {
        guard role == kAXButtonRole || role == "AXLink" else { return false }
        let exactLabels: Set<String> = ["退出登录", "登出", "log out", "sign out"]
        return exactLabels.contains(normalize(text))
    }

    private static func logoutConfirmationControls(in root: AXUIElement) -> [AXUIElement] {
        var hasConfirmationTitle = false
        var candidates: [(element: AXUIElement, area: CGFloat, inDialog: Bool)] = []
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
            if Self.isLogoutConfirmationTitle(text) {
                hasConfirmationTitle = true
            }
            guard Self.isLogoutConfirmationButton(role: role, text: text),
                  let frame = CodexLoginAutomator.frame(of: element),
                  frame.width > 1, frame.height > 1 else { return }
            candidates.append((
                element: element,
                area: frame.width * frame.height,
                inDialog: Self.hasDialogAncestor(element)
            ))
        }
        guard hasConfirmationTitle else { return [] }

        var seen: Set<String> = []
        let unique = candidates.filter { candidate in
            guard let frame = CodexLoginAutomator.frame(of: candidate.element) else { return false }
            let key = "\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width)):\(Int(frame.height))"
            return seen.insert(key).inserted
        }
        let dialogCandidates = unique.filter(\.inDialog)
        if !dialogCandidates.isEmpty {
            return dialogCandidates.map(\.element)
        }
        guard let largest = unique.max(by: { $0.area < $1.area }) else { return [] }
        let similarlySized = unique.filter { $0.area >= largest.area * 0.8 }
        guard similarlySized.count == 1 else { return similarlySized.map(\.element) }
        return [largest.element]
    }

    private static func logoutCommandControls(in root: AXUIElement) -> [AXUIElement] {
        var matches: [AXUIElement] = []
        let budget = ChatGPTAccountSwitcher.Box(2_000)
        ChatGPTAccountSwitcher.walkElements(
            in: root,
            depth: 0,
            budget: budget,
            deadline: Date().addingTimeInterval(5),
            maxDepth: 8
        ) { element in
            let role = CodexLoginAutomator.role(of: element)
            let text = CodexLoginAutomator.matchingText(of: element)
            if Self.isLogoutCommand(role: role, text: text) {
                matches.append(element)
            }
        }
        return matches
    }

    private static func hasDialogAncestor(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<10 {
            let semantic = [
                CodexLoginAutomator.stringAttribute(current, kAXRoleAttribute),
                CodexLoginAutomator.stringAttribute(current, kAXSubroleAttribute),
                CodexLoginAutomator.stringAttribute(current, kAXRoleDescriptionAttribute),
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            if semantic.contains("dialog") || semantic.contains("modal")
                || semantic.contains("alert") || semantic.contains("对话框")
                || semantic.contains("警告") || boolAttribute(current, kAXModalAttribute) == true {
                return true
            }
            guard let parent = CodexLoginAutomator.rawAttribute(
                current, kAXParentAttribute
            ) else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let raw = CodexLoginAutomator.rawAttribute(element, attribute) else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "？", with: "?")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

public actor FakeCodexNativeLogoutConfirmer: CodexNativeLogoutConfirming {
    private var callCountStorage = 0
    public var failure: Error?

    public init() {}

    public var callCount: Int { callCountStorage }

    public func logoutAndWaitForLoginScreen() async throws {
        callCountStorage += 1
        if let failure { throw failure }
    }
}

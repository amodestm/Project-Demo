import AppKit
import ApplicationServices
import Foundation

/// 从 Codex 左下角个人资料菜单发起退出，处理二次确认框并等待登录页出现。
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

        // 上一次运行可能在确认框出现后被中断（例如更新 AIRunner）。唯一的官方
        // 退出确认框已经可见时直接接管，不要求用户先取消再重新打开账号菜单。
        let pendingConfirmations = Self.logoutConfirmationControls(in: root)
        if pendingConfirmations.count > 1 {
            throw CodexBrowserOAuthError.codexLogoutConfirmationAmbiguous
        }
        let hasPendingConfirmation = pendingConfirmations.count == 1

        // 当前 Codex 的主要退出入口在左下角个人资料菜单。先按真实网页 UI 打开
        // 账号菜单并点击“退出登录”；找不到新版入口时才回退 macOS 应用菜单。
        let commandDeadline = Date().addingTimeInterval(8)
        var didPressLogoutCommand = hasPendingConfirmation
        var foundProfileMenu = false
        var usedSidebarLogoutCommand = false
        var logoutCommandPressedAt: Date?
        while !didPressLogoutCommand, Date() < commandDeadline {
            try Task.checkCancellation()
            root = AXUIElementCreateApplication(codex.processIdentifier)
            let profileMenus = Self.profileMenuControls(in: root)
            if profileMenus.count > 1 {
                throw CodexBrowserOAuthError.codexLogoutCommandAmbiguous
            }
            if let profileMenu = profileMenus.first {
                foundProfileMenu = true
                _ = codex.activate(options: [.activateAllWindows])
                guard CodexLoginAutomator.press(profileMenu)
                        || CodexLoginAutomator.clickCenter(profileMenu) else {
                    throw CodexBrowserOAuthError.codexLogoutCommandPressFailed
                }
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        if foundProfileMenu {
            // AXPress 有时先只聚焦 PopUpButton；菜单出现后重新读取整棵窗口树。
            let menuDeadline = Date().addingTimeInterval(12)
            var retriedProfileClick = false
            while Date() < menuDeadline {
                try Task.checkCancellation()
                root = AXUIElementCreateApplication(codex.processIdentifier)
                let commands = Self.sidebarLogoutControls(in: root)
                if commands.count > 1 {
                    throw CodexBrowserOAuthError.codexLogoutCommandAmbiguous
                }
                if let command = commands.first {
                    guard CodexLoginAutomator.press(command)
                            || CodexLoginAutomator.clickCenter(command) else {
                        throw CodexBrowserOAuthError.codexLogoutCommandPressFailed
                    }
                    didPressLogoutCommand = true
                    usedSidebarLogoutCommand = true
                    logoutCommandPressedAt = Date()
                    break
                }

                // 两秒后菜单仍未出现时，对已确认的同一个 PopUpButton 做一次
                // 真实 AXFrame 中心点击兜底，不使用固定坐标。
                if !retriedProfileClick,
                   Date().timeIntervalSince(menuDeadline.addingTimeInterval(-12)) >= 2 {
                    let profileMenus = Self.profileMenuControls(in: root)
                    if profileMenus.count == 1 {
                        retriedProfileClick = CodexLoginAutomator.clickCenter(profileMenus[0])
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        // 兼容没有左下角个人资料菜单的旧版 Codex。
        if !didPressLogoutCommand {
            let fallbackDeadline = Date().addingTimeInterval(5)
            while Date() < fallbackDeadline {
                try Task.checkCancellation()
                root = AXUIElementCreateApplication(codex.processIdentifier)
                let commands = Self.nativeMenuLogoutControls(in: root)
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
        }
        guard didPressLogoutCommand else {
            throw CodexBrowserOAuthError.codexLogoutCommandNotFound
        }

        let confirmationSearchDeadline = Date().addingTimeInterval(timeout)
        var completionDeadline: Date?
        var didPressConfirmation = false
        var confirmationPressedAt: Date?
        var retriedConfirmationClick = false
        var retriedSidebarLogoutClick = false
        while Date() < (completionDeadline ?? confirmationSearchDeadline) {
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
                if !didPressConfirmation {
                    _ = codex.activate(options: [.activateAllWindows])
                    guard CodexLoginAutomator.press(confirmation)
                            || CodexLoginAutomator.clickCenter(confirmation) else {
                        throw CodexBrowserOAuthError.codexLogoutConfirmationPressFailed
                    }
                    didPressConfirmation = true
                    confirmationPressedAt = Date()
                    completionDeadline = Date().addingTimeInterval(timeout)
                } else if !retriedConfirmationClick,
                          let pressedAt = confirmationPressedAt,
                          Date().timeIntervalSince(pressedAt) >= 2 {
                    // Chromium 也可能对确认按钮返回虚假的 AXPress 成功。确认框两秒后
                    // 仍在时，重新读取红色按钮的实时 AXFrame 并补点一次。
                    _ = codex.activate(options: [.activateAllWindows])
                    retriedConfirmationClick = true
                    guard CodexLoginAutomator.clickCenter(confirmation) else {
                        throw CodexBrowserOAuthError.codexLogoutConfirmationPressFailed
                    }
                }
            }

            // Chromium 的 AXPress 可能返回 success，但网页没有收到第一层菜单项的
            // 点击。若两秒后确认框和登录页都未出现，而且同一个“退出登录”仍然
            // 可见，就用该元素实时 AXFrame 的中心再点一次。只重试一次。
            if !didPressConfirmation,
               usedSidebarLogoutCommand, !retriedSidebarLogoutClick,
               let pressedAt = logoutCommandPressedAt,
               Date().timeIntervalSince(pressedAt) >= 2 {
                let commands = Self.sidebarLogoutControls(in: root)
                if commands.count > 1 {
                    throw CodexBrowserOAuthError.codexLogoutCommandAmbiguous
                }
                if let command = commands.first {
                    _ = codex.activate(options: [.activateAllWindows])
                    retriedSidebarLogoutClick = true
                    guard CodexLoginAutomator.clickCenter(command) else {
                        throw CodexBrowserOAuthError.codexLogoutCommandPressFailed
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard didPressConfirmation else {
            throw CodexBrowserOAuthError.codexLogoutConfirmationNotFound
        }

        // 超时时读取最终页面状态，区分“确认按钮没有生效”和“确认框已经消失、
        // 但登录页没有完成加载”，避免把前一种情况误报成已经退出。
        let finalRoot = AXUIElementCreateApplication(codex.processIdentifier)
        let remainingConfirmations = Self.logoutConfirmationControls(in: finalRoot)
        if remainingConfirmations.count > 1 {
            throw CodexBrowserOAuthError.codexLogoutConfirmationAmbiguous
        }
        if remainingConfirmations.count == 1 {
            throw CodexBrowserOAuthError.codexLogoutConfirmationDidNotDismiss
        }
        throw CodexBrowserOAuthError.codexLogoutDidNotComplete
    }

    static func isLogoutConfirmationTitle(_ text: String) -> Bool {
        let normalized = normalize(text)
        let exactTitles: Set<String> = [
            "退出登录?", "要退出登录?", "登出?", "要登出吗?", "log out?", "sign out?",
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

    static func isProfileMenuControl(role: String, text: String) -> Bool {
        guard role == "AXPopUpButton" || role == kAXButtonRole
                || role == "AXMenuButton" else { return false }
        let exactLabels: Set<String> = [
            "打开个人资料菜单", "打开账号菜单", "个人资料菜单", "账号菜单",
            "open profile menu", "open account menu", "profile menu", "account menu",
        ]
        return exactLabels.contains(normalize(text))
    }

    static func isSidebarLogoutControl(role: String, text: String) -> Bool {
        guard role == kAXButtonRole || role == kAXMenuItemRole || role == "AXLink"
                || role == kAXStaticTextRole else { return false }
        let exactLabels: Set<String> = ["退出登录", "登出", "注销", "log out", "sign out"]
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
        let deadline = Date().addingTimeInterval(8)
        for surface in CodexNativeLoginStarter.contentSurfaces(in: root) {
            let budget = ChatGPTAccountSwitcher.Box(20_000)
            ChatGPTAccountSwitcher.walkElements(
                in: surface,
                depth: 0,
                budget: budget,
                deadline: deadline,
                maxDepth: 40
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

    private static func profileMenuControls(in root: AXUIElement) -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(5)
        for surface in CodexNativeLoginStarter.contentSurfaces(in: root) {
            var matches: [AXUIElement] = []
            let budget = ChatGPTAccountSwitcher.Box(20_000)
            ChatGPTAccountSwitcher.walkElements(
                in: surface,
                depth: 0,
                budget: budget,
                deadline: deadline,
                maxDepth: 40
            ) { element in
                let role = CodexLoginAutomator.role(of: element)
                let text = CodexLoginAutomator.matchingText(of: element)
                if Self.isProfileMenuControl(role: role, text: text) {
                    matches.append(element)
                }
            }
            let unique = deduplicated(matches)
            if !unique.isEmpty { return unique }
        }
        return []
    }

    private static func sidebarLogoutControls(in root: AXUIElement) -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(5)
        for surface in CodexNativeLoginStarter.contentSurfaces(in: root) {
            var matches: [AXUIElement] = []
            let budget = ChatGPTAccountSwitcher.Box(20_000)
            ChatGPTAccountSwitcher.walkElements(
                in: surface,
                depth: 0,
                budget: budget,
                deadline: deadline,
                maxDepth: 40
            ) { element in
                let role = CodexLoginAutomator.role(of: element)
                let text = CodexLoginAutomator.matchingText(of: element)
                guard Self.isSidebarLogoutControl(role: role, text: text),
                      let actionable = actionableControl(for: element) else { return }
                matches.append(actionable)
            }
            let unique = deduplicated(matches)
            if !unique.isEmpty { return unique }
        }
        return []
    }

    private static func nativeMenuLogoutControls(in root: AXUIElement) -> [AXUIElement] {
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

    private static func actionableControl(for element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<6 {
            let role = CodexLoginAutomator.role(of: current)
            if role == kAXButtonRole || role == kAXMenuItemRole || role == "AXLink" {
                return current
            }
            guard let parent = CodexLoginAutomator.rawAttribute(
                current, kAXParentAttribute
            ) else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    private static func deduplicated(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen: Set<String> = []
        return elements.filter { element in
            let key: String
            if let frame = CodexLoginAutomator.frame(of: element) {
                key = "\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width)):\(Int(frame.height))"
            } else {
                key = "\(CodexLoginAutomator.role(of: element)):\(CodexLoginAutomator.matchingText(of: element))"
            }
            return seen.insert(key).inserted
        }
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

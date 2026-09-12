import AppKit
import ApplicationServices
import Foundation

/// Codex 浏览器 OAuth 页面的单步推进器。
///
/// 它只会在 `auth.openai.com` 上执行两类明确动作：
/// 1. 页面只有一个已登录账号时，按下该账号。
/// 2. Codex 授权页只有一个“继续”按钮时，按下它。
///
/// 如果有多个账号、需要重新登录或出现安全验证，立即停止，避免授权错账号。
public protocol CodexOAuthBrowserAutomating: Sendable {
    func reset() async

    @discardableResult
    func advance() async throws -> Bool
}

public enum CodexOAuthBrowserAutomationError: Error, LocalizedError, Sendable, Equatable {
    case accessibilityPermissionMissing
    case ambiguousAccounts
    case profileNotLoggedIn
    case securityChallenge
    case controlPressFailed
    case authorizationRejected

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "AIRunner 需要辅助功能权限，才能自动完成 Codex 浏览器授权。"
        case .ambiguousAccounts:
            return "当前 Chrome Profile 的 Codex 授权页出现多个账号，AIRunner 已停止以避免选错。"
        case .profileNotLoggedIn:
            return "当前 Chrome Profile 没有可用的 ChatGPT 登录会话。请先在该 Profile 登录 chatgpt.com。"
        case .securityChallenge:
            return "Codex 授权页出现验证码、两步验证或安全检查，AIRunner 已停止。"
        case .controlPressFailed:
            return "AIRunner 找到了 Codex 授权控件，但未能按下。"
        case .authorizationRejected:
            return "OpenAI 拒绝了这次 Codex 授权步骤。AIRunner 已停止，请重试以获取新的一次性授权流程。"
        }
    }
}

public actor CodexOAuthBrowserAutomator: CodexOAuthBrowserAutomating {
    struct Control: Sendable, Equatable {
        let role: String
        let text: String
        let enabled: Bool

        init(role: String = kAXButtonRole, text: String, enabled: Bool = true) {
            self.role = role
            self.text = text
            self.enabled = enabled
        }
    }

    enum IntendedAction: Sendable, Equatable {
        case wait
        case chooseAccount(Int)
        case continueConsent(Int)
        case ambiguousAccounts
        case profileNotLoggedIn
        case securityChallenge
        case authorizationRejected
    }

    private var pressedActions: Set<String> = []

    public init() {}

    public func reset() {
        pressedActions.removeAll()
    }

    @discardableResult
    public func advance() async throws -> Bool {
        guard AXIsProcessTrusted() else {
            throw CodexOAuthBrowserAutomationError.accessibilityPermissionMissing
        }
        guard let chrome = NSRunningApplication.runningApplications(
            withBundleIdentifier: ChromeProfileScanner.ChromeKind.chrome.rawValue
        ).first else {
            return false
        }

        let root = AXUIElementCreateApplication(chrome.processIdentifier)
        let windows = Self.orderedWindows(in: root)

        // 一次 OAuth 只允许驱动当前真正获得焦点的官方授权窗口；如果它正在
        // 加载，直接等待，不能继续扫描其他 Profile 遗留的旧授权页。
        // 只接受 Chrome 当前窗口。继续扫描其他窗口会在目标 Profile 尚在加载时
        // 接管另一个 Profile 遗留的授权页，造成看似“没有切换 Profile”。
        guard let window = windows.first,
              let document = CodexLoginAutomator.stringAttribute(
                  window, kAXDocumentAttribute
              ), let url = URL(string: document), url.scheme == "https",
              url.host?.lowercased() == "auth.openai.com" else {
            return false
        }

        // OpenAI 账号卡片在 Chrome AX 树中通常位于第 15–17 层。
        // 深度 24 可覆盖当前页面结构，同时继续用节点预算防止无界扫描。
        let elements = Self.descendants(of: window, maxDepth: 24, maxNodes: 1_600)
        let controls = elements.map {
            Control(
                role: CodexLoginAutomator.role(of: $0),
                text: CodexLoginAutomator.matchingText(of: $0),
                enabled: Self.boolAttribute($0, kAXEnabledAttribute) ?? true
            )
        }
        let pageText = controls.map(\.text).joined(separator: " ")

        // 按下账号后，OpenAI 会在 URL 尚未变化时先移除账号卡片；
        // 按下“继续”后也会先把按钮禁用。这两种都是正常跳转中状态，
        // 已执行的动作必须先于页面分类被识别，避免误报“未登录”。
        let currentActionKind: String? = if url.path.lowercased().contains("choose-an-account") {
            "choose-account"
        } else if url.path.lowercased().contains("/consent")
                    || url.path.lowercased().contains("/authorize") {
            "continue-consent"
        } else {
            nil
        }
        if let currentActionKind,
           pressedActions.contains("\(url.absoluteString)#\(currentActionKind)") {
            return false
        }

        let action = Self.intendedAction(url: url, controls: controls, pageText: pageText)

        switch action {
        case .wait:
            return false
        case .ambiguousAccounts:
            throw CodexOAuthBrowserAutomationError.ambiguousAccounts
        case .profileNotLoggedIn:
            throw CodexOAuthBrowserAutomationError.profileNotLoggedIn
        case .securityChallenge:
            throw CodexOAuthBrowserAutomationError.securityChallenge
        case .authorizationRejected:
            throw CodexOAuthBrowserAutomationError.authorizationRejected
        case .chooseAccount(let index), .continueConsent(let index):
            guard elements.indices.contains(index) else { return false }
            let actionKind: String
            switch action {
            case .chooseAccount: actionKind = "choose-account"
            case .continueConsent: actionKind = "continue-consent"
            default: return false
            }
            let actionKey = "\(url.absoluteString)#\(actionKind)"
            guard pressedActions.insert(actionKey).inserted else {
                return false
            }
            _ = chrome.activate(options: [.activateAllWindows])
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let element = elements[index]
            // Chromium 在 Codex 工作空间授权页会对 AXPress 返回 success，
            // 但偶尔不会把事件交给网页。这里对“继续”直接使用 AXFrame
            // 中心的一次真实点击；账号卡片仍优先 AXPress，避免在页面跳转
            // 较慢时重复选择同一张卡片而触发 invalid_auth_step。
            let didActivate: Bool
            switch action {
            case .continueConsent:
                didActivate = CodexLoginAutomator.clickCenter(element)
                    || CodexLoginAutomator.press(element)
            case .chooseAccount:
                didActivate = CodexLoginAutomator.press(element)
                    || CodexLoginAutomator.clickCenter(element)
            default:
                didActivate = false
            }
            guard didActivate else {
                pressedActions.remove(actionKey)
                throw CodexOAuthBrowserAutomationError.controlPressFailed
            }
            // 账号选择和授权确认点击后页面会异步跳转；等待 10 秒再进行下一次
            // 窗口扫描，避免把临时空白/旧 URL 当成目标页面。
            try? await Task.sleep(for: .seconds(10))
            return true
        }
    }

    /// 把网页语义分类和 AX 操作分开，便于验证“只有唯一明确目标才点击”。
    static func intendedAction(
        url: URL,
        controls: [Control],
        pageText: String
    ) -> IntendedAction {
        let path = url.path.lowercased()
        let normalizedPage = normalize(pageText)

        if normalizedPage.contains("invalid_auth_step")
            || normalizedPage.contains("授权步骤无效") {
            return .authorizationRejected
        }

        let challengeHints = [
            "captcha", "verify you are human", "security check", "two-factor",
            "two step verification", "2-step verification", "验证码", "人机验证",
            "安全检查", "两步验证", "双重验证",
        ]
        if challengeHints.contains(where: normalizedPage.contains) {
            return .securityChallenge
        }

        if path.contains("choose-an-account") {
            let candidates = controls.indices.filter { index in
                let control = controls[index]
                guard control.enabled, control.role == kAXButtonRole else { return false }
                let text = normalize(control.text)
                let isRemoval = text.contains("移除账户")
                    || text.contains("remove account")
                let isChoice = text.hasPrefix("选择账户")
                    || text.hasPrefix("选择账号")
                    || text.hasPrefix("select account")
                    || text.hasPrefix("choose account")
                    || text.hasPrefix("continue as")
                return isChoice && !isRemoval
            }
            if candidates.count == 1 { return .chooseAccount(candidates[0]) }
            if candidates.count > 1 { return .ambiguousAccounts }
            // 首次渲染和点击后跳转时，URL 已经到这里，账号卡片却可能
            // 短暂不在 AX 树。只有真正进入登录表单时才报“Profile 未登录”。
            return .wait
        }

        if path.contains("/consent") || path.contains("/authorize") {
            let candidates = controls.indices.filter { index in
                let control = controls[index]
                guard control.enabled, control.role == kAXButtonRole else { return false }
                let text = normalize(control.text)
                return text == "继续" || text == "continue"
                    || text == "授权" || text == "authorize"
                    || text == "允许" || text == "allow"
            }
            if candidates.count == 1 { return .continueConsent(candidates[0]) }
            return .wait
        }

        if path.contains("log-in") || path.contains("login") || path.contains("sign-in") {
            let hasLoginField = controls.contains { control in
                let role = control.role
                let text = normalize(control.text)
                return role == kAXTextFieldRole
                    || text.contains("email address") || text.contains("电子邮件地址")
            }
            if hasLoginField { return .profileNotLoggedIn }
        }

        return .wait
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func descendants(
        of root: AXUIElement,
        maxDepth: Int,
        maxNodes: Int
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var budget = maxNodes

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, budget > 0 else { return }
            budget -= 1
            result.append(element)
            for child in elements(in: element, attribute: kAXChildrenAttribute) {
                visit(child, depth: depth + 1)
                if budget <= 0 { break }
            }
        }
        visit(root, depth: 0)
        return result
    }

    private static func elements(in element: AXUIElement, attribute: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard status == .success, let result = raw as? [AXUIElement] else { return [] }
        return result
    }

    /// 优先返回 Chrome 当前真正获得焦点的窗口。
    ///
    /// 多个 Profile 可能同时留有旧的 OAuth 页；仅依赖 `AXWindows` 的数组顺序
    /// 会把上一次失败的授权页当成这一次的目标。Codex 点击“继续登录”前已将
    /// 目标 Profile 置为最近窗口，因此这里先取 focused window，再回退到其他窗口。
    private static func orderedWindows(in root: AXUIElement) -> [AXUIElement] {
        let windows = elements(in: root, attribute: kAXWindowsAttribute)
        guard !windows.isEmpty else { return [] }
        var rawFocused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root, kAXFocusedWindowAttribute as CFString, &rawFocused
        ) == .success, let rawFocused else {
            return windows
        }
        let focused = unsafeDowncast(rawFocused, to: AXUIElement.self)
        return [focused] + windows.filter { !CFEqual($0, focused) }
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }
}

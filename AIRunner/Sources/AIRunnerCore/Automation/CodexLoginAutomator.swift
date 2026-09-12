import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

// MARK: - 配置

/// 登出/登录自动化的可调参数 (全部候选集合, fail-closed)。
public struct CodexLoginAutomatorConfiguration: Sendable, Equatable {

    /// 登录邮箱输入框的候选提示词 (aria-label / placeholder)。
    public var emailFieldHints: [String] = [
        "email", "邮箱", "邮件", "电子邮件", "email address",
    ]

    /// 登录按钮 (chatgpt.com 未登录首页 / 邮箱页的「继续」) 的候选文案。
    public var continueButtonHints: [String] = [
        "继续", "Continue", "登录", "Log in", "Login",
    ]

    /// SSO 按钮要**排除**的关键词 —— 它们也含 "Continue"/"登录" 字样但不是我们要点的。
    public var ssoExcludedHints: [String] = [
        "google", "微软", "microsoft", "apple", "苹果", "sso", "single sign",
    ]

    /// 登出菜单项候选文案。
    public var logoutItemHints: [String] = [
        "登出", "退出登录", "注销", "Log out", "Sign out",
    ]

    /// 新 ChatGPT UI 左下角「账号」按钮候选 label。
    ///
    /// 旧版右上角头像菜单已改版消失, 登出改走左下角侧边栏账号按钮
    /// (点击后弹出含「Log out」的菜单)。该按钮的 label 通常就是你登录的
    /// 邮箱/显示名 —— 因此 `findSidebarAccountButton` 也会拿当前邮箱片段兜底匹配。
    public var sidebarAccountButtonHints: [String] = [
        "account", "账号", "profile", "个人资料", "manage account",
        "settings", "设置",
    ]

    /// ★ 人机验证 / 二次验证信号 —— 检测到任何一条立即停手交还用户 ★
    public var humanVerificationHints: [String] = [
        "verify you are human", "confirm you are human", "确认您是真人", "验证您是真人",
        "i'm not a robot", "captcha", "人机验证",
        "two-factor", "two factor", "2fa", "两步验证", "双重验证", "双因素",
        "verification code", "verify your email", "验证码", "输入你收到的代码", "check your email",
    ]

    /// 各阶段等待上限 (秒)。
    public var menuAppearDelay: Duration = .seconds(1)
    public var fieldPollTimeout: TimeInterval = 15
    public var actionPollInterval: Duration = .milliseconds(500)
    public var loginCompleteTimeout: TimeInterval = 30

    /// 逐字符输入的间隔 (模拟真人打字, 过快会被页面脚本丢事件)。
    public var typeInterval: Duration = .milliseconds(20)

    /// AX 遍历预算与超时。
    public var traversalNodeBudget: Int = 8000
    public var traversalMaxDepth: Int = 18
    public var traversalTimeout: TimeInterval = 10

    public init() {}
    public static let `default` = CodexLoginAutomatorConfiguration()
}

// MARK: - 错误

public enum CodexLoginError: Error, Sendable, Equatable, LocalizedError {
    /// 检测到人机验证 / 验证码 / 2FA —— **绝不绕过**, 停手交还用户。
    case humanVerificationRequired(String)
    case logoutFailed(String)
    case emailFieldNotFound
    case emailNotTyped(String)
    case passwordFieldNotFound
    case continueButtonNotFound
    case loginDidNotComplete(String)

    public var errorDescription: String? {
        switch self {
        case .humanVerificationRequired(let detail):
            return "需要人工完成验证 (\(detail))。请在浏览器里手动完成后, "
                + "回到 AIRunner 用「我已完成账号切换」或直接继续任务 —— "
                + "程序不会尝试绕过任何验证。"
        case .logoutFailed(let detail):
            return "登出未完成: \(detail)"
        case .emailFieldNotFound:
            return "找不到登录邮箱输入框。请确认浏览器已打开 ChatGPT 登录页。"
        case .emailNotTyped(let typed):
            return "邮箱未成功输入 (框内是「\(typed)」)。请手动检查登录页。"
        case .passwordFieldNotFound:
            return "点击继续后没有出现密码输入框 (可能被验证拦住, 或页面改版)。"
        case .continueButtonNotFound:
            return "找不到「继续/登录」按钮。"
        case .loginDidNotComplete(let detail):
            return "登录未在预期时间内完成: \(detail)"
        }
    }
}

// MARK: - 协议

/// Codex 登出/登录自动化 (测试注入替身)。
public protocol CodexLoginAutomating: Sendable {
    /// 登出当前账号。**幂等** —— 已处于登出态 (登录页) 则直接成功。
    ///
    /// `currentAccountEmail` 可选: 传入当前登录邮箱, 用于更稳地定位左下角侧边栏账号按钮
    /// (其 label 通常就是该邮箱)。
    ///
    /// 注意: 协议要求不能带默认参数 (Swift 限制), 默认 `nil` 由具体实现提供。
    func logout(currentAccountEmail: String?) async throws

    /// 用邮箱+密码登录。成功 = 回到 ChatGPT 已登录界面。
    /// 密码只在本次调用期间存在, 不落任何存储。
    func login(email: String, password: String) async throws

}

// MARK: - 真实实现

/// 通过 AX + CGEvent 完成「登出当前 Codex/ChatGPT 账号 → 账号密码重新登录」。
///
/// ## 与手动操作完全等价
///
/// * 打开侧边栏账号菜单、点「登出」 —— 与鼠标点等价
/// * 找到邮箱框, **逐字符键入** —— 与键盘打字等价 (CGEvent 键盘事件)
/// * 点「继续」, 等密码框出现, 逐字符键入密码, 点「登录」
///
/// ## ★ 两条铁律 ★
///
/// 1. **绝不绕过人机验证** —— 检测到 CAPTCHA / Cloudflare / 2FA 的任何信号,
///    立即抛 `humanVerificationRequired` 停手, 让用户在浏览器里手动完成。
/// 2. **密码零落盘** —— 密码只作为函数参数在内存中存在到登录结束,
///    不进日志、不进数据库、不进 Keychain 之外的任何地方。
public struct CodexLoginAutomator: CodexLoginAutomating {

    private let configuration: CodexLoginAutomatorConfiguration
    private let windows: BrowserWindowLocating
    private let settings: @Sendable () -> AppSettings
    /// 测试钩子: 键盘输入动作 (真实实现是 CGEvent postToPid)。
    private let keystroke: @Sendable (String, pid_t) async -> Void

    public init(
        configuration: CodexLoginAutomatorConfiguration = .default,
        windows: BrowserWindowLocating = BrowserWindowLocator(),
        settings: @escaping @Sendable () -> AppSettings = { .default }
    ) {
        self.configuration = configuration
        self.windows = windows
        self.settings = settings
        self.keystroke = { text, pid in
            await Self.typeText(text, to: pid)
        }
    }

    // MARK: - 登出

    public func logout(currentAccountEmail: String? = nil) async throws {
        let chrome = try requireTrustedChrome()

        // 已处于登录页 (能看到邮箱框) = 已经是登出态 → 幂等成功
        if let axApp = appAXElement(of: chrome),
           Self.findEmailField(in: axApp, configuration: configuration) != nil {
            return
        }

        _ = try? windows.focusWindow(
            bundleIdentifier: "com.google.Chrome",
            titleFragment: "ChatGPT",
            activateApp: true
        )

        guard let axApp = appAXElement(of: chrome) else {
            throw CodexLoginError.logoutFailed("无法读取 Chrome 的 AX 树")
        }

        // 找左下角侧边栏账号按钮 (新 ChatGPT UI; 旧版右上角头像菜单已改版消失)。
        // 找不到就 fail-closed 交还手动 —— 绝不猜测目标。
        guard let sidebarButton = Self.findSidebarAccountButton(
            in: axApp, configuration: configuration, currentEmail: currentAccountEmail
        ) else {
            throw CodexLoginError.logoutFailed(
                "在新 ChatGPT 界面里没找到左下角侧边栏账号按钮 (你的账号/邮箱)。"
                + "请手动点左下角账号 → 退出登录, 或在设置里调整侧边栏账号按钮提示词。"
            )
        }

        guard Self.press(sidebarButton) else {
            throw CodexLoginError.logoutFailed("无法点击侧边栏账号按钮")
        }
        try? await Task.sleep(for: configuration.menuAppearDelay)

        // 菜单里轮询找「登出」项 (可能要点确认弹窗才出现)
        var logoutItem: AXUIElement?
        let menuDeadline = Date().addingTimeInterval(configuration.loginCompleteTimeout)
        while Date() < menuDeadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: configuration.actionPollInterval)
            guard let appNow = appAXElement(of: chrome) else { break }

            if let signal = Self.humanVerificationSignal(
                in: appNow, configuration: configuration
            ) {
                throw CodexLoginError.humanVerificationRequired(signal)
            }

            if let item = Self.findFirst(
                in: appNow, configuration: configuration,
                matching: { Self.isLogoutItem($0, hints: configuration.logoutItemHints) }
            ) {
                logoutItem = item
                break
            }
        }

        guard let item = logoutItem else {
            throw CodexLoginError.logoutFailed("侧边栏菜单里没找到「登出 / Log out」项")
        }
        guard Self.press(item) else {
            throw CodexLoginError.logoutFailed("无法点击登出项")
        }

        // 等回到登录页 (邮箱框重新出现 = 登出完成)
        let deadline = Date().addingTimeInterval(configuration.loginCompleteTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: configuration.actionPollInterval)
            guard let appNow = appAXElement(of: chrome) else { break }

            if let signal = Self.humanVerificationSignal(
                in: appNow, configuration: configuration
            ) {
                throw CodexLoginError.humanVerificationRequired(signal)
            }

            if Self.findEmailField(in: appNow, configuration: configuration) != nil {
                return  // ★ 已登出, 落在登录页 ★
            }
        }

        throw CodexLoginError.logoutFailed("点击登出后未在预期时间内回到登录页")
    }

    // MARK: - 登录

    public func login(email: String, password: String) async throws {
        let chrome = try requireTrustedChrome()

        // 1) 打开 ChatGPT (未登录态会落在登录首页)
        let urlText = settings().chatGPTURL
        let url = URL(string: urlText) ?? URL(string: "https://chatgpt.com/")!
        _ = ChromeProfileScanner().open(url: url, profile: nil)
        try? await Task.sleep(for: configuration.menuAppearDelay)

        // 聚焦 ChatGPT 窗口 (登录页标题通常也含 ChatGPT; 找不到就聚焦 Chrome 任一窗口)
        _ = try? windows.focusWindow(
            bundleIdentifier: "com.google.Chrome",
            titleFragment: "ChatGPT",
            activateApp: true
        )
        _ = try? windows.focusWindow(
            bundleIdentifier: "com.google.Chrome",
            titleFragment: "Chat",
            activateApp: true
        )

        var axApp = appAXElement(of: chrome)

        // 2) 等邮箱输入框出现; 若先看到「登录」按钮则点它进入 auth 页
        var emailField: AXUIElement?
        let fieldDeadline = Date().addingTimeInterval(configuration.fieldPollTimeout)
        while Date() < fieldDeadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: configuration.actionPollInterval)
            axApp = appAXElement(of: chrome)

            if let signal = Self.humanVerificationSignal(
                in: axApp, configuration: configuration
            ) {
                throw CodexLoginError.humanVerificationRequired(signal)
            }

            if let field = Self.findEmailField(
                in: axApp, configuration: configuration
            ) {
                emailField = field
                break
            }
            // 首页有「Log in」入口 → 点它
            if let loginButton = Self.findContinueButton(
                in: axApp, configuration: configuration, matchLoginOnly: true
            ) {
                Self.press(loginButton)
            }
        }

        guard let emailElement = emailField else {
            throw CodexLoginError.emailFieldNotFound
        }

        // 3) 聚焦 + 清空 + 逐字符键入邮箱
        Self.focusField(emailElement)
        await Self.clearField(emailElement, pid: chrome.processIdentifier)
        await keystroke(email, chrome.processIdentifier)

        let typed = Self.value(of: emailElement) ?? ""
        guard typed.contains(email) else {
            throw CodexLoginError.emailNotTyped(typed)
        }

        // 4) 点「继续」
        guard let continueButton = Self.findContinueButton(
            in: axApp, configuration: configuration, matchLoginOnly: false
        ) else {
            throw CodexLoginError.continueButtonNotFound
        }
        guard Self.press(continueButton) else {
            throw CodexLoginError.continueButtonNotFound
        }

        // 5) 等密码框 (AXSecureTextField 是稳定信号); 期间盯人机验证
        var passwordField: AXUIElement?
        let pwDeadline = Date().addingTimeInterval(configuration.fieldPollTimeout)
        while Date() < pwDeadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: configuration.actionPollInterval)
            axApp = appAXElement(of: chrome)

            if let signal = Self.humanVerificationSignal(
                in: axApp, configuration: configuration
            ) {
                throw CodexLoginError.humanVerificationRequired(signal)
            }

            if let field = Self.findSecureField(
                in: axApp, configuration: configuration
            ) {
                passwordField = field
                break
            }
        }
        guard let pwElement = passwordField else {
            throw CodexLoginError.passwordFieldNotFound
        }

        // 6) 聚焦 + 键入密码 (不读回、不校验明文展示)
        Self.focusField(pwElement)
        await keystroke(password, chrome.processIdentifier)

        // 7) 点「登录/继续」
        guard let submitButton = Self.findContinueButton(
            in: axApp, configuration: configuration, matchLoginOnly: false
        ), Self.press(submitButton) else {
            throw CodexLoginError.continueButtonNotFound
        }

        // 8) 等登录完成 (头像出现) / 人机验证
        let doneDeadline = Date().addingTimeInterval(configuration.loginCompleteTimeout)
        while Date() < doneDeadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: configuration.actionPollInterval)
            axApp = appAXElement(of: chrome)

            if let signal = Self.humanVerificationSignal(
                in: axApp, configuration: configuration
            ) {
                throw CodexLoginError.humanVerificationRequired(signal)
            }

            // 登录完成信号: 已离开登录页 (邮箱框/密码框都不在), 且出现对话界面
            // (composer 文本框) 或左下角侧边栏账号按钮。旧版右上角头像菜单已改版消失,
            // 不再用它判断。
            let emailGone = Self.findEmailField(in: axApp, configuration: configuration) == nil
            let pwGone = Self.findSecureField(in: axApp, configuration: configuration) == nil
            let composer = Self.findComposerTextArea(in: axApp, configuration: configuration) != nil
            let sidebar = Self.findSidebarAccountButton(
                in: axApp, configuration: configuration, currentEmail: nil
            ) != nil
            if emailGone, pwGone, composer || sidebar {
                return  // ★ 登录完成 ★
            }
        }

        throw CodexLoginError.loginDidNotComplete("等待 \(Int(configuration.loginCompleteTimeout))s 未见已登录界面")
    }

    // MARK: - 元素判定 (静态, 纯逻辑可测)

    static func isLogoutItem(_ element: AXUIElement, hints: [String]) -> Bool {
        let role = Self.role(of: element)
        guard role == "AXButton" || role == "AXMenuItem" || role == "AXStaticText" else {
            return false
        }
        let text = ((Self.stringAttribute(element, kAXDescriptionAttribute)
            ?? Self.stringAttribute(element, kAXTitleAttribute)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !text.isEmpty else { return false }
        return hints.contains { text.contains($0.lowercased()) }
    }

    /// 文本是否命中人机验证信号 (静态纯函数, 可测)。
    public static func matchesHumanVerificationHints(
        _ text: String, configuration: CodexLoginAutomatorConfiguration
    ) -> Bool {
        let lower = text.lowercased()
        return configuration.humanVerificationHints.contains { lower.contains($0) }
    }

    /// 在 AX 树里扫人机验证信号 —— 命中即返回该文本。
    static func humanVerificationSignal(
        in appElement: AXUIElement?,
        configuration: CodexLoginAutomatorConfiguration
    ) -> String? {
        guard let appElement else { return nil }
        var hit: String?
        let box = ChatGPTAccountSwitcher.Box(configuration.traversalNodeBudget)
        ChatGPTAccountSwitcher.walkElements(
            in: appElement,
            depth: 0,
            budget: box,
            deadline: Date().addingTimeInterval(configuration.traversalTimeout),
            maxDepth: configuration.traversalMaxDepth
        ) { element in
            guard hit == nil else { return }
            let role = Self.role(of: element)
            guard role == "AXStaticText" || role == "AXHeading" || role == "AXButton"
                || role == "AXGroup" else { return }
            let text = (Self.stringAttribute(element, kAXTitleAttribute)
                ?? Self.stringAttribute(element, kAXDescriptionAttribute)) ?? ""
            if !text.isEmpty, matchesHumanVerificationHints(text, configuration: configuration) {
                hit = text
            }
        }
        return hit
    }

    /// 统一的遍历入口 (封装 Box / 预算 / 超时参数)。
    static func findFirst(
        in element: AXUIElement,
        configuration: CodexLoginAutomatorConfiguration,
        matching: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        let box = ChatGPTAccountSwitcher.Box(configuration.traversalNodeBudget)
        return ChatGPTAccountSwitcher.firstElement(
            in: element,
            depth: 0,
            budget: box,
            deadline: Date().addingTimeInterval(configuration.traversalTimeout),
            maxDepth: configuration.traversalMaxDepth,
            matching: matching
        )
    }

    static func findEmailField(
        in appElement: AXUIElement?,
        configuration: CodexLoginAutomatorConfiguration
    ) -> AXUIElement? {
        guard let appElement else { return nil }
        let hints = configuration.emailFieldHints.map { $0.lowercased() }
        return Self.findFirst(
            in: appElement, configuration: configuration
        ) { element in
            let role = Self.role(of: element)
            guard role == "AXTextField" || role == "AXTextArea" else { return false }
            let text = ((Self.stringAttribute(element, kAXDescriptionAttribute)
                ?? Self.stringAttribute(element, kAXTitleAttribute)) ?? "").lowercased()
            // 命中提示词, 或 auth 页上没有提示词的第一个空文本框
            if hints.contains(where: { text.contains($0) }) { return true }
            return text.isEmpty && (Self.value(of: element) ?? "").isEmpty
        }
    }

    /// 密码框: `<input type="password">` 在 Chromium AX 树里稳定映射为 AXSecureTextField。
    static func findSecureField(
        in appElement: AXUIElement?,
        configuration: CodexLoginAutomatorConfiguration
    ) -> AXUIElement? {
        guard let appElement else { return nil }
        return Self.findFirst(
            in: appElement, configuration: configuration
        ) { element in
            Self.role(of: element) == "AXSecureTextField"
        }
    }

    /// 对话输入框 (composer): 登录成功后 ChatGPT 主页出现的文本框, 是"已登录"的强信号
    /// (登录页没有任何 textarea)。
    static func findComposerTextArea(
        in appElement: AXUIElement?,
        configuration: CodexLoginAutomatorConfiguration
    ) -> AXUIElement? {
        guard let appElement else { return nil }
        return Self.findFirst(
            in: appElement, configuration: configuration
        ) { element in
            Self.role(of: element) == "AXTextArea"
        }
    }

    /// 左下角侧边栏账号按钮 (新 ChatGPT UI; 旧版右上角头像菜单已改版消失)。
    ///
    /// 匹配策略: 命中 `sidebarAccountButtonHints`, 或 label 含当前登录邮箱片段
    /// (侧边栏按钮通常就以邮箱/显示名作 label)。都命中不到则 fail-closed 交还手动。
    static func findSidebarAccountButton(
        in appElement: AXUIElement?,
        configuration: CodexLoginAutomatorConfiguration,
        currentEmail: String?
    ) -> AXUIElement? {
        guard let appElement else { return nil }
        let hints = configuration.sidebarAccountButtonHints.map { $0.lowercased() }
        let emailFragment = currentEmail
            .map { Self.significantFragment(of: $0).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        return Self.findFirst(
            in: appElement, configuration: configuration
        ) { element in
            let role = Self.role(of: element)
            guard role == "AXButton" || role == "AXMenuItem" else { return false }
            let text = ((Self.stringAttribute(element, kAXDescriptionAttribute)
                ?? Self.stringAttribute(element, kAXTitleAttribute)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !text.isEmpty else { return false }
            if hints.contains(where: { text.contains($0) }) { return true }
            if let frag = emailFragment, text.contains(frag) { return true }
            return false
        }
    }

    /// 取文本「显著片段」: 优先 @ 前的部分 (邮箱), 否则整个字符串。
    static func significantFragment(of label: String) -> String {
        if let at = label.firstIndex(of: "@") {
            return String(label[label.startIndex..<at])
        }
        return label
    }

    /// 找「继续/登录」按钮。`matchLoginOnly = true` 只匹配「登录/Log in」
    /// (用于 chatgpt.com 首页入口, 避免误点 SSO 的 Continue)。
    static func findContinueButton(
        in appElement: AXUIElement?,
        configuration: CodexLoginAutomatorConfiguration,
        matchLoginOnly: Bool
    ) -> AXUIElement? {
        guard let appElement else { return nil }
        let sso = configuration.ssoExcludedHints.map { $0.lowercased() }
        let wanted = matchLoginOnly
            ? ["登录", "log in", "login"]
            : configuration.continueButtonHints.map { $0.lowercased() }

        return Self.findFirst(
            in: appElement, configuration: configuration
        ) { element in
            guard Self.role(of: element) == "AXButton" else { return false }
            let text = ((Self.stringAttribute(element, kAXDescriptionAttribute)
                ?? Self.stringAttribute(element, kAXTitleAttribute)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !text.isEmpty else { return false }
            guard !sso.contains(where: { text.contains($0) }) else { return false }
            return wanted.contains { text.contains($0) }
        }
    }

    // MARK: - 键盘

    /// 逐字符把文本作为键盘事件发给目标进程 (与真人打字等价)。
    static func typeText(_ text: String, to pid: pid_t, interval: Duration = .milliseconds(20)) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for scalar in text.unicodeScalars {
            var chars = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            chars.withUnsafeMutableBufferPointer { buffer in
                down?.keyboardSetUnicodeString(
                    stringLength: buffer.count, unicodeString: buffer.baseAddress
                )
            }
            down?.postToPid(pid)

            try? await Task.sleep(for: interval)

            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            chars.withUnsafeMutableBufferPointer { buffer in
                up?.keyboardSetUnicodeString(
                    stringLength: buffer.count, unicodeString: buffer.baseAddress
                )
            }
            up?.postToPid(pid)
            try? await Task.sleep(for: interval)
        }
    }

    /// 清空一个文本框: 先 AX 置空, 再 Cmd+A + Backspace 双保险。
    static func clearField(_ element: AXUIElement, pid: pid_t) async {
        let empty = "" as CFString
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, empty)
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, empty)

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Cmd+A
        let aDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        aDown?.flags = .maskCommand
        aDown?.postToPid(pid)
        let aUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        aUp?.flags = .maskCommand
        aUp?.postToPid(pid)
        try? await Task.sleep(for: .milliseconds(60))
        // Backspace
        let bsDown = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
        bsDown?.postToPid(pid)
        let bsUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
        bsUp?.postToPid(pid)
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - AX 基础

    private func requireTrustedChrome() throws -> NSRunningApplication {
        guard AXIsProcessTrusted() else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }
        guard let chrome = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated
        }) else {
            throw ChatGPTAccountError.chromeNotFound
        }
        return chrome
    }

    private func appAXElement(of app: NSRunningApplication) -> AXUIElement? {
        AXIsProcessTrusted() ? AXUIElementCreateApplication(app.processIdentifier) : nil
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func focusField(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        press(element) // 点击等价, 双保险
    }

    static func role(of element: AXUIElement) -> String {
        stringAttribute(element, kAXRoleAttribute) ?? ""
    }

    static func value(of element: AXUIElement) -> String? {
        guard let raw = rawAttribute(element, kAXValueAttribute) else { return nil }
        if let s = raw as? String { return s }
        if let a = raw as? NSAttributedString { return a.string }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        guard let raw = rawAttribute(element, name) else { return nil }
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return s
    }

    static func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        return status == .success ? raw : nil
    }
}

// MARK: - 测试替身

/// 可编程的登出/登录替身 —— 记录调用序列与使用的凭据。
public final class FakeCodexLoginAutomator: CodexLoginAutomating, @unchecked Sendable {

    private let lock = NSLock()
    private var _logoutCalls = 0
    private var _logins: [(email: String, password: String)] = []
    private var _nextLoginError: CodexLoginError?

    public init() {}

    public func logout(currentAccountEmail: String? = nil) async throws {
        recordLogout()
    }

    public func login(email: String, password: String) async throws {
        try throwIfLoginScheduled()
        recordLogin(email: email, password: password)
    }


    // ---- 同步私有方法 (Swift 6: NSLock 不得出现在 async 函数体) ----
    private func recordLogout() {
        lock.lock(); defer { lock.unlock() }
        _logoutCalls += 1
    }

    private func recordLogin(email: String, password: String) {
        lock.lock(); defer { lock.unlock() }
        _logins.append((email: email, password: password))
    }


    private func throwIfLoginScheduled() throws {
        lock.lock(); defer { lock.unlock() }
        if let error = _nextLoginError {
            _nextLoginError = nil
            throw error
        }
    }

    // 可编程接口
    public func failNextLogin(with error: CodexLoginError) {
        lock.lock(); defer { lock.unlock() }
        _nextLoginError = error
    }

    public var logoutCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _logoutCalls
    }

    public var logins: [(email: String, password: String)] {
        lock.lock(); defer { lock.unlock() }
        return _logins
    }

}

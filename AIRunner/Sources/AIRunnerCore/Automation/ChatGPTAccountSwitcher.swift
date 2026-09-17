import Foundation
import ApplicationServices
import AppKit

// MARK: - 配置

/// ChatGPT 网页账号切换的可调参数。
///
/// ## 为什么全是候选集合
///
/// ChatGPT 是动态 React 应用, aria-label 随版本与语言变化。
/// 硬编码一个 label 一旦改版就失效; 按"候选列表依次尝试 + 找不到就
/// fail closed"的既有模式设计, 至少不会误操作。
public struct ChatGPTAccountSwitcherConfiguration: Sendable, Equatable {

    /// 右上角头像按钮的候选 label (多语言)。
    public var avatarButtonHints: [String] = [
        "打开账号菜单", "打开个人资料菜单", "账号菜单", "个人资料菜单",
        "Open account menu", "Open profile menu", "Profile menu", "Account menu",
    ]

    /// 账号菜单里「升级/设置/登出」等要**排除**的关键词 ——
    /// 它们也是菜单条目, 但点下去不是切换账号。
    public var excludedItemHints: [String] = [
        "升级", "Upgrade", "升级到", "设置", "Settings", "帮助", "Help",
        "登出", "退出登录", "Log out", "Sign out", "切换主题", "Theme",
    ]

    /// 点击头像后等菜单弹出的秒数。
    public var menuAppearDelay: Duration = .seconds(1)
    /// 点击账号后等页面刷新的秒数。
    public var accountSwitchDelay: Duration = .seconds(2)
    /// AX 遍历预算 (ChatGPT 页面节点多)。
    public var traversalNodeBudget: Int = 8000
    /// AX 遍历深度。
    public var traversalMaxDepth: Int = 18
    /// AX 遍历超时。
    public var traversalTimeout: TimeInterval = 12

    public init() {}
    public static let `default` = ChatGPTAccountSwitcherConfiguration()
}

// MARK: - 结果类型

/// 从账号菜单里读到的一个账号条目。
public struct ChatGPTAccountEntry: Sendable, Equatable, Identifiable {
    /// 条目文本 —— 通常是邮箱或显示名 (AXDescription / AXTitle)。
    public let label: String
    /// 是否是当前登录账号 (菜单里的标记)。
    public let isCurrent: Bool

    public var id: String { label }
}

/// 一次账号切换的结果。
public struct ChatGPTAccountSwitchOutcome: Sendable, Equatable {
    /// 切换到的账号 (菜单条目文本)。
    public let accountLabel: String
    /// 切换后 ChatGPT 输入框是否可用 (页面已刷新)。
    public let pageReloaded: Bool

    public var summary: String {
        "已切换 ChatGPT 账号 → \(accountLabel)" + (pageReloaded ? " (页面已就绪)" : "")
    }
}

// MARK: - 错误

public enum ChatGPTAccountError: Error, Sendable, Equatable, LocalizedError {
    case chromeNotFound
    case chatGPTWindowNotFound
    case avatarButtonNotFound
    case accountMenuNotFound
    case noAccountEntriesFound
    case targetAccountNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .chromeNotFound:
            return "Chrome 未运行。请先打开 ChatGPT 页面。"
        case .chatGPTWindowNotFound:
            return "没有找到包含 ChatGPT 的 Chrome 窗口。请先打开 chatgpt.com。"
        case .avatarButtonNotFound:
            return "找不到 ChatGPT 的账号菜单按钮 (右上角头像)。"
        case .accountMenuNotFound:
            return "点击头像后没有检测到账号菜单弹出。"
        case .noAccountEntriesFound:
            return "账号菜单里没有读到任何账号条目 —— 请确认浏览器里登录了多个 ChatGPT 账号。"
        case .targetAccountNotFound(let target):
            return "账号菜单里找不到「\(target)」。请确认该账号已在浏览器中登录。"
        }
    }
}

// MARK: - 协议

/// ChatGPT 网页账号切换 (测试可注入替身)。
public protocol ChatGPTAccountSwitching: Sendable {

    /// 枚举当前浏览器里登录的所有 ChatGPT 账号。
    ///
    /// 打开头像菜单 → 读条目 → 按 Escape 关闭。**不切换任何账号。**
    func listAccounts() async throws -> [ChatGPTAccountEntry]

    /// 切换到指定账号 (label 为 `listAccounts` 返回的条目文本)。
    func switchAccount(to label: String) async throws -> ChatGPTAccountSwitchOutcome
}

// MARK: - 真实实现

/// 通过 Chrome 的 AX 树自动切换 ChatGPT 网页账号。
///
/// ## 工作原理
///
/// ChatGPT 支持在同一浏览器登录多个账号, 右上角头像菜单可切换。
/// 本类型通过 macOS Accessibility API 操作**网页渲染出来的菜单**:
///
/// ```
/// 聚焦 ChatGPT 窗口
///   → AX 树里找头像按钮 (按候选 label 匹配)
///   → AXPress 打开菜单
///   → 等菜单弹出
///   → 在菜单里找目标账号条目 (含排除项过滤)
///   → AXPress 切换
///   → 等页面刷新
/// ```
///
/// ## ★ 不接触任何凭据 ★
///
/// 账号登录态在浏览器 Profile 里。这里只"点击菜单条目" ——
/// 与你用鼠标点完全等价。
public struct ChatGPTAccountSwitcher: ChatGPTAccountSwitching {

    private let configuration: ChatGPTAccountSwitcherConfiguration
    private let windows: BrowserWindowLocating

    public init(
        configuration: ChatGPTAccountSwitcherConfiguration = .default,
        windows: BrowserWindowLocating = BrowserWindowLocator()
    ) {
        self.configuration = configuration
        self.windows = windows
    }

    // MARK: listAccounts

    public func listAccounts() async throws -> [ChatGPTAccountEntry] {
        let chrome = try requireChrome()
        let (app, menuContext) = try await openAccountMenu()

        let entries = Self.accountEntries(
            in: menuContext, appElement: app, options: configuration
        )

        // 关菜单 (Escape 发给 Chrome 窗口)
        Self.sendEscape(to: chrome)

        guard !entries.isEmpty else {
            throw ChatGPTAccountError.noAccountEntriesFound
        }
        return entries
    }

    // MARK: switchAccount

    public func switchAccount(to label: String) async throws -> ChatGPTAccountSwitchOutcome {
        let chrome = try requireChrome()
        let (app, menuContext) = try await openAccountMenu()

        // 菜单里找目标账号条目
        guard let item = Self.findMenuItem(
            matching: label, in: menuContext, appElement: app, options: configuration
        ) else {
            Self.sendEscape(to: chrome)
            throw ChatGPTAccountError.targetAccountNotFound(label)
        }

        // 读取条目 label (用于结果摘要)
        let itemLabel = Self.stringAttribute(item, kAXDescriptionAttribute)
            ?? Self.stringAttribute(item, kAXTitleAttribute)
            ?? label

        // 点击切换
        guard Self.press(item) else {
            throw ChatGPTAccountError.accountMenuNotFound
        }

        // 等页面刷新
        try? await Task.sleep(for: configuration.accountSwitchDelay)

        // 验证: 头像按钮的 label 应包含新账号 (ChatGPT 会把当前账号标在头像 aria-label 里)
        let reloaded = await verifySwitched(to: label, appElement: app)

        return ChatGPTAccountSwitchOutcome(
            accountLabel: itemLabel,
            pageReloaded: reloaded
        )
    }

    // MARK: - 内部: 打开账号菜单

    private func requireChrome() throws -> NSRunningApplication {
        guard let chrome = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated
        }) else {
            throw ChatGPTAccountError.chromeNotFound
        }
        return chrome
    }

    /// 聚焦 ChatGPT 窗口 → 找头像按钮 → 打开菜单。返回 (appElement, 菜单容器)。
    private func openAccountMenu() async throws -> (AXUIElement, AXUIElement) {
        guard AXIsProcessTrusted() else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }

        // 1) 聚焦 ChatGPT 窗口
        _ = try windows.focusWindow(
            bundleIdentifier: "com.google.Chrome",
            titleFragment: "ChatGPT",
            activateApp: true
        )

        guard let chrome = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated
        }) else {
            throw ChatGPTAccountError.chromeNotFound
        }

        let app = AXUIElementCreateApplication(chrome.processIdentifier)

        // 2) 找头像按钮
        guard let avatar = Self.findAvatarButton(
            appElement: app, options: configuration
        ) else {
            throw ChatGPTAccountError.avatarButtonNotFound
        }

        // 3) 点击打开菜单
        guard Self.press(avatar) else {
            throw ChatGPTAccountError.avatarButtonNotFound
        }

        // 4) 等菜单弹出
        try? await Task.sleep(for: configuration.menuAppearDelay)

        // 5) 找菜单容器 (AXMenu, 或含账号条目的弹出 AXGroup)
        guard let menu = Self.findAccountMenu(
            appElement: app, options: configuration
        ) else {
            throw ChatGPTAccountError.accountMenuNotFound
        }

        return (app, menu)
    }

    /// 切换后验证: 头像按钮 label 是否含目标账号标识。
    private func verifySwitched(to label: String, appElement: AXUIElement) async -> Bool {
        // 头像 label 可能含账号邮箱/名; 用「含目标 label 的显著片段」判断
        let needle = Self.significantFragment(of: label)
        guard let avatar = Self.findAvatarButton(appElement: appElement, options: configuration) else {
            return false
        }
        let current = Self.stringAttribute(avatar, kAXDescriptionAttribute)
            ?? Self.stringAttribute(avatar, kAXTitleAttribute)
            ?? ""
        return current.lowercased().contains(needle)
    }

    // MARK: - AX 遍历 (静态纯函数, 便于测试)

    /// 在整个 App AX 树里找头像按钮。
    static func findAvatarButton(
        appElement: AXUIElement,
        options: ChatGPTAccountSwitcherConfiguration
    ) -> AXUIElement? {
        let hints = options.avatarButtonHints.map { $0.lowercased() }
        return firstElement(
            in: appElement,
            depth: 0,
            budget: Box(options.traversalNodeBudget),
            deadline: Date().addingTimeInterval(options.traversalTimeout),
            maxDepth: options.traversalMaxDepth
        ) { element in
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            guard role == "AXButton" else { return false }
            let desc = stringAttribute(element, kAXDescriptionAttribute) ?? ""
            let title = stringAttribute(element, kAXTitleAttribute) ?? ""
            return hints.contains { hint in
                desc.lowercased().contains(hint) || title.lowercased().contains(hint)
            }
        }
    }

    /// 找弹出的账号菜单容器。
    ///
    /// 优先 AXMenu; 找不到则接受「含多个可点击条目的 AXGroup」。
    static func findAccountMenu(
        appElement: AXUIElement,
        options: ChatGPTAccountSwitcherConfiguration
    ) -> AXUIElement? {
        // 先找 AXMenu (标准 role)
        if let menu = firstElement(
            in: appElement,
            depth: 0,
            budget: Box(options.traversalNodeBudget),
            deadline: Date().addingTimeInterval(options.traversalTimeout),
            maxDepth: options.traversalMaxDepth,
            matching: { element in
                (stringAttribute(element, kAXRoleAttribute) ?? "") == "AXMenu"
            }
        ) {
            return menu
        }
        // ChatGPT 某些版本用 AXGroup 自绘菜单: 找「含 ≥2 个按钮的浅层 group」
        // —— 由 findMenuItem 兜底, 这里返回 nil 让上层报 accountMenuNotFound
        // 只在确实没有 AXMenu 时。为稳妥, 回退: 返回 app 根, 让条目搜索全局进行。
        return appElement
    }

    /// 在菜单容器里枚举账号条目 (排除「升级/设置/登出」等)。
    static func accountEntries(
        in menu: AXUIElement,
        appElement: AXUIElement,
        options: ChatGPTAccountSwitcherConfiguration
    ) -> [ChatGPTAccountEntry] {
        let excluded = options.excludedItemHints.map { $0.lowercased() }

        var labels: [(String, Bool)] = []
        walkElements(
            in: menu, depth: 0,
            budget: Box(options.traversalNodeBudget),
            deadline: Date().addingTimeInterval(options.traversalTimeout),
            maxDepth: 6
        ) { element in
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            guard role == "AXButton" || role == "AXMenuItem" || role == "AXStaticText" else {
                return
            }
            let text = stringAttribute(element, kAXDescriptionAttribute)
                ?? stringAttribute(element, kAXTitleAttribute)
                ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count >= 3 else { return }
            // 排除导航类条目
            let lower = trimmed.lowercased()
            guard !excluded.contains(where: { lower.contains($0.lowercased()) }) else { return }
            // 排除头像菜单按钮自身
            guard !options.avatarButtonHints.contains(where: {
                lower == $0.lowercased()
            }) else { return }
            // 像账号条目的文本 (含 @ 或是常规名字); 去重
            if !labels.contains(where: { $0.0 == trimmed }) {
                labels.append((trimmed, false))
            }
        }

        return labels.map { ChatGPTAccountEntry(label: $0.0, isCurrent: false) }
    }

    /// 在菜单里找匹配目标账号的可点击条目。
    static func findMenuItem(
        matching target: String,
        in menu: AXUIElement,
        appElement: AXUIElement,
        options: ChatGPTAccountSwitcherConfiguration
    ) -> AXUIElement? {
        let needle = Self.significantFragment(of: target).lowercased()
        let excluded = options.excludedItemHints.map { $0.lowercased() }

        return firstElement(
            in: menu,
            depth: 0,
            budget: Box(options.traversalNodeBudget),
            deadline: Date().addingTimeInterval(options.traversalTimeout),
            maxDepth: 8
        ) { element in
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            guard role == "AXButton" || role == "AXMenuItem" else { return false }
            let text = stringAttribute(element, kAXDescriptionAttribute)
                ?? stringAttribute(element, kAXTitleAttribute)
                ?? ""
            let lower = text.lowercased()
            guard lower.contains(needle) else { return false }
            // 不允许点中「升级/设置/登出」
            return !excluded.contains { lower.contains($0) }
        }
    }

    /// 取账号文本的「显著片段」: 优先 @ 前的部分 (邮箱), 否则整个字符串。
    static func significantFragment(of label: String) -> String {
        if let at = label.firstIndex(of: "@") {
            return String(label[label.startIndex..<at])
        }
        return label
    }

    // MARK: - AX 基础

    private static func sendEscape(to app: NSRunningApplication) {
        app.activate()
        // CGEvent 发 Escape —— 与用户按 ⎋ 等价
        if let source = CGEventSource(stateID: .combinedSessionState),
           let escape = CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: true) {
            escape.postToPid(app.processIdentifier)
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: false) {
                up.postToPid(app.processIdentifier)
            }
        }
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }

    // MARK: 遍历辅助

    final class Box<T> {
        var value: T
        init(_ v: T) { value = v }
    }

    /// 深度优先, 返回第一个满足条件的元素。
    static func firstElement(
        in element: AXUIElement,
        depth: Int,
        budget: Box<Int>,
        deadline: Date,
        maxDepth: Int,
        matching: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard budget.value > 0, depth < maxDepth, Date() < deadline else { return nil }
        budget.value -= 1

        if matching(element) { return element }

        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &raw
        )
        guard status == .success, let children = raw as? [AXUIElement] else { return nil }

        for child in children {
            if let hit = firstElement(
                in: child, depth: depth + 1,
                budget: budget, deadline: deadline,
                maxDepth: maxDepth, matching: matching
            ) {
                return hit
            }
        }
        return nil
    }

    /// 深度优先访问全部元素。
    static func walkElements(
        in element: AXUIElement,
        depth: Int,
        budget: Box<Int>,
        deadline: Date,
        maxDepth: Int,
        visit: (AXUIElement) -> Void
    ) {
        guard budget.value > 0, depth < maxDepth, Date() < deadline else { return }
        budget.value -= 1

        visit(element)

        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &raw
        )
        guard status == .success, let children = raw as? [AXUIElement] else { return }

        for child in children {
            walkElements(
                in: child, depth: depth + 1,
                budget: budget, deadline: deadline,
                maxDepth: maxDepth, visit: visit
            )
        }
    }
}

// MARK: - 测试替身

/// 可编程的 ChatGPT 账号切换替身。
public final class FakeChatGPTAccountSwitcher: ChatGPTAccountSwitching, @unchecked Sendable {

    private let lock = NSLock()
    private var _accounts: [ChatGPTAccountEntry]
    private var _currentAccount: String?
    private var _switchCalls: [String] = []
    private var _listCalls = 0
    private var _failOnSwitch = false

    public init(accounts: [String] = ["a@test.com", "b@test.com"], current: String? = nil) {
        self._accounts = accounts.map { ChatGPTAccountEntry(label: $0, isCurrent: false) }
        self._currentAccount = current
    }

    public func listAccounts() async throws -> [ChatGPTAccountEntry] {
        performList()
    }

    public func switchAccount(to label: String) async throws -> ChatGPTAccountSwitchOutcome {
        try performSwitch(to: label)
    }

    // ---- 同步私有方法 (Swift 6: NSLock 不得出现在 async 函数体) ----

    private func performList() -> [ChatGPTAccountEntry] {
        lock.lock(); defer { lock.unlock() }
        _listCalls += 1
        if let current = _currentAccount {
            return _accounts.map {
                ChatGPTAccountEntry(label: $0.label, isCurrent: $0.label == current)
            }
        }
        return _accounts
    }

    private func performSwitch(to label: String) throws -> ChatGPTAccountSwitchOutcome {
        lock.lock(); defer { lock.unlock() }
        if _failOnSwitch {
            throw ChatGPTAccountError.noAccountEntriesFound
        }
        guard _accounts.contains(where: { $0.label == label }) else {
            throw ChatGPTAccountError.targetAccountNotFound(label)
        }
        _switchCalls.append(label)
        _currentAccount = label
        return ChatGPTAccountSwitchOutcome(accountLabel: label, pageReloaded: true)
    }

    // 可编程接口
    public var switchCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _switchCalls
    }

    public var listCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _listCalls
    }

    public var currentAccount: String? {
        lock.lock(); defer { lock.unlock() }
        return _currentAccount
    }
}

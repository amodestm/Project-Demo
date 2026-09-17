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
        let selected: Bool

        init(
            role: String = kAXButtonRole,
            text: String,
            enabled: Bool = true,
            selected: Bool = false
        ) {
            self.role = role
            self.text = text
            self.enabled = enabled
            self.selected = selected
        }
    }

    enum IntendedAction: Sendable, Equatable {
        case wait
        case chooseAccount(Int)
        case chooseWorkspaceAccount(Int)
        case continueWorkspace(Int)
        case continueConsent(Int)
        case ambiguousAccounts
        case profileNotLoggedIn
        case securityChallenge
        case authorizationRejected
    }

    /// 激活一个网页控件的方法。真实点击 = 与用户手动操作等价的 CGEvent
    /// 鼠标点击；AXPress = Chromium 的无障碍按下动作。
    enum ActivationMethod: String, Sendable, Equatable {
        case centerClick
        case press
    }

    /// 页面动作的执行顺序。
    ///
    /// Chromium 网页对 AXPress 可能返回 success 却不把事件交给页面
    /// （工作空间“继续”按钮已证实，账户卡片同样复现）。因此统一采用
    /// 「真实点击优先、AXPress 兜底」：仅在拿不到元素边框时退回 AXPress。
    /// 每次动作只会实际触发一次；页面未推进时的纠错重试由
    /// `shouldPressAgain` 的延时窗口控制，不会连续触发。
    static func activationMethods(for action: IntendedAction) -> [ActivationMethod] {
        switch action {
        case .chooseAccount, .chooseWorkspaceAccount,
                .continueWorkspace, .continueConsent:
            return [.centerClick, .press]
        default:
            return []
        }
    }

    /// 一次授权页动作的重试账本，键为 `URL#动作类型`。
    ///
    /// 首次扫描时页面可能还没渲染出账号卡片，按下的元素未必是目标。保留时间戳
    /// 是为了在「页面迟迟没有推进」时允许一次纠错重试；总次数上限两次，避免
    /// 反复选择同一张账号卡片而触发 invalid_auth_step。
    struct ActionAttempt: Sendable, Equatable {
        var count: Int
        var lastAt: Date
    }

    /// 页面在按下后多久仍未推进，才允许一次纠错重试。
    static let actionRetryDelay: TimeInterval = 25
    /// 同一个页面动作最多按下两次（首次 + 一次纠错）。
    static let maxActionAttempts = 2
    /// 登录页需要连续扫描确认的次数。
    static let loginPageConfirmations = 5

    private var actionAttempts: [String: ActionAttempt] = [:]
    private var choseWorkspaceAccount = false
    private var loginPageStreak = 0

    // 诊断追踪的去重标记：只在页面状态真正变化时写一行，避免刷屏。
    private var traceWindowMemo: String?
    private var tracePageMemo: String?
    private var traceRootsMemo: String?

    public init() {}

    public func reset() {
        actionAttempts.removeAll()
        choseWorkspaceAccount = false
        loginPageStreak = 0
        traceWindowMemo = nil
        tracePageMemo = nil
        traceRootsMemo = nil
    }

    // MARK: - 诊断追踪

    /// 追踪文件：记录授权页面扫描、动作选择与激活方式，供线上问题定位。
    /// 上限 512 KB，超出后重新开始；只在显著状态变化时追加，不刷屏。
    static let traceFileMaxBytes = 512 * 1024

    static var traceFileURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base
            .appendingPathComponent("AIRunner", isDirectory: true)
            .appendingPathComponent("oauth-chooser-trace.log")
    }

    private func appendTrace(_ text: String) {
        guard let url = Self.traceFileURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let attributes = try? fm.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int,
           size > Self.traceFileMaxBytes {
            try? data.write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 焦点窗口不是官方授权页时记一行（含窗口数与文档地址），用去重键防刷屏。
    private func traceFocusedWindow(_ windows: [AXUIElement]) {
        let document = windows.first.flatMap {
            CodexLoginAutomator.stringAttribute($0, kAXDocumentAttribute)
        }
        let key = "win:\(windows.count):\(document ?? "nil")"
        guard key != traceWindowMemo else { return }
        traceWindowMemo = key
        let host = document.flatMap { URL(string: $0)?.host }
        guard !Self.isOfficialOAuthHost(host) else { return }
        appendTrace("window-scan windows=\(windows.count) focused=\(document ?? "nil") — 焦点窗口非官方授权页，本轮跳过")
    }

    private func traceRootsMissing(
        url: URL,
        windows: [AXUIElement],
        enableInfo: String
    ) {
        var lines: [String] = []
        for (index, window) in windows.enumerated() {
            let document = CodexLoginAutomator.stringAttribute(
                window, kAXDocumentAttribute
            ) ?? "nil"
            let hasWeb = Self.containsWebArea(in: window)
            let shape = Self.roleShape(of: window, maxDepth: 3, budget: 400)
            lines.append(
                "  win[\(index)] webArea=\(hasWeb) roles={\(shape)} doc=\(document.prefix(46))"
            )
        }
        let detail = lines.joined(separator: "\n")
        let key = "roots:\(url.absoluteString):\(detail):\(enableInfo)"
        guard key != traceRootsMemo else { return }
        traceRootsMemo = key
        appendTrace("web-roots-empty url=\(url.absoluteString) enable(\(enableInfo))\n\(detail)")
    }

    /// 子树里是否存在 `AXWebArea`（网页内容根）。
    static func containsWebArea(in window: AXUIElement) -> Bool {
        var budget = 2_000
        var found = false
        func visit(_ element: AXUIElement, depth: Int) {
            guard !found, depth <= 14, budget > 0 else { return }
            budget -= 1
            if CodexLoginAutomator.role(of: element) == "AXWebArea" {
                found = true
                return
            }
            for child in elements(in: element, attribute: kAXChildrenAttribute) {
                visit(child, depth: depth + 1)
                if found || budget <= 0 { break }
            }
        }
        visit(window, depth: 0)
        return found
    }

    /// 浅层「角色×数量」概要，用来判断 Chromium 是否只暴露了原生窗框。
    static func roleShape(of window: AXUIElement, maxDepth: Int, budget budget0: Int) -> String {
        var counts: [String: Int] = [:]
        var budget = budget0
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, budget > 0 else { return }
            for child in elements(in: element, attribute: kAXChildrenAttribute) {
                guard budget > 0 else { return }
                budget -= 1
                counts[CodexLoginAutomator.role(of: child), default: 0] += 1
                visit(child, depth: depth + 1)
            }
        }
        visit(window, depth: 0)
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    /// 关键页面（choose-account / workspace / consent）的扫描快照：
    /// URL、判定动作、已发次数、可操作控件清单（角色/启用/边框/文本）。
    private func tracePage(
        url: URL,
        action: IntendedAction,
        controls: [Control],
        elements: [AXUIElement],
        kind: String?,
        attempts: Int
    ) {
        let lowered = url.absoluteString.lowercased()
        let interesting = kind != nil
            || lowered.contains("choose-an-account") || lowered.contains("choose-account")
            || lowered.contains("workspace") || lowered.contains("consent")
            || lowered.contains("authorize")
        guard interesting else { return }

        var lines: [String] = []
        for (index, control) in controls.enumerated() where lines.count < 12 {
            let text = control.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let isPressable = control.role == kAXButtonRole || control.role == "AXLink"
            guard isPressable || control.role == "AXGroup" || text.contains("@") else { continue }
            var line = "  [\(index)] \(control.role) enabled=\(control.enabled)"
            if let frame = CodexLoginAutomator.frame(of: elements[index]) {
                line += String(
                    format: " frame=%.0f,%.0f %.0fx%.0f",
                    frame.minX, frame.minY, frame.width, frame.height
                )
            }
            let shown = text.count > 100 ? String(text.prefix(100)) + "…" : text
            line += " text=\(shown)"
            lines.append(line)
        }

        let fingerprint = "\(controls.count)|\(lines.joined(separator: "\n").prefix(400))"
        let key = "page:\(url.absoluteString)#\(action)#\(attempts)#\(fingerprint)"
        guard key != tracePageMemo else { return }
        tracePageMemo = key
        var header = "page url=\(url.absoluteString) action=\(action) attempts=\(attempts) controls=\(controls.count)"
        if let kind { header += " kind=\(kind)" }
        appendTrace(header + (lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")))
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
        traceFocusedWindow(windows)

        // 一次 OAuth 只允许驱动当前真正获得焦点的官方授权窗口；如果它正在
        // 加载，直接等待，不能继续扫描其他 Profile 遗留的旧授权页。
        // 只接受 Chrome 当前窗口。继续扫描其他窗口会在目标 Profile 尚在加载时
        // 接管另一个 Profile 遗留的授权页，造成看似“没有切换 Profile”。
        guard let window = windows.first,
              let document = CodexLoginAutomator.stringAttribute(
                  window, kAXDocumentAttribute
              ), let url = URL(string: document), url.scheme == "https",
              Self.isOfficialOAuthHost(url.host) else {
            return false
        }

        // ★ 只在网页内容子树里找控件。★
        //
        // Chrome 窗口的 AX 树同时包含浏览器自己的工具栏，而 Chrome 的个人资料
        // 按钮文案就是 profile 名 —— 本项目里 profile 名就是账号邮箱
        // （例如 critic@example.com）。若从窗口根节点开始扫描，这个浏览器
        // 按钮会被当成「账号候选」按下，弹出 Chrome 个人资料菜单，整轮授权就此
        // 卡死，且永远不会推进。把扫描根限定为 AXWebArea 后，浏览器工具栏不再
        // 进入候选集，账号卡片仍可被正常识别。
        //
        // Chromium 惰性构建网页树：官方文档要求无障碍客户端把
        // AXEnhancedUserInterface 设在**主窗口**上（只设应用元素无效）。
        // 树是异步构建的，且主要在窗口获得焦点/成为主窗口时触发，因此这里
        // 先开关，空树时聚焦窗口并轮询等待构建完成。
        let enableInfo = Self.enableWebAccessibility(app: root, windows: windows)
        var scanRoots = Self.webContentRoots(in: window)
        if scanRoots.isEmpty {
            Self.focus(window, application: chrome)
            try? await Task.sleep(for: .milliseconds(300))
            _ = Self.enableWebAccessibility(app: root, windows: windows)
            for _ in 0..<8 where scanRoots.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                scanRoots = Self.webContentRoots(in: window)
            }
        }
        guard !scanRoots.isEmpty else {
            traceRootsMissing(url: url, windows: windows, enableInfo: enableInfo)
            return false
        }
        var elements: [AXUIElement] = []
        for root in scanRoots {
            // 账号卡片在网页子树里通常位于第 8–16 层；深度 26 覆盖当前页面结构，
            // 节点预算继续防止无界扫描。
            elements.append(contentsOf: Self.descendants(
                of: root, maxDepth: 26, maxNodes: 4_000
            ))
        }
        let controls = elements.map {
            Control(
                role: CodexLoginAutomator.role(of: $0),
                text: CodexLoginAutomator.matchingText(of: $0),
                enabled: Self.boolAttribute($0, kAXEnabledAttribute) ?? true,
                selected: Self.boolAttribute($0, kAXSelectedAttribute) == true
                    || Self.boolAttribute($0, "AXChecked") == true
            )
        }
        let pageText = controls.map(\.text).joined(separator: " ")

        // 按下账号后，OpenAI 会在 URL 尚未变化时先移除账号卡片；
        // 按下“继续”后也会先把按钮禁用。这两种都是正常跳转中状态，
        // 已执行的动作必须先于页面分类被识别，避免误报“未登录”。
        var action = Self.intendedAction(url: url, controls: controls, pageText: pageText)
        if case .chooseWorkspaceAccount = action, choseWorkspaceAccount,
           let index = Self.uniqueWorkspaceContinueIndex(in: controls) {
            action = .continueWorkspace(index)
        }
        // OpenAI 会先落到 /log-in 再重定向到 /choose-an-account。单次扫描命中
        // 登录表单就判定「Profile 未登录」，会把正常重定向误报成会话失效并立刻
        // 终止整轮授权。这里要求连续多次扫描都成立才下结论。
        if case .profileNotLoggedIn = action {
            loginPageStreak += 1
            if loginPageStreak < Self.loginPageConfirmations { return false }
        } else {
            loginPageStreak = 0
        }

        let currentActionKind: String? = switch action {
        case .chooseAccount: "choose-account"
        case .chooseWorkspaceAccount: "choose-workspace-account"
        case .continueWorkspace: "continue-workspace"
        case .continueConsent: "continue-consent"
        default: nil
        }
        let attemptCount = currentActionKind.map {
            actionAttempts["\(url.absoluteString)#\($0)"]?.count ?? 0
        } ?? 0
        tracePage(
            url: url, action: action, controls: controls, elements: elements,
            kind: currentActionKind, attempts: attemptCount
        )
        if let currentActionKind,
           !Self.shouldPressAgain(
               attempt: actionAttempts["\(url.absoluteString)#\(currentActionKind)"]
           ) {
            return false
        }

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
        case .chooseAccount(let index), .chooseWorkspaceAccount(let index),
                .continueWorkspace(let index), .continueConsent(let index):
            guard elements.indices.contains(index) else { return false }
            let actionKind: String
            switch action {
            case .chooseAccount: actionKind = "choose-account"
            case .chooseWorkspaceAccount: actionKind = "choose-workspace-account"
            case .continueWorkspace: actionKind = "continue-workspace"
            case .continueConsent: actionKind = "continue-consent"
            default: return false
            }
            let actionKey = "\(url.absoluteString)#\(actionKind)"
            _ = chrome.activate(options: [.activateAllWindows])
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            // 窗口置前与坐标点击之间存在异步竞态：CGEvent 按“投递时刻”的
            // 最前台窗口分发，Chromium 尚未完成置前时点击可能落空。用户手动
            // 点击总能成功，先等窗口层级稳定，再执行点击。
            try? await Task.sleep(for: .milliseconds(600))
            let element = elements[index]
            // 真实点击优先、AXPress 兜底；每次动作只实际触发一次。
            let didActivate: Bool
            let activationMethod: String?
            var activated = false
            var usedMethod: String?
            for method in Self.activationMethods(for: action) {
                let succeeded: Bool
                switch method {
                case .centerClick:
                    succeeded = CodexLoginAutomator.clickCenter(element)
                case .press:
                    succeeded = CodexLoginAutomator.press(element)
                }
                if succeeded {
                    activated = true
                    usedMethod = method.rawValue
                    break
                }
            }
            didActivate = activated
            activationMethod = usedMethod
            guard didActivate else {
                throw CodexOAuthBrowserAutomationError.controlPressFailed
            }
            actionAttempts[actionKey] = ActionAttempt(
                count: (actionAttempts[actionKey]?.count ?? 0) + 1,
                lastAt: Date()
            )
            appendTrace(
                "activation kind=\(actionKind) attempt=\(attemptCount + 1) method=\(activationMethod ?? "none")"
            )
            if case .chooseWorkspaceAccount = action {
                choseWorkspaceAccount = true
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

        let accountChooserPage = path.contains("choose-an-account")
            || path.contains("choose-account")
            || normalizedPage.contains("选择一个账户以继续前往 codex")
            || normalizedPage.contains("选择一个账号以继续前往 codex")
            || normalizedPage.contains("choose an account to continue to codex")
        if accountChooserPage {
            let candidates = controls.indices.filter { index in
                let control = controls[index]
                guard control.enabled,
                      control.role == kAXButtonRole || control.role == "AXLink" else {
                    return false
                }
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

            // 新版页面的账户卡片只显示姓名和邮箱，例如“Zpsksk\n邮箱”，
            // 不再附带“选择账户”前缀。邮箱是该页面唯一稳定的账户标识；
            // 排除删除、登录其他账户、创建账户等操作后仍必须唯一。
            let emailCandidates = controls.indices.filter { index in
                let control = controls[index]
                guard control.enabled,
                      control.role == kAXButtonRole || control.role == "AXLink" else {
                    return false
                }
                let text = normalize(control.text)
                let hasEmail = text.contains("@")
                    && text.split(whereSeparator: \Character.isWhitespace)
                        .contains { $0.contains("@") }
                let isSecondaryAction = text.contains("移除账户")
                    || text.contains("remove account")
                    || text.contains("登录至另一个账户")
                    || text.contains("登录到另一个账户")
                    || text.contains("sign in to another account")
                    || text.contains("log in to another account")
                    || text.contains("创建账户")
                    || text.contains("create account")
                return hasEmail && !isSecondaryAction
            }
            if emailCandidates.count == 1 { return .chooseAccount(emailCandidates[0]) }
            if emailCandidates.count > 1 { return .ambiguousAccounts }
            // 首次渲染和点击后跳转时，URL 已经到这里，账号卡片却可能
            // 短暂不在 AX 树。只有真正进入登录表单时才报“Profile 未登录”。
            return .wait
        }

        // “继续登录”之后的 ChatGPT 工作空间页可能位于 chatgpt.com，且 URL
        // 不包含 choose-an-account。先点击唯一的个人工作空间卡片（若页面
        // 暴露该卡片），下一次扫描再点击同页的“继续”；两个动作使用不同
        // 的去重键，避免第一步后永远卡在同一个 URL。
        let workspacePage = normalizedPage.contains("选择一个工作空间")
            || normalizedPage.contains("选择工作空间")
            || normalizedPage.contains("choose a workspace")
            || normalizedPage.contains("select a workspace")
            || normalizedPage.contains("个人账户")
            || normalizedPage.contains("个人帐户")
            || normalizedPage.contains("personal account")
        if workspacePage {
            let accounts = controls.indices.filter { index in
                let control = controls[index]
                guard control.enabled, control.role == kAXButtonRole else { return false }
                let text = normalize(control.text)
                return text.contains("个人账户") || text.contains("个人帐户")
                    || text.contains("personal account")
            }
            if accounts.count > 1 { return .ambiguousAccounts }
            if let account = accounts.first, !controls[account].selected {
                return .chooseWorkspaceAccount(account)
            }

            if let index = uniqueWorkspaceContinueIndex(in: controls) {
                return .continueWorkspace(index)
            }
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

    /// 是否允许按下这次动作。
    ///
    /// `nil` 表示该动作还没按过。已经按过一次时，只有在「页面没有推进」超过
    /// `actionRetryDelay` 之后才允许一次纠错重试；总次数受 `maxActionAttempts`
    /// 限制。这样既能从「第一下点空」中自愈，又不会反复选择同一张账号卡片。
    static func shouldPressAgain(attempt: ActionAttempt?, now: Date = Date()) -> Bool {
        guard let attempt else { return true }
        guard attempt.count < maxActionAttempts else { return false }
        return now.timeIntervalSince(attempt.lastAt) >= actionRetryDelay
    }

    /// 让 Chrome/Chromium 展开网页无障碍树。
    ///
    /// Chromium 官方行为（Mac）：只有当无障碍客户端把 `AXEnhancedUserInterface`
    /// 设在**主窗口**上时，浏览器才开启无障碍支持并构建网页内容子树；只把属性
    /// 设在应用元素（`AXUIElementCreateApplication`）上**无效**。Electron 系应用
    /// 另读应用元素上的 `AXManualAccessibility`。因此这里两个属性、两个层级都设。
    ///
    /// 未开启时窗口只暴露原生窗框（交通灯按钮 + 少量 AXGroup），`AXChildren`
    /// 下没有 `AXWebArea` → 扫描恒空、每轮静默返回 false，表现为“只有手动点击
    /// 窗口才推进”。返回值是各次设置的状态码，用于诊断。
    @discardableResult
    static func enableWebAccessibility(
        app: AXUIElement,
        windows: [AXUIElement]
    ) -> String {
        var parts: [String] = []
        let manual = AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        parts.append("manualApp=\(manual.rawValue)")
        let enhancedApp = AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )
        parts.append("enhApp=\(enhancedApp.rawValue)")
        for (index, window) in windows.enumerated() {
            let enhanced = AXUIElementSetAttributeValue(
                window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
            )
            parts.append("enhWin\(index)=\(enhanced.rawValue)")
        }
        return parts.joined(separator: ",")
    }

    /// 把目标窗口提升为 Chrome 的主窗口并置前，触发 Chromium 构建网页树。
    static func focus(_ window: AXUIElement, application: NSRunningApplication) {
        _ = application.activate(options: [.activateAllWindows])
        _ = AXUIElementSetAttributeValue(
            window, kAXMainAttribute as CFString, kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            window, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// 窗口里最外层的网页内容根节点（`AXWebArea`）。
    ///
    /// 命中后不再向下递归，避免把 iframe 的嵌套 WebArea 重复计入；返回空数组
    /// 表示网页尚未渲染完成，调用方应当继续等待而不是退回扫描整个窗口。
    static func webContentRoots(in window: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = []
        var budget = 2_000

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 12, budget > 0 else { return }
            budget -= 1
            if CodexLoginAutomator.role(of: element) == "AXWebArea" {
                roots.append(element)
                return
            }
            for child in elements(in: element, attribute: kAXChildrenAttribute) {
                visit(child, depth: depth + 1)
                if budget <= 0 { break }
            }
        }
        visit(window, depth: 0)
        return roots
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func isOfficialOAuthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "auth.openai.com" || host == "chatgpt.com"
            || host == "www.chatgpt.com"
    }

    private static func uniqueWorkspaceContinueIndex(
        in controls: [Control]
    ) -> Int? {
        let continues = controls.indices.filter { index in
            let control = controls[index]
            guard control.enabled, control.role == kAXButtonRole else { return false }
            let text = normalize(control.text)
            return text == "继续" || text == "continue"
        }
        return continues.count == 1 ? continues[0] : nil
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

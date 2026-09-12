import AppKit
import ApplicationServices
import Foundation

/// Codex 登出后，在原生登录界面按下“继续登录”或兼容版本的 ChatGPT 登录按钮。
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
        timeout: TimeInterval = 30
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
            try? await Task.sleep(for: .seconds(1))
        }
        let loginRoot = AXUIElementCreateApplication(codex.processIdentifier)
        guard Self.loginControls(in: loginRoot).count == 1 else {
            throw CodexBrowserOAuthError.codexLoginControlNotFound
        }

        // Chrome 会把外部链接交给最近激活的 Profile。先用本地准备页创建目标
        // Profile 的独立窗口，并在 AX 窗口树中确认这个标记确实属于刚才的窗口。
        // 不能只调用 activate()：那只能激活 Chrome，无法证明前台窗口是目标账号。
        guard let marker = await profiles.openTrackedProfileWindow(
            profile: profile, kind: .chrome, timeout: timeout
        ) else {
            throw CodexBrowserOAuthError.browserOpenFailed
        }
        // 目标 Profile 需要先创建窗口并成为 Chrome 的当前窗口；Codex 的外部
        // OAuth 链接随后才会被 Chrome 路由到这个 Profile。页面首次加载可能需要
        // 数秒，固定等待 10 秒后再回到 Codex；再次尝试提升带标记的窗口只是
        // 稳定性检查，标记因导航消失时不把已经确认的窗口误判为失败。
        try? await Task.sleep(for: .seconds(10))
        _ = await profiles.focusProfileWindow(marker: marker, kind: .chrome, timeout: 2)
        _ = codex.activate(options: [.activateAllWindows])
        // 应用切换完成前坐标点击可能落在 Chrome。等 Codex 真正回到前台后再读取
        // 实时 AXFrame，确保点击发生在用户看到的“继续登录”按钮上。
        try? await Task.sleep(for: .seconds(1))

        // 切换前台应用后重新读取控件，不能复用之前的 AX 句柄。
        var initialRoot = AXUIElementCreateApplication(codex.processIdentifier)
        var initialControls = Self.loginControls(in: initialRoot)
        if initialControls.count > 1 {
            throw CodexBrowserOAuthError.codexLoginControlAmbiguous
        }
        guard var initialControl = initialControls.first else {
            throw CodexBrowserOAuthError.codexLoginControlNotFound
        }

        // Codex 可能同时保留主界面和独立登录窗口。仅激活应用不能保证登录窗口
        // 位于 Chrome 前面；必须提升包含按钮的真实 AXWindow 并设为主窗口。
        guard Self.focusWindow(containing: initialControl, application: codex) else {
            throw CodexBrowserOAuthError.codexLoginWindowFocusFailed
        }
        let activationDeadline = Date().addingTimeInterval(5)
        while !codex.isActive, Date() < activationDeadline {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard codex.isActive else {
            throw CodexBrowserOAuthError.codexLoginWindowFocusFailed
        }

        // 窗口提升后重新读取一次 AXFrame。先尝试标准 AXPress；如果 Electron
        // 仍把它当作“成功但无反应”，半秒后再对同一个实时按钮做完整鼠标点击。
        initialRoot = AXUIElementCreateApplication(codex.processIdentifier)
        initialControls = Self.loginControls(in: initialRoot)
        if initialControls.count > 1 {
            throw CodexBrowserOAuthError.codexLoginControlAmbiguous
        }
        guard let refreshedControl = initialControls.first else {
            throw CodexBrowserOAuthError.codexLoginControlNotFound
        }
        initialControl = refreshedControl
        let didPress = CodexLoginAutomator.press(initialControl)
        try? await Task.sleep(for: .milliseconds(500))

        let afterPressRoot = AXUIElementCreateApplication(codex.processIdentifier)
        let controlsAfterPress = Self.loginControls(in: afterPressRoot)
        if controlsAfterPress.count > 1 {
            throw CodexBrowserOAuthError.codexLoginControlAmbiguous
        }
        let didClick: Bool
        if let controlAfterPress = controlsAfterPress.first {
            guard Self.focusWindow(containing: controlAfterPress, application: codex) else {
                throw CodexBrowserOAuthError.codexLoginWindowFocusFailed
            }
            didClick = CodexLoginAutomator.clickCenter(controlAfterPress)
        } else {
            didClick = false // AXPress 已使按钮消失，视为成功推进。
        }
        guard didPress || didClick || controlsAfterPress.isEmpty else {
            throw CodexBrowserOAuthError.codexLoginControlPressFailed
        }

        // 点击后每秒检查一次，最长 30 秒。若 AXPress 返回成功但页面没有响应，
        // 等满 10 秒后按同一控件中心补点一次；补点后仍只允许继续观察，避免重复
        // 触发 Codex 的登录路由。
        let pressDeadline = Date().addingTimeInterval(30)
        let clickedAt = Date()
        var retriedWithCenterClick = false
        var loginControlDismissed = false
        while Date() < pressDeadline {
            try Task.checkCancellation()
            let root = AXUIElementCreateApplication(codex.processIdentifier)
            let controls = Self.loginControls(in: root)
            if controls.count > 1 {
                throw CodexBrowserOAuthError.codexLoginControlAmbiguous
            }
            if let control = controls.first {
                if !retriedWithCenterClick,
                    Date().timeIntervalSince(clickedAt) >= 10 {
                    // 某些 Codex 版本的 AXPress 会返回成功但网页没有收到事件。
                    // 按用户可见控件中心补点一次，之后继续按秒扫描，避免重复点击。
                    guard Self.focusWindow(containing: control, application: codex),
                          CodexLoginAutomator.clickCenter(control) else {
                        throw CodexBrowserOAuthError.codexLoginControlPressFailed
                    }
                    retriedWithCenterClick = true
                }
            } else {
                loginControlDismissed = true
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        guard loginControlDismissed else {
            throw CodexBrowserOAuthError.codexLoginControlDidNotDismiss
        }
        // 按钮消失后 OAuth 页面仍可能在创建中；给 Chrome 10 秒完成首次路由，
        // 再交给浏览器自动机扫描授权站点。
        try? await Task.sleep(for: .seconds(10))
    }

    /// 把登录控件所属窗口提升为 Codex 主窗口，避免坐标点击落到刚刚准备好的
    /// Chrome Profile 窗口。只操作从精确登录控件向上找到的 AXWindow。
    private static func focusWindow(
        containing element: AXUIElement,
        application: NSRunningApplication
    ) -> Bool {
        var current = element
        var window: AXUIElement?
        for _ in 0..<50 {
            if CodexLoginAutomator.role(of: current) == kAXWindowRole {
                window = current
                break
            }
            guard let rawParent = CodexLoginAutomator.rawAttribute(
                current, kAXParentAttribute
            ) else { break }
            current = unsafeDowncast(rawParent, to: AXUIElement.self)
        }
        guard let window else { return false }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            root, kAXFrontmostAttribute as CFString, kCFBooleanTrue
        )
        _ = application.activate(options: [.activateAllWindows])
        _ = AXUIElementSetAttributeValue(
            window, kAXMainAttribute as CFString, kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            window, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        return AXUIElementPerformAction(
            window, kAXRaiseAction as CFString
        ) == .success
    }

    static func isChatGPTLoginControl(role: String, text: String) -> Bool {
        guard role == kAXButtonRole || role == "AXLink"
                || role == kAXStaticTextRole else { return false }
        let normalized = text.lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        let compactHints = [
            "继续登录", "继续登入",
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
        let deadline = Date().addingTimeInterval(8)
        for surface in contentSurfaces(in: root) {
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
                if isChatGPTLoginControl(role: role, text: text),
                   let actionable = actionableControl(for: element) {
                    matches.append(actionable)
                }
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

    /// Codex/Electron 的网页正文由 AXWindows 暴露，未必出现在应用的 AXChildren。
    /// 登录页控件只从真实窗口扫描；窗口属性暂不可用时才回退应用根节点。
    static func contentSurfaces(in root: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            root, kAXWindowsAttribute as CFString, &raw
        )
        if status == .success, let windows = raw as? [AXUIElement], !windows.isEmpty {
            var focusedRaw: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                root, kAXFocusedWindowAttribute as CFString, &focusedRaw
            ) == .success, let focusedRaw {
                let focused = unsafeDowncast(focusedRaw, to: AXUIElement.self)
                return [focused] + windows.filter { !CFEqual($0, focused) }
            }
            return windows
        }
        return [root]
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

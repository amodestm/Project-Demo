import AppKit
import ApplicationServices
import Foundation

/// 一个 Chrome profile。
///
/// ## 为什么用它来做"切换账号"
///
/// 每个 Chrome profile 是**彼此隔离**的登录环境。如果用户在两个 profile 里
/// 分别登录了两个 ChatGPT 账号, 那么"切换账号"就等价于"用另一个 profile 打开网址" ——
/// 不需要重新输入密码, 因为那个 profile 里的 session 早就是活的。
///
/// 这一步不读取密码；它只是把浏览器自己的一个已有能力 (多 profile)
/// 暴露给自动化流程。
public struct ChromeProfile: Sendable, Equatable, Identifiable {
    /// Chrome 内部目录名, 例如 `Default` / `Profile 1`。
    public let directoryName: String
    /// 用户在 Chrome 里给这个 profile 起的名字。
    public let displayName: String

    public var id: String { directoryName }

    public var label: String {
        displayName.isEmpty ? directoryName : "\(displayName) (\(directoryName))"
    }

    /// 讨论组默认用用户看到的 Profile 名称校验账号身份。
    ///
    /// 设置页已经确认过的邮箱别名最可靠；没有别名时使用 Chrome 里的
    /// Profile 显示名称，最后才回退到内部目录名。只有实际邮箱与这个默认值
    /// 不一致时，配置界面才需要用户另行输入。
    public func preferredAccountIdentity(alias: String? = nil) -> String {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAlias.isEmpty { return trimmedAlias }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDisplayName.isEmpty { return trimmedDisplayName }

        return directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(directoryName: String, displayName: String) {
        self.directoryName = directoryName
        self.displayName = displayName
    }
}

/// 扫描与启动 Chrome profile。
///
/// 只读 Chrome 的 `Local State` 里**用户自己给 profile 起的名字**。
/// 账号邮箱由用户在 AIRunner 中确认后作为显示别名保存。
public struct ChromeProfileScanner: Sendable {

    public enum ChromeKind: String, Sendable, CaseIterable {
        case chrome = "com.google.Chrome"
        case chromeCanary = "com.google.Chrome.canary"
        case chromium = "org.chromium.Chromium"
        case edge = "com.microsoft.edgemac"
        case brave = "com.brave.Browser"

        public var displayName: String {
            switch self {
            case .chrome:       return "Chrome"
            case .chromeCanary: return "Chrome Canary"
            case .chromium:     return "Chromium"
            case .edge:         return "Edge"
            case .brave:        return "Brave"
            }
        }

        /// `Local State` 所在的应用支持目录。
        public var applicationSupportDirectory: String {
            switch self {
            case .chrome:       return "Google/Chrome"
            case .chromeCanary: return "Google/Chrome Canary"
            case .chromium:     return "Chromium"
            case .edge:         return "Microsoft Edge"
            case .brave:        return "BraveSoftware/Brave-Browser"
            }
        }

        /// Chromium 系浏览器的主可执行文件。`open --args --new-window` 在已运行的
        /// Chrome 上可能只创建空壳窗口；直接调用浏览器才能可靠传入 URL。
        public var executablePath: String {
            switch self {
            case .chrome:
                return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            case .chromeCanary:
                return "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
            case .chromium:
                return "/Applications/Chromium.app/Contents/MacOS/Chromium"
            case .edge:
                return "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
            case .brave:
                return "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
            }
        }
    }

    private let homeDirectory: String

    public init(homeDirectory: String? = nil) {
        self.homeDirectory = homeDirectory ?? NSHomeDirectory()
    }

    // MARK: - 扫描

    /// 列出该浏览器里所有可用的 profile。
    public func availableProfiles(kind: ChromeKind = .chrome) throws -> [ChromeProfile] {
        let stateURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(kind.applicationSupportDirectory)
            .appendingPathComponent("Local State")

        guard FileManager.default.fileExists(atPath: stateURL.path) else { return [] }

        let data = try Data(contentsOf: stateURL)
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profiles = root["profile"] as? [String: Any],
            let cache = profiles["info_cache"] as? [String: [String: Any]]
        else {
            return []
        }

        return cache
            .map { directoryName, info in
                // ★ 只取用户自己起的名字。gaia_name (账号邮箱) 一律不读。★
                let name = (info["name"] as? String) ?? ""
                return ChromeProfile(directoryName: directoryName, displayName: name)
            }
            .sorted { lhs, rhs in
                // Default 排在最前, 其余按目录名
                if lhs.directoryName == "Default" { return true }
                if rhs.directoryName == "Default" { return false }
                return lhs.directoryName < rhs.directoryName
            }
    }

    /// 在所有常见 Chromium 系浏览器里找 profile。
    public func availableProfilesAcrossBrowsers() -> [(browser: ChromeKind, profiles: [ChromeProfile])] {
        ChromeKind.allCases.compactMap { kind in
            let found = (try? availableProfiles(kind: kind)) ?? []
            return found.isEmpty ? nil : (kind, found)
        }
    }

    // MARK: - 打开

    /// 为一次 Codex 登录准备一个可追踪的目标窗口。
    ///
    /// 仅仅调用 `activate()` 只能把 Chrome 置于前台，不能保证前台的窗口属于
    /// 传入的 profile。这里打开一个本地准备页，把一次性标记放进 URL，并在
    /// Accessibility 窗口树中找到包含该标记的窗口后再返回。准备页不访问
    /// ChatGPT，避免在真正点击 Codex 登录入口前制造普通 chatgpt.com 页面。
    @discardableResult
    public func openTrackedProfileWindow(
        profile: ChromeProfile,
        kind: ChromeKind = .chrome,
        timeout: TimeInterval = 30
    ) async -> String? {
        let marker = UUID().uuidString.lowercased()
        guard let url = Self.profileProbeURL(marker: marker),
              Self.writeProfileProbePage(for: url),
              open(url: url, profile: profile, kind: kind, newWindow: true),
              await focusProfileWindow(marker: marker, kind: kind, timeout: timeout)
        else {
            return nil
        }
        return marker
    }

    /// 找到带有一次性标记的 Chrome 窗口并将它提升到前台。
    ///
    /// 返回 `false` 通常表示辅助功能权限不足、浏览器没有按指定 profile
    /// 建立窗口，或页面尚未完成导航。调用方应把它当作“不能安全继续”处理。
    public func focusProfileWindow(
        marker: String,
        kind: ChromeKind = .chrome,
        timeout: TimeInterval = 30
    ) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            try? Task.checkCancellation()
            guard let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: kind.rawValue
            ).first(where: { !$0.isTerminated }) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            let root = AXUIElementCreateApplication(application.processIdentifier)
            let windows = Self.axElements(in: root, attribute: kAXWindowsAttribute)
            if let window = windows.first(where: { window in
                guard let document = Self.axStringAttribute(
                    window, name: kAXDocumentAttribute
                ) else { return false }
                return document.localizedCaseInsensitiveContains(marker)
            }) {
                _ = application.activate(options: [.activateAllWindows])
                return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            }

            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// 构造不会联网、不会读取或携带账号信息的 Profile 准备页地址。
    public static func profileProbeURL(marker: String) -> URL? {
        let pageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIRunner-Codex-Login-Profile.html")
        var components = URLComponents(
            url: pageURL, resolvingAgainstBaseURL: false
        )
        components?.fragment = "airunner_profile_probe=\(marker)"
        return components?.url
    }

    private static func writeProfileProbePage(for url: URL) -> Bool {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let fileURL = components?.url else { return false }
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <meta charset="utf-8">
        <meta name="color-scheme" content="dark light">
        <title>AIRunner 正在准备 Codex 登录</title>
        <style>
          body { font-family: -apple-system, sans-serif; display: grid; place-items: center;
                 min-height: 90vh; margin: 0; background: #171717; color: #f5f5f5; }
          main { text-align: center; }
          p { color: #aaa; }
        </style>
        <main><h2>正在准备 Codex 登录…</h2><p>AIRunner 已锁定这个 Chrome Profile</p></main>
        </html>
        """
        do {
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// 用指定 profile 打开一个 URL。
    ///
    /// 通过 `open -b <bundle-id> --args --profile-directory=<name>`。
    /// 浏览器已经在那个 profile 里登录着, 所以不会要求再次输入密码。
    @discardableResult
    public func open(
        url: URL,
        profile: ChromeProfile?,
        kind: ChromeKind = .chrome,
        newWindow: Bool = false
    ) -> Bool {
        if newWindow {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: kind.executablePath)
            process.arguments = ["--new-window"]
                + (profile.map { ["--profile-directory=\($0.directoryName)"] } ?? [])
                + [url.absoluteString]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Chrome 首次启动时主进程会一直运行，不能在这里等待退出，否则
                // AIRunner 会卡住。成功创建进程就表示启动请求已经交给 Chrome。
                return true
            } catch {
                return false
            }
        }

        var arguments = ["-b", kind.rawValue]
        if profile != nil {
            arguments.append("--args")
        }
        if let profile {
            arguments.append("--profile-directory=\(profile.directoryName)")
        }
        arguments.append(url.absoluteString)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 直接拉起 Chrome 的 profile 选择器, 让用户挑。
    @discardableResult
    public func openProfilePicker(kind: ChromeKind = .chrome) -> Bool {
        // Chrome 已经运行时，它会把第二次启动请求转发给现有进程，但会丢弃
        // `--profile-directory-picker`，最终只打开普通新标签页。对已运行的浏览器，直接按下
        // Chrome 自带的“添加个人资料…”菜单项；该菜单项有稳定的 AXIdentifier
        // `newProfile:`，所以不依赖中英文菜单名。
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: kind.rawValue
        ).first {
            guard AXIsProcessTrusted(), openNewProfileMenuItem(in: running) else {
                return false
            }
            return true
        }

        // 浏览器未运行时，启动参数会在初次启动时生效。
        guard FileManager.default.isExecutableFile(atPath: kind.executablePath) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kind.executablePath)
        process.arguments = ["--profile-directory-picker"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// 按下 Chromium 菜单里的“添加个人资料…”。
    ///
    /// Chrome 会在不同语言下改变菜单标题，但该项的 Accessibility identifier
    /// 始终是 `newProfile:`。隐藏的菜单也会出现在 AX 树里，可以直接执行 AXPress，
    /// 无需先猜测“个人资料 / Profiles”这一级菜单的本地化名称。
    private func openNewProfileMenuItem(in application: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawMenuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXMenuBarAttribute as CFString,
            &rawMenuBar
        ) == .success, let rawMenuBar else {
            return false
        }

        let menuBar = unsafeDowncast(rawMenuBar, to: AXUIElement.self)
        guard let menuItem = firstDescendant(
            of: menuBar,
            maxDepth: 5,
            matchingIdentifier: "newProfile:"
        ) else {
            return false
        }

        _ = application.activate(options: [.activateAllWindows])
        return AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
    }

    private func firstDescendant(
        of element: AXUIElement,
        maxDepth: Int,
        matchingIdentifier identifier: String
    ) -> AXUIElement? {
        guard maxDepth >= 0 else { return nil }

        var rawIdentifier: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXIdentifierAttribute as CFString,
            &rawIdentifier
        ) == .success, rawIdentifier as? String == identifier {
            return element
        }

        guard maxDepth > 0 else { return nil }
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &rawChildren
        ) == .success, let children = rawChildren as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let found = firstDescendant(
                of: child,
                maxDepth: maxDepth - 1,
                matchingIdentifier: identifier
            ) {
                return found
            }
        }
        return nil
    }

    private static func axElements(
        in element: AXUIElement,
        attribute: String
    ) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &raw
        ) == .success, let result = raw as? [AXUIElement] else {
            return []
        }
        return result
    }

    private static func axStringAttribute(
        _ element: AXUIElement,
        name: String
    ) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, name as CFString, &raw
        ) == .success else {
            return nil
        }
        return raw as? String
    }
}

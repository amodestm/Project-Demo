import AppKit
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
/// 账号邮箱由用户在设置页确认后作为显示别名保存。
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

    // MARK: - 打开

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
        var arguments = ["-g", "-b", kind.rawValue, "--args"]
        if newWindow {
            arguments.append("--new-window")
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
}

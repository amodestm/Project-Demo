import Foundation

/// 剪贴板读写。
///
/// 协议放在 Core, 具体实现由 App 层提供 —— `NSPasteboard` 属于 AppKit,
/// 而 Core 必须保持可被纯命令行测试驱动。这样 `swift test` 不需要窗口服务器。
public protocol ClipboardServicing: Sendable {

    /// 读取当前剪贴板文本。空或非文本内容返回 nil。
    func readString() -> String?

    /// 写入文本, 返回是否成功。
    @discardableResult
    func writeString(_ value: String) -> Bool
}

/// 内存剪贴板 —— 测试与无 UI 环境使用。
public final class InMemoryClipboard: ClipboardServicing, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: String?

    public init(seed: String? = nil) {
        self.storage = seed
    }

    public func readString() -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    @discardableResult
    public func writeString(_ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage = value
        return true
    }
}

/// 浏览器启动。
///
/// ## ★ 能力边界 (硬性) ★
///
/// 本协议**只**允许做一件事: 打开一个 URL, 让用户自己在已登录的浏览器里操作。
///
/// 明确禁止在本项目任何位置实现:
/// - 读取浏览器 Cookie 数据库 / 导出 Cookie
/// - 读取或注入 session token / authentication storage
/// - 自动填写账号密码
/// - 自动执行账号轮换
/// - 用自动化工具操作网页来绕过平台使用限制
///
/// 账号切换一律由用户在浏览器里手动完成, 程序只负责"提示 + 保存进度 + 恢复"。
public protocol BrowserLaunching: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

/// 什么也不做的实现 —— 用于测试与"用户不想自动打开浏览器"的设置。
public struct NoopBrowserLauncher: BrowserLaunching {
    public init() {}
    @discardableResult
    public func open(_ url: URL) -> Bool { false }
}

/// 测试用: 记录被请求打开的 URL, 不真的打开任何东西。
public final class RecordingBrowserLauncher: BrowserLaunching, @unchecked Sendable {

    private let lock = NSLock()
    private var opened: [URL] = []

    public init() {}

    @discardableResult
    public func open(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        opened.append(url)
        return true
    }

    public var openedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    public var lastOpened: URL? {
        lock.lock(); defer { lock.unlock() }
        return opened.last
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        opened.removeAll()
    }
}

/// ChatGPT Web 的目标地址。
///
/// 只保存 URL —— 不保存、不读取任何凭据。
public enum ChatGPTWebTarget {

    /// 默认地址。用户可以在设置里改 (例如用某个自建网关)。
    public static let defaultURLString = "https://chatgpt.com/"

    public static func resolvedURLString(override: String? = nil) -> String {
        guard let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultURLString
        }
        return override.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析成 URL。非法时回退到默认地址。
    public static func resolvedURL(override: String? = nil) -> URL {
        URL(string: resolvedURLString(override: override))
            ?? URL(string: defaultURLString)!
    }
}

import Foundation
import ApplicationServices
import AppKit

/// 浏览器窗口定位结果。
public struct BrowserWindowInfo: Sendable, Equatable {
    /// 窗口所属 App 的 bundle id。
    public let bundleIdentifier: String
    /// 窗口标题 (AXTitle)。
    public let title: String
    /// 窗口在 AX 树里的序号 (仅用于日志)。
    public let windowIndex: Int

    public init(bundleIdentifier: String, title: String, windowIndex: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.windowIndex = windowIndex
    }
}

/// 定位浏览器窗口并把指定窗口调到前台。
///
/// ## 用途
///
/// Chrome Profile 自动切换后, ChatGPT 会开在**新窗口或已有窗口的新标签页**里。
/// 这个类型负责:
/// 1. 找到目标浏览器 (Chrome 等) 的所有窗口
/// 2. 按标题匹配 (如包含 "ChatGPT")
/// 3. `AXRaise` 把匹配的窗口调到前台
///
/// ## ★ 只用 AX 属性, 不碰网页内容 ★
///
/// 读窗口标题 (`kAXTitleAttribute`) 与 `AXRaise` 都是系统无障碍 API 的
/// 正常窗口管理操作。
public struct BrowserWindowLocator: Sendable {

    public init() {}

    // MARK: - 查找

    /// 列出指定浏览器的所有窗口标题。
    public func listWindows(bundleIdentifier: String) throws -> [BrowserWindowInfo] {
        guard AXIsProcessTrusted() else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }
        guard let app = Self.runningApplication(bundleIdentifier: bundleIdentifier) else {
            throw CodexAutomationError.applicationNotFound(bundleIdentifier)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = Self.windowElements(of: appElement)

        return windows.enumerated().map { index, window in
            BrowserWindowInfo(
                bundleIdentifier: bundleIdentifier,
                title: Self.stringAttribute(window, kAXTitleAttribute) ?? "",
                windowIndex: index
            )
        }
    }

    /// 找到第一个标题包含 `titleFragment` 的窗口并调到前台。
    ///
    /// - Parameters:
    ///   - titleFragment: 标题片段 (大小写不敏感), 如 "ChatGPT"。
    ///   - activateApp: 是否同时把 App 本身激活。
    /// - Returns: 被聚焦的窗口信息。
    @discardableResult
    public func focusWindow(
        bundleIdentifier: String,
        titleFragment: String,
        activateApp: Bool = true
    ) throws -> BrowserWindowInfo {

        guard AXIsProcessTrusted() else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }
        guard let app = Self.runningApplication(bundleIdentifier: bundleIdentifier) else {
            throw CodexAutomationError.applicationNotFound(bundleIdentifier)
        }

        if activateApp {
            app.activate()
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = Self.windowElements(of: appElement)

        let needle = titleFragment.lowercased()
        for (index, window) in windows.enumerated() {
            let title = Self.stringAttribute(window, kAXTitleAttribute) ?? ""
            if title.lowercased().contains(needle) {
                // AXRaise: 把这个窗口带到最前。
                let result = AXUIElementPerformAction(window, "AXRaise" as CFString)
                if result != .success {
                    throw CodexAutomationError.sendFailed("无法前置窗口 (AXRaise 失败): \(title)")
                }
                return BrowserWindowInfo(
                    bundleIdentifier: bundleIdentifier,
                    title: title,
                    windowIndex: index
                )
            }
        }

        throw AppError.invalidRequest(
            "未找到 \(bundleIdentifier) 里标题含「\(titleFragment)」的窗口。"
            + "请先在浏览器里打开 ChatGPT 页面并切到前台, 再重试。"
        )
    }

    // MARK: - AX 读取

    private static func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
    }

    private static func windowElements(of appElement: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &raw
        )
        guard status == .success, let windows = raw as? [AXUIElement] else { return [] }
        return windows
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - 测试协议

/// 可注入的窗口定位 (测试替身用)。
public protocol BrowserWindowLocating: Sendable {
    func listWindows(bundleIdentifier: String) throws -> [BrowserWindowInfo]
    @discardableResult
    func focusWindow(
        bundleIdentifier: String,
        titleFragment: String,
        activateApp: Bool
    ) throws -> BrowserWindowInfo
}

extension BrowserWindowLocator: BrowserWindowLocating {}

/// 测试替身: 记录调用、返回可编程窗口列表。
public final class FakeBrowserWindowLocator: BrowserWindowLocating, @unchecked Sendable {

    private let lock = NSLock()
    private var _windows: [BrowserWindowInfo]
    private var _raisedTitles: [String] = []

    public init(windows: [BrowserWindowInfo] = []) {
        self._windows = windows
    }

    public func listWindows(bundleIdentifier: String) throws -> [BrowserWindowInfo] {
        lock.lock(); defer { lock.unlock() }
        return _windows.filter { $0.bundleIdentifier == bundleIdentifier }
    }

    @discardableResult
    public func focusWindow(
        bundleIdentifier: String,
        titleFragment: String,
        activateApp: Bool
    ) throws -> BrowserWindowInfo {
        lock.lock(); defer { lock.unlock() }
        guard let match = _windows.first(where: {
            $0.bundleIdentifier == bundleIdentifier
                && $0.title.lowercased().contains(titleFragment.lowercased())
        }) else {
            throw AppError.invalidRequest(
                "未找到 \(bundleIdentifier) 里标题含「\(titleFragment)」的窗口。"
                + "请先在浏览器里打开 ChatGPT 页面并切到前台, 再重试。"
            )
        }
        _raisedTitles.append(match.title)
        return match
    }

    // 可编程接口
    public func setWindows(_ windows: [BrowserWindowInfo]) {
        lock.lock(); defer { lock.unlock() }
        _windows = windows
    }

    public var raisedTitles: [String] {
        lock.lock(); defer { lock.unlock() }
        return _raisedTitles
    }
}

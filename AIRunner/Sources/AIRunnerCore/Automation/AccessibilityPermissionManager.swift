import Foundation
import ApplicationServices

/// 辅助功能权限管理。
///
/// 没有这个权限, 任何 UI 自动化都不可能工作 —— 而且 macOS 不会在调用 API 时
/// 自动弹窗, 只会静默返回空结果。所以必须在**开始任何操作之前**显式检查,
/// 否则用户看到的只是"什么都没发生"。
public protocol AccessibilityPermissionManaging: Sendable {

    /// 当前是否已被授权。**不触发任何 UI**。
    func currentStatus() -> AccessibilityPermissionStatus

    /// 触发系统授权提示 (会弹出系统对话框, 把 App 加进辅助功能列表)。
    @discardableResult
    func requestPermission() -> Bool

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    func openAccessibilitySettings()
}

/// 基于 `AXIsProcessTrusted` 的真实实现。
public struct AccessibilityPermissionManager: AccessibilityPermissionManaging {

    public init() {}

    public func currentStatus() -> AccessibilityPermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    @discardableResult
    public func requestPermission() -> Bool {
        // 这个调用会把本 App 加入系统设置的辅助功能列表并弹出提示。
        // 用户仍需在系统设置里手动勾选 —— macOS 不允许程序自我授权。
        //
        // 键名直接用字面量: `kAXTrustedCheckOptionPrompt` 是全局可变状态,
        // Swift 6 严格并发不允许在并发上下文中引用它。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func openAccessibilitySettings() {
        // 用 /usr/bin/open 而不是 NSWorkspace: 让本文件保持不依赖 AppKit。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        try? process.run()
    }
}

/// 测试替身: 可编程的权限状态。
public final class FakeAccessibilityPermissionManager: AccessibilityPermissionManaging, @unchecked Sendable {

    private let lock = NSLock()
    private var status: AccessibilityPermissionStatus
    private var settingsOpened = false

    public init(status: AccessibilityPermissionStatus = .granted) {
        self.status = status
    }

    public func currentStatus() -> AccessibilityPermissionStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    @discardableResult
    public func requestPermission() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // 模拟用户同意
        status = .granted
        return true
    }

    public func openAccessibilitySettings() {
        lock.lock(); defer { lock.unlock() }
        settingsOpened = true
    }

    public var didOpenSettings: Bool {
        lock.lock(); defer { lock.unlock() }
        return settingsOpened
    }

    public func setStatus(_ value: AccessibilityPermissionStatus) {
        lock.lock(); defer { lock.unlock() }
        status = value
    }
}

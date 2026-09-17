import Foundation
import ApplicationServices

/// 辅助功能权限的单一查询点。
///
/// 驱动 Chrome 网页 UI 完全依赖 macOS 的辅助功能（AX）API；没授权时一切自动化
/// 都会静默失败，所以**必须在下手之前就查**，并把结果如实告诉调用方。
public enum AccessibilityPermission {

    /// 当前进程是否已获授辅助功能权限。
    ///
    /// 注意：这个判定针对的是**当前进程**。MCP 服务端只是代理，真正驱动 Chrome 的
    /// 是 app，所以这里的值应该由 app 侧回答（见 `DiscussionBridgeHub.capabilities`）。
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 申请授权（会弹系统对话框）。仅在 app 首次启动时调用一次即可。
    @discardableResult
    public static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 系统设置里「辅助功能」面板的深链，用于引导用户。
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}

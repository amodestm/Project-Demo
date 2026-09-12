import Foundation
import AppKit
import AIRunnerCore

/// macOS 剪贴板实现。
///
/// 这是 Core 的 `ClipboardServicing` 协议在 App 层的落地。
/// Core 本身**不依赖 AppKit**, 因此 `swift test` 可以在没有窗口服务器的环境下运行。
struct PasteboardClipboard: ClipboardServicing {

    func readString() -> String? {
        let value = NSPasteboard.general.string(forType: .string)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    func writeString(_ value: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
}

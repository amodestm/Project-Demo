import Foundation
import AppKit
import AIRunnerCore

/// 用系统默认浏览器打开 URL。
///
/// ## ★ 能力边界 (硬性) ★
///
/// 本类型只做一件事: `NSWorkspace.shared.open(url)`。
///
/// 它**不**读取 Cookie、**不**注入 session token、**不**填写任何表单、
/// **不**通过自动化工具操作网页。账号切换完全由用户在浏览器里手动完成 ——
/// 程序只负责把用户引导到页面, 以及把进度存好。
struct WorkspaceBrowserLauncher: BrowserLaunching {

    @discardableResult
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

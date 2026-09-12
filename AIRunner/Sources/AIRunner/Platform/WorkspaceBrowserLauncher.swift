import Foundation
import AppKit
import AIRunnerCore

/// 用系统默认浏览器打开 URL。
///
/// ## ★ 能力边界 (硬性) ★
///
/// 本类型只做一件事: `NSWorkspace.shared.open(url)`。
///
/// 它**不**读取 Cookie、**不**注入 session token，也不填写表单；登录、提交与
/// 账号轮换由独立的 AX 自动化组件负责。这个类型只负责打开目标地址。
struct WorkspaceBrowserLauncher: BrowserLaunching {

    @discardableResult
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

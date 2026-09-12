import Foundation

/// 任务的执行通道。
///
/// 架构定位:
/// ```
///                  JobRunner
///                      │
///         ┌────────────┴─────────────┐
///         │                          │
///   Web Execution              API Execution
///     (primary)                  (optional)
///         │                          │
///  WebExecutionCoordinator      AIProvider
///         │
///  ContinuationPromptBuilder
///         │
///     ChatGPT Web
///  (manual session auth)
/// ```
///
/// 两条通道**共用**完全相同的持久化与编排设施:
/// SQLite / TaskStep / Checkpoint / RecoveryManager / Logs / ResponseValidator。
/// 差别只在"这一步的结果从哪里来"。
public enum ExecutionMode: String, Codable, Sendable, CaseIterable, Identifiable {

    /// ★ 主流程: ChatGPT Web + 账号交接。
    ///
    /// 程序负责: 检查点、已完成的步骤、续跑 prompt 生成、自动提交与读取、
    /// 暂停与恢复、崩溃恢复。自动化无法确认时可以降级为手工回填。
    /// 账号受限时可使用 macOS Keychain 中由用户保存的凭据登录下一个账号。
    ///
    /// 程序**不做**: 读 Cookie / 读 session token / 绕过验证码、两步验证或安全挑战。
    case chatGPTWeb = "chatgpt_web"

    /// 可选后端: 官方 API 直连。
    ///
    /// 代码位于 `Legacy/API/`, 默认不参与主流程。需要用户自行配置 API Key,
    /// 且是否启用完全由用户决定。
    case api = "api"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatGPTWeb: return "ChatGPT Web"
        case .api:        return "API (可选)"
        }
    }

    public var detail: String {
        switch self {
        case .chatGPTWeb:
            return "AIRunner 在浏览器中执行任务；新任务会主动退出当前会话并登录轮换池下一账号，同时负责检查点、续跑 prompt 与崩溃恢复。"
        case .api:
            return "直连官方 API 全自动执行, 需自行配置 API Key。默认不启用。"
        }
    }

    /// 是否为默认通道。
    public var isPrimary: Bool { self == .chatGPTWeb }
}

import Foundation

/// 任务的执行通道。
///
/// 架构定位:
/// ```
///                  JobRunner
///                      │
///         ┌────────────┬─────────────┐
///         │            │             │
///  Codex Desktop   Web Manual    API Execution
///    (primary)      (legacy)       (optional)
/// ```
///
/// 两条通道**共用**完全相同的持久化与编排设施:
/// SQLite / TaskStep / Checkpoint / RecoveryManager / Logs / ResponseValidator。
/// 差别只在"这一步的结果从哪里来"。
public enum ExecutionMode: String, Codable, Sendable, CaseIterable, Identifiable {

    /// ★ 主流程: 绑定 Codex 桌面工作对话并自动恢复。
    ///
    /// 程序负责目标对话定位、模型与思考程度核定、额度监视、Chrome Profile
    /// OAuth 账号切换，以及切换后的单次续跑。不会启动 Web 剪贴板 Runner。
    case codexDesktop = "codex_desktop"

    /// 兼容流程: ChatGPT Web + 剪贴板手动回填。
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
        case .codexDesktop: return "Codex 自动执行"
        case .chatGPTWeb: return "Web 手动回填（兼容）"
        case .api:        return "API (可选)"
        }
    }

    public var detail: String {
        switch self {
        case .codexDesktop:
            return "绑定一个 Codex 工作对话；后台监控额度，按指定或轮换的 Chrome Profile 切换账号，并自动回到原对话继续。"
        case .chatGPTWeb:
            return "旧版剪贴板流程：生成分步 Prompt、打开 ChatGPT，等待手动粘贴回答并推进检查点。"
        case .api:
            return "直连官方 API 全自动执行, 需自行配置 API Key。默认不启用。"
        }
    }

    /// 是否为默认通道。
    public var isPrimary: Bool { self == .codexDesktop }
}

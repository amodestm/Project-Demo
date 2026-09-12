import Foundation

/// Provider 实现类型。
///
/// `mock` 仅供测试与离线演示。**绝不进入生产默认路由** ——
/// 见 `ProviderConfig.defaults`, 其中不含任何 mock 条目。
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case openAICompatible = "openai_compatible"
    case mock

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .mock:             return "Mock (仅测试)"
        }
    }
}

/// 一个 Provider 的配置。
public struct ProviderConfig: Codable, Sendable, Identifiable, Equatable, Hashable {

    public var id: String
    public var displayName: String
    public var kind: ProviderKind

    /// 例如 https://api.openai.com/v1 (不含 /chat/completions)
    public var baseURL: String
    public var defaultModel: String
    public var models: [String]

    public var timeout: TimeInterval
    public var maxOutputTokens: Int

    /// Keychain 中使用的键名, 例如 "openai.apiKey"。
    public var keychainKey: String
    public var enabled: Bool

    public init(
        id: String,
        displayName: String,
        kind: ProviderKind = .openAICompatible,
        baseURL: String,
        defaultModel: String,
        models: [String] = [],
        timeout: TimeInterval = 180,
        maxOutputTokens: Int = 2048,
        keychainKey: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.models = models.isEmpty ? [defaultModel] : models
        self.timeout = timeout
        self.maxOutputTokens = maxOutputTokens
        self.keychainKey = keychainKey ?? "\(id).apiKey"
        self.enabled = enabled
    }

    /// 本地模型 / mock 不需要 API Key。
    public var requiresAPIKey: Bool {
        switch kind {
        case .openAICompatible: return !isLocalEndpoint
        case .mock:             return false
        }
    }

    private var isLocalEndpoint: Bool {
        let lower = baseURL.lowercased()
        return lower.contains("127.0.0.1") || lower.contains("localhost") || lower.contains("0.0.0.0")
    }

    public var chatCompletionsURL: URL? {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: trimmed + "/chat/completions")
    }

    public var modelsURL: URL? {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: trimmed + "/models")
    }

    // MARK: - 出厂默认

    /// 出厂 Provider 列表。全部是"用户自己合法配置的官方 API 端点"。
    /// 不含任何 Cookie / 网页自动化 / 账号轮换相关的配置项。
    public static let defaults: [ProviderConfig] = [
        ProviderConfig(
            id: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            models: ["gpt-4o-mini", "gpt-4o"],
            timeout: 180,
            maxOutputTokens: 2048
        ),
        ProviderConfig(
            id: "anthropic",
            displayName: "Anthropic",
            // 注意: Anthropic 原生协议与 OpenAI 不同, MVP 阶段请填官方兼容网关
            // 或自建 OpenAI-compatible 代理端点。
            baseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-3-5-haiku-latest",
            models: ["claude-3-5-haiku-latest"],
            timeout: 180,
            maxOutputTokens: 2048
        ),
        ProviderConfig(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            models: ["deepseek-chat"],
            timeout: 240,
            maxOutputTokens: 2048
        ),
        ProviderConfig(
            id: "ollama",
            displayName: "Ollama (本地)",
            baseURL: "http://127.0.0.1:11434/v1",
            defaultModel: "qwen2.5:7b",
            models: ["qwen2.5:7b"],
            timeout: 600,
            maxOutputTokens: 2048,
            enabled: false      // 默认关闭, 用户装了本地模型再开启
        ),
    ]
}

/// 路由表的一行。
public struct RouteEntry: Codable, Sendable, Identifiable, Equatable, Hashable {

    public var priority: Int
    public var provider: String
    public var model: String
    public var enabled: Bool
    public var note: String?

    public var id: Int { priority }

    public init(
        priority: Int,
        provider: String,
        model: String,
        enabled: Bool = true,
        note: String? = nil
    ) {
        self.priority = priority
        self.provider = provider
        self.model = model
        self.enabled = enabled
        self.note = note
    }

    public var label: String { "\(provider) / \(model)" }

    /// 出厂路由: Primary + Backup1 + Backup2 (+ 本地兜底)。
    public static let defaults: [RouteEntry] = [
        RouteEntry(priority: 1, provider: "openai", model: "gpt-4o-mini",
                   note: "主力"),
        RouteEntry(priority: 2, provider: "openai", model: "gpt-4o",
                   note: "同 Provider 升级模型"),
        RouteEntry(priority: 3, provider: "deepseek", model: "deepseek-chat",
                   note: "跨 Provider 兜底"),
        RouteEntry(priority: 4, provider: "ollama", model: "qwen2.5:7b",
                   enabled: false, note: "本地兜底 (需自行启动)"),
    ]
}

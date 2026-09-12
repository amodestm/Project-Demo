import Foundation

/// 期望的响应格式。
public enum ResponseFormat: String, Codable, Sendable, CaseIterable {
    case text
    case json

    public var displayName: String {
        switch self {
        case .text: return "文本"
        case .json: return "JSON"
        }
    }
}

/// 统一的模型请求。JobRunner 只构造这个结构, 不关心具体是哪家 SDK。
///
/// 注意: `model` 刻意不在这里 —— 模型绑定在 Provider 实例上 (见 ProviderConfig),
/// 这样 ModelRouter 只需要产出 (provider, model) 二元组即可构造 backend。
public struct AIRequest: Codable, Sendable, Equatable {

    public var systemPrompt: String
    public var userPrompt: String
    public var maxOutputTokens: Int?
    public var temperature: Double?
    public var responseFormat: ResponseFormat
    public var timeout: TimeInterval

    public init(
        systemPrompt: String,
        userPrompt: String,
        maxOutputTokens: Int? = 2048,
        temperature: Double? = 0.2,
        responseFormat: ResponseFormat = .text,
        timeout: TimeInterval = 180
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.responseFormat = responseFormat
        self.timeout = timeout
    }

    /// 当上下文超长时, 缩小 user prompt 的辅助方法。
    ///
    /// 简单按字符数截断并保留尾部 —— reasoning 类任务的尾部通常更重要。
    public func shrinkingUserPrompt(factor: Double) -> AIRequest {
        var copy = self
        let keep = max(200, Int(Double(userPrompt.count) * factor))
        if userPrompt.count > keep {
            let cut = userPrompt.index(userPrompt.endIndex, offsetBy: -keep)
            copy.userPrompt = "[上下文已截断以适应模型窗口]\n" + String(userPrompt[cut...])
        }
        return copy
    }
}

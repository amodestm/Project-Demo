import Foundation

/// 统一的模型响应。
public struct AIResponse: Codable, Sendable, Equatable {

    public let text: String
    public let provider: String
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let latencyMilliseconds: Int
    /// 部分 Provider 会返回 finish_reason (如 length / stop), 便于诊断截断。
    public let finishReason: String?

    public init(
        text: String,
        provider: String,
        model: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        latencyMilliseconds: Int,
        finishReason: String? = nil
    ) {
        self.text = text
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latencyMilliseconds = latencyMilliseconds
        self.finishReason = finishReason
    }

    public var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    public var backendLabel: String { "\(provider) / \(model)" }

    public var isTruncated: Bool {
        finishReason?.lowercased() == "length"
    }
}

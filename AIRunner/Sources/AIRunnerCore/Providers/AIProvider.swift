import Foundation

/// 所有模型后端统一接口。
///
/// JobRunner **只** 依赖这个协议, 不认识任何具体 SDK。
/// 这样将来加 Anthropic / Gemini 原生协议, 或换 http 客户端, 都不用动 Runner。
public protocol AIProvider: Sendable {

    /// Provider 标识 (如 "openai")。
    var id: String { get }

    /// 本实例绑定的模型名。
    var model: String { get }

    /// 执行一次请求。
    /// - Throws: 必须抛出 `AppError`, 不许抛裸 `Error` —— 否则错误分类会失效。
    func execute(request: AIRequest) async throws -> AIResponse

    /// 轻量健康探测。**不应** 消耗生成额度, 也 **不应** 抛错。
    func healthCheck() async -> ProviderHealth
}

/// backend = (provider 实例, 模型名) 的组合。
///
/// ModelRouter 的产出就是它。刻意做成值类型, 便于记录"本次步骤试过哪些 backend"。
public struct BackendRef: Sendable, Equatable, Hashable {
    public let providerID: String
    public let model: String
    public let priority: Int

    public init(providerID: String, model: String, priority: Int) {
        self.providerID = providerID
        self.model = model
        self.priority = priority
    }

    public var label: String { "\(providerID) / \(model)" }
}

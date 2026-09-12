import Foundation

/// Mock 行为脚本。
///
/// 生产代码 **绝不** 使用 Mock —— `ProviderConfig.defaults` 里没有任何 mock 条目,
/// `ModelRouter` 也不会自动注入它。它只由测试与离线 Demo 显式构造。
public enum MockBehavior: Sendable, Equatable {
    case success(text: String)
    case jsonSuccess(payload: String)
    case rateLimited(retryAfter: TimeInterval?)
    case timeout
    case serverError
    case authError
    case billingError
    case emptyOutput
    case networkFailure
    case latency(seconds: TimeInterval)

    public static var ok: MockBehavior { .success(text: "mock ok") }
}

/// 可编程的假 Provider。
///
/// 按 `script` 顺序逐次返回预设结果, 用尽后使用 `fallback`。
/// 这让"第 3 步超时一次然后成功"这类场景可以被精确构造与断言。
public final class MockAIProvider: AIProvider, @unchecked Sendable {

    public let id: String
    public let model: String

    private let lock = NSLock()
    private var script: [MockBehavior]
    private var fallback: MockBehavior
    private var callCount = 0
    private var capturedRequests: [AIRequest] = []
    private var healthOverride: ProviderHealth?

    public init(
        id: String = "mock",
        model: String = "mock-fast",
        script: [MockBehavior] = [],
        fallback: MockBehavior = .success(text: "mock ok")
    ) {
        self.id = id
        self.model = model
        self.script = script
        self.fallback = fallback
    }

    // MARK: - 测试控制面

    public var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return callCount
    }

    public var requests: [AIRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        callCount = 0
        capturedRequests = []
    }

    public func setFallback(_ behavior: MockBehavior) {
        lock.lock(); defer { lock.unlock() }
        fallback = behavior
    }

    public func appendScript(_ behaviors: [MockBehavior]) {
        lock.lock(); defer { lock.unlock() }
        script.append(contentsOf: behaviors)
    }

    public func setHealthOverride(_ health: ProviderHealth?) {
        lock.lock(); defer { lock.unlock() }
        healthOverride = health
    }

    // MARK: - AIProvider

    public func execute(request: AIRequest) async throws -> AIResponse {
        let behavior = dequeueBehavior(for: request)

        let started = Date()

        switch behavior {
        case .success(let text):
            return AIResponse(
                text: text,
                provider: id,
                model: model,
                inputTokens: request.userPrompt.count / 4,
                outputTokens: text.count / 4,
                latencyMilliseconds: elapsedMs(since: started),
                finishReason: "stop"
            )

        case .jsonSuccess(let payload):
            return AIResponse(
                text: payload,
                provider: id,
                model: model,
                inputTokens: request.userPrompt.count / 4,
                outputTokens: payload.count / 4,
                latencyMilliseconds: elapsedMs(since: started),
                finishReason: "stop"
            )

        case .latency(let seconds):
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            let text = "mock delayed ok (step latency \(seconds)s)"
            return AIResponse(
                text: text, provider: id, model: model,
                inputTokens: nil, outputTokens: nil,
                latencyMilliseconds: elapsedMs(since: started), finishReason: "stop"
            )

        case .rateLimited(let retryAfter):
            throw AppError.rateLimit(retryAfter: retryAfter)

        case .timeout:
            throw AppError.timeout

        case .serverError:
            throw AppError.providerUnavailable

        case .authError:
            throw AppError.authentication

        case .billingError:
            throw AppError.billingRequired

        case .emptyOutput:
            throw AppError.invalidOutput("mock: 内容为空")

        case .networkFailure:
            throw AppError.network("mock: 连接被重置")
        }
    }

    public func healthCheck() async -> ProviderHealth {
        // 锁操作必须留在同步函数里: NSLock.lock() 在 async 上下文中被 Swift 6 标记为不可用,
        // 因为在异步上下文里阻塞线程可能造成线程饥饿。
        if let override = currentHealthOverride() {
            return override
        }
        return ProviderHealth(provider: id, model: model, state: .healthy, lastSuccess: Date())
    }

    private func dequeueBehavior(for request: AIRequest) -> MockBehavior {
        lock.lock(); defer { lock.unlock() }
        let index = callCount
        callCount += 1
        capturedRequests.append(request)
        return index < script.count ? script[index] : fallback
    }

    private func currentHealthOverride() -> ProviderHealth? {
        lock.lock(); defer { lock.unlock() }
        return healthOverride
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }
}

import Foundation

/// 重试/熔断参数。
public struct RetryConfiguration: Sendable, Equatable, Codable {

    /// 基础退避秒数。序列: 5, 10, 20, 40, 80, 160, 300(封顶)
    public var baseDelay: TimeInterval = 5
    public var factor: Double = 2
    public var maxDelay: TimeInterval = 300
    /// 加性 jitter 比例。0.3 表示最多再加 30% 的随机量。
    public var jitterRatio: Double = 0.3

    /// 单步的普通错误重试上限。
    public var maxRetries: Int = 8
    /// 限流等待次数上限。与 maxRetries 分开计账 —— 限流不代表步骤有问题。
    public var maxRateLimitWaits: Int = 12
    /// 输出格式修复重试上限。
    public var maxRepairs: Int = 2

    /// 连续失败多少次要标记为 degraded。
    public var providerDegradedThreshold: Int = 3
    /// 连续失败多少次要标记为 unavailable 并进入冷却。
    public var providerUnavailableThreshold: Int = 5

    public var providerCooldown: TimeInterval = 600
    /// 余额耗尽/认证失败属于"用户不处理就不会好"的问题, 冷却要足够长。
    public var billingCooldown: TimeInterval = 6 * 3600

    /// 上下文超长时的缩减比例。
    public var contextShrinkFactor: Double = 0.5

    public init() {}

    public static let `default` = RetryConfiguration()
}

/// 单个步骤的重试预算。
public struct StepRetryBudget: Sendable, Equatable {
    public var retries: Int = 0
    public var rateLimitWaits: Int = 0
    public var repairs: Int = 0

    public init() {}

    public var summary: String {
        "retries=\(retries) rateLimitWaits=\(rateLimitWaits) repairs=\(repairs)"
    }
}

/// 纯函数式退避计算。
///
/// 刻意做成无状态 `enum` + 可注入随机源 —— 这样"第 N 次重试等待多少秒"可以在
/// 单元测试里被精确断言, 不依赖真实时钟或随机数。
public enum RetryPolicy {

    /// 返回 [0, 1) 的随机数发生器。测试时注入固定值即可得到确定性结果。
    public typealias RandomSource = @Sendable () -> Double

    public static let defaultRandom: RandomSource = { Double.random(in: 0..<1) }

    /// `delay = min(base * factor^retryCount, maxDelay) + jitter`
    public static func computeDelay(
        retryCount: Int,
        config: RetryConfiguration = .default,
        random: RandomSource = RetryPolicy.defaultRandom
    ) -> TimeInterval {
        let exponent = Double(max(0, retryCount))
        let raw = config.baseDelay * pow(config.factor, exponent)
        let capped = min(raw, config.maxDelay)
        let jitter = capped * max(0, config.jitterRatio) * max(0, min(1, random()))
        return (capped + jitter).rounded(toPlaces: 2)
    }

    /// 本次错误应当等待多久。返回 nil 表示"不该等待重试"。
    public static func plan(
        error: AppError,
        budget: StepRetryBudget,
        config: RetryConfiguration = .default,
        random: RandomSource = RetryPolicy.defaultRandom
    ) -> TimeInterval? {
        // 服务端给了 Retry-After 就听它的
        if let retryAfter = error.retryAfter, retryAfter > 0 {
            return min(max(1, retryAfter), config.maxDelay * 4)
        }

        switch error.strategy {
        case .retryWithBackoff:
            return computeDelay(
                retryCount: budget.rateLimitWaits, config: config, random: random
            )
        case .retrySame, .shrinkContext:
            return computeDelay(
                retryCount: budget.retries, config: config, random: random
            )
        case .switchBackend, .pauseTask, .failStep, .failTask:
            return nil
        }
    }

    /// 是否还有预算重试。
    public static func shouldRetry(
        error: AppError,
        budget: StepRetryBudget,
        config: RetryConfiguration = .default
    ) -> Bool {
        // 输出格式错误走独立的 repair 预算
        if case .invalidOutput = error {
            return budget.repairs < config.maxRepairs && budget.retries < config.maxRetries
        }

        switch error.strategy {
        case .retrySame, .shrinkContext:
            return budget.retries < config.maxRetries
        case .retryWithBackoff:
            return budget.rateLimitWaits < config.maxRateLimitWaits
        case .switchBackend, .pauseTask, .failStep, .failTask:
            return false
        }
    }

    /// 消耗预算。
    public static func consume(_ budget: inout StepRetryBudget, error: AppError) {
        if case .invalidOutput = error {
            budget.repairs += 1
        }
        switch error.strategy {
        case .retrySame, .shrinkContext:
            budget.retries += 1
        case .retryWithBackoff:
            budget.rateLimitWaits += 1
        case .switchBackend, .pauseTask, .failStep, .failTask:
            break
        }
    }
}

/// 退避执行的协调者。
///
/// 做成 actor 是为了让"同一个 Runner 的多次决策"序列化, 但真正的退避数学都在
/// `RetryPolicy` 里 (纯函数), 因此核心逻辑仍可被独立测试。
public actor RetryManager {

    private let config: RetryConfiguration
    private let random: RetryPolicy.RandomSource

    public init(
        config: RetryConfiguration = .default,
        random: @escaping RetryPolicy.RandomSource = RetryPolicy.defaultRandom
    ) {
        self.config = config
        self.random = random
    }

    public nonisolated var configuration: RetryConfiguration { config }

    public func delay(for error: AppError, budget: StepRetryBudget) -> TimeInterval? {
        RetryPolicy.plan(error: error, budget: budget, config: config, random: random)
    }

    public func shouldRetry(error: AppError, budget: StepRetryBudget) -> Bool {
        RetryPolicy.shouldRetry(error: error, budget: budget, config: config)
    }

    /// 可被打断的睡眠。
    ///
    /// 退避可能长达 5 分钟 —— 必须能在用户点 Pause/Cancel 时立刻中断,
    /// 否则 UI 会"卡住"长达数分钟。分片轮询 + 外部取消谓词实现。
    public func sleep(
        _ seconds: TimeInterval,
        isCancelled: @Sendable () async -> Bool
    ) async throws {
        guard seconds > 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { throw AppError.cancelled }
            if await isCancelled() { throw AppError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            let slice = min(0.25, max(0.01, remaining))
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

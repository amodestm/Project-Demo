import XCTest
@testable import AIRunnerCore

final class RetryManagerTests: XCTestCase {

    // MARK: - 退避序列

    func testBackoffSequenceMatchesSpecification() {
        var config = RetryConfiguration()
        config.baseDelay = 5
        config.factor = 2
        config.maxDelay = 300
        config.jitterRatio = 0            // 关掉 jitter 才能精确断言

        // 需求: 5, 10, 20, 40, 80 ... 上限 300
        let expected: [TimeInterval] = [5, 10, 20, 40, 80, 160, 300, 300, 300]

        for (index, want) in expected.enumerated() {
            let got = RetryPolicy.computeDelay(
                retryCount: index, config: config, random: { 0 }
            )
            XCTAssertEqual(got, want, accuracy: 0.001, "第 \(index) 次重试的退避不对")
        }
    }

    func testJitterIsBoundedAndAdditive() {
        var config = RetryConfiguration()
        config.baseDelay = 10
        config.factor = 2
        config.maxDelay = 300
        config.jitterRatio = 0.5

        let noJitter = RetryPolicy.computeDelay(retryCount: 0, config: config, random: { 0 })
        let maxJitter = RetryPolicy.computeDelay(retryCount: 0, config: config, random: { 0.999 })

        XCTAssertEqual(noJitter, 10, accuracy: 0.001)
        XCTAssertEqual(maxJitter, 15, accuracy: 0.02, "jitter 上限应为 base * ratio = 5")
        XCTAssertGreaterThan(maxJitter, noJitter)
    }

    func testServerRetryAfterOverridesBackoff() {
        let error = AppError.rateLimit(retryAfter: 42)
        let delay = RetryPolicy.plan(
            error: error,
            budget: StepRetryBudget(),
            config: .default,
            random: { 0 }
        )
        XCTAssertEqual(delay, 42, "服务端给了 Retry-After 就必须听它的")
    }

    func testRateLimitUsesItsOwnBackoffLadder() {
        var config = RetryConfiguration()
        config.baseDelay = 5
        config.factor = 2
        config.maxDelay = 300
        config.jitterRatio = 0

        var budget = StepRetryBudget()
        let error = AppError.rateLimit(retryAfter: nil)

        let first = RetryPolicy.plan(error: error, budget: budget, config: config, random: { 0 })
        RetryPolicy.consume(&budget, error: error)
        let second = RetryPolicy.plan(error: error, budget: budget, config: config, random: { 0 })

        XCTAssertEqual(first, 5)
        XCTAssertEqual(second, 10)
    }

    // MARK: - 策略路由

    func testErrorStrategyRouting() {
        XCTAssertEqual(AppError.network("x").strategy, .retrySame)
        XCTAssertEqual(AppError.timeout.strategy, .retrySame)
        XCTAssertEqual(AppError.rateLimit(retryAfter: nil).strategy, .retryWithBackoff)
        XCTAssertEqual(AppError.providerUnavailable.strategy, .switchBackend)
        XCTAssertEqual(AppError.modelUnavailable.strategy, .switchBackend)
        XCTAssertEqual(AppError.authentication.strategy, .pauseTask)
        XCTAssertEqual(AppError.billingRequired.strategy, .pauseTask)
        XCTAssertEqual(AppError.invalidRequest("bad").strategy, .failStep)
        XCTAssertEqual(AppError.contextTooLong.strategy, .shrinkContext)
        XCTAssertEqual(AppError.invalidOutput("junk").strategy, .retrySame)
        XCTAssertEqual(AppError.fatal("boom").strategy, .failTask)
    }

    func testNonRetryableErrorsAreNeverRetried() {
        let budget = StepRetryBudget()
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .authentication, budget: budget))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .billingRequired, budget: budget))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .invalidRequest("bad"), budget: budget))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .fatal("boom"), budget: budget))

        // contextTooLong 属于"缩上下文后可重试" —— 允许重试, 但同样受预算约束,
        // 不会变成无限循环。
        XCTAssertTrue(RetryPolicy.shouldRetry(error: .contextTooLong, budget: budget))
        var exhausted = StepRetryBudget()
        exhausted.retries = RetryConfiguration.default.maxRetries
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .contextTooLong, budget: exhausted))
    }

    func testForbiddenPathsHaveNoBackoff() {
        // 这些错误不该产生任何等待 —— 等待毫无意义。
        for error: AppError in [.authentication, .billingRequired, .invalidRequest("x"),
                                .providerUnavailable, .cancelled] {
            let delay = RetryPolicy.plan(
                error: error, budget: StepRetryBudget(), config: .default, random: { 0 }
            )
            XCTAssertNil(delay, "\(error.eventName) 不应进入退避")
        }
    }

    // MARK: - 预算

    func testRetryBudgetExhaustsAfterMaxRetries() {
        var config = RetryConfiguration()
        config.maxRetries = 3
        var budget = StepRetryBudget()
        let error = AppError.network("flaky")

        for attempt in 0..<3 {
            XCTAssertTrue(
                RetryPolicy.shouldRetry(error: error, budget: budget, config: config),
                "第 \(attempt + 1) 次仍应允许重试"
            )
            RetryPolicy.consume(&budget, error: error)
        }

        XCTAssertFalse(
            RetryPolicy.shouldRetry(error: error, budget: budget, config: config),
            "达到 maxRetries 后必须停止重试"
        )
        XCTAssertEqual(budget.retries, 3)
    }

    func testRateLimitBudgetIsSeparateFromRetryBudget() {
        var config = RetryConfiguration()
        config.maxRetries = 1
        config.maxRateLimitWaits = 5
        var budget = StepRetryBudget()

        RetryPolicy.consume(&budget, error: .network("x"))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .network("x"), budget: budget, config: config))
        XCTAssertTrue(
            RetryPolicy.shouldRetry(error: .rateLimit(retryAfter: nil), budget: budget, config: config),
            "限流必须使用独立预算, 不该被普通重试挤掉"
        )
    }

    func testRepairBudgetBoundsInvalidOutputRetries() {
        var config = RetryConfiguration()
        config.maxRepairs = 2
        config.maxRetries = 100
        var budget = StepRetryBudget()
        let error = AppError.invalidOutput("not json")

        RetryPolicy.consume(&budget, error: error)
        XCTAssertTrue(RetryPolicy.shouldRetry(error: error, budget: budget, config: config))
        RetryPolicy.consume(&budget, error: error)
        XCTAssertFalse(
            RetryPolicy.shouldRetry(error: error, budget: budget, config: config),
            "repair 次数达到上限后不得再重试"
        )
        XCTAssertEqual(budget.repairs, 2)
        XCTAssertEqual(budget.retries, 2, "repair 也应计入总重试预算")
    }

    // MARK: - 熔断触发判定

    func testOnlyCertainErrorsTripProviderCircuit() {
        XCTAssertTrue(AppError.authentication.tripsProviderCircuit)
        XCTAssertTrue(AppError.billingRequired.tripsProviderCircuit)
        XCTAssertTrue(AppError.providerUnavailable.tripsProviderCircuit)

        XCTAssertFalse(AppError.network("x").tripsProviderCircuit, "网络抖动不该熔断 Provider")
        XCTAssertFalse(AppError.timeout.tripsProviderCircuit)
        XCTAssertFalse(AppError.rateLimit(retryAfter: nil).tripsProviderCircuit)
        XCTAssertFalse(AppError.invalidOutput("x").tripsProviderCircuit)
    }

    // MARK: - Actor 行为

    func testRetryManagerComputesDeterministically() async {
        var config = RetryConfiguration()
        config.baseDelay = 2
        config.factor = 3
        config.maxDelay = 1000
        config.jitterRatio = 0

        let manager = RetryManager(config: config, random: { 0 })

        let first = await manager.delay(for: .timeout, budget: StepRetryBudget())
        XCTAssertEqual(first, 2)

        var budget = StepRetryBudget()
        RetryPolicy.consume(&budget, error: .timeout)
        let second = await manager.delay(for: .timeout, budget: budget)
        XCTAssertEqual(second, 6)
    }

    func testSleepReturnsEarlyWhenCancelled() async {
        let manager = RetryManager(config: .default)
        let start = Date()

        do {
            try await manager.sleep(30, isCancelled: { true })
            XCTFail("应当抛出 cancelled")
        } catch let error as AppError {
            XCTAssertEqual(error.eventName, "CANCELLED")
        } catch {
            XCTFail("抛出了非 AppError: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "取消必须立刻中断退避")
    }
}

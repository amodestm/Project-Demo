import XCTest
@testable import AIRunnerCore

final class ModelRouterTests: XCTestCase {

    // MARK: - 装置

    private func makeRouter(routes: [RouteEntry], providers: [ProviderConfig]) -> ModelRouter {
        ModelRouter(
            routes: routes,
            providers: providers,
            config: TestSupport.fastRetryConfig()
        )
    }

    private func twoProviderSetup() -> ModelRouter {
        makeRouter(
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ],
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ]
        )
    }

    // MARK: - 优先级

    func testSelectsLowestPriorityNumberFirst() async {
        let router = twoProviderSetup()
        let backend = await router.selectBackend(excluding: [])
        XCTAssertEqual(backend?.providerID, "p1")
        XCTAssertEqual(backend?.model, "m1")
    }

    func testSelectionOrderFollowsRouteTable() async {
        let router = twoProviderSetup()
        let all = await router.allBackends()
        XCTAssertEqual(all.map(\.label), ["p1 / m1", "p2 / m2"])
    }

    func testDisabledRouteIsNeverSelected() async {
        let router = makeRouter(
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1", enabled: false),
                RouteEntry(priority: 2, provider: "p2", model: "m2", enabled: true),
            ],
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ]
        )
        let backend = await router.selectBackend(excluding: [])
        XCTAssertEqual(backend?.providerID, "p2", "被禁用的路由必须跳过")
    }

    // MARK: - ★ 防无限循环 ★

    func testAlreadyAttemptedBackendsAreSkipped() async {
        let router = twoProviderSetup()

        let first = await router.selectBackend(excluding: [])
        XCTAssertEqual(first?.providerID, "p1")

        let second = await router.selectBackend(excluding: ["p1 / m1"])
        XCTAssertEqual(second?.providerID, "p2")

        let third = await router.selectBackend(excluding: ["p1 / m1", "p2 / m2"])
        XCTAssertNil(third, "所有 backend 都试过后必须返回 nil, 不能回到 p1")
    }

    func testRouterNeverProducesABABCycle() async {
        let router = twoProviderSetup()
        var attempted: Set<String> = []
        var sequence: [String] = []

        // 模拟 Runner 的循环: 每次都把选中的 backend 加进 attempted
        while let backend = await router.selectBackend(excluding: attempted) {
            sequence.append(backend.label)
            attempted.insert(backend.label)
            XCTAssertLessThanOrEqual(sequence.count, 4, "出现了无限循环")
        }

        XCTAssertEqual(sequence, ["p1 / m1", "p2 / m2"])
        XCTAssertEqual(Set(sequence).count, sequence.count, "同一个 backend 不得被选中两次")
    }

    // MARK: - 熔断

    func testAuthenticationTripsCircuitBreakerImmediately() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        let health = await router.noteFailure(backend, error: .authentication)

        XCTAssertEqual(health.state, .unavailable, "认证失败必须立刻熔断, 不能靠重试")
        XCTAssertNotNil(health.cooldownUntil)

        let next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p2", "熔断后应直接走备用 Provider")
    }

    func testBillingRequiredTripsProviderLevelCircuit() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        await router.noteFailure(backend, error: .billingRequired)

        let providerHealth = await router.providerHealth("p1")
        XCTAssertEqual(providerHealth?.state, .unavailable, "余额耗尽应熔断整个 Provider")

        let next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p2")
    }

    func testNetworkFailureDoesNotDegradeProvider() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        for _ in 0..<10 {
            _ = await router.noteFailure(backend, error: .network("connection reset"))
        }

        let health = await router.health(for: backend)
        XCTAssertEqual(health?.state, .healthy, "网络抖动不该把 Provider 熔断掉")
        XCTAssertEqual(health?.consecutiveErrors, 0)

        let next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p1", "p1 仍应可用")
    }

    func testRateLimitDoesNotDegradeProvider() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        for _ in 0..<10 {
            _ = await router.noteFailure(backend, error: .rateLimit(retryAfter: 5))
        }

        let health = await router.health(for: backend)
        XCTAssertEqual(health?.state, .healthy, "限流只说明节奏太快, 不代表 Provider 坏了")
    }

    func testRepeatedProviderUnavailableEventuallyTripsThreshold() async {
        var config = TestSupport.fastRetryConfig()
        config.providerDegradedThreshold = 2
        config.providerUnavailableThreshold = 3

        let router = ModelRouter(
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ],
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ],
            config: config
        )
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        let h1 = await router.noteFailure(backend, error: .providerUnavailable)
        XCTAssertEqual(h1.state, .healthy, "第 1 次失败还没到阈值")

        let h2 = await router.noteFailure(backend, error: .providerUnavailable)
        XCTAssertEqual(h2.state, .degraded, "第 2 次应进入 degraded")

        let h3 = await router.noteFailure(backend, error: .providerUnavailable)
        XCTAssertEqual(h3.state, .unavailable, "第 3 次应彻底熔断")
        XCTAssertNotNil(h3.cooldownUntil)
    }

    func testModelUnavailableOnlyBlocksThatModel() async {
        let router = makeRouter(
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "gone"),
                RouteEntry(priority: 2, provider: "p1", model: "m1"),
            ],
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "gone"),
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
            ]
        )
        let backend = BackendRef(providerID: "p1", model: "gone", priority: 1)

        await router.noteFailure(backend, error: .modelUnavailable)

        let providerHealth = await router.providerHealth("p1")
        XCTAssertNil(providerHealth ?? nil, "Provider 级不应被熔断")

        let next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.model, "m1", "应换到同 Provider 的其它模型")
    }

    func testSuccessClearsCooldown() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        _ = await router.noteFailure(backend, error: .authentication)
        var next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p2")

        await router.noteSuccess(backend)

        let health = await router.health(for: backend)
        XCTAssertEqual(health?.state, .healthy)
        XCTAssertNil(health?.cooldownUntil)

        next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p1", "恢复后应立刻重新可用")
    }

    // MARK: - 诊断

    func testExplainNoBackendListsReasons() async {
        let router = makeRouter(
            routes: [RouteEntry(priority: 1, provider: "p1", model: "m1")],
            providers: [TestSupport.mockProviderConfig(id: "p1", model: "m1")]
        )
        let explanation = await router.explainNoBackend(excluding: ["p1 / m1"])
        XCTAssertTrue(explanation.contains("已试过"), "诊断信息应说明该 backend 已被试过")
    }

    func testExhaustedCheckAgreesWithSelect() async {
        let router = twoProviderSetup()
        let attempted: Set<String> = ["p1 / m1", "p2 / m2"]
        let exhausted = await router.isExhausted(excluding: attempted)
        XCTAssertTrue(exhausted)
    }

    // MARK: - 首选 backend

    func testPreferredBackendIsTriedFirst() async {
        let router = twoProviderSetup()
        let backend = await router.selectBackend(
            excluding: [],
            preferredProvider: "p2",
            preferredModel: "m2"
        )
        XCTAssertEqual(backend?.providerID, "p2", "任务声明的 primary 应优先")
    }

    func testPreferredBackendIsAlsoSubjectToAttemptedFilter() async {
        let router = twoProviderSetup()
        let backend = await router.selectBackend(
            excluding: ["p2 / m2"],
            preferredProvider: "p2",
            preferredModel: "m2"
        )
        XCTAssertEqual(backend?.providerID, "p1", "首选已试过则退回按优先级选")
    }
}

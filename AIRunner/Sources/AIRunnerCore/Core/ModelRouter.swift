import Foundation

/// 模型路由器。
///
/// 输入: 任务 + 已试过的 backend 集合 + Provider 健康度
/// 输出: 下一个 (provider, model)
///
/// ★ 防无限循环 ★
/// 调用方每试一个 backend 就把它加入 `attempted` 并传回来。
/// 已试过的 backend 不会再被选中, 因此不可能出现 A → B → A → B 的死循环。
/// 当 `selectBackend` 返回 nil 时, 说明候选池已耗尽 —— Runner 据此暂停或失败,
/// 绝不原地打转。
public actor ModelRouter {

    // MARK: 依赖

    private let providerConfigs: [String: ProviderConfig]
    private var routes: [RouteEntry]
    private let healthRepository: ProviderHealthRepository?
    private let logger: LoggerService?
    private let config: RetryConfiguration
    private let now: @Sendable () -> Date
    private let isProviderConfigured: @Sendable (String) -> Bool

    // MARK: 状态

    /// key = "provider::model" 或 "provider::*" (provider 级)
    private var health: [String: ProviderHealth] = [:]

    public init(
        routes: [RouteEntry],
        providers: [ProviderConfig],
        healthRepository: ProviderHealthRepository? = nil,
        logger: LoggerService? = nil,
        config: RetryConfiguration = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        isProviderConfigured: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        var map: [String: ProviderConfig] = [:]
        for provider in providers { map[provider.id] = provider }

        self.providerConfigs = map
        self.routes = routes.sorted { $0.priority < $1.priority }
        self.healthRepository = healthRepository
        self.logger = logger
        self.config = config
        self.now = now
        self.isProviderConfigured = isProviderConfigured

        if let repo = healthRepository, let stored = try? repo.fetchAll() {
            for item in stored {
                health[Self.key(provider: item.provider, model: item.model)] = item
            }
        }
    }

    // MARK: - 路由表

    public func updateRoutes(_ newRoutes: [RouteEntry]) {
        routes = newRoutes.sorted { $0.priority < $1.priority }
    }

    public func currentRoutes() -> [RouteEntry] { routes }

    /// 全部候选 backend (按优先级)。
    public func allBackends() -> [BackendRef] {
        orderedRoutes().compactMap { route in
            guard providerConfigs[route.provider] != nil else { return nil }
            return BackendRef(providerID: route.provider, model: route.model, priority: route.priority)
        }
    }

    private func orderedRoutes() -> [RouteEntry] {
        routes.filter { $0.enabled }.sorted { $0.priority < $1.priority }
    }

    // MARK: - 选择

    /// 选择一个可用 backend。
    ///
    /// - Parameters:
    ///   - attempted: 本次步骤已经试过的 backend (`BackendRef.label`)
    ///   - preferredProvider/Model: 任务声明的 primary, 优先级最高
    /// - Returns: 可用 backend; nil 表示候选池耗尽或全部处于冷却。
    public func selectBackend(
        excluding attempted: Set<String>,
        preferredProvider: String? = nil,
        preferredModel: String? = nil
    ) -> BackendRef? {
        let current = now()
        let candidates = orderedRoutes()

        // 1) 优先尝试任务指定的 primary
        if let preferredProvider, let preferredModel {
            let label = "\(preferredProvider) / \(preferredModel)"
            if !attempted.contains(label),
               let route = candidates.first(where: {
                   $0.provider == preferredProvider && $0.model == preferredModel
               }),
               isUsable(route, at: current) {
                return BackendRef(
                    providerID: route.provider, model: route.model, priority: route.priority
                )
            }
        }

        // 2) 按优先级取第一个可用
        for route in candidates {
            let label = "\(route.provider) / \(route.model)"
            if attempted.contains(label) { continue }
            if isUsable(route, at: current) {
                return BackendRef(
                    providerID: route.provider, model: route.model, priority: route.priority
                )
            }
        }
        return nil
    }

    /// 候选池是否已经耗尽 (给 Runner 判断"该暂停还是该失败")。
    public func isExhausted(excluding attempted: Set<String>) -> Bool {
        selectBackend(excluding: attempted) == nil
    }

    /// 解释为什么没有可用 backend —— 写日志用, 避免"静默失败"。
    public func explainNoBackend(excluding attempted: Set<String>) -> String {
        let current = now()
        var reasons: [String] = []
        for route in orderedRoutes() {
            let label = "\(route.provider) / \(route.model)"
            if attempted.contains(label) {
                reasons.append("\(label): 本次已试过")
                continue
            }
            if !isProviderConfigured(route.provider) {
                reasons.append("\(label): 未配置 API Key")
                continue
            }
            if let health = health[Self.key(provider: route.provider, model: nil)],
               !health.isUsable(at: current) {
                reasons.append("\(label): Provider 熔断 (\(health.statusDescription))")
                continue
            }
            if let health = health[Self.key(provider: route.provider, model: route.model)],
               !health.isUsable(at: current) {
                reasons.append("\(label): 模型熔断 (\(health.statusDescription))")
                continue
            }
            reasons.append("\(label): 可用")
        }
        if reasons.isEmpty { return "路由表为空" }
        return reasons.joined(separator: "; ")
    }

    private func isUsable(_ route: RouteEntry, at time: Date) -> Bool {
        guard let config = providerConfigs[route.provider], config.enabled else { return false }
        guard isProviderConfigured(route.provider) else { return false }

        if let providerHealth = health[Self.key(provider: route.provider, model: nil)],
           !providerHealth.isUsable(at: time) {
            return false
        }
        if let modelHealth = health[Self.key(provider: route.provider, model: route.model)],
           !modelHealth.isUsable(at: time) {
            return false
        }
        return true
    }

    // MARK: - 健康度反馈

    public func noteSuccess(_ backend: BackendRef) {
        let time = now()

        var modelHealth = health[Self.key(provider: backend.providerID, model: backend.model)]
            ?? ProviderHealth(provider: backend.providerID, model: backend.model)
        modelHealth.state = .healthy
        modelHealth.consecutiveErrors = 0
        modelHealth.lastSuccess = time
        modelHealth.cooldownUntil = nil
        modelHealth.reason = nil
        store(modelHealth)

        // 成功说明整个 Provider 可达, 清掉 provider 级熔断。
        if let providerHealth = health[Self.key(provider: backend.providerID, model: nil)],
           providerHealth.state != .healthy {
            var recovered = providerHealth
            recovered.state = .healthy
            recovered.consecutiveErrors = 0
            recovered.cooldownUntil = nil
            recovered.reason = nil
            recovered.lastSuccess = time
            store(recovered)
            logger?.info(.providerRecovered, "Provider \(backend.providerID) 恢复正常",
                         metadata: .object(["provider": .string(backend.providerID)]))
        }
    }

    /// 记录一次失败, 返回更新后的健康度。
    @discardableResult
    public func noteFailure(_ backend: BackendRef, error: AppError) -> ProviderHealth {
        let time = now()
        let key = Self.key(provider: backend.providerID, model: backend.model)
        var modelHealth = health[key] ?? ProviderHealth(provider: backend.providerID, model: backend.model)
        modelHealth.lastFailure = time
        modelHealth.reason = error.userMessage

        switch error {

        case .billingRequired, .authentication:
            // 用户不处理就不会好。立即熔断 + 长冷却。
            modelHealth.state = .unavailable
            modelHealth.cooldownUntil = time.addingTimeInterval(config.billingCooldown)
            tripProvider(
                backend.providerID,
                reason: error.userMessage,
                cooldown: config.billingCooldown,
                at: time
            )
            logger?.error(.billingBlocked,
                          "熔断 Provider \(backend.providerID): \(error.userMessage)",
                          metadata: .object(["provider": .string(backend.providerID)]))

        case .modelUnavailable:
            // 只是这个模型名不对, Provider 本身没问题 —— 只拉黑该模型。
            modelHealth.state = .unavailable
            modelHealth.cooldownUntil = time.addingTimeInterval(config.providerCooldown)

        case .providerUnavailable:
            modelHealth.consecutiveErrors += 1
            if modelHealth.consecutiveErrors >= config.providerUnavailableThreshold {
                modelHealth.state = .unavailable
                modelHealth.cooldownUntil = time.addingTimeInterval(config.providerCooldown)
                tripProvider(
                    backend.providerID,
                    reason: "连续 \(modelHealth.consecutiveErrors) 次不可用",
                    cooldown: config.providerCooldown,
                    at: time
                )
            } else if modelHealth.consecutiveErrors >= config.providerDegradedThreshold {
                modelHealth.state = .degraded
            }

        default:
            // 网络抖动 / 限流 / 输出格式问题都不该熔断 Provider ——
            // 继续调用是有意义的, 只是节奏需要调整。
            break
        }

        store(modelHealth)
        return modelHealth
    }

    private func tripProvider(
        _ providerID: String,
        reason: String,
        cooldown: TimeInterval,
        at time: Date
    ) {
        var providerHealth = health[Self.key(provider: providerID, model: nil)]
            ?? ProviderHealth(provider: providerID, model: nil)
        providerHealth.state = .unavailable
        providerHealth.cooldownUntil = time.addingTimeInterval(cooldown)
        providerHealth.reason = reason
        providerHealth.lastFailure = time
        providerHealth.consecutiveErrors += 1
        store(providerHealth)
    }

    // MARK: - 查询与重置

    public func healthSnapshot() -> [ProviderHealth] {
        health.values.sorted {
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return ($0.model ?? "") < ($1.model ?? "")
        }
    }

    public func health(for backend: BackendRef) -> ProviderHealth? {
        health[Self.key(provider: backend.providerID, model: backend.model)]
    }

    public func providerHealth(_ providerID: String) -> ProviderHealth? {
        health[Self.key(provider: providerID, model: nil)]
    }

    /// 清空熔断状态。用户在 Settings 里点了"重置"时调用。
    public func resetHealth(provider: String? = nil) {
        if let provider {
            health = health.filter { $0.value.provider != provider }
        } else {
            health.removeAll()
        }
        _ = try? healthRepository?.reset(provider: provider)
    }

    // MARK: - 内部

    private func store(_ item: ProviderHealth) {
        health[Self.key(provider: item.provider, model: item.model)] = item
        try? healthRepository?.upsert(item)
    }

    static func key(provider: String, model: String?) -> String {
        "\(provider)::\(model ?? "*")"
    }
}

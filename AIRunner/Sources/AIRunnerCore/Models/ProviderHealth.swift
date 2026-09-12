import Foundation

public enum ProviderHealthState: String, Codable, Sendable, CaseIterable {
    case healthy
    case degraded
    case unavailable

    public var displayName: String {
        switch self {
        case .healthy:     return "正常"
        case .degraded:    return "降级"
        case .unavailable: return "不可用"
        }
    }
}

/// Provider / 模型的健康度与熔断状态。
///
/// 熔断规则 (阈值来自 `RetryManager` 配置):
/// * 连续 3 次失败 -> `.degraded`
/// * 连续 5 次失败 -> `.unavailable` + 进入 cooldown
/// * `billingRequired` / `authentication` -> 立即 `.unavailable`, 且 cooldown 很长
///
/// 熔断的意义不是"绕过限制", 而是**停止无意义的重复调用** —— 认证失败或余额耗尽时
/// 继续打 API 只会浪费时间, 所以必须让 Router 立刻改走别的 backend 或暂停任务。
public struct ProviderHealth: Codable, Sendable, Equatable, Hashable {

    public var provider: String
    /// nil 表示这是 Provider 级 (所有模型共享) 的健康状态。
    public var model: String?
    public var state: ProviderHealthState
    public var consecutiveErrors: Int
    public var lastSuccess: Date?
    public var lastFailure: Date?
    public var cooldownUntil: Date?
    public var reason: String?

    public init(
        provider: String,
        model: String? = nil,
        state: ProviderHealthState = .healthy,
        consecutiveErrors: Int = 0,
        lastSuccess: Date? = nil,
        lastFailure: Date? = nil,
        cooldownUntil: Date? = nil,
        reason: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.state = state
        self.consecutiveErrors = consecutiveErrors
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.cooldownUntil = cooldownUntil
        self.reason = reason
    }

    public static func healthy(provider: String, model: String? = nil) -> ProviderHealth {
        ProviderHealth(provider: provider, model: model)
    }

    /// 在给定时刻是否仍处于冷却中。
    public func isCoolingDown(at now: Date = Date()) -> Bool {
        guard let cooldownUntil else { return false }
        return cooldownUntil > now
    }

    /// 现在能否使用。
    public func isUsable(at now: Date = Date()) -> Bool {
        if isCoolingDown(at: now) { return false }
        return state != .unavailable
    }

    public var cooldownRemaining: TimeInterval? {
        guard let cooldownUntil else { return nil }
        let remaining = cooldownUntil.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    public var label: String {
        model.map { "\(provider) / \($0)" } ?? provider
    }

    public var statusDescription: String {
        var parts = [state.displayName]
        if consecutiveErrors > 0 {
            parts.append("连续失败 \(consecutiveErrors)")
        }
        if let remaining = cooldownRemaining {
            parts.append("冷却剩余 \(Int(remaining))s")
        }
        if let reason { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}

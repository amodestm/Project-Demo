import Foundation

/// Provider 熔断状态持久化。
///
/// 为什么必须落盘: 若只存在内存, App 重启后会立刻去重试那个已经"余额耗尽"或
/// "Key 无效"的 Provider, 白白浪费时间。持久化后重启仍然遵守冷却期。
public struct ProviderHealthRepository: Sendable {

    /// provider 级 (所有模型共享) 健康度使用这个 model 占位符。
    public static let anyModel = "*"

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func upsert(_ health: ProviderHealth) throws {
        let modelKey = health.model ?? Self.anyModel
        try db.execute(
            """
            INSERT INTO provider_health (
                provider, model, state, consecutive_errors,
                last_success, last_failure, cooldown_until, reason, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(provider, model) DO UPDATE SET
                state = excluded.state,
                consecutive_errors = excluded.consecutive_errors,
                last_success = excluded.last_success,
                last_failure = excluded.last_failure,
                cooldown_until = excluded.cooldown_until,
                reason = excluded.reason,
                updated_at = excluded.updated_at
            """,
            [
                .text(health.provider),
                .text(modelKey),
                .text(health.state.rawValue),
                .int(health.consecutiveErrors),
                health.lastSuccess.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                health.lastFailure.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                health.cooldownUntil.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                health.reason.map { SQLValue.text($0) } ?? .null,
                .text(DateCoding.string(from: Date())),
            ]
        )
    }

    public func fetch(provider: String, model: String? = nil) throws -> ProviderHealth? {
        let modelKey = model ?? Self.anyModel
        guard let row = try db.queryOne(
            "SELECT * FROM provider_health WHERE provider = ? AND model = ?",
            [.text(provider), .text(modelKey)]
        ) else { return nil }
        return Self.decode(row)
    }

    public func fetchAll() throws -> [ProviderHealth] {
        try db.query("SELECT * FROM provider_health ORDER BY provider ASC").map { Self.decode($0) }
    }

    /// 清空熔断状态 (用户在 Settings 里点"重置 Provider 状态"时调用)。
    @discardableResult
    public func reset(provider: String? = nil) throws -> Int {
        let before = try db.scalarInt("SELECT COUNT(*) FROM provider_health") ?? 0
        if let provider {
            try db.execute("DELETE FROM provider_health WHERE provider = ?", [.text(provider)])
        } else {
            try db.execute("DELETE FROM provider_health")
        }
        let after = try db.scalarInt("SELECT COUNT(*) FROM provider_health") ?? 0
        return before - after
    }

    static func decode(_ row: SQLRow) -> ProviderHealth {
        let rawState = row.string("state") ?? ProviderHealthState.healthy.rawValue
        let modelKey = row.string("model")
        return ProviderHealth(
            provider: row.string("provider") ?? "?",
            model: (modelKey == nil || modelKey == anyModel) ? nil : modelKey,
            state: ProviderHealthState(rawValue: rawState) ?? .healthy,
            consecutiveErrors: row.int("consecutive_errors") ?? 0,
            lastSuccess: row.date("last_success"),
            lastFailure: row.date("last_failure"),
            cooldownUntil: row.date("cooldown_until"),
            reason: row.string("reason")
        )
    }
}

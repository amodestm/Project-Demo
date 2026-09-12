import Foundation

/// 一次 Resume 操作的租约。
///
/// 存在意义: **跨进程**防止同一个绑定被重复发送「继续」。
///
/// 不能只用 actor 内存状态 —— 用户可能同时开着两个 AIRunner 实例,
/// 或者上一次发送途中 App 异常退出。所以 claim 必须在 SQLite 事务里完成,
/// `binding_id` 作为主键天然保证"一个绑定同时只有一行"。
public struct CodexResumeLease: Sendable, Equatable {
    public let bindingID: String
    public let ownerID: String
    public let acquiredAt: Date
    public let expiresAt: Date

    public init(bindingID: String, ownerID: String, acquiredAt: Date, expiresAt: Date) {
        self.bindingID = bindingID
        self.ownerID = ownerID
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date = Date()) -> Bool { expiresAt <= now }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }
}

/// claim 的结果。
public enum LeaseClaimResult: Sendable, Equatable {
    case acquired(CodexResumeLease)
    /// 已有**未过期**的租约, 且持有者是别人。
    case busy(existing: CodexResumeLease)
    /// 存在一个**已过期**的租约。
    ///
    /// 这里刻意**不静默覆盖** —— 过期通常意味着"上一次 Resume 异常退出",
    /// 此时究竟有没有发出去是未知的。交给用户显式确认 (Recover Resume Lock)
    /// 比程序自作主张安全得多。
    case staleRequiresExplicitRecovery(existing: CodexResumeLease)
}

/// Resume 租约表访问。
public struct CodexResumeLeaseRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    /// 尝试认领某个 binding 的 resume 权。
    ///
    /// - Parameters:
    ///   - ttl: 租约有效期。Monitor 长跑时需要定期续租。
    public func claim(
        bindingID: String,
        ownerID: String,
        ttl: TimeInterval,
        now: Date = Date()
    ) throws -> LeaseClaimResult {

        try db.transaction {
            if let existing = try Self.fetchOne(db, bindingID: bindingID) {

                if existing.isExpired(at: now) {
                    return .staleRequiresExplicitRecovery(existing: existing)
                }

                // 同一个 owner 重复 claim → 续租 (Monitor 会周期性 tick), 视为成功。
                if existing.ownerID != ownerID {
                    return .busy(existing: existing)
                }
            }

            let lease = CodexResumeLease(
                bindingID: bindingID,
                ownerID: ownerID,
                acquiredAt: now,
                expiresAt: now.addingTimeInterval(ttl)
            )

            try db.execute(
                """
                INSERT INTO codex_resume_leases (binding_id, owner_id, acquired_at, expires_at)
                VALUES (?,?,?,?)
                ON CONFLICT(binding_id) DO UPDATE SET
                    owner_id    = excluded.owner_id,
                    acquired_at = excluded.acquired_at,
                    expires_at  = excluded.expires_at
                """,
                [
                    .text(lease.bindingID),
                    .text(lease.ownerID),
                    .text(DateCoding.string(from: lease.acquiredAt)),
                    .text(DateCoding.string(from: lease.expiresAt)),
                ]
            )

            return .acquired(lease)
        }
    }

    /// 释放租约。只有持有者本人能释放。
    @discardableResult
    public func release(bindingID: String, ownerID: String) throws -> Bool {
        try db.transaction {
            try db.execute(
                "DELETE FROM codex_resume_leases WHERE binding_id = ? AND owner_id = ?",
                [.text(bindingID), .text(ownerID)]
            )
            return (try db.scalarInt("SELECT changes()") ?? 0) > 0
        }
    }

    /// 用户点击「恢复 Resume 锁」时调用 —— 强制清掉, 不再询问。
    @discardableResult
    public func forceRelease(bindingID: String) throws -> Bool {
        try db.transaction {
            try db.execute(
                "DELETE FROM codex_resume_leases WHERE binding_id = ?",
                [.text(bindingID)]
            )
            return (try db.scalarInt("SELECT changes()") ?? 0) > 0
        }
    }

    public func current(bindingID: String) throws -> CodexResumeLease? {
        try Self.fetchOne(db, bindingID: bindingID)
    }

    public func all() throws -> [CodexResumeLease] {
        try db.query(
            "SELECT * FROM codex_resume_leases ORDER BY acquired_at ASC"
        ).map { Self.decode($0) }
    }

    /// 清理已过期租约 (启动时调用, 保持表干净)。
    @discardableResult
    public func purgeExpired(now: Date = Date()) throws -> Int {
        let expired = try all().filter { $0.isExpired(at: now) }
        guard !expired.isEmpty else { return 0 }
        try db.transaction {
            for lease in expired {
                try db.execute(
                    "DELETE FROM codex_resume_leases WHERE binding_id = ?",
                    [.text(lease.bindingID)]
                )
            }
        }
        return expired.count
    }

    // MARK: - 内部

    private static func fetchOne(_ db: Database, bindingID: String) throws -> CodexResumeLease? {
        guard let row = try db.queryOne(
            "SELECT * FROM codex_resume_leases WHERE binding_id = ?",
            [.text(bindingID)]
        ) else { return nil }
        return decode(row)
    }

    private static func decode(_ row: SQLRow) -> CodexResumeLease {
        CodexResumeLease(
            bindingID: row.string("binding_id") ?? "?",
            ownerID: row.string("owner_id") ?? "?",
            acquiredAt: row.date("acquired_at") ?? Date(),
            expiresAt: row.date("expires_at") ?? Date()
        )
    }
}

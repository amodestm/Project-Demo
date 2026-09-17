import Foundation

/// 一条账号额度快照。
///
/// 只包含额度计量值与账号标识（邮箱、plan 名称），**不含任何凭据** ——
/// access token 仅存在于 `CodexQuotaProbe` 的调用栈里，不会落库。
public struct CodexQuotaSnapshot: Sendable, Equatable {

    public var profileDirectory: String
    public var capturedAt: Date
    /// 采集来源: `rotation-before` / `rotation-after` / `mcp` / `manual`。
    public var source: String

    public var email: String?
    public var accountID: String?
    public var planType: String?
    public var allowed: Bool?
    public var limitReached: Bool?
    public var rateLimitReachedType: String?

    /// 5 小时窗口。
    public var primaryUsedPercent: Double?
    public var primaryWindowSeconds: Int?
    public var primaryResetAt: Int?

    /// 每周窗口。
    public var secondaryUsedPercent: Double?
    public var secondaryWindowSeconds: Int?
    public var secondaryResetAt: Int?

    /// 模型不可用时的恢复时间戳（按最晚的一个模型记录）。
    public var modelAvailableAt: Int?

    public var creditsBalance: String?
    public var resetCreditsAvailable: Int?

    /// 原始响应, 便于事后核对字段含义的变化。
    public var rawJSON: String?

    public init(
        profileDirectory: String,
        capturedAt: Date = Date(),
        source: String,
        email: String? = nil,
        accountID: String? = nil,
        planType: String? = nil,
        allowed: Bool? = nil,
        limitReached: Bool? = nil,
        rateLimitReachedType: String? = nil,
        primaryUsedPercent: Double? = nil,
        primaryWindowSeconds: Int? = nil,
        primaryResetAt: Int? = nil,
        secondaryUsedPercent: Double? = nil,
        secondaryWindowSeconds: Int? = nil,
        secondaryResetAt: Int? = nil,
        modelAvailableAt: Int? = nil,
        creditsBalance: String? = nil,
        resetCreditsAvailable: Int? = nil,
        rawJSON: String? = nil
    ) {
        self.profileDirectory = profileDirectory
        self.capturedAt = capturedAt
        self.source = source
        self.email = email
        self.accountID = accountID
        self.planType = planType
        self.allowed = allowed
        self.limitReached = limitReached
        self.rateLimitReachedType = rateLimitReachedType
        self.primaryUsedPercent = primaryUsedPercent
        self.primaryWindowSeconds = primaryWindowSeconds
        self.primaryResetAt = primaryResetAt
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryWindowSeconds = secondaryWindowSeconds
        self.secondaryResetAt = secondaryResetAt
        self.modelAvailableAt = modelAvailableAt
        self.creditsBalance = creditsBalance
        self.resetCreditsAvailable = resetCreditsAvailable
        self.rawJSON = rawJSON
    }

    public var primaryRemainingPercent: Double? {
        primaryUsedPercent.map { max(0, 100 - $0) }
    }
}

/// 选号时需要的精简视图。
public struct CodexQuotaStanding: Sendable, Equatable {
    public let profileDirectory: String
    public let capturedAt: Date
    public let limitReached: Bool
    public let primaryUsedPercent: Double?
    public let primaryResetAt: Int?

    public init(
        profileDirectory: String,
        capturedAt: Date,
        limitReached: Bool,
        primaryUsedPercent: Double? = nil,
        primaryResetAt: Int? = nil
    ) {
        self.profileDirectory = profileDirectory
        self.capturedAt = capturedAt
        self.limitReached = limitReached
        self.primaryUsedPercent = primaryUsedPercent
        self.primaryResetAt = primaryResetAt
    }

    /// 该账号在指定时刻是否处于「额度已耗尽且尚未恢复」的状态。
    public func isBlocked(at date: Date) -> Bool {
        guard limitReached else { return false }
        guard let resetAt = primaryResetAt, resetAt > 0 else { return true }
        return Date(timeIntervalSince1970: TimeInterval(resetAt)) > date
    }
}

/// 额度快照表访问。
public struct CodexQuotaSnapshotRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    // MARK: - 写入

    public func record(_ snapshot: CodexQuotaSnapshot) throws {
        try db.execute(
            """
            INSERT INTO codex_account_quota_snapshots (
                profile_directory, captured_at, source,
                email, account_id, plan_type, allowed, limit_reached, rate_limit_reached_type,
                primary_used_percent, primary_window_seconds, primary_reset_at,
                secondary_used_percent, secondary_window_seconds, secondary_reset_at,
                model_available_at, credits_balance, reset_credits_available, raw_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(profile_directory, captured_at) DO NOTHING
            """,
            [
                .text(snapshot.profileDirectory),
                .text(DateCoding.string(from: snapshot.capturedAt)),
                .text(snapshot.source),
                snapshot.email.map { SQLValue.text($0) } ?? .null,
                snapshot.accountID.map { SQLValue.text($0) } ?? .null,
                snapshot.planType.map { SQLValue.text($0) } ?? .null,
                snapshot.allowed.map { SQLValue.int($0 ? 1 : 0) } ?? .null,
                snapshot.limitReached.map { SQLValue.int($0 ? 1 : 0) } ?? .null,
                snapshot.rateLimitReachedType.map { SQLValue.text($0) } ?? .null,
                snapshot.primaryUsedPercent.map { SQLValue.double($0) } ?? .null,
                snapshot.primaryWindowSeconds.map { SQLValue.int($0) } ?? .null,
                snapshot.primaryResetAt.map { SQLValue.int($0) } ?? .null,
                snapshot.secondaryUsedPercent.map { SQLValue.double($0) } ?? .null,
                snapshot.secondaryWindowSeconds.map { SQLValue.int($0) } ?? .null,
                snapshot.secondaryResetAt.map { SQLValue.int($0) } ?? .null,
                snapshot.modelAvailableAt.map { SQLValue.int($0) } ?? .null,
                snapshot.creditsBalance.map { SQLValue.text($0) } ?? .null,
                snapshot.resetCreditsAvailable.map { SQLValue.int($0) } ?? .null,
                snapshot.rawJSON.map { SQLValue.text($0) } ?? .null,
            ]
        )
    }

    // MARK: - 读取

    public func latest(profileDirectory: String) throws -> CodexQuotaSnapshot? {
        try db.query(
            """
            SELECT * FROM codex_account_quota_snapshots
            WHERE profile_directory = ?
            ORDER BY captured_at DESC
            LIMIT 1
            """,
            [.text(profileDirectory)]
        ).first.map(Self.decode)
    }

    /// 每个 profile 最近一条快照。
    public func latestByProfile() throws -> [String: CodexQuotaSnapshot] {
        let rows = try db.query(
            """
            SELECT s.* FROM codex_account_quota_snapshots s
            JOIN (
                SELECT profile_directory, MAX(captured_at) AS ts
                FROM codex_account_quota_snapshots
                GROUP BY profile_directory
            ) latest
              ON latest.profile_directory = s.profile_directory
             AND latest.ts = s.captured_at
            """
        )
        var result: [String: CodexQuotaSnapshot] = [:]
        for row in rows {
            let snapshot = Self.decode(row)
            result[snapshot.profileDirectory] = snapshot
        }
        return result
    }

    public func quotaStanding() throws -> [String: CodexQuotaStanding] {
        var result: [String: CodexQuotaStanding] = [:]
        for (directory, snapshot) in try latestByProfile() {
            result[directory] = CodexQuotaStanding(
                profileDirectory: directory,
                capturedAt: snapshot.capturedAt,
                limitReached: snapshot.limitReached ?? false,
                primaryUsedPercent: snapshot.primaryUsedPercent,
                primaryResetAt: snapshot.primaryResetAt
            )
        }
        return result
    }

    public func history(profileDirectory: String?, limit: Int = 100) throws -> [CodexQuotaSnapshot] {
        if let profileDirectory {
            return try db.query(
                """
                SELECT * FROM codex_account_quota_snapshots
                WHERE profile_directory = ?
                ORDER BY captured_at DESC LIMIT ?
                """,
                [.text(profileDirectory), .int(limit)]
            ).map(Self.decode)
        }
        return try db.query(
            """
            SELECT * FROM codex_account_quota_snapshots
            ORDER BY captured_at DESC LIMIT ?
            """,
            [.int(limit)]
        ).map(Self.decode)
    }

    /// 按 profile 保留最近 N 条, 其余删除。避免长期运行把库撑大。
    @discardableResult
    public func prune(keepingPerProfile keep: Int = 200) throws -> Int {
        guard keep > 0 else { return 0 }
        let before = try db.scalarInt("SELECT COUNT(*) FROM codex_account_quota_snapshots;") ?? 0
        try db.execute(
            """
            DELETE FROM codex_account_quota_snapshots
            WHERE rowid NOT IN (
                SELECT rowid FROM (
                    SELECT rowid,
                           ROW_NUMBER() OVER (
                               PARTITION BY profile_directory ORDER BY captured_at DESC
                           ) AS rank
                    FROM codex_account_quota_snapshots
                ) WHERE rank <= ?
            )
            """,
            [.int(keep)]
        )
        let after = try db.scalarInt("SELECT COUNT(*) FROM codex_account_quota_snapshots;") ?? 0
        return max(0, before - after)
    }

    // MARK: - 解码

    private static func decode(_ row: SQLRow) -> CodexQuotaSnapshot {
        CodexQuotaSnapshot(
            profileDirectory: row.string("profile_directory") ?? "",
            capturedAt: row.date("captured_at") ?? Date(timeIntervalSince1970: 0),
            source: row.string("source") ?? "unknown",
            email: row.string("email"),
            accountID: row.string("account_id"),
            planType: row.string("plan_type"),
            allowed: row.bool("allowed"),
            limitReached: row.bool("limit_reached"),
            rateLimitReachedType: row.string("rate_limit_reached_type"),
            primaryUsedPercent: row.double("primary_used_percent"),
            primaryWindowSeconds: row.int("primary_window_seconds"),
            primaryResetAt: row.int("primary_reset_at"),
            secondaryUsedPercent: row.double("secondary_used_percent"),
            secondaryWindowSeconds: row.int("secondary_window_seconds"),
            secondaryResetAt: row.int("secondary_reset_at"),
            modelAvailableAt: row.int("model_available_at"),
            creditsBalance: row.string("credits_balance"),
            resetCreditsAvailable: row.int("reset_credits_available"),
            rawJSON: row.string("raw_json")
        )
    }
}

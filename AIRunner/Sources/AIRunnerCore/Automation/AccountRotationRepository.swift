import Foundation

/// 账号轮换状态表访问。
public struct AccountRotationRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    /// 读取某任务当前的 profile 目录名。
    public func currentProfile(taskID: String) throws -> String? {
        try db.queryOne(
            "SELECT current_profile FROM account_rotation_state WHERE task_id = ?",
            [.text(taskID)]
        )?.string("current_profile")
    }

    /// 读取轮换次数。
    public func rotationCount(taskID: String) throws -> Int {
        try db.scalarInt(
            "SELECT rotation_count FROM account_rotation_state WHERE task_id = ?",
            [.text(taskID)]
        ) ?? 0
    }

    /// 写入/更新某任务的轮换状态。
    public func update(
        taskID: String,
        currentProfile: String?,
        rotatedAt: Date = Date()
    ) throws {
        try db.execute(
            """
            INSERT INTO account_rotation_state
                (task_id, current_profile, rotation_count, last_rotated_at)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(task_id) DO UPDATE SET
                current_profile = excluded.current_profile,
                rotation_count = account_rotation_state.rotation_count + 1,
                last_rotated_at = excluded.last_rotated_at
            """,
            [
                .text(taskID),
                currentProfile.map { SQLValue.text($0) } ?? .null,
                .text(DateCoding.string(from: rotatedAt)),
            ]
        )
    }

    /// 显式设定 (不累计计数) —— 用于绑定初始 profile。
    public func setInitial(
        taskID: String,
        profile: String?,
        at date: Date = Date()
    ) throws {
        try db.execute(
            """
            INSERT INTO account_rotation_state
                (task_id, current_profile, rotation_count, last_rotated_at)
            VALUES (?, ?, 0, ?)
            ON CONFLICT(task_id) DO NOTHING
            """,
            [
                .text(taskID),
                profile.map { SQLValue.text($0) } ?? .null,
                .text(DateCoding.string(from: date)),
            ]
        )
    }

    // MARK: - ChatGPT 网页账号指针

    /// 读取某任务当前使用的 ChatGPT 账号 (网页内账号, 非 Chrome profile)。
    public func currentChatGPTAccount(taskID: String) throws -> String? {
        try db.queryOne(
            "SELECT current_chatgpt_account FROM account_rotation_state WHERE task_id = ?",
            [.text(taskID)]
        )?.string("current_chatgpt_account")
    }

    /// 最近一次由 AIRunner 成功登录的 ChatGPT 账号。
    /// 新任务尚无自己的指针时用它继续全局轮换，避免每个任务都从第一条开始。
    public func mostRecentChatGPTAccount() throws -> String? {
        try db.queryOne(
            """
            SELECT current_chatgpt_account
            FROM account_rotation_state
            WHERE current_chatgpt_account IS NOT NULL
            ORDER BY last_rotated_at DESC
            LIMIT 1
            """
        )?.string("current_chatgpt_account")
    }

    /// 记录一次 ChatGPT 网页账号切换。
    public func recordChatGPTAccount(taskID: String, account: String) throws {
        try db.execute(
            """
            INSERT INTO account_rotation_state
                (task_id, current_profile, rotation_count, last_rotated_at, current_chatgpt_account)
            VALUES (?, NULL, 1, ?, ?)
            ON CONFLICT(task_id) DO UPDATE SET
                current_chatgpt_account = excluded.current_chatgpt_account,
                last_rotated_at = excluded.last_rotated_at
            """,
            [
                .text(taskID),
                .text(DateCoding.string(from: Date())),
                .text(account),
            ]
        )
    }

    public func delete(taskID: String) throws {
        try db.execute(
            "DELETE FROM account_rotation_state WHERE task_id = ?",
            [.text(taskID)]
        )
    }
}

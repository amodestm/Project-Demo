import Foundation

/// 检查点表访问。
public struct CheckpointRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func insert(_ checkpoint: Checkpoint) throws {
        try db.execute(
            """
            INSERT INTO checkpoints (
                id, task_id, completed_step, next_step,
                working_summary, state_json, created_at
            ) VALUES (?,?,?,?,?,?,?)
            """,
            [
                .text(checkpoint.id),
                .text(checkpoint.taskID),
                .int(checkpoint.completedStep),
                .int(checkpoint.nextStep),
                checkpoint.workingSummary.map { SQLValue.text($0) } ?? .null,
                .text((try? JSONCoding.encodeToString(checkpoint.state)) ?? "{}"),
                .text(DateCoding.string(from: checkpoint.createdAt)),
            ]
        )
    }

    /// 取最新检查点 (按 completed_step 降序)。
    ///
    /// 这是崩溃恢复的权威依据: 重启后读它就知道该从哪一步继续。
    /// 若任务从未成功执行过任何步骤, 返回 nil —— 调用方应回退到 "从 0 开始"。
    public func latest(taskID: String) throws -> Checkpoint? {
        let rows = try db.query(
            """
            SELECT * FROM checkpoints
             WHERE task_id = ?
             ORDER BY completed_step DESC, created_at DESC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    public func list(taskID: String, limit: Int = 100) throws -> [Checkpoint] {
        try db.query(
            """
            SELECT * FROM checkpoints
             WHERE task_id = ?
             ORDER BY completed_step DESC
             LIMIT ?
            """,
            [.text(taskID), .int(limit)]
        ).map { try Self.decode($0) }
    }

    public func count(taskID: String) throws -> Int {
        try db.scalarInt(
            "SELECT COUNT(*) FROM checkpoints WHERE task_id = ?", [.text(taskID)]
        ) ?? 0
    }

    static func decode(_ row: SQLRow) throws -> Checkpoint {
        Checkpoint(
            id: try row.requireString("id"),
            taskID: try row.requireString("task_id"),
            completedStep: try row.requireInt("completed_step"),
            nextStep: try row.requireInt("next_step"),
            workingSummary: row.string("working_summary"),
            state: row.json("state_json") ?? .emptyObject,
            createdAt: row.date("created_at") ?? Date()
        )
    }
}

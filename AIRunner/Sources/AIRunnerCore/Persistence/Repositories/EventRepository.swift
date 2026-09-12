import Foundation

/// 事件/日志表访问。
///
/// 注意: 写入本表的内容必须已经过脱敏 —— 见 `LoggerService`。
/// 这里不做二次过滤, 因为 LoggerService 是唯一的写入入口。
public struct EventRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func append(_ event: AppEvent) throws {
        try db.execute(
            """
            INSERT INTO events (
                id, task_id, step_index, level, event_type,
                message, metadata_json, created_at
            ) VALUES (?,?,?,?,?,?,?,?)
            """,
            [
                .text(event.id),
                event.taskID.map { SQLValue.text($0) } ?? .null,
                event.stepIndex.map { SQLValue.int($0) } ?? .null,
                .text(event.level.rawValue),
                .text(event.eventType.rawValue),
                .text(event.message),
                event.metadata.map { SQLValue.text((try? JSONCoding.encodeToString($0)) ?? "null") } ?? .null,
                .text(DateCoding.string(from: event.createdAt)),
            ]
        )
    }

    public func append(contentsOf events: [AppEvent]) throws {
        guard !events.isEmpty else { return }
        try db.transaction {
            for event in events {
                try append(event)
            }
        }
    }

    public func list(
        taskID: String? = nil,
        level: LogLevel? = nil,
        limit: Int = 300
    ) throws -> [AppEvent] {
        var sql = "SELECT * FROM events WHERE 1=1"
        var params: [SQLValue] = []

        if let taskID {
            sql += " AND task_id = ?"
            params.append(.text(taskID))
        }
        if let level {
            sql += " AND level = ?"
            params.append(.text(level.rawValue))
        }
        sql += " ORDER BY created_at DESC LIMIT ?"
        params.append(.int(limit))

        return try db.query(sql, params).map { try Self.decode($0) }
    }

    public func count(taskID: String? = nil) throws -> Int {
        if let taskID {
            return try db.scalarInt(
                "SELECT COUNT(*) FROM events WHERE task_id = ?", [.text(taskID)]
            ) ?? 0
        }
        return try db.scalarInt("SELECT COUNT(*) FROM events") ?? 0
    }

    /// 清理旧日志, 避免长期运行后日志表无限膨胀。
    @discardableResult
    public func prune(keepingMostRecent keep: Int = 20_000) throws -> Int {
        let total = try count()
        guard total > keep else { return 0 }
        let excess = total - keep
        try db.execute(
            """
            DELETE FROM events WHERE id IN (
                SELECT id FROM events ORDER BY created_at ASC LIMIT ?
            )
            """,
            [.int(excess)]
        )
        return excess
    }

    static func decode(_ row: SQLRow) throws -> AppEvent {
        let rawLevel = row.string("level") ?? LogLevel.info.rawValue
        let rawType = row.string("event_type") ?? EventType.unknown.rawValue

        return AppEvent(
            id: try row.requireString("id"),
            taskID: row.string("task_id"),
            stepIndex: row.int("step_index"),
            level: LogLevel(rawValue: rawLevel) ?? .info,
            eventType: EventType(rawValue: rawType) ?? .unknown,
            message: try row.requireString("message"),
            metadata: row.json("metadata_json"),
            createdAt: row.date("created_at") ?? Date()
        )
    }
}

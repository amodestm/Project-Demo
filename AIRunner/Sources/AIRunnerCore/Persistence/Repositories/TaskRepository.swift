import Foundation

/// 任务表访问。
public struct TaskRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    // MARK: - 写入

    public func insert(_ task: AITask) throws {
        try db.execute(
            """
            INSERT INTO tasks (
                id, name, goal, status, execution_mode,
                primary_provider, primary_model,
                current_step, total_steps, retry_count, max_retries,
                created_at, updated_at, error_message, error_class,
                waiting_until, plan_type, meta_json
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(task.id),
                .text(task.name),
                .text(task.goal),
                .text(task.status.rawValue),
                .text(task.executionMode.rawValue),
                .text(task.primaryProvider),
                .text(task.primaryModel),
                .int(task.currentStep),
                .int(task.totalSteps),
                .int(task.retryCount),
                .int(task.maxRetries),
                .text(DateCoding.string(from: task.createdAt)),
                .text(DateCoding.string(from: task.updatedAt)),
                task.errorMessage.map { SQLValue.text($0) } ?? .null,
                task.errorClass.map { SQLValue.text($0) } ?? .null,
                task.waitingUntil.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                .text(task.planType),
                .text((try? JSONCoding.encodeToString(task.meta)) ?? "{}"),
            ]
        )
    }

    /// 全量更新可变字段 (不改 id / created_at)。
    public func update(_ task: AITask) throws {
        try db.execute(
            """
            UPDATE tasks SET
                name = ?, goal = ?, status = ?, execution_mode = ?,
                primary_provider = ?, primary_model = ?,
                current_step = ?, total_steps = ?,
                retry_count = ?, max_retries = ?,
                updated_at = ?, error_message = ?, error_class = ?,
                waiting_until = ?, plan_type = ?, meta_json = ?
            WHERE id = ?
            """,
            [
                .text(task.name),
                .text(task.goal),
                .text(task.status.rawValue),
                .text(task.executionMode.rawValue),
                .text(task.primaryProvider),
                .text(task.primaryModel),
                .int(task.currentStep),
                .int(task.totalSteps),
                .int(task.retryCount),
                .int(task.maxRetries),
                .text(DateCoding.string(from: Date())),
                task.errorMessage.map { SQLValue.text($0) } ?? .null,
                task.errorClass.map { SQLValue.text($0) } ?? .null,
                task.waitingUntil.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                .text(task.planType),
                .text((try? JSONCoding.encodeToString(task.meta)) ?? "{}"),
                .text(task.id),
            ]
        )
    }

    /// 带合法迁移校验的状态更新。
    ///
    /// 校验存在的意义: 阻止"已完成的任务被 Resume"这类会把 checkpoint 推进逻辑
    /// 搞乱的非法迁移 —— 一旦状态机被绕过, 续跑语义就不再可信。
    @discardableResult
    public func updateStatus(
        id: String,
        to newStatus: TaskStatus,
        errorMessage: String? = nil,
        errorClass: String? = nil,
        waitingUntil: Date? = nil
    ) throws -> AITask {
        guard let current = try fetch(id: id) else {
            throw AppError.database("任务不存在: \(id)")
        }
        guard current.status.canTransition(to: newStatus) else {
            throw AppError.database(
                "非法状态迁移: \(current.status.rawValue) -> \(newStatus.rawValue) (task=\(id))"
            )
        }

        try db.execute(
            """
            UPDATE tasks SET
                status = ?, updated_at = ?,
                error_message = ?, error_class = ?, waiting_until = ?
            WHERE id = ?
            """,
            [
                .text(newStatus.rawValue),
                .text(DateCoding.string(from: Date())),
                errorMessage.map { SQLValue.text($0) } ?? .null,
                errorClass.map { SQLValue.text($0) } ?? .null,
                waitingUntil.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                .text(id),
            ]
        )

        guard let updated = try fetch(id: id) else {
            throw AppError.database("状态更新后无法重新读取任务: \(id)")
        }
        return updated
    }

    /// 只改跨状态共享的字段 (进度 / 重试计数 / 错误信息)。
    public func updateProgress(
        id: String,
        currentStep: Int? = nil,
        retryCount: Int? = nil,
        errorMessage: String? = nil,
        errorClass: String? = nil
    ) throws {
        var sets: [String] = ["updated_at = ?"]
        var params: [SQLValue] = [.text(DateCoding.string(from: Date()))]

        if let currentStep {
            sets.append("current_step = ?")
            params.append(.int(currentStep))
        }
        if let retryCount {
            sets.append("retry_count = ?")
            params.append(.int(retryCount))
        }
        if let errorMessage {
            sets.append("error_message = ?")
            params.append(.text(errorMessage))
        }
        if let errorClass {
            sets.append("error_class = ?")
            params.append(.text(errorClass))
        }

        params.append(.text(id))
        try db.execute("UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id = ?", params)
    }

    public func delete(id: String) throws {
        // task_steps / checkpoints 通过 ON DELETE CASCADE 一并删除
        try db.execute("DELETE FROM tasks WHERE id = ?", [.text(id)])
    }

    // MARK: - 读取

    public func fetch(id: String) throws -> AITask? {
        guard let row = try db.queryOne("SELECT * FROM tasks WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try Self.decode(row)
    }

    public func fetchAll(status: TaskStatus? = nil, limit: Int = 500) throws -> [AITask] {
        let rows: [SQLRow]
        if let status {
            rows = try db.query(
                "SELECT * FROM tasks WHERE status = ? ORDER BY created_at DESC LIMIT ?",
                [.text(status.rawValue), .int(limit)]
            )
        } else {
            rows = try db.query(
                "SELECT * FROM tasks ORDER BY created_at DESC LIMIT ?",
                [.int(limit)]
            )
        }
        return try rows.map { try Self.decode($0) }
    }

    /// 所有"非终态"任务 —— 启动时决定哪些需要恢复。
    public func fetchUnfinished() throws -> [AITask] {
        try db.query(
            "SELECT * FROM tasks WHERE status NOT IN ('completed','failed','cancelled') ORDER BY created_at ASC"
        ).map { try Self.decode($0) }
    }

    public func statusCounts() throws -> [TaskStatus: Int] {
        let rows = try db.query(
            "SELECT status, COUNT(*) AS n FROM tasks GROUP BY status"
        )
        var result: [TaskStatus: Int] = [:]
        for row in rows {
            guard let s = row.string("status"), let status = TaskStatus(rawValue: s) else { continue }
            result[status] = row.int("n") ?? 0
        }
        return result
    }

    public func count() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM tasks") ?? 0
    }

    // MARK: - 行解码

    static func decode(_ row: SQLRow) throws -> AITask {
        let rawStatus = try row.requireString("status")
        let status = TaskStatus(rawValue: rawStatus) ?? .failed
        let created = row.date("created_at") ?? Date()
        let updated = row.date("updated_at") ?? created

        return AITask(
            id: try row.requireString("id"),
            name: try row.requireString("name"),
            goal: try row.requireString("goal"),
            status: status,
            executionMode: ExecutionMode(rawValue: row.string("execution_mode") ?? "")
                ?? .chatGPTWeb,
            primaryProvider: row.string("primary_provider") ?? "",
            primaryModel: try row.requireString("primary_model"),
            currentStep: row.int("current_step") ?? 0,
            totalSteps: row.int("total_steps") ?? 0,
            retryCount: row.int("retry_count") ?? 0,
            maxRetries: row.int("max_retries") ?? 8,
            createdAt: created,
            updatedAt: updated,
            errorMessage: row.string("error_message"),
            errorClass: row.string("error_class"),
            waitingUntil: row.date("waiting_until"),
            planType: row.string("plan_type") ?? "uniform",
            meta: row.json("meta_json") ?? .emptyObject
        )
    }
}

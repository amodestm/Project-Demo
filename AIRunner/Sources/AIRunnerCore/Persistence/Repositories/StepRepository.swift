import Foundation

/// 一次"成功步骤"的原子提交载荷。
public struct SuccessfulStepCommit: Sendable {
    public var stepID: String
    public var taskID: String
    public var output: JSONValue
    public var provider: String
    public var model: String
    public var durationMs: Int
    /// 本步成功后要写入的检查点。
    public var checkpoint: Checkpoint
    /// 任务新的 current_step。
    public var newCurrentStep: Int

    /// 允许被提交的**前置状态** —— 即 CAS (Compare-And-Swap) 的期望值。
    ///
    /// * Web 通道只应是 `[.prepared]`
    /// * API 通道只应是 `[.running]`
    ///
    /// 默认值是两者的并集, 仅为让既有的底层调用点保持兼容;
    /// 两条通道的正式入口是 `commitPreparedWebStep` / `commitRunningAPIStep`,
    /// 它们会强制传入各自唯一合法的前置状态。
    public var expectedStatuses: Set<StepStatus>

    public init(
        stepID: String,
        taskID: String,
        output: JSONValue,
        provider: String,
        model: String,
        durationMs: Int,
        checkpoint: Checkpoint,
        newCurrentStep: Int,
        expectedStatuses: Set<StepStatus> = [.running, .prepared]
    ) {
        self.stepID = stepID
        self.taskID = taskID
        self.output = output
        self.provider = provider
        self.model = model
        self.durationMs = durationMs
        self.checkpoint = checkpoint
        self.newCurrentStep = newCurrentStep
        self.expectedStatuses = expectedStatuses
    }
}

/// 步骤表访问 + 原子提交。
public struct StepRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    // MARK: - 批量插入

    /// 批量插入步骤。已存在的 (task_id, step_index) 会被**忽略**
    /// (`INSERT OR IGNORE` + UNIQUE 索引), 因此重复调用是幂等的,
    /// 不会打乱已有进度、也不会因为唯一约束失败而炸掉整个事务。
    @discardableResult
    public func insertBatch(_ steps: [TaskStep]) throws -> Int {
        guard !steps.isEmpty else { return 0 }
        var inserted = 0
        try db.transaction {
            for step in steps {
                try db.execute(
                    """
                    INSERT OR IGNORE INTO task_steps (
                        id, task_id, step_index, type, status,
                        input_json, output_json, provider, model,
                        retry_count, started_at, finished_at, created_at,
                        last_error, error_class, duration_ms, attempt_log_json,
                        prepared_at, submitted_at
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    [
                        .text(step.id),
                        .text(step.taskID),
                        .int(step.index),
                        .text(step.type.rawValue),
                        .text(step.status.rawValue),
                        .text((try? JSONCoding.encodeToString(step.input)) ?? "{}"),
                        step.output.map { SQLValue.text((try? JSONCoding.encodeToString($0)) ?? "null") } ?? .null,
                        step.provider.map { SQLValue.text($0) } ?? .null,
                        step.model.map { SQLValue.text($0) } ?? .null,
                        .int(step.retryCount),
                        step.startedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                        step.finishedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                        .text(DateCoding.string(from: step.createdAt)),
                        step.lastError.map { SQLValue.text($0) } ?? .null,
                        step.errorClass.map { SQLValue.text($0) } ?? .null,
                        .int(step.durationMs),
                        .text((try? JSONCoding.encodeToString(JSONValue.array(step.attemptLog))) ?? "[]"),
                        step.preparedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                        step.submittedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                    ]
                )
                if db.lastInsertRowID() != 0 { inserted += 1 }
            }
        }
        return inserted
    }

    // MARK: - 读取

    public func fetch(id: String) throws -> TaskStep? {
        guard let row = try db.queryOne("SELECT * FROM task_steps WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try Self.decode(row)
    }

    public func fetch(taskID: String, index: Int) throws -> TaskStep? {
        guard let row = try db.queryOne(
            "SELECT * FROM task_steps WHERE task_id = ? AND step_index = ?",
            [.text(taskID), .int(index)]
        ) else { return nil }
        return try Self.decode(row)
    }

    public func fetchAll(taskID: String) throws -> [TaskStep] {
        try db.query(
            "SELECT * FROM task_steps WHERE task_id = ? ORDER BY step_index ASC",
            [.text(taskID)]
        ).map { try Self.decode($0) }
    }

    /// ★ 幂等性核心查询 ★
    ///
    /// 只返回 `pending` / `interrupted` / `prepared` 的步骤。
    /// **completed / failed / skipped 永远不会出现在结果里** ——
    /// 这就是"已完成的步骤绝不重跑"的实现方式: 不靠调用方自觉判断,
    /// 而是让查询本身取不到已完成的行。
    ///
    /// `prepared` 也必须可执行: Web 模式下 prompt 已生成但结果未回填时若 App 崩溃,
    /// 该步骤必须能被重新取走 (prompt 是纯函数生成的, 重新生成结果相同)。
    public func nextExecutableStep(taskID: String) throws -> TaskStep? {
        let rows = try db.query(
            """
            SELECT * FROM task_steps
             WHERE task_id = ?
               AND status IN ('pending','interrupted','prepared')
             ORDER BY step_index ASC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// 取当前正在等待用户回填结果的那个步骤 (Web 模式)。
    public func awaitingResultStep(taskID: String) throws -> TaskStep? {
        let rows = try db.query(
            """
            SELECT * FROM task_steps
             WHERE task_id = ? AND status = 'prepared'
             ORDER BY step_index ASC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// 只取已完成步骤的下标 (不搬运整行), 供续跑 prompt 生成使用。
    ///
    /// 一个 300~3000 步的任务每次都要列已完成范围, 用整行 `fetchAll` 会造成
    /// 无谓的 JSON 解析开销。
    public func completedIndexes(taskID: String) throws -> [Int] {
        try db.query(
            """
            SELECT step_index FROM task_steps
             WHERE task_id = ? AND status = 'completed'
             ORDER BY step_index ASC
            """,
            [.text(taskID)]
        ).compactMap { $0.int("step_index") }
    }

    public func statusCounts(taskID: String) throws -> [StepStatus: Int] {
        let rows = try db.query(
            "SELECT status, COUNT(*) AS n FROM task_steps WHERE task_id = ? GROUP BY status",
            [.text(taskID)]
        )
        var result: [StepStatus: Int] = [:]
        for row in rows {
            guard let s = row.string("status"), let st = StepStatus(rawValue: s) else { continue }
            result[st] = row.int("n") ?? 0
        }
        return result
    }

    public func count(taskID: String) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM task_steps WHERE task_id = ?", [.text(taskID)]) ?? 0
    }

    // MARK: - 状态变更

    public func markRunning(stepID: String, provider: String?, model: String?) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'running',
                started_at = ?,
                provider = COALESCE(?, provider),
                model = COALESCE(?, model),
                last_error = NULL,
                error_class = NULL
            WHERE id = ?
            """,
            [
                .text(DateCoding.string(from: Date())),
                provider.map { SQLValue.text($0) } ?? .null,
                model.map { SQLValue.text($0) } ?? .null,
                .text(stepID),
            ]
        )
    }

    // MARK: - Web 模式状态

    /// 标记步骤为 `prepared`: 续跑 prompt 已生成并交付给用户。
    ///
    /// 幂等 —— 重复调用只刷新时间戳。这正是"崩溃后重新生成相同 prompt"的落点:
    /// 步骤可以被重新取走, `ContinuationPromptBuilder` 用同样的输入产出同样的文本。
    public func markPrepared(stepID: String) throws {
        let now = DateCoding.string(from: Date())
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'prepared',
                prepared_at = ?,
                started_at = COALESCE(started_at, ?),
                last_error = NULL,
                error_class = NULL
            WHERE id = ?
            """,
            [.text(now), .text(now), .text(stepID)]
        )
    }

    /// 记录用户已把 prompt 提交给 ChatGPT (仅用于审计与 UI 提示)。
    public func markSubmitted(stepID: String) throws {
        try db.execute(
            "UPDATE task_steps SET submitted_at = ? WHERE id = ?",
            [.text(DateCoding.string(from: Date())), .text(stepID)]
        )
    }

    /// 丢弃已生成的 prompt, 把步骤退回 `pending`。
    /// 用于"用户觉得这个 prompt 不对, 想重新生成"。
    public func clearPrepared(stepID: String) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'pending', prepared_at = NULL, submitted_at = NULL
            WHERE id = ? AND status = 'prepared'
            """,
            [.text(stepID)]
        )
    }

    /// 把 running 的步骤退回 pending (重试前 / 崩溃恢复时使用)。
    public func markPending(stepID: String, error: String? = nil, errorClass: String? = nil) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'pending',
                started_at = NULL,
                last_error = ?,
                error_class = ?,
                provider = provider,
                model = model
            WHERE id = ?
            """,
            [
                error.map { SQLValue.text($0) } ?? .null,
                errorClass.map { SQLValue.text($0) } ?? .null,
                .text(stepID),
            ]
        )
    }

    public func markFailed(stepID: String, error: String, errorClass: String, durationMs: Int = 0) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'failed', last_error = ?, error_class = ?,
                finished_at = ?, duration_ms = ?
            WHERE id = ?
            """,
            [
                .text(error),
                .text(errorClass),
                .text(DateCoding.string(from: Date())),
                .int(durationMs),
                .text(stepID),
            ]
        )
    }

    public func markSkipped(stepID: String, reason: String) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'skipped', last_error = ?, finished_at = ?
            WHERE id = ?
            """,
            [.text(reason), .text(DateCoding.string(from: Date())), .text(stepID)]
        )
    }

    /// 崩溃恢复: 把所有处于 `running` 的步骤标记为 `interrupted`。
    ///
    /// 这些步骤的特征是"已经开始执行, 但对应的 checkpoint 从未提交" ——
    /// 即进程在 HTTP 请求途中被杀。它们的输出不可信, 必须重跑。
    ///
    /// 之所以标记为 `interrupted` 而不是直接改回 `pending`, 是为了在 UI 与审计里
    /// 留下"这一步曾被打断"的痕迹。`nextExecutableStep` 同样把 `interrupted`
    /// 视为可执行, 因此恢复后能自动接上。
    ///
    /// - Returns: 被标记的步骤数量。
    @discardableResult
    public func markRunningInterrupted(taskID: String? = nil) throws -> Int {
        var sql = """
            UPDATE task_steps SET
                status = 'interrupted',
                last_error = '进程中断: 该步骤未提交结果, 恢复后将重新执行',
                error_class = 'INTERRUPTED'
            WHERE status = 'running'
            """
        if taskID != nil {
            sql += " AND task_id = ?"
        }

        return try db.transaction {
            if let taskID {
                try db.execute(sql, [.text(taskID)])
            } else {
                try db.execute(sql)
            }
            return try db.scalarInt("SELECT changes()") ?? 0
        }
    }

    /// 统计失败步骤数。
    public func failedCount(taskID: String) throws -> Int {
        try db.scalarInt(
            "SELECT COUNT(*) FROM task_steps WHERE task_id = ? AND status = 'failed'",
            [.text(taskID)]
        ) ?? 0
    }

    /// 第一个失败的步骤 (按 index 升序)。
    ///
    /// 崩溃恢复时用它判断"任务里是否卡着一个失败步骤" —— 存在的话**不能**继续
    /// 往后跑 pending 步骤, 否则结果会建立在缺失的前置输入上。
    public func firstFailedStep(taskID: String) throws -> TaskStep? {
        let rows = try db.query(
            """
            SELECT * FROM task_steps
             WHERE task_id = ? AND status = 'failed'
             ORDER BY step_index ASC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// 把所有 `failed` 步骤重置为 `pending` —— 「重试失败步骤」的实现。
    ///
    /// - Returns: 被重置的步骤数量。
    @discardableResult
    public func resetFailedSteps(taskID: String) throws -> Int {
        try db.transaction {
            try db.execute(
                """
                UPDATE task_steps SET
                    status = 'pending',
                    last_error = NULL,
                    error_class = NULL,
                    started_at = NULL,
                    finished_at = NULL
                WHERE task_id = ? AND status = 'failed'
                """,
                [.text(taskID)]
            )
            return try db.scalarInt("SELECT changes()") ?? 0
        }
    }

    /// 统计还能继续执行的步骤数。
    public func executableCount(taskID: String) throws -> Int {
        try db.scalarInt(
            """
            SELECT COUNT(*) FROM task_steps
             WHERE task_id = ? AND status IN ('pending','interrupted','prepared')
            """,
            [.text(taskID)]
        ) ?? 0
    }

    /// 追加一条失败尝试的审计记录, 并 retry_count += 1。
    /// 读-改-写在同一事务内完成, 避免并发追加时丢失记录。
    public func appendAttempt(stepID: String, attempt: JSONValue, bumpRetry: Bool = true) throws {
        try db.transaction {
            let existing: JSONValue
            if let row = try db.queryOne(
                "SELECT attempt_log_json FROM task_steps WHERE id = ?", [.text(stepID)]
            ), let parsed = row.json("attempt_log_json") {
                existing = parsed
            } else {
                existing = .emptyArray
            }
            var list = existing.arrayValue ?? []
            list.append(attempt)

            let json = (try? JSONCoding.encodeToString(JSONValue.array(list))) ?? "[]"
            if bumpRetry {
                try db.execute(
                    "UPDATE task_steps SET attempt_log_json = ?, retry_count = retry_count + 1 WHERE id = ?",
                    [.text(json), .text(stepID)]
                )
            } else {
                try db.execute(
                    "UPDATE task_steps SET attempt_log_json = ? WHERE id = ?",
                    [.text(json), .text(stepID)]
                )
            }
        }
    }

    /// 记录本次选中并尝试过的 backend (不增加 retry 计数)。
    public func recordBackendAttempt(stepID: String, provider: String, model: String, note: String?) throws {
        let attempt = JSONValue.object([
            "kind": .string("backend_attempt"),
            "provider": .string(provider),
            "model": .string(model),
            "note": note.map { JSONValue.string($0) } ?? .null,
            "at": .string(DateCoding.string(from: Date())),
        ])
        try appendAttempt(stepID: stepID, attempt: attempt, bumpRetry: false)
    }

    // MARK: - ★ 原子提交 ★

    /// 在**单个事务**内完成三件事:
    ///
    /// 1. `task_steps` 标记 completed 并写入输出
    /// 2. 插入新的 `checkpoints` 记录
    /// 3. 推进 `tasks.current_step`
    ///
    /// 三者要么全成功, 要么全回滚。
    ///
    /// 这是整个项目最重要的一段代码。若把这三步拆成三个独立事务, 进程在
    /// 任意两写之间被 kill 都会留下一致性裂痕 —— 例如"步骤已完成但 checkpoint
    /// 没推进", 重启后会重复执行该步骤, 甚至产生错误的进度显示。
    public func commitSuccessfulStep(_ commit: SuccessfulStepCommit) throws {
        let now = DateCoding.string(from: Date())

        guard !commit.expectedStatuses.isEmpty else {
            throw AppError.invalidRequest("expectedStatuses 不能为空 —— 否则 CAS 形同虚设")
        }

        try db.transaction {

            // ---- 0) 顺序不变量校验 ----
            //
            // 只允许"提交任务当前的下一步"。这同时挡住了两类错误:
            //   * 过期 / 重复的提交把进度推回去 (currentStep > stepIndex)
            //   * 跳步提交 (currentStep < stepIndex)
            //
            // 这里刻意**不用** MAX() 静默掩盖 —— 一旦不一致就整体回滚并明确报错,
            // 因为不一致本身说明上层逻辑已经出问题了, 掩盖只会让问题后移。
            guard let taskRow = try db.queryOne(
                "SELECT current_step FROM tasks WHERE id = ?",
                [.text(commit.taskID)]
            ), let currentStep = taskRow.int("current_step") else {
                throw AppError.database("任务不存在: \(commit.taskID)")
            }

            guard let stepRow = try db.queryOne(
                "SELECT step_index, status FROM task_steps WHERE id = ? AND task_id = ?",
                [.text(commit.stepID), .text(commit.taskID)]
            ), let stepIndex = stepRow.int("step_index") else {
                throw AppError.database("步骤不存在或不属于该任务: \(commit.stepID)")
            }

            let actualStatus = stepRow.string("status") ?? "?"

            guard commit.newCurrentStep == stepIndex + 1 else {
                throw AppError.database(
                    "提交不自洽: newCurrentStep=\(commit.newCurrentStep), 但该步骤 index=\(stepIndex)。"
                    + "拒绝写入以避免进度错乱。"
                )
            }

            guard currentStep == stepIndex else {
                throw AppError.concurrentModification(
                    "任务进度为 \(currentStep), 但本次要提交的是第 \(stepIndex + 1) 步。"
                    + "这可能是一次重复或过期的提交。"
                )
            }

            // ---- 1) CAS: 只有处于期望状态的步骤才能被标记完成 ----
            let allowed = commit.expectedStatuses.map(\.rawValue).sorted()
            let placeholders = Array(repeating: "?", count: allowed.count).joined(separator: ",")

            try db.execute(
                """
                UPDATE task_steps SET
                    status = 'completed',
                    output_json = ?,
                    provider = ?,
                    model = ?,
                    finished_at = ?,
                    duration_ms = ?,
                    last_error = NULL,
                    error_class = NULL
                WHERE id = ? AND task_id = ? AND status IN (\(placeholders))
                """,
                [
                    .text((try? JSONCoding.encodeToString(commit.output)) ?? "null"),
                    .text(commit.provider),
                    .text(commit.model),
                    .text(now),
                    .int(commit.durationMs),
                    .text(commit.stepID),
                    .text(commit.taskID),
                ] + allowed.map { SQLValue.text($0) }
            )

            // changed 必须恰好为 1。0 表示状态不匹配 (stale / duplicate 提交)。
            let changed = try db.scalarInt("SELECT changes()") ?? 0
            guard changed == 1 else {
                throw AppError.concurrentModification(
                    "步骤 \(stepIndex + 1) 不处于可提交状态 "
                    + "(期望 \(allowed.joined(separator: "/")), 实际 \(actualStatus))。"
                    + "本次提交已回滚, 不会生成新检查点。"
                )
            }

            // ---- 2) 写入检查点 ----
            try db.execute(
                """
                INSERT INTO checkpoints (
                    id, task_id, completed_step, next_step,
                    working_summary, state_json, created_at
                ) VALUES (?,?,?,?,?,?,?)
                """,
                [
                    .text(commit.checkpoint.id),
                    .text(commit.checkpoint.taskID),
                    .int(commit.checkpoint.completedStep),
                    .int(commit.checkpoint.nextStep),
                    commit.checkpoint.workingSummary.map { SQLValue.text($0) } ?? .null,
                    .text((try? JSONCoding.encodeToString(commit.checkpoint.state)) ?? "{}"),
                    .text(DateCoding.string(from: commit.checkpoint.createdAt)),
                ]
            )

            // ---- 3) 推进任务进度, 并清掉上一次的错误标记 ----
            try db.execute(
                """
                UPDATE tasks SET
                    current_step = ?,
                    updated_at = ?,
                    error_message = NULL,
                    error_class = NULL
                WHERE id = ?
                """,
                [.int(commit.newCurrentStep), .text(now), .text(commit.taskID)]
            )
        }
    }

    // MARK: - 两条通道的正式提交入口

    /// Web 通道专用: 前置状态**必须**是 `prepared`。
    ///
    /// 让调用方无法"忘记"校验 —— 状态约束被固化在入口里。
    public func commitPreparedWebStep(_ commit: SuccessfulStepCommit) throws {
        var strict = commit
        strict.expectedStatuses = [.prepared]
        try commitSuccessfulStep(strict)
    }

    /// API 通道专用: 前置状态**必须**是 `running`。
    public func commitRunningAPIStep(_ commit: SuccessfulStepCommit) throws {
        var strict = commit
        strict.expectedStatuses = [.running]
        try commitSuccessfulStep(strict)
    }

    // MARK: - 行解码

    static func decode(_ row: SQLRow) throws -> TaskStep {
        let rawStatus = row.string("status") ?? StepStatus.pending.rawValue
        let status = StepStatus(rawValue: rawStatus) ?? .pending
        let rawType = row.string("type") ?? StepType.llm.rawValue
        let type = StepType(rawValue: rawType) ?? .llm

        let attemptList: [JSONValue]
        if let arr = row.json("attempt_log_json")?.arrayValue {
            attemptList = arr
        } else {
            attemptList = []
        }

        return TaskStep(
            id: try row.requireString("id"),
            taskID: try row.requireString("task_id"),
            index: try row.requireInt("step_index"),
            type: type,
            status: status,
            input: row.json("input_json") ?? .emptyObject,
            output: row.json("output_json"),
            provider: row.string("provider"),
            model: row.string("model"),
            retryCount: row.int("retry_count") ?? 0,
            startedAt: row.date("started_at"),
            finishedAt: row.date("finished_at"),
            createdAt: row.date("created_at") ?? Date(),
            lastError: row.string("last_error"),
            errorClass: row.string("error_class"),
            durationMs: row.int("duration_ms") ?? 0,
            attemptLog: attemptList,
            preparedAt: row.date("prepared_at"),
            submittedAt: row.date("submitted_at")
        )
    }
}

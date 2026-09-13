import Foundation

/// Codex 线程绑定表访问。
public struct CodexTaskBindingRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    // MARK: - 写入

    public func insert(_ binding: CodexTaskBinding) throws {
        try db.execute(
            """
            INSERT INTO codex_task_bindings (
                id, task_id,
                display_title, project_name, repository_path, worktree_path,
                application_bundle_identifier, application_name, window_title_hint,
                chrome_profile_directory,
                fingerprint_json, resume_message, preferred_model_id, reasoning_effort,
                last_verified_at, last_resume_sent_at,
                created_at, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(binding.id),
                binding.taskID.map { SQLValue.text($0) } ?? .null,
                .text(binding.displayTitle),
                binding.projectName.map { SQLValue.text($0) } ?? .null,
                binding.repositoryPath.map { SQLValue.text($0) } ?? .null,
                binding.worktreePath.map { SQLValue.text($0) } ?? .null,
                .text(binding.applicationBundleIdentifier),
                binding.applicationName.map { SQLValue.text($0) } ?? .null,
                binding.windowTitleHint.map { SQLValue.text($0) } ?? .null,
                binding.chromeProfileDirectory.map { SQLValue.text($0) } ?? .null,
                .text((try? JSONCoding.encodeToString(binding.fingerprint)) ?? "{}"),
                .text(binding.resumeMessage),
                binding.executionPreference.map { .text($0.modelID) } ?? .null,
                binding.executionPreference.map { .text($0.reasoningEffort.rawValue) } ?? .null,
                binding.lastVerifiedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                binding.lastResumeSentAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                .text(DateCoding.string(from: binding.createdAt)),
                .text(DateCoding.string(from: binding.updatedAt)),
            ]
        )
    }

    public func update(_ binding: CodexTaskBinding) throws {
        try db.execute(
            """
            UPDATE codex_task_bindings SET
                task_id = ?,
                display_title = ?, project_name = ?, repository_path = ?, worktree_path = ?,
                application_bundle_identifier = ?, application_name = ?, window_title_hint = ?,
                chrome_profile_directory = ?,
                fingerprint_json = ?, resume_message = ?,
                preferred_model_id = ?, reasoning_effort = ?,
                updated_at = ?
            WHERE id = ?
            """,
            [
                binding.taskID.map { SQLValue.text($0) } ?? .null,
                .text(binding.displayTitle),
                binding.projectName.map { SQLValue.text($0) } ?? .null,
                binding.repositoryPath.map { SQLValue.text($0) } ?? .null,
                binding.worktreePath.map { SQLValue.text($0) } ?? .null,
                .text(binding.applicationBundleIdentifier),
                binding.applicationName.map { SQLValue.text($0) } ?? .null,
                binding.windowTitleHint.map { SQLValue.text($0) } ?? .null,
                binding.chromeProfileDirectory.map { SQLValue.text($0) } ?? .null,
                .text((try? JSONCoding.encodeToString(binding.fingerprint)) ?? "{}"),
                .text(binding.resumeMessage),
                binding.executionPreference.map { .text($0.modelID) } ?? .null,
                binding.executionPreference.map { .text($0.reasoningEffort.rawValue) } ?? .null,
                .text(DateCoding.string(from: Date())),
                .text(binding.id),
            ]
        )
    }

    /// 记录一次成功的验证 (Test Locate / Dry Run / Resume 都会调用)。
    public func markVerified(bindingID: String, at date: Date = Date()) throws {
        try db.execute(
            """
            UPDATE codex_task_bindings SET last_verified_at = ?, updated_at = ?
            WHERE id = ?
            """,
            [
                .text(DateCoding.string(from: date)),
                .text(DateCoding.string(from: date)),
                .text(bindingID),
            ]
        )
    }

    /// 记录一次已发送。**这是 60 秒冷却的唯一依据。**
    public func markResumeSent(bindingID: String, at date: Date = Date()) throws {
        try db.execute(
            """
            UPDATE codex_task_bindings SET last_resume_sent_at = ?, updated_at = ?
            WHERE id = ?
            """,
            [
                .text(DateCoding.string(from: date)),
                .text(DateCoding.string(from: date)),
                .text(bindingID),
            ]
        )
    }

    public func delete(id: String) throws {
        try db.execute("DELETE FROM codex_task_bindings WHERE id = ?", [.text(id)])
    }

    // MARK: - 读取

    public func fetch(id: String) throws -> CodexTaskBinding? {
        guard let row = try db.queryOne(
            "SELECT * FROM codex_task_bindings WHERE id = ?", [.text(id)]
        ) else { return nil }
        return try Self.decode(row)
    }

    /// 按 AIRunner 任务查绑定。一个任务当前只允许有一个绑定, 取最新的那个。
    public func fetchByTask(taskID: String) throws -> CodexTaskBinding? {
        let rows = try db.query(
            """
            SELECT * FROM codex_task_bindings
             WHERE task_id = ?
             ORDER BY updated_at DESC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    public func fetchAll() throws -> [CodexTaskBinding] {
        try db.query(
            "SELECT * FROM codex_task_bindings ORDER BY updated_at DESC"
        ).map { try Self.decode($0) }
    }

    /// 所有"还挂在非终态任务上"的绑定 —— App 启动时用来恢复 Monitor。
    public func fetchAttachedToUnfinishedTasks() throws -> [CodexTaskBinding] {
        try db.query(
            """
            SELECT b.* FROM codex_task_bindings b
              JOIN tasks t ON t.id = b.task_id
             WHERE t.status NOT IN ('completed','failed','cancelled')
             ORDER BY b.updated_at DESC
            """
        ).map { try Self.decode($0) }
    }

    public func count() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM codex_task_bindings") ?? 0
    }

    // MARK: - 解码

    static func decode(_ row: SQLRow) throws -> CodexTaskBinding {
        // 直接用原始 JSON 字符串解码 —— 不走 JSONValue 中转, 避免无谓的二次序列化。
        let fingerprint: CodexTaskFingerprint = {
            guard let raw = row.string("fingerprint_json"), !raw.isEmpty else {
                return CodexTaskFingerprint()
            }
            return (try? JSONCoding.decode(CodexTaskFingerprint.self, from: raw))
                ?? CodexTaskFingerprint()
        }()

        let executionPreference: CodexExecutionPreference? = {
            guard let modelID = row.string("preferred_model_id"),
                  let rawEffort = row.string("reasoning_effort"),
                  let effort = CodexReasoningEffort(rawValue: rawEffort) else { return nil }
            return CodexExecutionPreference(modelID: modelID, reasoningEffort: effort)
        }()

        return CodexTaskBinding(
            id: try row.requireString("id"),
            taskID: row.string("task_id"),
            displayTitle: try row.requireString("display_title"),
            projectName: row.string("project_name"),
            repositoryPath: row.string("repository_path"),
            worktreePath: row.string("worktree_path"),
            applicationBundleIdentifier: try row.requireString("application_bundle_identifier"),
            applicationName: row.string("application_name"),
            windowTitleHint: row.string("window_title_hint"),
            chromeProfileDirectory: row.string("chrome_profile_directory"),
            fingerprint: fingerprint,
            resumeMessage: row.string("resume_message") ?? "继续",
            executionPreference: executionPreference,
            lastVerifiedAt: row.date("last_verified_at"),
            lastResumeSentAt: row.date("last_resume_sent_at"),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }
}

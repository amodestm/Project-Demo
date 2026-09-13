import Foundation

/// 数据库迁移。
///
/// 用 `PRAGMA user_version` 做版本追踪。每次迁移在**单个事务**内完成:
/// 要么整版建好, 要么完全不改 —— 避免"建了一半"的半损坏 schema。
public enum DatabaseMigrator {

    /// 当前 schema 版本。
    ///
    /// ★ 每个 migration 只允许把自己推进到**自己的**版本号 ★
    /// 详见 `migrateToV1` 的注释。
    public static let currentVersion = 7

    public static func migrate(_ db: Database) throws {
        let existing = try db.scalarInt("PRAGMA user_version;") ?? 0

        if existing > currentVersion {
            throw AppError.database(
                "数据库版本 (\(existing)) 高于本程序支持的版本 (\(currentVersion))。"
                + "请升级 AIRunner, 不要用旧版本打开新数据库。"
            )
        }

        if existing < 1 {
            try migrateToV1(db)
        }

        if existing < 2 {
            try migrateToV2(db)
        }

        if existing < 3 {
            try migrateToV3(db)
        }

        if existing < 4 {
            try migrateToV4(db)
        }

        if existing < 5 {
            try migrateToV5(db)
        }

        if existing < 6 {
            try migrateToV6(db)
        }

        if existing < 7 {
            try migrateToV7(db)
        }
    }

    // MARK: - V1

    private static func migrateToV1(_ db: Database) throws {
        try db.transaction {
            for statement in v1Statements {
                try db.execute(statement)
            }
            // ★ 只推进到 1 —— 不是 currentVersion ★
            //
            // 若这里写 currentVersion, V1 跑完版本号就等于最新版了; 之后 V2/V3 万一失败,
            // 下次启动会因为"已是最新版本"而跳过它们, 留下 schema 残缺但版本号很新的库。
            try db.execute("PRAGMA user_version = 1;")
        }
    }

    private static let v1Statements: [String] = [

        // ------------------------------------------------------------------ tasks
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id               TEXT PRIMARY KEY NOT NULL,
            name             TEXT NOT NULL,
            goal             TEXT NOT NULL,

            status           TEXT NOT NULL,

            primary_provider TEXT NOT NULL,
            primary_model    TEXT NOT NULL,

            current_step     INTEGER NOT NULL DEFAULT 0,
            total_steps      INTEGER NOT NULL DEFAULT 0,

            retry_count      INTEGER NOT NULL DEFAULT 0,
            max_retries      INTEGER NOT NULL DEFAULT 8,

            created_at       TEXT NOT NULL,
            updated_at       TEXT NOT NULL,

            -- 扩展字段 (供 UI 展示失败原因 / 等待解除时间)
            error_message    TEXT,
            error_class      TEXT,
            waiting_until    TEXT,
            plan_type        TEXT NOT NULL DEFAULT 'uniform',
            meta_json        TEXT NOT NULL DEFAULT '{}'
        );
        """,

        "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);",
        "CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at DESC);",

        // ------------------------------------------------------------- task_steps
        """
        CREATE TABLE IF NOT EXISTS task_steps (
            id          TEXT PRIMARY KEY NOT NULL,

            task_id     TEXT NOT NULL,

            step_index  INTEGER NOT NULL,

            type        TEXT NOT NULL,

            status      TEXT NOT NULL,

            input_json  TEXT NOT NULL,

            output_json TEXT,

            provider    TEXT,

            model       TEXT,

            retry_count INTEGER NOT NULL DEFAULT 0,

            started_at  TEXT,

            finished_at TEXT,

            created_at  TEXT NOT NULL,

            -- 扩展字段
            last_error       TEXT,
            error_class      TEXT,
            duration_ms      INTEGER NOT NULL DEFAULT 0,
            attempt_log_json TEXT NOT NULL DEFAULT '[]',

            FOREIGN KEY(task_id)
                REFERENCES tasks(id)
                ON DELETE CASCADE
        );
        """,

        // ★ 幂等保证: 同一任务内 step_index 唯一。
        //   即便 plan 被重复生成, 也不会出现两个 index=3 的步骤。
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_task_steps_task_index
            ON task_steps(task_id, step_index);
        """,

        "CREATE INDEX IF NOT EXISTS idx_task_steps_status ON task_steps(task_id, status);",

        // ------------------------------------------------------------ checkpoints
        """
        CREATE TABLE IF NOT EXISTS checkpoints (
            id             TEXT PRIMARY KEY NOT NULL,

            task_id        TEXT NOT NULL,

            completed_step INTEGER NOT NULL,

            next_step      INTEGER NOT NULL,

            working_summary TEXT,

            state_json     TEXT NOT NULL,

            created_at     TEXT NOT NULL,

            FOREIGN KEY(task_id)
                REFERENCES tasks(id)
                ON DELETE CASCADE
        );
        """,

        // 恢复时只需要"最新一条", 这个索引让它变成 O(log n)。
        """
        CREATE INDEX IF NOT EXISTS idx_checkpoints_task_step
            ON checkpoints(task_id, completed_step DESC);
        """,

        // ----------------------------------------------------------------- events
        """
        CREATE TABLE IF NOT EXISTS events (
            id            TEXT PRIMARY KEY NOT NULL,

            task_id       TEXT,

            step_index    INTEGER,

            level         TEXT NOT NULL,

            event_type    TEXT NOT NULL,

            message       TEXT NOT NULL,

            metadata_json TEXT,

            created_at    TEXT NOT NULL
        );
        """,

        "CREATE INDEX IF NOT EXISTS idx_events_task ON events(task_id, created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_events_level ON events(level, created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at DESC);",

        // -------------------------------------------------------- provider_health
        // 熔断状态必须持久化: App 重启后不应立刻去打那个已经余额耗尽的 Provider。
        """
        CREATE TABLE IF NOT EXISTS provider_health (
            provider           TEXT NOT NULL,
            model              TEXT NOT NULL DEFAULT '*',

            state              TEXT NOT NULL,

            consecutive_errors INTEGER NOT NULL DEFAULT 0,

            last_success       TEXT,
            last_failure       TEXT,
            cooldown_until     TEXT,
            reason             TEXT,

            updated_at         TEXT NOT NULL,

            PRIMARY KEY (provider, model)
        );
        """,
    ]

    // MARK: - V2: ChatGPT Web 执行模式

    /// 引入 `execution_mode` 与 Web 步骤时间戳。
    ///
    /// 全部是 `ALTER TABLE ADD COLUMN` + 默认值 —— **非破坏性**迁移:
    /// 已有数据库里的任务、步骤、检查点、日志、Provider 健康记录一条都不动。
    /// 老任务会被默认标记为 `chatgpt_web`，作为兼容通道保留。
    private static func migrateToV2(_ db: Database) throws {
        let additions: [(table: String, column: String, definition: String)] = [
            ("tasks", "execution_mode",
             "TEXT NOT NULL DEFAULT '\(ExecutionMode.chatGPTWeb.rawValue)'"),
            ("task_steps", "prepared_at", "TEXT"),
            ("task_steps", "submitted_at", "TEXT"),
        ]

        try db.transaction {
            for addition in additions {
                // SQLite 的 ADD COLUMN 不是幂等的, 重复执行会报 "duplicate column name"。
                // 先查 table_info 再决定, 保证迁移可重入。
                if try columnExists(db, table: addition.table, column: addition.column) {
                    continue
                }
                try db.execute(
                    "ALTER TABLE \(addition.table) ADD COLUMN \(addition.column) \(addition.definition);"
                )
            }
            // ★ 只推进到 2 ★
            try db.execute("PRAGMA user_version = 2;")
        }
    }

    // MARK: - V3: Codex Existing Thread 绑定

    /// 引入 Codex 长任务绑定表与跨进程 Resume 租约表。
    ///
    /// 同样是**非破坏性**迁移 —— 只新建表, 不触碰任何既有表。
    ///
    /// 这里**不存**任何认证信息: 没有 email / password / cookie / session token /
    /// authentication storage。存的全部是"如何在自己的 UI 里重新找到那个线程"
    /// 的可重建定位信息。
    private static func migrateToV3(_ db: Database) throws {
        try db.transaction {
            for statement in v3Statements {
                try db.execute(statement)
            }
            try db.execute("PRAGMA user_version = 3;")
        }
    }

    private static let v3Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS codex_task_bindings (
            id                            TEXT PRIMARY KEY NOT NULL,
            task_id                       TEXT,

            display_title                 TEXT NOT NULL,
            project_name                  TEXT,
            repository_path               TEXT,
            worktree_path                 TEXT,

            application_bundle_identifier TEXT NOT NULL,
            application_name              TEXT,
            window_title_hint             TEXT,

            fingerprint_json              TEXT NOT NULL,
            resume_message                TEXT NOT NULL DEFAULT '继续',

            last_verified_at              TEXT,
            last_resume_sent_at           TEXT,

            created_at                    TEXT NOT NULL,
            updated_at                    TEXT NOT NULL,

            FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE SET NULL
        );
        """,

        """
        CREATE INDEX IF NOT EXISTS idx_codex_bindings_task
            ON codex_task_bindings(task_id);
        """,

        // 跨进程 Resume 租约。
        //
        // 不能只用 actor 内存状态防重复 —— 用户可能同时开着两个 AIRunner 实例,
        // 或者上次发送途中 App 异常退出。binding_id 作为主键天然保证"一个 binding 一行",
        // claim 在 SQLite 事务里完成, 因此两个进程只会有一个成功。
        """
        CREATE TABLE IF NOT EXISTS codex_resume_leases (
            binding_id  TEXT PRIMARY KEY NOT NULL,
            owner_id    TEXT NOT NULL,
            acquired_at TEXT NOT NULL,
            expires_at  TEXT NOT NULL
        );
        """,

        """
        CREATE INDEX IF NOT EXISTS idx_codex_leases_expiry
            ON codex_resume_leases(expires_at);
        """,
    ]

    // MARK: - V4

    /// V4: Codex 绑定支持 Chrome Profile —— 自动账号轮换的落点。
    ///
    /// `chrome_profile_directory` 存的是 Chrome 的 profile 目录名 (如 "Profile 1"),
    /// **不是任何凭据**。用户在该 profile 里已登录, 切换 = 用该 profile 打开 ChatGPT。
    private static func migrateToV4(_ db: Database) throws {
        try db.transaction {
            if try !columnExists(db, table: "codex_task_bindings", column: "chrome_profile_directory") {
                try db.execute(
                    "ALTER TABLE codex_task_bindings ADD COLUMN chrome_profile_directory TEXT;"
                )
            }

            // 账号轮换状态: 每个任务当前使用的 Chrome profile。
            // 存的是**目录名** (公开信息), 不含任何凭据。
            try db.execute(
                """
                CREATE TABLE IF NOT EXISTS account_rotation_state (
                    task_id             TEXT PRIMARY KEY NOT NULL,
                    current_profile     TEXT,
                    rotation_count      INTEGER NOT NULL DEFAULT 0,
                    last_rotated_at     TEXT,
                    FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
                );
                """
            )

            try db.execute("PRAGMA user_version = 4;")
        }
    }

    // MARK: - V5

    /// V5: ChatGPT **网页内**账号切换 —— 记录每个任务当前使用的 ChatGPT 账号。
    ///
    /// 存的是账号显示名/邮箱 (菜单条目文本), 不是任何凭据。
    /// 登录态在浏览器 session 里, 本程序只"点头像菜单里的条目"。
    private static func migrateToV5(_ db: Database) throws {
        try db.transaction {
            if try !columnExists(db, table: "account_rotation_state", column: "current_chatgpt_account") {
                try db.execute(
                    "ALTER TABLE account_rotation_state ADD COLUMN current_chatgpt_account TEXT;"
                )
            }
            try db.execute("PRAGMA user_version = 5;")
        }
    }

    // MARK: - V6

    /// V6: 每个 Codex 绑定保存发送前要校验的模型与思考程度。
    /// 两列均可为空，旧绑定继续沿用 Codex 当前设置。
    private static func migrateToV6(_ db: Database) throws {
        try db.transaction {
            if try !columnExists(db, table: "codex_task_bindings", column: "preferred_model_id") {
                try db.execute(
                    "ALTER TABLE codex_task_bindings ADD COLUMN preferred_model_id TEXT;"
                )
            }
            if try !columnExists(db, table: "codex_task_bindings", column: "reasoning_effort") {
                try db.execute(
                    "ALTER TABLE codex_task_bindings ADD COLUMN reasoning_effort TEXT;"
                )
            }
            try db.execute("PRAGMA user_version = 6;")
        }
    }

    // MARK: - V7: Codex 自动执行成为独立主通道

    /// 已绑定 Codex 工作对话的旧 Web 任务实际已经在使用桌面自动恢复链路。
    /// 将这些任务迁入独立模式，并清除旧剪贴板 Runner 留下的“等待提交结果”状态。
    /// 未绑定的 `chatgpt_web` 任务保持不变，继续作为兼容回填流程使用。
    private static func migrateToV7(_ db: Database) throws {
        try db.transaction {
            try db.execute(
                """
                UPDATE tasks
                SET execution_mode = 'codex_desktop',
                    status = CASE WHEN status = 'waitingForUser' THEN 'running' ELSE status END,
                    error_message = CASE WHEN error_class = 'AWAITING_RESULT' THEN NULL ELSE error_message END,
                    error_class = CASE WHEN error_class = 'AWAITING_RESULT' THEN NULL ELSE error_class END,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                WHERE execution_mode = 'chatgpt_web'
                  AND id IN (
                      SELECT task_id FROM codex_task_bindings WHERE task_id IS NOT NULL
                  );
                """
            )
            try db.execute("PRAGMA user_version = 7;")
        }
    }

    /// 判断某列是否已存在 (用于让 ADD COLUMN 可重入)。
    static func columnExists(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try db.query("PRAGMA table_info(\(table));")
        return rows.contains { $0.string("name") == column }
    }

    /// 判断某表是否已存在。
    static func tableExists(_ db: Database, table: String) throws -> Bool {
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(table)]
        )
        return !rows.isEmpty
    }
}

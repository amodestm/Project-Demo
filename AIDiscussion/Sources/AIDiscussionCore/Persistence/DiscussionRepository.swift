import Foundation

/// 讨论组的持久化。
///
/// ## 存储取舍
///
/// - **配置层** (`discussion_groups`): 成员与轮次以 JSON 列整体读写。
///   配置天然是"整份保存", 按成员拆表只会带来无谓 JOIN。
/// - **运行时层** (`discussion_runs` / `discussion_utterances`): 规范化列。
///   它们需要频繁增量更新 —— 每条发言一收到就落盘, 崩溃后能精确续跑,
///   整份 JSON 覆盖会把已完成的发言冲掉。
public struct DiscussionRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func ensureSchema() throws {
        try db.transaction {
            try db.execute(
                """
                CREATE TABLE IF NOT EXISTS discussion_groups (
                    id                      TEXT PRIMARY KEY,
                    name                    TEXT NOT NULL,
                    topic                   TEXT NOT NULL DEFAULT '',
                    consensus               TEXT NOT NULL DEFAULT 'moderatorSummary',
                    moderator_participant_id TEXT,
                    participants_json       TEXT NOT NULL DEFAULT '[]',
                    rounds_json             TEXT NOT NULL DEFAULT '[]',
                    created_at              TEXT NOT NULL,
                    updated_at              TEXT NOT NULL
                );
                """
            )
            try db.execute(
                """
                CREATE TABLE IF NOT EXISTS discussion_runs (
                    id                     TEXT PRIMARY KEY,
                    group_id               TEXT NOT NULL,
                    state                  TEXT NOT NULL DEFAULT 'idle',
                    current_round          INTEGER NOT NULL DEFAULT 0,
                    current_participant_id TEXT,
                    final_decision         TEXT,
                    error_message          TEXT,
                    started_at             TEXT,
                    finished_at            TEXT
                );
                """
            )
            try db.execute("CREATE INDEX IF NOT EXISTS idx_discussion_runs_group ON discussion_runs(group_id);")
            try db.execute(
                """
                CREATE TABLE IF NOT EXISTS discussion_utterances (
                    id                 TEXT PRIMARY KEY,
                    run_id             TEXT NOT NULL,
                    round_index        INTEGER NOT NULL DEFAULT 0,
                    participant_id     TEXT NOT NULL,
                    prompt_sent        TEXT NOT NULL,
                    response_text      TEXT,
                    account_email_used TEXT,
                    status             TEXT NOT NULL DEFAULT 'pending',
                    created_at         TEXT NOT NULL,
                    completed_at       TEXT
                );
                """
            )
            try db.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_discussion_utterances_run
                    ON discussion_utterances(run_id, round_index);
                """
            )
            try db.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_discussion_utterance_identity
                    ON discussion_utterances(run_id, round_index, participant_id);
                """
            )
            try db.execute(
                """
                CREATE TRIGGER IF NOT EXISTS discussion_runs_group_exists
                BEFORE INSERT ON discussion_runs
                WHEN NOT EXISTS (SELECT 1 FROM discussion_groups WHERE id = NEW.group_id)
                BEGIN
                    SELECT RAISE(ABORT, 'discussion group does not exist');
                END;
                """
            )
            try db.execute(
                """
                CREATE TRIGGER IF NOT EXISTS discussion_utterances_run_exists
                BEFORE INSERT ON discussion_utterances
                WHEN NOT EXISTS (SELECT 1 FROM discussion_runs WHERE id = NEW.run_id)
                BEGIN
                    SELECT RAISE(ABORT, 'discussion run does not exist');
                END;
                """
            )
        }
    }

    // MARK: - 讨论组

    public func save(_ group: DiscussionGroup) throws {
        let participants = try JSONCoding.encodeToString(group.participants)
        let rounds = try JSONCoding.encodeToString(group.rounds)

        try db.execute(
            """
            INSERT INTO discussion_groups
                (id, name, topic, consensus, moderator_participant_id,
                 participants_json, rounds_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name                     = excluded.name,
                topic                    = excluded.topic,
                consensus                = excluded.consensus,
                moderator_participant_id = excluded.moderator_participant_id,
                participants_json        = excluded.participants_json,
                rounds_json              = excluded.rounds_json,
                updated_at               = excluded.updated_at;
            """,
            [
                .text(group.id),
                .text(group.name),
                .text(group.topic),
                .text(group.consensus.rawValue),
                group.moderatorParticipantID.map(SQLValue.text) ?? .null,
                .text(participants),
                .text(rounds),
                .text(DateCoding.string(from: group.createdAt)),
                .text(DateCoding.string(from: group.updatedAt)),
            ]
        )
    }

    public func fetchGroup(id: String) throws -> DiscussionGroup? {
        guard let row = try db.queryOne(
            "SELECT * FROM discussion_groups WHERE id = ?", [.text(id)]
        ) else { return nil }
        return Self.decodeGroup(row)
    }

    public func fetchAllGroups() throws -> [DiscussionGroup] {
        let rows = try db.query("SELECT * FROM discussion_groups ORDER BY updated_at DESC")
        return rows.map(Self.decodeGroup)
    }

    public func deleteGroup(id: String) throws {
        // 先删发言与运行, 避免残留孤儿数据
        let runIDs = try db.query(
            "SELECT id FROM discussion_runs WHERE group_id = ?", [.text(id)]
        ).compactMap { $0.string("id") }

        for runID in runIDs {
            try db.execute(
                "DELETE FROM discussion_utterances WHERE run_id = ?", [.text(runID)]
            )
        }
        try db.execute("DELETE FROM discussion_runs WHERE group_id = ?", [.text(id)])
        try db.execute("DELETE FROM discussion_groups WHERE id = ?", [.text(id)])
    }

    // MARK: - 运行

    public func save(_ run: DiscussionRun) throws {
        try db.execute(
            """
            INSERT INTO discussion_runs
                (id, group_id, state, current_round, current_participant_id,
                 final_decision, error_message, started_at, finished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                state                  = excluded.state,
                current_round          = excluded.current_round,
                current_participant_id = excluded.current_participant_id,
                final_decision         = excluded.final_decision,
                error_message          = excluded.error_message,
                started_at             = excluded.started_at,
                finished_at            = excluded.finished_at;
            """,
            [
                .text(run.id),
                .text(run.groupID),
                .text(run.state.rawValue),
                .int(run.currentRound),
                run.currentParticipantID.map(SQLValue.text) ?? .null,
                run.finalDecision.map(SQLValue.text) ?? .null,
                run.errorMessage.map(SQLValue.text) ?? .null,
                run.startedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                run.finishedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
            ]
        )
    }

    public func fetchRun(id: String) throws -> DiscussionRun? {
        guard let row = try db.queryOne(
            "SELECT * FROM discussion_runs WHERE id = ?", [.text(id)]
        ) else { return nil }
        return Self.decodeRun(row)
    }

    public func fetchRuns(groupID: String) throws -> [DiscussionRun] {
        let rows = try db.query(
            "SELECT * FROM discussion_runs WHERE group_id = ? ORDER BY started_at DESC",
            [.text(groupID)]
        )
        return rows.map(Self.decodeRun)
    }

    /// 该组最近一次运行 (用于"继续上次讨论"及开屏查看)。
    /// 优先选择正在进行中的运行；若无，优先选择已产生有效发言的运行；最后按启动时间倒序。
    public func latestRun(groupID: String) throws -> DiscussionRun? {
        guard let row = try db.queryOne(
            """
            SELECT r.* FROM discussion_runs r
            WHERE r.group_id = ?
            ORDER BY 
                CASE WHEN r.state IN ('running', 'waitingForResponse') THEN 1 ELSE 0 END DESC,
                (SELECT COUNT(*) FROM discussion_utterances u WHERE u.run_id = r.id AND u.status = 'received') > 0 DESC,
                r.started_at DESC
            LIMIT 1
            """,
            [.text(groupID)]
        ) else { return nil }
        return Self.decodeRun(row)
    }

    // MARK: - 发言

    /// 新增一条发言。
    public func insert(_ utterance: DiscussionUtterance) throws {
        try db.execute(
            """
            INSERT INTO discussion_utterances
                (id, run_id, round_index, participant_id, prompt_sent,
                 response_text, account_email_used, status, created_at, completed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            Self.bindings(for: utterance)
        )
    }

    /// 更新一条发言 (通常是"收到回复"或"标记失败")。
    public func update(_ utterance: DiscussionUtterance) throws {
        try db.execute(
            """
            UPDATE discussion_utterances SET
                round_index        = ?,
                participant_id     = ?,
                prompt_sent        = ?,
                response_text      = ?,
                account_email_used = ?,
                status             = ?,
                completed_at       = ?
            WHERE id = ?;
            """,
            [
                .int(utterance.roundIndex),
                .text(utterance.participantID),
                .text(utterance.promptSent),
                utterance.responseText.map(SQLValue.text) ?? .null,
                utterance.accountEmailUsed.map(SQLValue.text) ?? .null,
                .text(utterance.status.rawValue),
                utterance.completedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                .text(utterance.id),
            ]
        )
    }

    public func fetchUtterances(runID: String) throws -> [DiscussionUtterance] {
        let rows = try db.query(
            """
            SELECT * FROM discussion_utterances WHERE run_id = ?
            ORDER BY round_index ASC, created_at ASC
            """,
            [.text(runID)]
        )
        return rows.map(Self.decodeUtterance)
    }

    /// 某轮已完成的发言 (断点续跑: 跳过这些)。
    public func completedUtterances(runID: String, roundIndex: Int) throws -> [DiscussionUtterance] {
        let rows = try db.query(
            """
            SELECT * FROM discussion_utterances
            WHERE run_id = ? AND round_index = ? AND status = 'received'
            ORDER BY created_at ASC
            """,
            [.text(runID), .int(roundIndex)]
        )
        return rows.map(Self.decodeUtterance)
    }

    // MARK: - 内部: 绑定与解码

    private static func bindings(for u: DiscussionUtterance) -> [SQLValue] {
        [
            .text(u.id),
            .text(u.runID),
            .int(u.roundIndex),
            .text(u.participantID),
            .text(u.promptSent),
            u.responseText.map(SQLValue.text) ?? .null,
            u.accountEmailUsed.map(SQLValue.text) ?? .null,
            .text(u.status.rawValue),
            .text(DateCoding.string(from: u.createdAt)),
            u.completedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
        ]
    }

    private static func decodeGroup(_ row: SQLRow) -> DiscussionGroup {
        let participantsJSON = row.string("participants_json") ?? "[]"
        let roundsJSON = row.string("rounds_json") ?? "[]"

        let participants =
            (try? JSONCoding.decode([DiscussionParticipant].self, from: participantsJSON)) ?? []
        var rounds =
            (try? JSONCoding.decode([DiscussionRoundConfig].self, from: roundsJSON)) ?? []

        // 兼容: 老数据没有轮次配置时回落到默认议程
        if rounds.isEmpty { rounds = DiscussionGroup.defaultRounds }

        return DiscussionGroup(
            id: row.string("id") ?? "",
            name: row.string("name") ?? "",
            topic: row.string("topic") ?? "",
            participants: participants,
            rounds: rounds,
            consensus: ConsensusRule(rawValue: row.string("consensus") ?? "")
                ?? .moderatorSummary,
            moderatorParticipantID: row.string("moderator_participant_id"),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }

    private static func decodeRun(_ row: SQLRow) -> DiscussionRun {
        DiscussionRun(
            id: row.string("id") ?? "",
            groupID: row.string("group_id") ?? "",
            state: DiscussionRunState(rawValue: row.string("state") ?? "") ?? .idle,
            currentRound: row.int("current_round") ?? 0,
            currentParticipantID: row.string("current_participant_id"),
            finalDecision: row.string("final_decision"),
            errorMessage: row.string("error_message"),
            startedAt: row.date("started_at"),
            finishedAt: row.date("finished_at")
        )
    }

    private static func decodeUtterance(_ row: SQLRow) -> DiscussionUtterance {
        DiscussionUtterance(
            id: row.string("id") ?? "",
            runID: row.string("run_id") ?? "",
            roundIndex: row.int("round_index") ?? 0,
            participantID: row.string("participant_id") ?? "",
            promptSent: row.string("prompt_sent") ?? "",
            responseText: row.string("response_text"),
            accountEmailUsed: row.string("account_email_used"),
            status: UtteranceStatus(rawValue: row.string("status") ?? "") ?? .pending,
            createdAt: row.date("created_at") ?? Date(),
            completedAt: row.date("completed_at")
        )
    }
}

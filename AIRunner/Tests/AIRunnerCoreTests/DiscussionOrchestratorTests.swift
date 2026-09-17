import XCTest
@testable import AIRunnerCore

/// 讨论组编排逻辑测试。
///
/// 真实 Chrome 窗口不参与 —— 会话由 `ScriptedSessionProvider` 提供,
/// 因此轮次推进、上下文注入、身份校验、收敛与续跑都能在无真机的情况下回归。
@MainActor
final class DiscussionOrchestratorTests: XCTestCase {

    // MARK: - 构造辅助

    private func makeGroup() -> DiscussionGroup {
        DiscussionGroup(
            name: "测试讨论",
            topic: "要不要重构这个模块?",
            participants: [
                DiscussionParticipant(
                    displayName: "批判者",
                    rolePrompt: "你只负责挑毛病。",
                    emailHint: "critic@x.com"
                ),
                DiscussionParticipant(
                    displayName: "成本专家",
                    rolePrompt: "你只算成本。",
                    emailHint: "cost@x.com"
                ),
                DiscussionParticipant(
                    displayName: "执行者",
                    rolePrompt: "你只关心能不能落地。",
                    emailHint: "doer@x.com"
                ),
            ]
        )
    }

    private func makeOrchestrator(
        group: DiscussionGroup,
        sessions: DiscussionSessionProviding,
        repository: DiscussionRepository? = nil
    ) throws -> DiscussionOrchestrator {
        let services = try TestSupport.makeServices()
        return DiscussionOrchestrator(
            group: group,
            sessions: sessions,
            repository: repository,
            logger: services.logger
        )
    }

    // MARK: - 议程推进

    func testAgendaRunsSeriallyAndConverges() async throws {
        let group = makeGroup()
        let provider = ScriptedSessionProvider(group: group, replyDelay: .zero)
        let orch = try makeOrchestrator(group: group, sessions: provider)

        await orch.start()

        XCTAssertEqual(orch.run.state, .converged, "讨论应正常收敛")
        XCTAssertNotNil(orch.run.finalDecision, "收敛后必须有最终决策")
        XCTAssertNil(orch.run.errorMessage)

        // 默认议程: 独立论述 3 + 交叉质询 3 + 收敛(仅主席) 1 = 7
        XCTAssertEqual(orch.utterances.count, 7)
        XCTAssertTrue(orch.utterances.allSatisfy { $0.status == .received })

        // 收敛轮只有主席发言
        let convergence = orch.utterances.filter { $0.roundIndex == 2 }
        XCTAssertEqual(convergence.count, 1, "收敛轮应只有主席发言")
        XCTAssertEqual(
            convergence.first?.participantID,
            group.moderator()?.id,
            "收敛轮发言人必须是主席"
        )
    }

    func testRoundsAdvanceInOrder() async throws {
        let group = makeGroup()
        let provider = ScriptedSessionProvider(group: group, replyDelay: .zero)
        let orch = try makeOrchestrator(group: group, sessions: provider)

        await orch.start()

        let roundZero = orch.utterances.filter { $0.roundIndex == 0 }.map(\.participantID)
        let roundOne = orch.utterances.filter { $0.roundIndex == 1 }.map(\.participantID)

        XCTAssertEqual(roundZero.count, 3)
        XCTAssertEqual(roundOne.count, 3)
        // 两轮发言人顺序一致 (都按配置顺序)
        XCTAssertEqual(roundZero, roundOne)
        XCTAssertEqual(
            Set(roundZero),
            Set(group.enabledParticipants.map(\.id)),
            "每轮应覆盖全部启用成员"
        )
    }

    // MARK: - 上下文可见性

    func testIndependentRoundHidesOthersAndCrossExaminationShows() async throws {
        let group = makeGroup()
        let provider = ScriptedSessionProvider(group: group, replyDelay: .zero)
        let orch = try makeOrchestrator(group: group, sessions: provider)

        // 先跑完第一轮, 造出"他人发言"
        await orch.start()

        let speaker = group.enabledParticipants[1]

        let independentPrompt = orch.buildPrompt(round: group.rounds[0], speaker: speaker)
        XCTAssertFalse(
            independentPrompt.contains("【当前讨论记录】"),
            "独立论述轮不该注入他人观点, 否则会被带节奏"
        )

        let crossPrompt = orch.buildPrompt(round: group.rounds[1], speaker: speaker)
        XCTAssertTrue(
            crossPrompt.contains("【当前讨论记录】"),
            "交叉质询轮必须注入他人观点"
        )
        // 自己上一轮的发言按设计不出现在"看他人"里
        XCTAssertFalse(
            crossPrompt.contains("— \(speaker.displayName):"),
            "「看他人」可见性应排除发言者自己"
        )
        XCTAssertTrue(
            crossPrompt.contains("— 批判者:"),
            "应能看到其他成员的发言"
        )
    }

    // MARK: - 身份校验 fail closed

    func testIdentityMismatchStopsDiscussion() async throws {
        let group = makeGroup()
        let orch = try makeOrchestrator(
            group: group,
            sessions: WrongIdentityProvider()
        )

        await orch.start()

        XCTAssertEqual(orch.run.state, .failed, "账号不匹配必须停止, 不能继续发言")
        XCTAssertTrue(orch.utterances.isEmpty, "校验失败时不该产生任何发言")
        XCTAssertTrue(
            orch.run.errorMessage?.contains("账号不匹配") == true,
            "错误信息应说明是账号不匹配: \(orch.run.errorMessage ?? "")"
        )
    }

    // MARK: - 取消

    func testCancelStopsBeforeNextUtterance() async throws {
        let group = makeGroup()
        // 每句话都要 0.5 秒, 留出取消窗口
        let provider = ScriptedSessionProvider(group: group, replyDelay: .milliseconds(500))
        let orch = try makeOrchestrator(group: group, sessions: provider)

        let task = Task { await orch.start() }
        try await Task.sleep(for: .milliseconds(700))
        orch.cancel()
        await task.value

        XCTAssertEqual(orch.run.state, .cancelled)
        XCTAssertNil(orch.run.finalDecision, "取消后不应产出决策")
        // 已发出的发言保留, 但远少于完整议程的 7 条
        XCTAssertLessThan(orch.utterances.count, 7)
    }

    // MARK: - 断点续跑

    func testResumeSkipsCompletedUtterances() async throws {
        let services = try TestSupport.makeServices()
        let repo = services.discussionRepo
        let group = makeGroup()

        try repo.save(group)
        let run = DiscussionRun(groupID: group.id, state: .idle, currentRound: 0)
        try repo.save(run)

        // 预置: 第 0 轮第一位成员已经说过且收到了
        let done = DiscussionUtterance(
            runID: run.id,
            roundIndex: 0,
            participantID: group.enabledParticipants[0].id,
            promptSent: "旧提示词",
            responseText: "旧回复",
            accountEmailUsed: "critic@x.com",
            status: .received,
            completedAt: Date()
        )
        try repo.insert(done)

        let provider = ScriptedSessionProvider(group: group, replyDelay: .zero)
        let orch = DiscussionOrchestrator(
            group: group,
            sessions: provider,
            repository: repo,
            logger: services.logger,
            run: run
        )
        orch.loadHistory()

        XCTAssertEqual(orch.utterances.count, 1, "应先载入历史发言")

        await orch.start()

        XCTAssertEqual(orch.run.state, .converged)

        // 预置那条不该被重复执行
        let roundZeroIDs = orch.utterances
            .filter { $0.roundIndex == 0 }
            .map(\.participantID)
        XCTAssertEqual(
            Set(roundZeroIDs).count, roundZeroIDs.count,
            "第 0 轮不应出现重复成员: \(roundZeroIDs)"
        )
        XCTAssertEqual(orch.utterances.count, 7, "续跑后总数仍应是完整议程的 7 条")
        XCTAssertTrue(
            orch.utterances.contains { $0.id == done.id },
            "原有的那条发言应被保留而不是重跑"
        )
    }

    // MARK: - 收敛

    func testConvergesWithoutConvergenceRoundByAskingModerator() async throws {
        var group = makeGroup()
        // 只留独立论述与交叉质询, 没有收敛轮
        group.rounds = [
            DiscussionRoundConfig(kind: .independentOpinion),
            DiscussionRoundConfig(kind: .crossExamination),
        ]

        let provider = ScriptedSessionProvider(group: group, replyDelay: .zero)
        let orch = try makeOrchestrator(group: group, sessions: provider)

        await orch.start()

        XCTAssertEqual(orch.run.state, .converged)
        XCTAssertNotNil(orch.run.finalDecision, "没有收敛轮时应让主席补一次汇总")
        // 3 + 3 + 主席补的 1 条
        XCTAssertEqual(orch.utterances.count, 7)
    }

    func testResetForNewRunKeepsOldRunAndClearsTranscript() async throws {
        let group = makeGroup()
        let provider = ScriptedSessionProvider(group: group, replyDelay: .zero)
        let orch = try makeOrchestrator(group: group, sessions: provider)

        await orch.start()
        let completedRunID = orch.run.id
        XCTAssertEqual(orch.run.state, .converged)

        orch.resetForNewRun()

        XCTAssertNotEqual(orch.run.id, completedRunID)
        XCTAssertEqual(orch.run.state, .idle)
        XCTAssertTrue(orch.utterances.isEmpty)
        XCTAssertNil(orch.run.finalDecision)
    }

    func testMajorityVoteUsesAllMembersAndProducesAuditableCount() async throws {
        var group = makeGroup()
        group.consensus = .majorityVote
        var sessions: [String: any DiscussionSessionDriving] = [:]
        for (index, participant) in group.enabledParticipants.enumerated() {
            sessions[participant.id] = ScriptedDiscussionSession(
                account: participant.emailHint,
                reply: { _ in index < 2 ? "理由\nVOTE: YES" : "理由\nVOTE: NO" }
            )
        }
        let orch = try makeOrchestrator(
            group: group,
            sessions: ScriptedSessionProvider(sessions: sessions)
        )

        await orch.start()

        XCTAssertEqual(orch.run.state, .converged)
        XCTAssertTrue(orch.run.finalDecision?.contains("通过") == true)
        XCTAssertTrue(orch.run.finalDecision?.contains("赞成 2，反对 1") == true)
        XCTAssertEqual(orch.utterances.filter { $0.roundIndex == 2 }.count, 3)
    }

    func testDatabaseRejectsDuplicateSpeakerInSameRunAndRound() throws {
        let services = try TestSupport.makeServices()
        let repo = services.discussionRepo
        let group = makeGroup()
        try repo.save(group)
        let run = DiscussionRun(groupID: group.id)
        try repo.save(run)
        let first = group.enabledParticipants[0]
        try repo.insert(DiscussionUtterance(
            runID: run.id,
            roundIndex: 0,
            participantID: first.id,
            promptSent: "first"
        ))

        XCTAssertThrowsError(try repo.insert(DiscussionUtterance(
            runID: run.id,
            roundIndex: 0,
            participantID: first.id,
            promptSent: "duplicate"
        )))
    }
}

// MARK: - 测试替身

/// 永远校验失败的会话 —— 用于验证 fail closed。
private struct WrongIdentityProvider: DiscussionSessionProviding {
    func session(for participant: DiscussionParticipant) async throws -> DiscussionSessionDriving {
        WrongIdentitySession()
    }
}

private struct WrongIdentitySession: DiscussionSessionDriving {
    func verifyIdentity(emailHint: String) async throws -> Bool { false }
    func currentAccount() async throws -> String? { "someone-else@x.com" }
    func send(prompt: String) async throws -> String {
        XCTFail("校验失败时绝不能发送")
        return ""
    }
}

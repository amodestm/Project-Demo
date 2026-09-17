import Foundation
import Combine

/// 讨论组编排器 —— 按议程串行推进, 让多个账号轮流"说话"并收敛出决策。
///
/// ## 架构 I: 串行·多窗口常驻
///
/// 额度无限的前提下, 并行不是刚需; 而串行可以用**前台操作**完成,
/// 稳定性远高于后台 AX 写入。因此一次只驱动一个会话, 换人只是切窗口。
///
/// ## ★ 两条铁律 ★
///
/// 1. **身份校验 fail closed** —— 窗口账号与成员不匹配时**立即停止**,
///    绝不把成员 A 的观点发进成员 B 的窗口(发错人 = 整场讨论作废)。
/// 2. **每条发言收到即落盘** —— 崩溃后从最后一条完成的发言继续,
///    绝不重复已经说过的内容。
@MainActor
public final class DiscussionOrchestrator: ObservableObject {

    // MARK: - UI 可观察状态

    @Published public private(set) var run: DiscussionRun
    @Published public private(set) var utterances: [DiscussionUtterance] = []
    /// 正在"思考"(已发送、等回复)的成员 —— UI 靠它显示打字动画。
    @Published public private(set) var thinkingParticipantID: String?
    @Published public private(set) var isRunning = false

    // MARK: - 依赖

    public let group: DiscussionGroup
    private let sessions: DiscussionSessionProviding
    private let repository: DiscussionRepository?
    private let logger: LoggerService

    private var cancelled = false

    public init(
        group: DiscussionGroup,
        sessions: DiscussionSessionProviding,
        repository: DiscussionRepository? = nil,
        logger: LoggerService,
        run: DiscussionRun? = nil
    ) {
        self.group = group
        self.sessions = sessions
        self.repository = repository
        self.logger = logger
        self.run = run ?? DiscussionRun(groupID: group.id)
    }

    // MARK: - 载入历史 (续跑 / 查看上次讨论)

    public func loadHistory() {
        guard let repository else { return }
        utterances = (try? repository.fetchUtterances(runID: run.id)) ?? []
    }

    // MARK: - 控制

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false

        if run.startedAt == nil { run.startedAt = Date() }
        run.state = .running
        run.errorMessage = nil
        do {
            try persistRun()
            logger.info(
                .discussionStarted,
                "开始讨论「\(group.name)」: \(group.enabledParticipants.count) 个成员 / "
                + "\(group.rounds.count) 轮 / 收敛方式 \(group.consensus.displayName)"
            )
            try await runAgenda()
        } catch {
            if run.state != .cancelled {
                run.state = .failed
                run.errorMessage = AppError.normalize(error).userMessage
                run.finishedAt = Date()
                logger.error(.discussionFailed, run.errorMessage ?? "讨论失败")
            }
        }

        thinkingParticipantID = nil
        isRunning = false
        do {
            try persistRun()
        } catch {
            run.state = .failed
            run.errorMessage = "讨论状态无法写入数据库：\(AppError.normalize(error).userMessage)"
            logger.error(.discussionFailed, run.errorMessage ?? "讨论状态保存失败")
        }
    }

    public func cancel() {
        cancelled = true
        guard !run.state.isTerminal else { return }
        run.state = .cancelled
        run.finishedAt = Date()
        do {
            try persistRun()
        } catch {
            run.errorMessage = "取消状态无法写入数据库：\(AppError.normalize(error).userMessage)"
            logger.error(.discussionFailed, run.errorMessage ?? "取消状态保存失败")
        }
        logger.info(.discussionCancelled, "讨论「\(group.name)」已取消")
    }

    /// 结束的运行重新开始一场新讨论；旧运行仍保留在数据库中供审计。
    public func resetForNewRun() {
        guard !isRunning else { return }
        run = DiscussionRun(groupID: group.id)
        utterances = []
        thinkingParticipantID = nil
        cancelled = false
    }

    // MARK: - 议程推进

    private func runAgenda() async throws {
        for (index, round) in group.rounds.enumerated() {
            if cancelled { return }
            // 断点续跑: 已推进过的轮次不重跑
            if index < run.currentRound { continue }

            run.currentRound = index
            try persistRun()
            logger.info(.discussionRoundStarted, "第 \(index + 1) 轮 · \(round.title)")

            for speaker in speakers(for: round) {
                if cancelled { return }
                try await speak(round: round, roundIndex: index, speaker: speaker)
            }
        }

        if cancelled { return }
        try await converge()
    }

    /// 本轮发言人: 显式指定优先; 收敛轮默认只让主席说; 否则全体启用成员。
    private func speakers(for round: DiscussionRoundConfig) -> [DiscussionParticipant] {
        if !round.speakerIDs.isEmpty {
            return round.speakerIDs.compactMap { id in
                group.enabledParticipants.first { $0.id == id }
            }
        }
        if round.kind == .convergence {
            switch group.consensus {
            case .majorityVote, .unanimous:
                return group.enabledParticipants
            case .moderatorSummary, .chairmanDecides:
                if let moderator = group.moderator() { return [moderator] }
            }
        }
        return group.enabledParticipants
    }

    // MARK: - 单次发言

    private func speak(
        round: DiscussionRoundConfig,
        roundIndex: Int,
        speaker: DiscussionParticipant
    ) async throws {
        // 断点续跑: 本轮该成员已经说过且收到了 → 跳过
        let finishedKeys = Set(
            utterances
                .filter { $0.status == .received }
                .map { "\($0.roundIndex)-\($0.participantID)" }
        )
        if finishedKeys.contains("\(roundIndex)-\(speaker.id)") { return }
        if utterances.contains(where: {
            $0.roundIndex == roundIndex && $0.participantID == speaker.id
        }) {
            throw AppError.invalidRequest(
                "成员「\(speaker.displayName)」本轮已有未完成的发送记录。"
                + "为避免崩溃恢复后重复发送，请开始一场新讨论。"
            )
        }

        let session = try await sessions.session(for: speaker)

        // ★ 铁律 1: 身份校验 fail closed ★
        guard try await session.verifyIdentity(emailHint: speaker.emailHint) else {
            let actual = (try? await session.currentAccount()) ?? "未知"
            logger.error(
                .discussionIdentityFailed,
                "成员「\(speaker.displayName)」窗口账号不匹配: 期望 \(speaker.emailHint), 实际 \(actual)"
            )
            throw AppError.invalidRequest(
                "成员「\(speaker.displayName)」的窗口账号不匹配"
                + "(期望 \(speaker.emailHint), 实际 \(actual))。已停止, 不会把发言发到错误的账号。"
            )
        }

        let prompt = buildPrompt(round: round, speaker: speaker)

        var utterance = DiscussionUtterance(
            runID: run.id,
            roundIndex: roundIndex,
            participantID: speaker.id,
            promptSent: prompt,
            status: .pending
        )
        try repository?.insert(utterance)
        refresh(utterance)

        // UI: 这个成员开始"思考"
        run.currentParticipantID = speaker.id
        run.state = .waitingForResponse
        thinkingParticipantID = speaker.id
        try persistRun()

        let response: String
        do {
            response = try await session.send(prompt: prompt)
            try Task.checkCancellation()
            if cancelled { throw CancellationError() }
        } catch {
            utterance.status = .failed
            utterance.completedAt = Date()
            try? repository?.update(utterance)
            refresh(utterance)
            throw error
        }

        utterance.status = .received
        utterance.responseText = response
        utterance.accountEmailUsed = (try? await session.currentAccount()) ?? speaker.emailHint
        utterance.completedAt = Date()

        // ★ 铁律 2: 收到即落盘 ★
        try repository?.update(utterance)
        refresh(utterance)

        run.state = .running
        run.currentParticipantID = nil
        thinkingParticipantID = nil
        logger.info(
            .discussionUtteranceSent,
            "\(speaker.displayName) 完成第 \(roundIndex + 1) 轮发言 (\(response.count) 字)"
        )
    }

    // MARK: - 收敛

    private func converge() async throws {
        let received = utterances.filter { $0.status == .received }

        // 议程内已有收敛轮 → 按配置的收敛规则解释本轮输出。
        if let index = group.rounds.firstIndex(where: { $0.kind == .convergence }) {
            let convergence = received.filter { $0.roundIndex == index }
            guard !convergence.isEmpty else {
                throw AppError.invalidRequest("收敛轮没有收到任何有效回复。")
            }
            switch group.consensus {
            case .moderatorSummary, .chairmanDecides:
                run.finalDecision = convergence.last?.responseText
            case .majorityVote:
                run.finalDecision = try voteDecision(from: convergence, requireUnanimous: false)
            case .unanimous:
                run.finalDecision = try voteDecision(from: convergence, requireUnanimous: true)
            }
            run.state = .converged
            run.finishedAt = Date()
            try persistRun()
            logger.info(.discussionConverged, "讨论「\(group.name)」已收敛")
            return
        }

        // 没有显式收敛轮时补一轮；投票规则由全体发言，其他规则由主席发言。
        let round = DiscussionRoundConfig(
            kind: .convergence,
            title: "收敛 · 最终决策",
            instruction: "综合以上所有发言, 给出最终决策、理由与主要风险。",
            visibility: .all
        )
        let roundIndex = group.rounds.count
        let speakers = speakers(for: round)
        guard !speakers.isEmpty else {
            throw AppError.invalidRequest("无法收敛：讨论组没有可用成员。")
        }
        for speaker in speakers {
            try await speak(round: round, roundIndex: roundIndex, speaker: speaker)
        }
        let convergence = utterances.filter {
            $0.roundIndex == roundIndex && $0.status == .received
        }
        switch group.consensus {
        case .moderatorSummary, .chairmanDecides:
            run.finalDecision = convergence.last?.responseText
        case .majorityVote:
            run.finalDecision = try voteDecision(from: convergence, requireUnanimous: false)
        case .unanimous:
            run.finalDecision = try voteDecision(from: convergence, requireUnanimous: true)
        }
        run.state = .converged
        run.finishedAt = Date()
        try persistRun()
        logger.info(.discussionConverged, "讨论「\(group.name)」已收敛 (主席补汇总)")
    }

    // MARK: - 提示词构造

    /// 构造发给某个成员的完整提示词。
    ///
    /// 可见性由轮次配置决定: 独立论述轮**故意不给**他人观点, 避免被带节奏。
    func buildPrompt(round: DiscussionRoundConfig, speaker: DiscussionParticipant) -> String {
        var parts: [String] = []

        parts.append("【议题】\n\(group.topic)")
        parts.append("【你的角色与立场】\n\(speaker.rolePrompt)")

        if !round.instruction.isEmpty {
            parts.append("【本轮任务】\n\(round.instruction)")
        }

        if round.kind == .convergence {
            switch group.consensus {
            case .majorityVote, .unanimous:
                parts.append(
                    "【投票格式】请先独立判断议题是否应通过。回复最后一行必须严格写为 "
                    + "VOTE: YES 或 VOTE: NO。"
                )
            case .chairmanDecides:
                parts.append("【主席裁决】请直接给出最终决定，可以简述必要条件。")
            case .moderatorSummary:
                break
            }
        }

        let visible = visibleUtterances(for: round, speaker: speaker)
        if !visible.isEmpty {
            let lines = visible.map { utterance in
                let name = group.participants
                    .first { $0.id == utterance.participantID }?.displayName ?? "成员"
                return "— \(name): \(utterance.responseText ?? "")"
            }
            parts.append("【当前讨论记录】\n" + lines.joined(separator: "\n\n"))
        }

        parts.append(
            "【要求】直接给出你的判断与理由, 不要复述他人观点, 300 字以内。"
        )
        return parts.joined(separator: "\n\n")
    }

    private func visibleUtterances(
        for round: DiscussionRoundConfig,
        speaker: DiscussionParticipant
    ) -> [DiscussionUtterance] {
        let configuredIndex = group.rounds.firstIndex { $0.id == round.id }
            ?? (round.kind == .convergence ? group.rounds.count : nil)
        let received = utterances.filter { utterance in
            guard utterance.status == .received else { return false }
            // 投票必须相互独立：同一收敛轮里，后投票的人不能看到前人的票。
            if round.kind == .convergence,
               group.consensus == .majorityVote || group.consensus == .unanimous,
               let configuredIndex {
                return utterance.roundIndex < configuredIndex
            }
            return true
        }
        switch round.visibility {
        case .none:   return []
        case .others: return received.filter { $0.participantID != speaker.id }
        case .all:    return received
        }
    }

    private func voteDecision(
        from utterances: [DiscussionUtterance],
        requireUnanimous: Bool
    ) throws -> String {
        let votes = try utterances.map { utterance -> (String, Bool) in
            guard let text = utterance.responseText,
                  let vote = Self.parseVote(text) else {
                let name = group.participants.first {
                    $0.id == utterance.participantID
                }?.displayName ?? "成员"
                throw AppError.invalidRequest("无法解析「\(name)」的投票；要求最后一行是 VOTE: YES 或 VOTE: NO。")
            }
            let name = group.participants.first {
                $0.id == utterance.participantID
            }?.displayName ?? "成员"
            return (name, vote)
        }
        let yes = votes.filter(\.1).count
        let no = votes.count - yes
        let passed: Bool
        let rule: String
        if requireUnanimous {
            passed = no == 0
            rule = "一致同意"
        } else if yes == no, let moderator = group.moderator(),
                  let chairVote = votes.first(where: { $0.0 == moderator.displayName })?.1 {
            passed = chairVote
            rule = "多数投票（平票由主席裁决）"
        } else {
            passed = yes > no
            rule = "多数投票"
        }
        let details = votes.map { "\($0.0)：\($0.1 ? "赞成" : "反对")" }
            .joined(separator: "；")
        return "\(rule)结果：\(passed ? "通过" : "不通过")。赞成 \(yes)，反对 \(no)。\n\(details)"
    }

    static func parseVote(_ response: String) -> Bool? {
        for line in response.split(separator: "\n").reversed() {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalized == "VOTE: YES" || normalized == "VOTE：YES" { return true }
            if normalized == "VOTE: NO" || normalized == "VOTE：NO" { return false }
        }
        return nil
    }

    // MARK: - 内部

    private func refresh(_ utterance: DiscussionUtterance) {
        if let index = utterances.firstIndex(where: { $0.id == utterance.id }) {
            utterances[index] = utterance
        } else {
            utterances.append(utterance)
        }
    }

    private func persistRun() throws {
        guard let repository else { return }
        try repository.save(run)
    }
}

import Foundation
import Combine
import AIDiscussionBridge

/// 桥接请求的实际处理者：持有服务与"正在跑的任务"。
///
/// ## 职责边界
///
/// - **不做任何 I/O**（socket 由 `DiscussionBridgeServer` 负责），因此全部逻辑可以在
///   单元测试里直接驱动，不需要真的开监听。
/// - 每个任务持有一个 `DiscussionOrchestrator`，跑完把结论落库（复用既有
///   `DiscussionRepository`），所以即使 app 重启，历史也能从数据库读回。
@MainActor
public final class DiscussionBridgeHub: ObservableObject {

    /// 交给界面观察的任务句柄 —— 界面直接 `@ObservedObject` 它的 orchestrator
    /// 就能拿到实时进度，不必额外做轮询。
    public struct JobHandle: Identifiable {
        public let id: String
        public let group: DiscussionGroup
        public let orchestrator: DiscussionOrchestrator
        public let startedAt: Date

        /// 一句人话进度，界面与桥接返回共用同一套文案。
        @MainActor public var progressText: String {
            let completed = orchestrator.utterances.filter { $0.status == .received }.count
            return DiscussionBridgeHub.describe(
                group: group,
                run: orchestrator.run,
                completedUtterances: completed,
                expectedUtterances: DiscussionBridgeHub.expectedUtteranceCount(for: group)
            )
        }

        /// 隔离在 MainActor 上：`DiscussionOrchestrator` 的 `run` 只有主线程能读。
        @MainActor public var isFinished: Bool { orchestrator.run.state.isTerminal }
    }

    private struct JobRunner {
        let runID: String
        let group: DiscussionGroup
        let orchestrator: DiscussionOrchestrator
        let task: Task<Void, Never>
        let startedAt: Date
    }

    @Published public private(set) var handles: [JobHandle] = []

    private let services: DiscussionServices
    private let appVersion: String
    private var runners: [String: JobRunner] = [:]

    /// 已完成任务保留时长：够 Codex 事后取结论，又不会无限堆积。
    static let finishedJobRetention: TimeInterval = 60 * 60
    /// 阻塞式 `run` 的默认与上限等待秒数。
    static let defaultRunTimeoutSeconds = 1_800
    static let maxRunTimeoutSeconds = 3_600

    public init(services: DiscussionServices, appVersion: String? = nil) {
        self.services = services
        self.appVersion = appVersion ?? Self.bundleVersion()
    }

    /// 供桥接服务端与界面复用，避免"hub 报真实版本、server 报 dev"这种不一致。
    public nonisolated static func appVersionString() -> String { bundleVersion() }

    // MARK: - 入口

    public func handle(op: BridgeOp, payload: JSONValue?) async -> BridgeResponse {
        pruneFinishedJobs()

        switch op {
        case .ping:
            return .encoding(capabilities())

        case .roles:
            return .encoding(DiscussionPresets.roles.map {
                BridgeRoleTemplate(
                    name: $0.displayName,
                    rolePrompt: $0.rolePrompt,
                    avatarSymbol: $0.avatarSymbol,
                    accentHex: $0.accentHex
                )
            })

        case .profiles:
            return .encoding(profileList())

        case .groups:
            do {
                return .encoding(try groupList())
            } catch {
                return .failure(normalize(error))
            }

        case .start:
            do {
                let spec = try decode(BridgeDiscussionSpec.self, from: payload)
                return .encoding(try startJob(spec: spec))
            } catch {
                return .failure(normalize(error))
            }

        case .run:
            do {
                let spec = try decode(BridgeDiscussionSpec.self, from: payload)
                return await runToCompletion(spec: spec)
            } catch {
                return .failure(normalize(error))
            }

        case .status:
            do {
                let ref = try decodeOptional(BridgeJobRef.self, from: payload) ?? BridgeJobRef()
                if let jobID = ref.jobId?.trimmingCharacters(in: .whitespacesAndNewlines), !jobID.isEmpty {
                    return .encoding(try snapshot(jobID: jobID))
                }
                return .encoding(bridgeStatus())
            } catch {
                return .failure(normalize(error))
            }

        case .result:
            do {
                let ref = try requireJobRef(payload)
                return .encoding(try finishedOutcome(jobID: ref))
            } catch {
                return .failure(normalize(error))
            }

        case .cancel:
            do {
                let ref = try requireJobRef(payload)
                return .encoding(try cancel(jobID: ref))
            } catch {
                return .failure(normalize(error))
            }
        }
    }

    // MARK: - 目录类

    public func capabilities() -> BridgeCapabilities {
        BridgeCapabilities(
            protocolVersion: BridgeProtocol.version,
            appVersion: appVersion,
            operations: BridgeOp.allCases.map(\.rawValue),
            accessibilityGranted: AccessibilityPermission.isGranted,
            groups: (try? services.discussionRepo.fetchAllGroups().count) ?? 0,
            profiles: ((try? services.chromeProfiles.availableProfiles()) ?? []).count,
            activeJobs: runners.values.filter { !$0.orchestrator.run.state.isTerminal }.count
        )
    }

    private func profileList() -> [BridgeProfile] {
        let aliases = services.settings.accountRotationProfileAliases
        let profiles = (try? services.chromeProfiles.availableProfiles()) ?? []
        return profiles.map { profile in
            let alias = aliases[profile.directoryName]
            return BridgeProfile(
                directory: profile.directoryName,
                displayName: profile.displayName,
                suggestedIdentity: profile.preferredAccountIdentity(alias: alias),
                alias: alias
            )
        }
    }

    private func groupList() throws -> [BridgeGroupSummary] {
        try services.discussionRepo.fetchAllGroups().map { group in
            BridgeGroupSummary(
                name: group.name,
                topic: group.topic,
                participants: group.enabledParticipants.map(\.displayName),
                rounds: group.rounds.map(\.title),
                consensus: group.consensus.rawValue,
                moderator: group.moderator()?.displayName
            )
        }
    }

    private func bridgeStatus() -> BridgeBridgeStatus {
        BridgeBridgeStatus(
            capabilities: capabilities(),
            activeJobs: runners.values
                .filter { !$0.orchestrator.run.state.isTerminal }
                .map { snapshot(for: $0) }
        )
    }

    // MARK: - 任务

    private func startJob(spec: BridgeDiscussionSpec) throws -> BridgeStartedJob {
        let group = try BridgeSpecBuilder.build(spec: spec, services: services)
        let persistent = spec.persist ?? true

        let repository = persistent ? services.discussionRepo : nil
        if persistent {
            try? services.discussionRepo.save(group)
        }

        // 真实 Chrome 会话；MCP 入口永远不做"脚本演示"的静默降级
        let router = RoutingDiscussionSessionProvider(
            mode: .realChrome,
            realProvider: services.discussionSessions,
            scriptedProvider: ScriptedSessionProvider(group: group)
        )

        let orchestrator = DiscussionOrchestrator(
            group: group,
            sessions: router,
            repository: repository,
            logger: services.logger
        )

        let jobID = UUID().uuidString
        let task = Task { await orchestrator.start() }

        runners[jobID] = JobRunner(
            runID: orchestrator.run.id,
            group: group,
            orchestrator: orchestrator,
            task: task,
            startedAt: Date()
        )
        publishHandles()

        services.logger.info(
            "MCP 启动讨论「\(group.name)」job=\(jobID) 议题=\(group.topic.prefix(40))"
        )

        return BridgeStartedJob(
            jobId: jobID,
            runId: orchestrator.run.id,
            groupName: group.name,
            topic: group.topic,
            totalRounds: group.rounds.count,
            expectedUtterances: Self.expectedUtteranceCount(for: group)
        )
    }

    private func runToCompletion(spec: BridgeDiscussionSpec) async -> BridgeResponse {
        let started: BridgeStartedJob
        do {
            started = try startJob(spec: spec)
        } catch {
            return .failure(normalize(error))
        }

        let timeout = min(
            max(spec.timeoutSeconds ?? Self.defaultRunTimeoutSeconds, 30),
            Self.maxRunTimeoutSeconds
        )

        guard let runner = runners[started.jobId] else {
            return .failure(BridgeError(code: .internalError, message: "任务创建后立即丢失。"))
        }

        let finished = await Self.awaitCompletion(of: runner.task, seconds: timeout)

        guard finished else {
            // 超时不等于失败：任务还在跑，让调用方改用轮询，避免重复起一场讨论
            return .failure(
                BridgeError(
                    code: .timeout,
                    message: "讨论超过 \(timeout) 秒仍未收敛，任务仍在后台继续。",
                    hint: "jobId=\(started.jobId)。改用 discussion_status 看进度、"
                        + "discussion_result 取结论，或 discussion_cancel 结束它。"
                )
            )
        }

        do {
            return .encoding(try outcome(jobID: started.jobId, includeJobID: true))
        } catch {
            return .failure(normalize(error))
        }
    }

    /// 等待任务结束；返回 false 表示超时（任务**不会**被取消）。
    ///
    /// 用任务组赛跑而不是 `Task.sleep` 轮询：讨论可能 1 秒结束也可能 40 分钟，
    /// 轮询既浪费又会让"结束了但还没到下一个 tick"白白多等。
    static func awaitCompletion(of task: Task<Void, Never>, seconds: Int) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func cancel(jobID: String) throws -> BridgeCancelResult {
        guard let runner = runners[jobID] else {
            throw BridgeError(
                code: .notFound,
                message: "没有 jobId=\(jobID) 的任务。",
                hint: "用 discussion_status（不带 jobId）列出在跑的任务。"
            )
        }
        let alreadyFinished = runner.orchestrator.run.state.isTerminal
        runner.orchestrator.cancel()
        publishHandles()
        return BridgeCancelResult(jobId: jobID, alreadyFinished: alreadyFinished)
    }

    // MARK: - 结果与进度

    private func snapshot(jobID: String) throws -> BridgeJobSnapshot {
        guard let runner = runners[jobID] else {
            throw BridgeError(
                code: .notFound,
                message: "没有 jobId=\(jobID) 的任务。",
                hint: "任务只保留最近一小时；更早的讨论请到 AIDiscussion 界面按讨论组查看。"
            )
        }
        return snapshot(for: runner, jobID: jobID)
    }

    private func snapshot(for runner: JobRunner, jobID: String? = nil) -> BridgeJobSnapshot {
        let run = runner.orchestrator.run
        let finished = run.state.isTerminal
        let completed = runner.orchestrator.utterances.filter { $0.status == .received }.count
        let expected = Self.expectedUtteranceCount(for: runner.group)
        let totalRounds = max(runner.group.rounds.count, 1)
        let roundNumber = min(run.currentRound + 1, totalRounds)
        let speaker = run.currentParticipantID.flatMap { id in
            runner.group.participants.first { $0.id == id }?.displayName
        }

        let issue = runner.orchestrator.currentOrInferredLoginIssue.map { issue in
            BridgeLoginIssue(
                participant: issue.participantName,
                profile: issue.profileDirectory,
                accountHint: issue.accountHint,
                loginURL: issue.loginURL.absoluteString
            )
        }

        return BridgeJobSnapshot(
            jobId: jobID ?? runners.first(where: { $0.value.runID == runner.runID })?.key ?? "",
            runId: runner.runID,
            groupName: runner.group.name,
            topic: runner.group.topic,
            state: run.state.rawValue,
            isFinished: finished,
            currentRound: roundNumber,
            totalRounds: totalRounds,
            currentParticipant: speaker,
            completedUtterances: completed,
            expectedUtterances: expected,
            progressText: Self.describe(
                group: runner.group,
                run: run,
                completedUtterances: completed,
                expectedUtterances: expected
            ),
            errorMessage: run.errorMessage,
            loginIssue: issue,
            startedAt: Self.iso(run.startedAt)
        )
    }

    private func finishedOutcome(jobID: String, includeJobID: Bool = true) throws -> BridgeOutcome {
        try outcome(jobID: jobID, includeJobID: includeJobID)
    }

    private func outcome(jobID: String, includeJobID: Bool) throws -> BridgeOutcome {
        guard let runner = runners[jobID] else {
            throw BridgeError(
                code: .notFound,
                message: "没有 jobId=\(jobID) 的任务。",
                hint: "任务只保留最近一小时；更早的讨论请到 AIDiscussion 界面按讨论组查看。"
            )
        }
        guard runner.orchestrator.run.state.isTerminal else {
            throw BridgeError(
                code: .busy,
                message: "讨论还没结束，当前状态：\(runner.orchestrator.run.state.displayName)。",
                hint: "\(snapshot(for: runner, jobID: jobID).progressText) —— 稍后再取，或先做别的事。"
            )
        }

        let run = runner.orchestrator.run
        let group = runner.group
        let utterances = runner.orchestrator.utterances.map { utterance -> BridgeUtterance in
            let name = group.participants.first { $0.id == utterance.participantID }?.displayName ?? "未知成员"
            let title = group.rounds.indices.contains(utterance.roundIndex)
                ? group.rounds[utterance.roundIndex].title
                : "第 \(utterance.roundIndex + 1) 轮"
            return BridgeUtterance(
                roundIndex: utterance.roundIndex,
                roundTitle: title,
                participant: name,
                status: utterance.status.rawValue,
                prompt: utterance.promptSent,
                response: utterance.responseText,
                accountUsed: utterance.accountEmailUsed
            )
        }

        let audit = group.enabledParticipants.map { participant in
            BridgeAuditEntry(
                participant: participant.displayName,
                profile: participant.profileDirectory,
                account: participant.emailHint,
                utterances: utterances.filter {
                    $0.participant == participant.displayName && $0.status == UtteranceStatus.received.rawValue
                }.count
            )
        }

        return BridgeOutcome(
            runId: run.id,
            jobId: includeJobID ? jobID : nil,
            groupName: group.name,
            topic: group.topic,
            state: run.state.rawValue,
            finalDecision: run.finalDecision,
            errorMessage: run.errorMessage,
            utterances: utterances,
            audit: audit,
            startedAt: Self.iso(run.startedAt),
            finishedAt: Self.iso(run.finishedAt)
        )
    }

    // MARK: - 内部

    /// 议程理论上会产生多少条发言（收敛轮可能只由主席发言，这里按配置估算）。
    public static func expectedUtteranceCount(for group: DiscussionGroup) -> Int {
        let enabled = group.enabledParticipants.count
        return group.rounds.reduce(into: 0) { total, round in
            total += round.speakerIDs.isEmpty ? enabled : round.speakerIDs.count
        }
    }

    /// 一句人话进度。界面与桥接返回共用，保证用户看到的和模型读到的完全一致。
    public static func describe(
        group: DiscussionGroup,
        run: DiscussionRun,
        completedUtterances: Int,
        expectedUtterances: Int
    ) -> String {
        if run.state.isTerminal {
            return "\(run.state.displayName)（共 \(completedUtterances) 条发言）"
        }
        let totalRounds = max(group.rounds.count, 1)
        let roundNumber = min(run.currentRound + 1, totalRounds)
        let speaker = run.currentParticipantID.flatMap { id in
            group.participants.first { $0.id == id }?.displayName
        }
        if let speaker {
            return "第 \(roundNumber)/\(totalRounds) 轮 · \(speaker) 正在作答"
                + "（已完成 \(completedUtterances)/\(expectedUtterances) 条发言）"
        }
        return "第 \(roundNumber)/\(totalRounds) 轮准备中"
            + "（已完成 \(completedUtterances)/\(expectedUtterances) 条发言）"
    }

    private func publishHandles() {
        handles = runners
            .sorted { $0.value.startedAt > $1.value.startedAt }
            .map { key, runner in
                JobHandle(
                    id: key,
                    group: runner.group,
                    orchestrator: runner.orchestrator,
                    startedAt: runner.startedAt
                )
            }
    }

    private func pruneFinishedJobs() {
        let cutoff = Date().addingTimeInterval(-Self.finishedJobRetention)
        let before = runners.count
        runners = runners.filter { _, runner in
            !(runner.orchestrator.run.state.isTerminal && runner.startedAt < cutoff)
        }
        if runners.count != before { publishHandles() }
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: JSONValue?) throws -> T {
        guard let payload, !payload.isNull else {
            throw BridgeError(code: .invalidRequest, message: "缺少请求参数。")
        }
        let data = try BridgeJSON.encode(payload)
        do {
            return try BridgeJSON.decode(type, from: data)
        } catch {
            throw BridgeError(
                code: .invalidRequest,
                message: "请求参数解析失败：\(error)",
                hint: "检查字段名与类型是否与工具 schema 一致。"
            )
        }
    }

    private func decodeOptional<T: Decodable>(_ type: T.Type, from payload: JSONValue?) throws -> T? {
        guard let payload, !payload.isNull else { return nil }
        return try decode(type, from: payload)
    }

    private func requireJobRef(_ payload: JSONValue?) throws -> String {
        let ref = try decode(BridgeJobRef.self, from: payload)
        let jobID = ref.jobId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !jobID.isEmpty else {
            throw BridgeError(
                code: .invalidRequest,
                message: "缺少 jobId。",
                hint: "discussion_run 与 discussion_start 都会返回 jobId。"
            )
        }
        return jobID
    }

    /// 把内部错误统一翻译成桥接错误 —— 调用方（模型）看到的是可行动的提示，
    /// 而不是 Swift 的默认描述。
    private func normalize(_ error: Error) -> BridgeError {
        if let bridge = error as? BridgeError { return bridge }

        let appError = AppError.normalize(error)
        switch appError {
        case let .loginRequired(issue):
            return BridgeError(
                code: .loginRequired,
                message: "成员「\(issue.participantName)」未登录：\(appError.userMessage)",
                hint: "在 AIDiscussion 界面点「一键跳转登录」，"
                    + "或让用户手动访问 \(issue.loginURL.absoluteString) 完成登录后重试。"
            )
        case .invalidRequest:
            return BridgeError(
                code: .invalidRequest,
                message: appError.userMessage,
                hint: "检查 discussion_profiles 返回的可用 Profile 与账号标识是否对得上。"
            )
        default:
            return BridgeError(code: .internalError, message: appError.userMessage)
        }
    }

    private static func iso(_ date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    /// 只读 `Bundle.main`，不碰任何状态，因此在 MainActor 之外也能安全调用
    /// （桥接服务端就是在非隔离上下文里取版本号的）。
    private nonisolated static func bundleVersion() -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "dev"
        }
    }
}

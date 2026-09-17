import SwiftUI
import AIRunnerCore

/// 讨论运行界面 —— 多个成员像群聊一样轮流发言。
///
/// ## 演示模式说明
///
/// 当前会话由 `ScriptedSessionProvider` 提供(脚本化回复), 用于跑通编排逻辑与界面。
/// 真实 Chrome 窗口驱动(`ChromeDiscussionSession`)接入后替换 provider 即可,
/// 编排与界面代码**不需要改动**。
struct DiscussionRunView: View {

    let services: AppServices
    let onGroupUpdated: ((DiscussionGroup) -> Void)?
    private let sessionRouter: RoutingDiscussionSessionProvider
    @State private var group: DiscussionGroup
    @State private var executionMode: RoutingDiscussionSessionProvider.Mode

    @StateObject private var orchestrator: DiscussionOrchestrator

    @State private var showingConfig = false
    @State private var errorMessage: String?
    @State private var discussionTask: Task<Void, Never>?

    init(
        services: AppServices,
        group: DiscussionGroup,
        onGroupUpdated: ((DiscussionGroup) -> Void)? = nil
    ) {
        self.services = services
        self.onGroupUpdated = onGroupUpdated
        self._group = State(initialValue: group)
        self._executionMode = State(initialValue: .realChrome)
        let router = RoutingDiscussionSessionProvider(
            mode: .realChrome,
            realProvider: services.discussionSessions,
            scriptedProvider: ScriptedSessionProvider(group: group)
        )
        self.sessionRouter = router
        let resumedRun = (try? services.discussionRepo.latestRun(groupID: group.id))
            .flatMap { $0.state.isTerminal ? nil : $0 }
        self._orchestrator = StateObject(wrappedValue: DiscussionOrchestrator(
            group: group,
            sessions: router,
            repository: services.discussionRepo,
            logger: services.logger,
            run: resumedRun
        ))
    }

    // MARK: - 视图

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .onAppear { orchestrator.loadHistory() }
        .sheet(isPresented: $showingConfig) {
            DiscussionConfigView(services: services, group: $group) { updated in
                group = updated
                orchestrator.updateGroup(updated)
                sessionRouter.updateScriptedGroup(updated)
                onGroupUpdated?(updated)
            }
        }
        .alert("讨论出错", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: orchestrator.run.errorMessage) { _, newMsg in
            if let newMsg, !newMsg.isEmpty {
                errorMessage = newMsg
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.headline)

                if !group.topic.isEmpty {
                    Text(group.topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Picker("会话模式", selection: $executionMode) {
                Text("真实 Chrome").tag(RoutingDiscussionSessionProvider.Mode.realChrome)
                Text("脚本演示").tag(RoutingDiscussionSessionProvider.Mode.demo)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .controlSize(.small)
            .onChange(of: executionMode) { _, newMode in
                sessionRouter.mode = newMode
            }

            statusPill

            Button {
                showingConfig = true
            } label: {
                Label("配置", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
            .help("编辑成员、轮次与收敛规则")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            if orchestrator.isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }
            Text(orchestrator.run.state.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }

    private var statusColor: Color {
        switch orchestrator.run.state {
        case .converged: return .green
        case .failed:    return .red
        case .cancelled: return .orange
        case .idle:      return .secondary
        case .running, .waitingForResponse: return .blue
        }
    }

    // MARK: - 发言流

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if orchestrator.utterances.isEmpty && !orchestrator.isRunning {
                        DiscussionIdlePlaceholder(participants: group.enabledParticipants)
                    }

                    ForEach(orchestrator.utterances) { utterance in
                        bubble(for: utterance)
                            .id(utterance.id)
                    }

                    // 正在思考的成员 (还没收到回复)
                    if let thinkingID = orchestrator.thinkingParticipantID,
                       let participant = group.participants.first(where: { $0.id == thinkingID }) {
                        MessageBubble(
                            participant: participant,
                            text: nil,
                            isThinking: true,
                            roundTitle: currentRoundTitle
                        )
                        .id("thinking-\(thinkingID)")
                    }

                    if let decision = orchestrator.run.finalDecision {
                        DecisionCard(
                            decision: decision,
                            moderatorName: group.moderator()?.displayName ?? "主席"
                        )
                        .id("decision")
                    }
                }
                .padding(16)
            }
            .onChange(of: orchestrator.utterances.count) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: orchestrator.thinkingParticipantID ?? "") { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: orchestrator.run.finalDecision ?? "") { _, _ in
                withAnimation { proxy.scrollTo("decision", anchor: .bottom) }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let last = orchestrator.utterances.last else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var currentRoundTitle: String? {
        let index = orchestrator.run.currentRound
        return group.rounds.indices.contains(index) ? group.rounds[index].title : nil
    }

    private func bubble(for utterance: DiscussionUtterance) -> some View {
        let participant = group.participants
            .first { $0.id == utterance.participantID }
            ?? DiscussionParticipant(
                displayName: "未知成员",
                rolePrompt: "",
                accentHex: "#999999"
            )

        let roundTitle = group.rounds.indices.contains(utterance.roundIndex)
            ? group.rounds[utterance.roundIndex].title
            : nil

        return MessageBubble(
            participant: participant,
            text: utterance.status == .received
                ? utterance.responseText
                : "（等待回复…）",
            isThinking: utterance.status == .sent,
            roundTitle: roundTitle
        )
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            executionBadge

            Spacer()

            if let message = orchestrator.run.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(message)
            }

            if orchestrator.isRunning {
                Button("停止") {
                    discussionTask?.cancel()
                    orchestrator.cancel()
                }
                .buttonStyle(.bordered)
            } else if orchestrator.run.state == .failed {
                Button {
                    orchestrator.resetForNewRun()
                    discussionTask = Task { await orchestrator.start() }
                } label: {
                    Label("重新开始", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(startButtonDisabled)

                Button {
                    discussionTask = Task { await orchestrator.start() }
                } label: {
                    Label("重试本次讨论", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(startButtonDisabled)
                .help(topicPlaceholder)
            } else {
                Button {
                    if orchestrator.run.state == .converged || orchestrator.run.state == .cancelled {
                        orchestrator.resetForNewRun()
                    }
                    discussionTask = Task { await orchestrator.start() }
                } label: {
                    Label(
                        orchestrator.run.state == .converged ? "再讨论一次" : "开始讨论",
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(startButtonDisabled)
                .help(topicPlaceholder)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var unconfiguredParticipants: [DiscussionParticipant] {
        group.enabledParticipants.filter {
            $0.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.emailHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var isRealChromeReady: Bool {
        group.enabledParticipants.count >= 2 && unconfiguredParticipants.isEmpty
    }

    private var startButtonDisabled: Bool {
        if group.enabledParticipants.isEmpty || group.topic.isEmpty { return true }
        if executionMode == .realChrome && !isRealChromeReady { return true }
        return false
    }

    private var topicPlaceholder: String {
        if group.topic.isEmpty { return "请先在「配置」里填写议题" }
        if group.enabledParticipants.count < 2 { return "请先在「配置」里添加至少两位启用成员" }
        if executionMode == .realChrome && !isRealChromeReady {
            let names = unconfiguredParticipants.map(\.displayName).joined(separator: "、")
            return "成员「\(names)」尚未绑定 Chrome Profile，请点击「配置」一键分配账号"
        }
        return "按议程开始讨论"
    }

    private var executionBadge: some View {
        Group {
            if executionMode == .realChrome {
                if isRealChromeReady {
                    Label("真实 Chrome 会话就绪", systemImage: "globe")
                        .foregroundStyle(.green)
                        .help("使用各成员绑定的已登录 Chrome Profile 发起真实讨论，全程保护剪贴板")
                } else {
                    Button {
                        showingConfig = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("未配置账号 (\(unconfiguredParticipants.count) 位待绑定)")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("点击打开配置并使用「一键分配 Chrome 账号」")
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "theatermasks.fill")
                    Text("演示模式（脚本假回复）")
                }
                .foregroundStyle(.purple)
                .help("当前使用预设脚本回复跑通流程，不调用真实网页。切换到「真实 Chrome」可调用真实账号。")
            }
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (executionMode == .realChrome ? (isRealChromeReady ? Color.green : Color.orange) : Color.purple)
                .opacity(0.12),
            in: Capsule()
        )
    }
}

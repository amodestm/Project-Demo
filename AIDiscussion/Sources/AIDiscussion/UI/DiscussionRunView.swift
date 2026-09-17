import SwiftUI
import AIDiscussionCore

/// 讨论运行界面 —— 多个成员像群聊一样轮流发言。
///
/// ## 演示模式说明
///
/// 当前会话由 `ScriptedSessionProvider` 提供(脚本化回复), 用于跑通编排逻辑与界面。
/// 真实 Chrome 窗口驱动(`ChromeDiscussionSession`)接入后替换 provider 即可,
/// 编排与界面代码**不需要改动**。
struct DiscussionRunView: View {

    let services: DiscussionServices
    let onGroupUpdated: ((DiscussionGroup) -> Void)?
    private let sessionRouter: RoutingDiscussionSessionProvider
    @State private var group: DiscussionGroup
    @State private var executionMode: RoutingDiscussionSessionProvider.Mode

    @StateObject private var orchestrator: DiscussionOrchestrator

    @State private var showingConfig = false
    @State private var errorMessage: String?
    @State private var discussionTask: Task<Void, Never>?
    @State private var showBrowserWindows = false

    init(
        services: DiscussionServices,
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
        let resumedRun = try? services.discussionRepo.latestRun(groupID: group.id)
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
            progressBanner
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
            if let msg = errorMessage, msg.contains("辅助功能") || msg.contains("Accessibility") {
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                    errorMessage = nil
                }
            }
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

            if executionMode == .realChrome {
                Toggle(isOn: $showBrowserWindows) {
                    Label(
                        showBrowserWindows ? "窗口已显示" : "静默后台中",
                        systemImage: showBrowserWindows ? "eye" : "eye.slash"
                    )
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(showBrowserWindows ? "Chrome 窗口正在主屏幕显示；点击可将窗口移至屏幕外实现 100% 静默隐形讨论" : "Chrome 窗口已移至屏幕外，绝不弹窗打扰；点击可将窗口移回主屏幕查看实时页面")
                .onChange(of: showBrowserWindows) { _, newValue in
                    Task {
                        await services.discussionSessions.setAllVisible(newValue)
                    }
                }
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

    // MARK: - 讨论进度指示看板

    private var progressBanner: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // 当前状态徽章与阶段
                HStack(spacing: 6) {
                    Image(systemName: progressStatusIcon)
                        .foregroundStyle(statusColor)
                        .font(.headline)
                    Text(progressStatusTitle)
                        .font(.subheadline.bold())
                }

                Spacer()

                // 发言进度统计
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(.secondary)
                    Text(progressCountText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }

            // 轮次步骤卡 (Steps)
            if !group.rounds.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(group.rounds.enumerated()), id: \.offset) { index, round in
                        roundStepPill(index: index, round: round)
                    }
                }
            }

            // 实时活动或续跑提示
            if let detail = progressDetailMessage {
                HStack(spacing: 6) {
                    if orchestrator.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else if orchestrator.canResume {
                        Image(systemName: "arrow.forward.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func roundStepPill(index: Int, round: DiscussionRoundConfig) -> some View {
        let isDone = index < orchestrator.run.currentRound || orchestrator.run.state == .converged
        let isCurrent = index == orchestrator.run.currentRound && orchestrator.run.state != .converged

        return HStack(spacing: 5) {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isCurrent && orchestrator.isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else if isCurrent {
                Image(systemName: "circle.circle.fill")
                    .foregroundStyle(orchestrator.canResume ? .orange : .blue)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary.opacity(0.5))
            }

            Text("第 \(index + 1) 轮 · \(round.title)")
                .font(.caption2.bold())
                .foregroundStyle(isCurrent ? .primary : (isDone ? .secondary : .tertiary))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : (isDone ? Color.green.opacity(0.08) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isCurrent ? Color.accentColor.opacity(0.35) : (isDone ? Color.green.opacity(0.25) : Color.gray.opacity(0.15)), lineWidth: 1)
        )
    }

    private var progressStatusIcon: String {
        if orchestrator.isRunning { return "waveform.path.badge.plus" }
        if orchestrator.run.state == .converged { return "checkmark.seal.fill" }
        if orchestrator.canResume { return "pause.circle.fill" }
        if orchestrator.run.state == .failed { return "exclamationmark.circle.fill" }
        return "bubble.left.and.bubble.right"
    }

    private var progressStatusTitle: String {
        if orchestrator.run.state == .converged {
            return "讨论已达成决议（共 \(group.rounds.count) 轮已收敛）"
        }
        let totalRounds = max(group.rounds.count, 1)
        let cur = min(orchestrator.run.currentRound + 1, totalRounds)
        let roundName = currentRoundTitle ?? "议程进行中"
        if orchestrator.isRunning {
            return "第 \(cur) / \(totalRounds) 轮 · \(roundName)"
        }
        if orchestrator.canResume {
            return "第 \(cur) / \(totalRounds) 轮 · \(roundName)（已保留记录，待继续）"
        }
        return "第 1 / \(totalRounds) 轮 · \(roundName)（待开始）"
    }

    private var progressCountText: String {
        let received = orchestrator.utterances.filter { $0.status == .received }.count
        return "已发言 \(received) 条"
    }

    private var progressDetailMessage: String? {
        if let thinkingID = orchestrator.thinkingParticipantID,
           let participant = group.participants.first(where: { $0.id == thinkingID }) {
            return "正在等待「\(participant.displayName)」发言（思考强度：高，Chrome 静默执行中）..."
        }
        if orchestrator.isRunning {
            return "议程推进中，正在按发言顺序调度..."
        }
        if orchestrator.run.state == .converged {
            return "主席与所有成员已完成发言，最终决议已生成在下方。"
        }
        if orchestrator.canResume {
            let received = orchestrator.utterances.filter { $0.status == .received }.count
            return "已保留前 \(received) 条发言。点击下方高亮的「继续讨论」即可无缝从下一个成员继续推进。"
        }
        if !orchestrator.utterances.isEmpty {
            return "当前已加载历史讨论记录。"
        }
        return "请点击下方「开始讨论」，各成员将按议程依次表态并收敛。"
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

                    // 兜底：刚启动思考但尚未插入 utterance 时
                    if let thinkingID = orchestrator.thinkingParticipantID,
                       !orchestrator.utterances.contains(where: { $0.participantID == thinkingID && $0.roundIndex == orchestrator.run.currentRound }),
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

        let isThinking = utterance.status == .sent || utterance.status == .pending
        let textContent: String?
        if utterance.status == .received {
            textContent = utterance.responseText
        } else if utterance.status == .failed {
            textContent = "（发言中断或出错，点击下方「继续讨论」可重试）"
        } else {
            textContent = nil
        }

        return MessageBubble(
            participant: participant,
            text: textContent,
            isThinking: isThinking,
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
                Button(role: .destructive) {
                    discussionTask?.cancel()
                    orchestrator.cancel()
                } label: {
                    Label("停止讨论", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else if orchestrator.canResume {
                Button {
                    orchestrator.resetForNewRun()
                    discussionTask = Task { await orchestrator.start() }
                } label: {
                    Label("从头开始", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(startButtonDisabled)
                .help("清空当前轮次已发言的内容，从第 1 轮重新开始")

                Button {
                    discussionTask = Task { await orchestrator.start() }
                } label: {
                    Label("继续讨论", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(startButtonDisabled)
                .help("保留已发言记录，从卡住或中断的成员继续往下推进")
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

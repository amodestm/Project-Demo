import SwiftUI
import AIRunnerCore

struct TaskDetailView: View {

    @ObservedObject var manager: TaskManager
    let services: AppServices
    let task: AITask

    @State private var showingLogs = false
    @State private var showingAllSteps = false

    // Codex 绑定表单
    @State private var codexDisplayTitle = ""
    @State private var codexThreadTitle = ""
    @State private var codexProjectName = ""
    @State private var codexBundleID = ""
    @State private var showingCodexBindingForm = false

    private var steps: [TaskStep] { manager.steps(for: task) }
    private var latestCheckpoint: Checkpoint? { manager.latestCheckpoint(for: task) }
    private var counts: [StepStatus: Int] { manager.stepStatusCounts(for: task) }

    private var displayedSteps: [TaskStep] {
        showingAllSteps ? steps : Array(steps.suffix(40))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                actionSection
                webExecutionSection
                codexSection
                metricsSection
                checkpointSection
                stepsSection
                footerSection
            }
            .padding(22)
        }
        .navigationTitle(task.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingLogs = true
                } label: {
                    Label("日志", systemImage: "text.alignleft")
                }
            }
        }
        .sheet(isPresented: $showingLogs) {
            LogView(manager: manager, task: task, isPresented: $showingLogs)
        }
    }

    // MARK: - 头部

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: task.status.symbolName)
                    .font(.title2)
                    .foregroundStyle(task.status.tintColor)
                Text(task.name)
                    .font(.title2.bold())
                StatusBadge(status: task.status)
                Spacer()
            }

            Text(task.goal)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let message = task.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.actionHint).font(.caption.bold())
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            ProgressView(value: task.progress) {
                HStack {
                    Text(task.progressText).font(.caption.monospacedDigit())
                    Spacer()
                    Text("\(Int(task.progress * 100))%").font(.caption.monospacedDigit())
                }
            }
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        HStack(spacing: 10) {
            switch task.status {
            case .queued:
                Button {
                    manager.start(task)
                } label: { Label("开始执行", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)

            case .running:
                Button {
                    manager.pause(task)
                } label: { Label("暂停", systemImage: "pause.fill") }
                    .buttonStyle(.borderedProminent)

            case .paused, .waiting, .failed,
                 .waitingForAccount, .waitingForBrowser, .waitingForUser:
                Button {
                    manager.resume(task)
                } label: { Label("继续", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)

            case .completed, .cancelled:
                EmptyView()
            }

            if !task.status.isTerminal {
                Button(role: .destructive) {
                    manager.cancel(task)
                } label: { Label("取消", systemImage: "stop.fill") }
            }

            Spacer()

            if manager.isActive(task) {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Runner 正在执行").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - ChatGPT Web 执行区

    @ViewBuilder
    private var webExecutionSection: some View {
        if task.executionMode == .chatGPTWeb {
            VStack(alignment: .leading, spacing: 12) {

                HStack(spacing: 8) {
                    Label("Web Execution", systemImage: "safari")
                        .font(.headline)
                    Text("ChatGPT Web")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.teal.opacity(0.18), in: Capsule())
                        .foregroundStyle(.teal)
                    Spacer()
                    Text("从 macOS 钥匙串自动登录下一个账号 · 不读取 Cookie")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 10) {
                    webStat("Execution Mode", task.executionMode.displayName)
                    webStat("Current Step",
                            "\(min(task.currentStep + 1, max(task.totalSteps, 1))) / \(task.totalSteps)")
                    webStat("Checkpoint", "\(completedCount)")
                    webStat("Status", task.status.displayName)
                }

                if task.status == .waitingForAccount {
                    accountHandoffGuide
                }

                if task.status == .waitingForUser, let info = manager.lastInfoMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.teal)
                        Text(info).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                // 主操作: 复制 prompt → 打开 ChatGPT → 粘贴结果
                HStack(spacing: 10) {
                    Button {
                        manager.copyContinuationPrompt(task)
                    } label: {
                        Label("复制续跑 Prompt", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPreparePrompt)
                    .help("生成续跑 prompt、复制到剪贴板, 并把该步骤标记为「已就绪」")

                    Button {
                        openChatGPT()
                    } label: {
                        Label("打开 ChatGPT", systemImage: "safari")
                    }
                    .help("用系统默认浏览器打开 ChatGPT —— 不涉及任何自动化操作")

                    Button {
                        manager.pasteResult(task)
                    } label: {
                        Label("粘贴结果", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!canPasteResult)
                    .help("把剪贴板里 ChatGPT 的回复提交为本步骤的结果")

                    Spacer()
                }

                // 账号交接
                HStack(spacing: 10) {
                    Button {
                        manager.pauseForAccountSwitch(task)
                    } label: {
                        Label("受限后自动换账号",
                              systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                    .disabled(task.status.isTerminal || task.status == .waitingForAccount)

                    // ★ 一键自动切换 ChatGPT 网页账号 (凭据自动登录: 侧边栏登出 → 键入账号密码) ★
                    Button {
                        manager.switchChatGPTAccount(task)
                    } label: {
                        if manager.isRotatingAccount {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("切换中…")
                            }
                        } else {
                            Label("自动登录下一个账号",
                                  systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(task.status.isTerminal || manager.isRotatingAccount)
                    .help("退出当前 ChatGPT 账号，从 macOS 钥匙串读取下一个账号并输入邮箱和密码登录；成功后从检查点恢复。验证码、两步验证或安全挑战需要你处理。")

                    if let account = manager.currentChatGPTAccountName(for: task) {
                        Text("当前账号: \(account)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.purple.opacity(0.10), in: Capsule())
                    }

                    Button {
                        manager.resumeAfterAccountSwitch(task)
                    } label: {
                        Label("我已完成账号切换", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(task.status != .waitingForAccount)

                    if manager.awaitingStep(task) != nil {
                        Button("丢弃当前 Prompt") {
                            manager.discardPreparedPrompt(task)
                        }
                        .controlSize(.small)
                    }

                    Spacer()
                }

                if let preview = manager.promptPreview,
                   manager.promptPreviewTaskID == task.id,
                   !preview.isEmpty {
                    promptPreviewBlock(preview)
                }
            }
            .padding(14)
            .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.teal.opacity(0.22), lineWidth: 1)
            )
        }
    }

    // MARK: - Codex Existing Thread 自动恢复

    private var currentCodexBinding: CodexTaskBinding? { manager.codexBinding(for: task) }

    @ViewBuilder
    private var codexSection: some View {
        if task.executionMode == .chatGPTWeb {
            VStack(alignment: .leading, spacing: 12) {

                HStack(spacing: 8) {
                    Label("Codex 自动恢复", systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                    Text("账号交接后自动续跑")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.indigo.opacity(0.18), in: Capsule())
                        .foregroundStyle(.indigo)
                    Spacer()
                    Text("只发「继续」· 不碰 Cookie / token / 登录")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let binding = currentCodexBinding {
                    codexBoundView(binding)
                } else {
                    codexUnboundView
                }

                if let verification = manager.codexVerification,
                   manager.codexVerificationTaskID == task.id {
                    codexVerificationView(verification)
                }
            }
            .padding(14)
            .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.indigo.opacity(0.22), lineWidth: 1)
            )
        }
    }

    /// 已绑定 Codex 线程时的视图。
    private func codexBoundView(_ binding: CodexTaskBinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(binding.displayTitle)
                        .font(.callout.weight(.semibold))
                    Text("目标: \(binding.displayTarget)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !binding.fingerprint.summary.isEmpty {
                        Text(binding.fingerprint.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let verified = binding.lastVerifiedAt {
                    Label("已验证 \(format(verified))", systemImage: "checkmark.shield")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            // 操作按钮: Test Locate → Dry Run → Resume (递进, 绝不跳级)
            HStack(spacing: 10) {
                Button {
                    manager.testLocateCodex(bindingID: binding.id)
                } label: {
                    Label("Test Locate", systemImage: "scope")
                }
                .help("定位并打开绑定的线程, 二次验证后停住 —— 绝不发送")

                Button {
                    manager.dryRunCodex(bindingID: binding.id)
                } label: {
                    Label("Dry Run", systemImage: "play.circle")
                }
                .help("定位 + 验证 + 找到输入框, 但不输入、不发送")

                Button {
                    manager.resumeCodex(bindingID: binding.id)
                } label: {
                    Label("发送「继续」", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .help("真正发送「\(binding.resumeMessage)」到绑定的 Codex 线程")

                Spacer()

                Button(role: .destructive) {
                    manager.deleteCodexBinding(binding)
                } label: {
                    Label("解绑", systemImage: "trash")
                }
                .controlSize(.small)
            }

            // 账号交接自动恢复监视器
            codexMonitorView(binding: binding)
        }
    }

    /// 未绑定时的引导视图 + 绑定表单。
    private var codexUnboundView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showingCodexBindingForm {
                VStack(alignment: .leading, spacing: 8) {
                    Text("绑定一个已存在的 Codex 线程")
                        .font(.callout.weight(.semibold))

                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            Text("显示名").font(.caption).foregroundStyle(.secondary)
                            TextField("例如: 300 份 PDF 研究", text: $codexDisplayTitle)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("线程标题").font(.caption).foregroundStyle(.secondary)
                            TextField("Codex 侧边栏里的线程名", text: $codexThreadTitle)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("项目名 (可选)").font(.caption).foregroundStyle(.secondary)
                            TextField("辅助信号, 提升匹配精度", text: $codexProjectName)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("App Bundle ID").font(.caption).foregroundStyle(.secondary)
                            TextField("com.openai.chatgpt 等", text: $codexBundleID)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    HStack {
                        Button("保存绑定") {
                            saveCodexBinding()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(codexDisplayTitle.isEmpty || codexThreadTitle.isEmpty || codexBundleID.isEmpty)

                        Button("取消") {
                            showingCodexBindingForm = false
                            resetCodexForm()
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Text("尚未绑定 Codex 线程。绑定后可在账号交接后自动发送「继续」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingCodexBindingForm = true
                        if let pref = services.settings.codexPreferredApplicationBundleIdentifier {
                            codexBundleID = pref
                        }
                    } label: {
                        Label("绑定 Codex 线程", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
            }
        }
    }

    /// 监视器状态与启停。
    private func codexMonitorView(binding: CodexTaskBinding) -> some View {
        let monitoring = manager.isMonitoringCodex(taskID: task.id)
        let state = manager.codexMonitorStates[task.id]

        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: monitoring ? "eye.fill" : "eye.slash")
                    .foregroundStyle(monitoring ? .indigo : .secondary)
                if monitoring, let state {
                    Text("监视中: \(state.displayName)")
                        .font(.caption)
                } else {
                    Text("未监视")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if monitoring {
                    Button {
                        manager.stopCodexMonitor(taskID: task.id)
                    } label: {
                        Label("停止监视", systemImage: "stop.circle")
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        manager.startCodexMonitor(taskID: task.id)
                    } label: {
                        Label("开启自动恢复", systemImage: "bolt.fill")
                    }
                    .controlSize(.small)
                }
            }
            Text("开启后: 你在浏览器里完成账号切换/重新认证, AIRunner 检测到 Codex 恢复可用会自动发送一次「\(binding.resumeMessage)」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 验证报告展示。
    private func codexVerificationView(_ verification: CodexResumeVerification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("验证报告 (\(verification.passedGateCount)/12 通过)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView {
                Text(verification.report)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 160)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Codex 绑定表单操作

    private func saveCodexBinding() {
        let fingerprint = CodexTaskFingerprint(
            threadTitle: codexThreadTitle.isEmpty ? nil : codexThreadTitle,
            projectName: codexProjectName.isEmpty ? nil : codexProjectName,
            applicationBundleIdentifier: codexBundleID.isEmpty ? nil : codexBundleID
        )
        let binding = CodexTaskBinding(
            taskID: task.id,
            displayTitle: codexDisplayTitle,
            applicationBundleIdentifier: codexBundleID,
            fingerprint: fingerprint
        )
        manager.saveCodexBinding(binding)
        showingCodexBindingForm = false
        resetCodexForm()
    }

    private func resetCodexForm() {
        codexDisplayTitle = ""
        codexThreadTitle = ""
        codexProjectName = ""
        codexBundleID = ""
    }

    /// 已完成的步骤数 (检查点记录的是"最后完成的 index", 这里换算成个数)。
    private var completedCount: Int {
        (latestCheckpoint?.completedStep ?? -1) + 1
    }

    private var canPreparePrompt: Bool {
        guard !task.status.isTerminal else { return false }
        if manager.awaitingStep(task) != nil { return true }   // 允许重新生成
        return task.currentStep < task.totalSteps
    }

    private var canPasteResult: Bool {
        guard !task.status.isTerminal else { return false }
        return manager.awaitingStep(task) != nil || task.status == .waitingForUser
    }

    private func openChatGPT() {
        let url = ChatGPTWebTarget.resolvedURL(override: services.settings.chatGPTURL)
        WorkspaceBrowserLauncher().open(url)
    }

    private func webStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private var accountHandoffGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.purple)
                Text("Waiting for account switch").font(.callout.bold())
                Spacer()
            }
            Text("""
            任务已安全保存检查点 (共完成 \(completedCount) 步)。

            ★ 自动方式: 若设置已开启，进入此状态时程序会退出当前账号，从 macOS
            钥匙串读取下一个账号并输入邮箱和密码登录，然后自动恢复执行。
            也可以点上方「自动登录下一个账号」立即重试。

            手动方式 (备用):
            1. 在浏览器里完成验证码、两步验证或其他安全挑战。
            2. 回到这里点「我已完成账号切换」。
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func promptPreviewBlock(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("当前续跑 Prompt")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if PasteboardClipboard().writeString(preview) {
                        manager.lastInfoMessage = "续跑 prompt 已复制到剪贴板"
                    }
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            MetricCard(title: "当前步骤", value: "\(task.currentStep) / \(task.totalSteps)",
                       symbol: "list.number")
            MetricCard(title: "执行通道", value: task.executionMode.displayName,
                       symbol: task.executionMode == .chatGPTWeb ? "safari" : "server.rack")

            if task.executionMode == .chatGPTWeb {
                MetricCard(title: "账号", value: "钥匙串自动轮换", symbol: "person.crop.circle")
                MetricCard(title: "结果来源", value: "剪贴板回填", symbol: "doc.on.clipboard")
            } else {
                MetricCard(title: "主力 Provider", value: task.primaryProvider,
                           symbol: "server.rack")
                MetricCard(title: "主力模型", value: task.primaryModel,
                           symbol: "cpu")
            }
            MetricCard(title: "任务重试次数", value: "\(task.retryCount) / \(task.maxRetries)",
                       symbol: "arrow.clockwise")
            MetricCard(title: "已完成步骤", value: "\(counts[.completed] ?? 0)",
                       symbol: "checkmark.circle")
            MetricCard(title: "失败步骤", value: "\(counts[.failed] ?? 0)",
                       symbol: "xmark.circle")
            MetricCard(
                title: "最新检查点",
                value: latestCheckpoint.map { "nextStep = \($0.nextStep)" } ?? "无",
                symbol: "flag.checkered"
            )
            MetricCard(title: "创建时间", value: format(task.createdAt), symbol: "clock")
        }
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 检查点

    private var checkpointSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最新检查点", symbol: "flag.checkered")

            if let checkpoint = latestCheckpoint {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Label("completedStep = \(checkpoint.completedStep)",
                              systemImage: "checkmark")
                        Label("nextStep = \(checkpoint.nextStep)",
                              systemImage: "arrow.right")
                        Label(format(checkpoint.createdAt), systemImage: "clock")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Text(checkpoint.summaryPreview)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
            } else {
                Text("尚未产生检查点")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 步骤

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("步骤", symbol: "square.stack.3d.up")
                Spacer()
                if steps.count > 40 {
                    Toggle("显示全部 \(steps.count) 步", isOn: $showingAllSteps)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            if steps.isEmpty {
                Text("没有步骤")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedSteps) { step in
                        StepRowView(step: step)
                        if step.id != displayedSteps.last?.id {
                            Divider()
                        }
                    }
                }
                .background(.quaternary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.headline)
    }

    // MARK: - 底部

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("数据库: \(services.database.databasePath)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("API Key 存储于 macOS Keychain (service: com.airunner.apikeys)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 子组件

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StepRowView: View {
    let step: TaskStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.status.symbolName)
                .foregroundStyle(step.status.tintColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("第 \(step.index + 1) 步")
                        .font(.callout.weight(.medium))
                    Text(step.type.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Text(step.status.displayName)
                        .font(.caption2)
                        .foregroundStyle(step.status.tintColor)
                    Spacer()
                    if step.retryCount > 0 {
                        Text("重试 \(step.retryCount)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if step.durationMs > 0 {
                        Text("\(step.durationMs)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let backend = step.provider, let model = step.model {
                    Text("\(backend) / \(model)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let text = step.outputText, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let error = step.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

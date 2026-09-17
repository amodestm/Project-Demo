import SwiftUI
import AppKit
import AIRunnerCore

struct TaskDetailView: View {

    @ObservedObject var manager: TaskManager
    let services: AppServices
    let task: AITask

    @State private var showingLogs = false
    @State private var showingAllSteps = false

    // Codex 绑定表单
    @State private var codexThreadTitle = ""
    @State private var codexProjectName = ""
    @State private var codexPrompt = "继续"
    @State private var codexModelID = "gpt-5.6-sol"
    @State private var codexReasoningEffort: CodexReasoningEffort = .high
    @State private var showingCodexBindingForm = false
    @State private var showingCodexExecutionEditor = false
    /// 当前编辑器草稿对应的绑定 ID。绑定区会随 manager 发布状态而重绘，
    /// 不能再用空的 @State 默认值覆盖已经保存的草稿。
    @State private var codexEditorBindingID: String?
    @State private var isReadingCodexTitle = false
    /// 主界面账号选择器当前选中的 Chrome Profile。
    @State private var selectedCodexProfileDirectory: String?

    private let codexModels: [(id: String, name: String)] = [
        ("gpt-5.6-sol", "GPT-5.6 Sol"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-5.6-luna", "GPT-5.6 Luna"),
        ("gpt-6-astra", "GPT-6 Astra"),
        ("gpt-5.5", "GPT-5.5"),
    ]

    private var steps: [TaskStep] { manager.steps(for: task) }
    private var latestCheckpoint: Checkpoint? { manager.latestCheckpoint(for: task) }
    private var counts: [StepStatus: Int] { manager.stepStatusCounts(for: task) }
    private var usesBrowserOAuth: Bool { services.settings.useCodexBrowserOAuthRotation }
    private var accountRotationCaption: String {
        usesBrowserOAuth
            ? "Codex 退出 → 指定 Chrome Profile 授权 → 回到 Codex"
            : "从 macOS 钥匙串自动登录下一个账号"
    }
    private var accountRotationHelp: String {
        usesBrowserOAuth
            ? "退出当前 Codex 账号，使用下一个 Chrome Profile 中已登录的 ChatGPT 会话完成官方授权；成功后回到 Codex 并从检查点恢复。"
            : "退出当前 ChatGPT 账号，从 macOS 钥匙串读取下一个账号并输入邮箱和密码登录；成功后从检查点恢复。"
    }

    private var displayedSteps: [TaskStep] {
        showingAllSteps ? steps : Array(steps.suffix(40))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                actionSection
                if task.executionMode == .codexDesktop {
                    codexSection
                } else {
                    webExecutionSection
                    codexSection
                    metricsSection
                    checkpointSection
                    stepsSection
                    footerSection
                }
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
        .onAppear { syncSelectedCodexProfile() }
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

            if task.executionMode != .codexDesktop {
                ProgressView(value: task.progress) {
                    HStack {
                        Text(task.progressText).font(.caption.monospacedDigit())
                        Spacer()
                        Text("\(Int(task.progress * 100))%").font(.caption.monospacedDigit())
                    }
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
                } label: {
                    Label(task.executionMode == .codexDesktop ? "开始监控" : "开始执行",
                          systemImage: "play.fill")
                }
                    .buttonStyle(.borderedProminent)

            case .running:
                Button {
                    manager.pause(task)
                } label: {
                    Label(task.executionMode == .codexDesktop ? "暂停监控" : "暂停",
                          systemImage: "pause.fill")
                }
                    .buttonStyle(.borderedProminent)

            case .paused, .waiting, .failed,
                 .waitingForAccount, .waitingForBrowser, .waitingForUser:
                Button {
                    manager.resume(task)
                } label: {
                    Label(task.executionMode == .codexDesktop ? "恢复监控" : "继续",
                          systemImage: "play.fill")
                }
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

            if task.executionMode != .codexDesktop, manager.isActive(task) {
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
                    Text(accountRotationCaption)
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
                    .help(accountRotationHelp + "验证码、两步验证或安全挑战需要你处理。")

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

    /// 主界面显示的账号池。设置页保存的是有序目录名；这里再从当前机器
    /// 读取对应 Profile 的用户可读名称/邮箱别名，避免让用户面对“Profile 1”。
    private var configuredCodexProfiles: [ChromeProfile] {
        let allProfiles = manager.availableChromeProfiles()
            .first(where: { $0.browser == .chrome })?.profiles ?? []
        let directories = services.settings.accountRotationProfileDirectories
        guard !directories.isEmpty else { return allProfiles }
        return directories.compactMap { directory in
            allProfiles.first(where: { $0.directoryName == directory })
        }
    }

    private var currentCodexProfileDirectory: String? {
        manager.currentAccountProfileName(for: task)
    }

    private func codexProfileDisplayName(_ profile: ChromeProfile) -> String {
        let alias = services.settings.accountRotationProfileAliases[profile.directoryName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !alias.isEmpty { return alias }
        return profile.displayName.isEmpty ? profile.directoryName : profile.displayName
    }

    private func codexProfileDisplayName(directory: String) -> String {
        if let profile = configuredCodexProfiles.first(where: { $0.directoryName == directory }) {
            return codexProfileDisplayName(profile)
        }
        return services.settings.accountRotationProfileAliases[directory]
            ?? directory
    }

    private func syncSelectedCodexProfile() {
        let current = currentCodexProfileDirectory
        if let current,
           configuredCodexProfiles.contains(where: { $0.directoryName == current }) {
            selectedCodexProfileDirectory = current
        } else if selectedCodexProfileDirectory == nil {
            selectedCodexProfileDirectory = configuredCodexProfiles.first?.directoryName
        }
    }

    /// 账号选择器是 Codex 主执行界面的唯一账号入口。它只显示用户配置的
    /// 邮箱别名，切换按钮复用安全退出 + 指定 Profile OAuth 链路。
    @ViewBuilder
    private var codexAccountSelector: some View {
        if usesBrowserOAuth {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Codex 账号", systemImage: "person.crop.circle")
                        .font(.callout.weight(.semibold))
                    if let current = currentCodexProfileDirectory {
                        Text("当前：\(codexProfileDisplayName(directory: current))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚未选择")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if configuredCodexProfiles.isEmpty {
                    Text("没有找到已配置的 Chrome Profile。请在设置中检测并勾选至少两个 Profile，再回到这里选择账号。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        Picker("选择账号", selection: Binding(
                            get: {
                                selectedCodexProfileDirectory
                                    ?? currentCodexProfileDirectory
                                    ?? configuredCodexProfiles[0].directoryName
                            },
                            set: { selectedCodexProfileDirectory = $0 }
                        )) {
                            ForEach(configuredCodexProfiles) { profile in
                                Text(codexProfileDisplayName(profile))
                                    .tag(profile.directoryName)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 180, alignment: .leading)

                        Button {
                            guard let selectedCodexProfileDirectory else { return }
                            manager.switchCodexAccount(task, to: selectedCodexProfileDirectory)
                        } label: {
                            if manager.isRotatingAccount {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("切换中…")
                                }
                            } else {
                                Label("切换到所选账号", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(
                            manager.isRotatingAccount
                            || currentCodexBinding == nil
                            || selectedCodexProfileDirectory == nil
                            || task.status == .running
                        )
                        .help(task.status == .running
                              ? "当前任务仍在运行，请先暂停监控再切换账号"
                              : "安全退出当前 Codex 账号，使用所选 Chrome Profile 完成 OAuth；不会发送任务消息")
                    }
                }

                if task.status == .running {
                    Label(
                        "当前任务正在监视中。请先暂停监控再手动切换；额度耗尽时，自动切换会在安全门通过后执行。",
                        systemImage: "lock.shield"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let message = manager.lastInfoMessage,
                   manager.isRotatingAccount || message.contains("切换") || message.contains("登录") {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        } else if task.executionMode == .codexDesktop {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("当前使用的是钥匙串兼容登录。若要在主界面按邮箱选择 Chrome Profile，请到设置开启“Chrome Profile + Codex 浏览器授权切换”。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var codexSection: some View {
        if task.executionMode == .chatGPTWeb || task.executionMode == .codexDesktop {
            VStack(alignment: .leading, spacing: 12) {

                HStack(spacing: 8) {
                    Label("Codex 自动恢复", systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                    Text(task.executionMode == .codexDesktop ? "主执行通道" : "兼容模式")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.indigo.opacity(0.18), in: Capsule())
                        .foregroundStyle(.indigo)
                    Spacer()
                    Text(task.executionMode == .codexDesktop
                         ? "按标题锁定 · 选择账号 · 自动监控额度"
                         : (usesBrowserOAuth
                            ? "按标题锁定工作对话 · 模型与提示词按任务预设"
                            : "按标题锁定工作对话 · 账号登录由钥匙串模块处理"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                codexAccountSelector

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
                    Text(binding.fingerprint.threadTitle ?? binding.displayTitle)
                        .font(.callout.weight(.semibold))
                    if let projectName = binding.projectName, !projectName.isEmpty {
                        Text("项目文件夹：\(projectName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let verified = binding.lastVerifiedAt {
                    Label("已验证 \(format(verified))", systemImage: "checkmark.shield")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                Label(
                    binding.executionPreference?.displayName ?? "沿用 Codex 当前模型",
                    systemImage: "cpu"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("提示词: \(binding.resumeMessage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("编辑绑定") {
                    loadCodexExecutionEditor(binding)
                }
                .controlSize(.small)
            }

            if showingCodexExecutionEditor {
                codexExecutionEditor(binding: binding)
                    .onAppear {
                        // 仅在切换到另一条绑定时从数据库装载；同一条绑定的
                        // manager 更新不能覆盖用户正在编辑的字段。
                        if codexEditorBindingID != binding.id {
                            loadCodexExecutionEditor(binding)
                        }
                    }
            }

            // 操作按钮: 定位 → 锁定模型 → 完整发送（递进验证）。
            HStack(spacing: 10) {
                Button {
                    manager.testLocateCodex(bindingID: binding.id)
                } label: {
                    Label("定位测试", systemImage: "scope")
                }
                .help("定位并打开绑定的线程, 二次验证后停住 —— 绝不发送")

                Button {
                    manager.prepareCodexExecution(bindingID: binding.id)
                } label: {
                    Label("锁定与模型测试", systemImage: "checkmark.shield")
                }
                .help("锁定目标对话，设置并回读模型；不输入提示词，也不发送")

                Button {
                    manager.resumeCodex(bindingID: binding.id)
                } label: {
                    Label("锁定并发送", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .help("锁定线程和模型后，发送预设提示词「\(binding.resumeMessage)」")

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
                    Text("绑定一个已存在的 Codex 工作对话")
                        .font(.callout.weight(.semibold))

                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            Text("工作对话标题").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                TextField("Codex 左侧栏中显示的完整对话名称", text: $codexThreadTitle)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    readCurrentCodexTitle()
                                } label: {
                                    if isReadingCodexTitle {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("读取当前对话")
                                    }
                                }
                                .disabled(isReadingCodexTitle)
                                .help("激活 Codex 后读取当前主会话标题，最多等待 10 秒；不会输入或发送消息")
                            }
                        }
                        GridRow {
                            Text("项目文件夹名称").font(.caption).foregroundStyle(.secondary)
                            TextField("可选，用于辅助确认，例如 AIRunner", text: $codexProjectName)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("预设模型").font(.caption).foregroundStyle(.secondary)
                            modelPicker
                        }
                        GridRow {
                            Text("思考程度").font(.caption).foregroundStyle(.secondary)
                            reasoningPicker
                        }
                        GridRow {
                            Text("提示词").font(.caption).foregroundStyle(.secondary)
                            TextField("发送到目标对话的内容", text: $codexPrompt)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text("工作对话标题就是 Codex 左侧栏中这条对话显示的名称。必须完整一致；项目文件夹名称只用于辅助确认。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("保存绑定") {
                            saveCodexBinding()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(codexThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("取消") {
                            showingCodexBindingForm = false
                            resetCodexForm()
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Text("尚未绑定 Codex 工作对话。填写左侧栏中的对话标题即可保存；项目文件夹名称可选。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        resetCodexForm()
                        showingCodexBindingForm = true
                    } label: {
                        Label("绑定 Codex 工作对话", systemImage: "link")
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

                Button {
                    manager.simulateCodexQuotaHandoff(task)
                } label: {
                    Label(
                        task.status == .waitingForAccount
                            ? "继续安全模拟"
                            : "安全模拟额度耗尽",
                        systemImage: "testtube.2"
                    )
                }
                .controlSize(.small)
                .disabled(task.status.isTerminal || manager.isRotatingAccount)
                .help(
                    task.status == .waitingForAccount
                        ? "检查点已经保存；继续未完成的 Profile 轮换、OAuth 登录和目标线程恢复"
                        : "先确认绑定线程没有生成内容，再走真实的 Codex 退出、Profile 轮换、OAuth 登录和自动恢复流程"
                )
            }
            Text("开启后，AIRunner 会持续检测额度耗尽或登录失效。只有任务已停止生成、页面处于空闲且异常连续确认后，才会自动退出当前 Codex 账号并切换下一个；切换完成后会重新锁定目标对话与模型，再发送一次「\(binding.resumeMessage)」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 验证报告展示。
    private func codexVerificationView(_ verification: CodexResumeVerification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("验证报告 (\(verification.passedGateCount)/13 通过)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if verification.threadMatched,
               verification.executionPreferenceMatched,
               !verification.messageInserted {
                Label(
                    "锁定与模型测试会停在发送前；要验证提示词输入和“继续”，请点击“锁定并发送”。",
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.indigo)
            }
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

    private var modelPicker: some View {
        Picker("预设模型", selection: $codexModelID) {
            ForEach(codexModels, id: \.id) { model in
                Text(model.name).tag(model.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningPicker: some View {
        Picker("思考程度", selection: $codexReasoningEffort) {
            ForEach(CodexReasoningEffort.allCases, id: \.self) { effort in
                Text(effort.displayName).tag(effort)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codexExecutionEditor(binding: CodexTaskBinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("工作对话标题").font(.caption).foregroundStyle(.secondary)
                    TextField("Codex 左侧栏中显示的完整对话名称", text: $codexThreadTitle)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("项目文件夹名称").font(.caption).foregroundStyle(.secondary)
                    TextField("可选，用于辅助确认", text: $codexProjectName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("预设模型").font(.caption).foregroundStyle(.secondary)
                    modelPicker
                }
                GridRow {
                    Text("思考程度").font(.caption).foregroundStyle(.secondary)
                    reasoningPicker
                }
                GridRow {
                    Text("提示词").font(.caption).foregroundStyle(.secondary)
                    TextField("发送到目标对话的内容", text: $codexPrompt)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button("保存绑定") {
                    let title = codexThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let projectName = codexProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let prompt = codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    var updated = binding
                    updated.displayTitle = title
                    updated.projectName = projectName.isEmpty ? nil : projectName
                    updated.applicationBundleIdentifier = "com.openai.codex"
                    updated.applicationName = "Codex"
                    updated.fingerprint.threadTitle = title
                    updated.fingerprint.projectName = projectName.isEmpty ? nil : projectName
                    updated.fingerprint.applicationBundleIdentifier = "com.openai.codex"
                    updated.resumeMessage = prompt.isEmpty ? "继续" : prompt
                    updated.executionPreference = CodexExecutionPreference(
                        modelID: codexModelID,
                        reasoningEffort: codexReasoningEffort
                    )
                    updated.updatedAt = Date()
                    if manager.saveCodexBinding(updated) {
                        showingCodexExecutionEditor = false
                        codexEditorBindingID = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(codexThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("取消") {
                    showingCodexExecutionEditor = false
                    codexEditorBindingID = nil
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadCodexExecutionEditor(_ binding: CodexTaskBinding) {
        codexEditorBindingID = binding.id
        codexThreadTitle = binding.fingerprint.threadTitle ?? binding.displayTitle
        codexProjectName = binding.projectName ?? binding.fingerprint.projectName ?? ""
        codexPrompt = binding.resumeMessage
        codexModelID = binding.executionPreference?.modelID ?? "gpt-5.6-sol"
        codexReasoningEffort = binding.executionPreference?.reasoningEffort ?? .high
        showingCodexExecutionEditor = true
    }

    private func saveCodexBinding() {
        let title = codexThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let projectName = codexProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = CodexTaskFingerprint(
            threadTitle: title,
            projectName: projectName.isEmpty ? nil : projectName,
            applicationBundleIdentifier: "com.openai.codex"
        )
        let binding = CodexTaskBinding(
            taskID: task.id,
            displayTitle: title,
            projectName: projectName.isEmpty ? nil : projectName,
            applicationBundleIdentifier: "com.openai.codex",
            applicationName: "Codex",
            chromeProfileDirectory: selectedCodexProfileDirectory,
            fingerprint: fingerprint,
            resumeMessage: prompt.isEmpty ? "继续" : prompt,
            executionPreference: CodexExecutionPreference(
                modelID: codexModelID,
                reasoningEffort: codexReasoningEffort
            )
        )
        if manager.saveCodexBinding(binding) {
            showingCodexBindingForm = false
            resetCodexForm()
        }
    }

    private func resetCodexForm() {
        codexThreadTitle = ""
        codexProjectName = ""
        codexPrompt = "继续"
        codexModelID = "gpt-5.6-sol"
        codexReasoningEffort = .high
    }

    private func readCurrentCodexTitle() {
        isReadingCodexTitle = true
        Task {
            defer { isReadingCodexTitle = false }
            let title = await manager.readCurrentCodexThreadTitle()
            // 读取动作需要短暂激活 Codex 以刷新 Electron 的 AX 树；读完后把
            // AIRunner 窗口带回前台，让用户可以直接继续填写并保存绑定表单。
            NSApp.activate(ignoringOtherApps: true)
            if let title {
                codexThreadTitle = title
            }
        }
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
            Text(usesBrowserOAuth ? """
            任务已安全保存检查点 (共完成 \(completedCount) 步)。

            ★ 自动方式: 程序调用 Codex 官方登出，轮换到下一个 Chrome Profile，自动选择该 Profile 的唯一账号并确认授权，验证 Codex 重新登录后恢复执行。
            也可以点上方「自动登录下一个账号」立即重试。

            若出现多个候选账号、验证码、两步验证或安全检查，程序会停止，不会推进轮换指针。
            """ : """
            任务已安全保存检查点 (共完成 \(completedCount) 步)。

            ★ 自动方式: 程序退出当前账号，从 macOS 钥匙串读取下一个账号并输入邮箱和密码登录，然后自动恢复执行。
            也可以点上方「自动登录下一个账号」立即重试。
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
                MetricCard(title: "账号", value: usesBrowserOAuth ? "Chrome Profile OAuth 轮换" : "钥匙串自动轮换", symbol: "person.crop.circle")
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

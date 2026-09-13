import SwiftUI
import AIRunnerCore

struct SettingsView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let services = appState.services {
                TabView {
                    ProviderSettingsView(services: services)
                        .tabItem { Label("Provider 与密钥", systemImage: "key.fill") }

                    RoutingSettingsView(services: services)
                        .tabItem { Label("模型路由", systemImage: "arrow.triangle.branch") }

                    ChatGptWebSettingsView(services: services)
                        .tabItem { Label("执行方式", systemImage: "arrow.triangle.branch") }

                    CodexSettingsView(services: services)
                        .tabItem { Label("Codex 自动恢复", systemImage: "bolt.horizontal.circle") }

                    RuntimeSettingsView(services: services)
                        .tabItem { Label("运行与健康", systemImage: "gearshape.2.fill") }
                }
                .padding(12)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(appState.bootstrapError ?? "服务未就绪")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

// MARK: - 执行方式

struct ChatGptWebSettingsView: View {

    let services: AppServices

    @State private var urlText = ""
    @State private var copyPrompt = true
    @State private var openBrowser = true
    @State private var defaultMode: ExecutionMode = .codexDesktop
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                VStack(alignment: .leading, spacing: 8) {
                    Text("执行通道").font(.headline)
                    Text("新建任务默认使用哪种方式执行。推荐使用 Codex 自动执行：任务绑定已有 Codex 工作对话，主界面直接监控额度并按邮箱选择 Profile 切换账号。旧 Web 剪贴板回填和 API 仍保留为兼容选项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $defaultMode) {
                        ForEach(ExecutionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    Text(defaultMode.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if defaultMode == .chatGPTWeb {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("兼容 Web 设置").font(.headline)
                        TextField("https://chatgpt.com/", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Text("仅在选择“Web 手动回填（兼容）”时使用。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Toggle("生成 Prompt 后复制到剪贴板", isOn: $copyPrompt)
                        Toggle("生成 Prompt 后打开 ChatGPT", isOn: $openBrowser)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("自动登录与续跑").font(.headline)
                    Text(defaultMode == .codexDesktop ? """
                    Codex 自动执行任务会:
                     · 只使用你绑定的 Codex 工作对话，不会因新建任务自动打开网页
                     · 在主界面选择邮箱对应的 Chrome Profile
                     · 监视额度耗尽/登录失效信号，确认已停止后安全退出并切换账号
                     · 切换完成后重新锁定目标对话、模型和提示词，再发送一次「继续」
                     · 遇到验证码、两步验证或安全挑战时停止并提示你处理
                    """ : """
                    兼容 Web 任务会保存检查点、生成续跑 Prompt，并等待你手动提交和回填结果。
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                    if let statusMessage {
                        Text(statusMessage).font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            .padding(16)
        }
        .task {
            urlText = services.settings.chatGPTURL
            copyPrompt = services.settings.copyPromptToClipboard
            openBrowser = services.settings.openBrowserOnPrepare
            defaultMode = services.settings.defaultExecutionMode
        }
    }

    private func save() {
        var settings = services.settings
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.chatGPTURL = trimmed.isEmpty ? ChatGPTWebTarget.defaultURLString : trimmed
        settings.copyPromptToClipboard = copyPrompt
        settings.openBrowserOnPrepare = openBrowser
        settings.defaultExecutionMode = defaultMode

        Task {
            await services.saveSettings(settings)
            await MainActor.run { statusMessage = "已保存" }
        }
    }
}

// MARK: - 模型路由

struct RoutingSettingsView: View {

    let services: AppServices

    @State private var routes: [RouteEntry] = []
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Text("路由表")
                .font(.headline)

            Text("按优先级从高到低尝试。某个 backend 失败时, Runner 会把它加入"
                 + "「本次已试过」集合并换下一个 —— 因此绝不会出现 A→B→A→B 的循环。")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.callout.monospacedDigit().bold())
                            .frame(width: 20)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(route.provider) / \(route.model)")
                                .font(.callout)
                            if let note = route.note, !note.isEmpty {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if services.factory.isConfigured(providerID: route.provider) {
                            Label("可用", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                                .help("已配置")
                        } else {
                            Label("缺少密钥", systemImage: "exclamationmark.circle")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.orange)
                                .help("该 Provider 尚未配置 API Key")
                        }

                        Toggle("", isOn: Binding(
                            get: { route.enabled },
                            set: { newValue in
                                routes[index].enabled = newValue
                                persist()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { source, destination in
                    routes.move(fromOffsets: source, toOffset: destination)
                    persist()
                }
            }
            .listStyle(.inset)

            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.green)
            }

            HStack {
                Button {
                    routes = RouteEntry.defaults
                    persist()
                } label: {
                    Label("恢复出厂路由", systemImage: "arrow.counterclockwise")
                }
                Spacer()
                Text("拖动可调整优先级")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .onAppear {
            routes = services.settings.sortedRoutes
        }
    }

    private func persist() {
        var settings = services.settings
        settings.routes = routes
        Task {
            await services.saveSettings(settings)
            await MainActor.run {
                routes = services.settings.sortedRoutes
                statusMessage = "路由已保存"
            }
        }
    }
}

// MARK: - 运行参数与 Provider 健康

struct RuntimeSettingsView: View {

    let services: AppServices

    @State private var concurrencyText = "3"
    @State private var maxRetriesText = "8"
    @State private var baseDelayText = "5"
    @State private var health: [ProviderHealth] = []
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var diagnostics: Database.Diagnostics? {
        try? services.databaseDiagnostics()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ---- 运行参数 ----
                VStack(alignment: .leading, spacing: 12) {
                    Text("运行参数").font(.headline)

                    HStack(spacing: 24) {
                        numberField("全局并发任务数", text: $concurrencyText, width: 70)
                        numberField("单步最大重试次数", text: $maxRetriesText, width: 70)
                        numberField("退避基础秒数", text: $baseDelayText, width: 70)
                    }

                    Text("退避序列 = base × 2^n, 上限 300s, 并叠加 30% 随机抖动。"
                         + "限流单独计数, 不消耗普通重试预算。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("保存运行参数") { saveRuntime() }
                            .buttonStyle(.borderedProminent)
                        if let statusMessage {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(statusIsError ? .red : .green)
                        }
                    }
                }

                Divider()

                // ---- Provider 健康 ----
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Provider 健康与熔断").font(.headline)
                        Spacer()
                        Button {
                            Task {
                                await services.resetProviderHealth()
                                health = await services.healthSnapshot()
                            }
                        } label: {
                            Label("重置全部熔断", systemImage: "arrow.counterclockwise")
                        }
                        .controlSize(.small)
                    }

                    Text("认证失败或余额耗尽会让 Provider 立即熔断并进入长冷却, "
                         + "避免无意义地反复调用。网络抖动与限流不会熔断。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if health.isEmpty {
                        Text("暂无健康记录 (尚未发生失败)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(health, id: \.label) { item in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(item.state.tintColor)
                                        .frame(width: 8, height: 8)
                                    Text(item.label)
                                        .font(.callout)
                                        .frame(width: 220, alignment: .leading)
                                    Text(item.statusDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                        .background(.quaternary.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Divider()

                // ---- 数据库 ----
                VStack(alignment: .leading, spacing: 8) {
                    Text("存储").font(.headline)

                    if let diagnostics {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                            GridRow {
                                Text("路径").foregroundStyle(.secondary)
                                Text(services.database.databasePath)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            GridRow {
                                Text("journal_mode").foregroundStyle(.secondary)
                                Text(diagnostics.journalMode)
                            }
                            GridRow {
                                Text("外键约束").foregroundStyle(.secondary)
                                Text(diagnostics.foreignKeys ? "已启用" : "未启用")
                            }
                            GridRow {
                                Text("完整性检查").foregroundStyle(.secondary)
                                Text(diagnostics.integrityOK ? "ok" : "异常")
                                    .foregroundStyle(diagnostics.integrityOK ? .green : .red)
                            }
                        }
                        .font(.caption)
                    }

                    Text("API Key 存放于 macOS Keychain, 不进入数据库与日志。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
        .task {
            concurrencyText = "\(services.settings.concurrency)"
            maxRetriesText = "\(services.settings.retry.maxRetries)"
            baseDelayText = "\(Int(services.settings.retry.baseDelay))"
            health = await services.healthSnapshot()
        }
    }

    private func numberField(_ title: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: width)
        }
    }

    private func saveRuntime() {
        guard let concurrency = Int(concurrencyText.trimmingCharacters(in: .whitespaces)),
              (1...32).contains(concurrency) else {
            statusMessage = "并发数必须是 1 – 32 的整数"
            statusIsError = true
            return
        }
        guard let retries = Int(maxRetriesText.trimmingCharacters(in: .whitespaces)),
              (0...50).contains(retries) else {
            statusMessage = "重试次数必须是 0 – 50 的整数"
            statusIsError = true
            return
        }
        guard let delay = Double(baseDelayText.trimmingCharacters(in: .whitespaces)),
              delay >= 1, delay <= 3600 else {
            statusMessage = "基础退避必须是 1 – 3600 秒"
            statusIsError = true
            return
        }

        var settings = services.settings
        settings.concurrency = concurrency
        settings.retry.maxRetries = retries
        settings.retry.baseDelay = delay

        Task {
            await services.saveSettings(settings)
            await MainActor.run {
                statusMessage = "已保存 (并发数需重启 App 后对 Runner 生效)"
                statusIsError = false
            }
        }
    }
}

// MARK: - Codex Existing Thread 自动恢复

private struct SavedChatGPTAccount: Identifiable, Equatable {
    let id: String
    let label: String
    let email: String
}

struct CodexSettingsView: View {

    let services: AppServices

    @State private var cooldownText = "60"
    @State private var pollIntervalText = "15"
    @State private var resumeMessage = "继续"
    @State private var preferredBundleID = ""
    @State private var autoResumeAfterManualAuthentication = true
    @State private var autoLoginNextChatGPTAccountOnHandoff = true
    @State private var useCodexBrowserOAuthRotation = false
    @State private var availableChromeProfiles: [ChromeProfile] = []
    @State private var selectedChromeProfileDirectories: Set<String> = []
    @State private var profileAliases: [String: String] = [:]
    @State private var profileScanMessage: String?
    @State private var isTestingOAuthLogin = false
    @State private var oauthTestMessage: String?
    @State private var oauthTestIsError = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                VStack(alignment: .leading, spacing: 8) {
                    Text("Codex 自动恢复").font(.headline)
                    Text("""
                    当任务需要换账号时，AIRunner 会先保存检查点，再选择下一个独立 Chrome Profile，通过 Codex 官方浏览器授权切换账号，最后继续任务。

                    每个 Chrome Profile 只需预先登录一个 ChatGPT 账号。AIRunner 不读取 Cookie 或 session token；网页会话过期、验证码或安全挑战出现时会停下来等你处理。
                    """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("恢复参数").font(.headline)

                    Toggle("完成手动认证后自动恢复绑定线程",
                           isOn: $autoResumeAfterManualAuthentication)
                    Text("关闭后仍可手动使用 Test Locate、Dry Run 和「发送继续」；已在运行的监视器会在下次启动时不再自动恢复。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Toggle("任务进入账号交接时自动登录下一个账号",
                           isOn: $autoLoginNextChatGPTAccountOnHandoff)
                    Text("开启后，点任务里的「暂停以切换账号」会直接完成退出、登录和检查点恢复。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Toggle("使用 Chrome Profile + Codex 浏览器授权切换",
                           isOn: $useCodexBrowserOAuthRotation)
                    Text("开启后从 Codex 原生“使用 ChatGPT/GPT 账号登录”入口进入官方浏览器授权；至少需要两个独立 Chrome Profile，且每个 Profile 已登录不同 ChatGPT 账号。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 24) {
                        numberField("两次恢复最小间隔 (秒)", text: $cooldownText, width: 80)
                        numberField("监视器轮询间隔 (秒)", text: $pollIntervalText, width: 80)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("默认发送内容").font(.caption).foregroundStyle(.secondary)
                        TextField("继续", text: $resumeMessage)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("首选 App Bundle ID (可选)")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("例如 com.openai.chatgpt", text: $preferredBundleID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Text("绑定时会用这个值预填。留空则每次手动输入。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("网页账号 Profile").font(.headline)
                        Spacer()
                        Button("重新检测") { scanChromeProfiles(selectNewProfiles: false) }
                            .controlSize(.small)
                        Button("打开 Chrome Profile 管理") {
                            if !services.chromeProfiles.openProfilePicker() {
                                profileScanMessage = "无法打开 Chrome Profile 管理器，请确认已安装 Chrome。"
                            }
                        }
                        .controlSize(.small)
                    }

                    Text("每个勾选项都应在 chatgpt.com 保持一个不同的 ChatGPT 账号登录。Chrome 个人资料无需登录 Google 账号；创建时可选“保持未登录状态”。可为 Profile 填写账号邮箱作为显示名称，轮换顺序按下列顺序循环。保存后请在任务详情的“Codex 账号”选择器中执行切换；这里仅负责配置 Profile 和做独立登录测试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if availableChromeProfiles.isEmpty {
                        Text("没有检测到 Chrome Profile。先打开 Profile 管理器创建至少两个，再回到这里点“重新检测”。")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(availableChromeProfiles) { profile in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Toggle(profileDisplayName(for: profile), isOn: Binding(
                                        get: {
                                            selectedChromeProfileDirectories.contains(profile.directoryName)
                                        },
                                        set: { selected in
                                            if selected {
                                                selectedChromeProfileDirectories.insert(profile.directoryName)
                                            } else {
                                                selectedChromeProfileDirectories.remove(profile.directoryName)
                                            }
                                        }
                                    ))

                                    Spacer()
                                }

                                HStack(spacing: 8) {
                                    Text("账号邮箱")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField(
                                        "可选，例如 name@example.com",
                                        text: profileAliasBinding(for: profile.directoryName)
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    Text(profile.directoryName)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.leading, 26)
                            }
                        }

                        let selectedCount = selectedChromeProfileDirectories.count
                        Text(selectedCount >= 2
                             ? "已选择 \(selectedCount) 个 Profile，可以轮换。"
                             : "当前只选择了 \(selectedCount) 个；自动轮换至少需要 2 个。")
                            .font(.caption2)
                            .foregroundStyle(selectedCount >= 2 ? .green : .orange)
                    }

                    if let profileScanMessage {
                        Text(profileScanMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("一键退出 / 登录测试").font(.headline)
                    Text("手动点击按钮后，AIRunner 会先检查所有 Codex 窗口并确认当前页面已经停止生成，再真实退出账号；等待 Codex 原生登录入口出现后，才打开轮换列表中的下一个 Chrome Profile 并完成网页授权。测试不会新建、绑定或修改任务，也不会发送“继续”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            runOAuthLoginSafetyTest()
                        } label: {
                            if isTestingOAuthLogin {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("正在测试退出和登录…")
                                }
                            } else {
                                Label("一键测试安全退出并登录", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(
                            isTestingOAuthLogin
                            || !useCodexBrowserOAuthRotation
                            || selectedChromeProfileDirectories.count < 2
                        )

                        if let oauthTestMessage {
                            Text(oauthTestMessage)
                                .font(.caption)
                                .foregroundStyle(oauthTestIsError ? .red : .green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("这是一次真实退出操作。Codex 正在生成或无法确认已经停止时，程序会在退出前拒绝测试。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Divider()

                // 旧凭据方式保留为可选回退。
                CodexAccountCredentialSection(services: services)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("安全边界").font(.headline)
                    Text("""
                    自动登录与恢复只做这些:
                     · 在独立 Chrome Profile 中打开 Codex 官方短时授权地址
                     · 不读取、不复制、不注入网页 Cookie 或 session token
                     · 检测到验证码、两步验证或安全挑战时立即停止
                     · 通过 macOS Accessibility API 定位已绑定的线程
                     · 二次验证 (标题 + 至少一个辅助信号) 后才发送
                     · 发送一句「继续」并观察确认信号
                     · 辅助信号不足时绝不猜测目标, 而是 fail closed 停止
                    """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .green)
                    }
                    Spacer()
                }
            }
            .padding(16)
        }
        .task {
            cooldownText = "\(Int(services.settings.codexResumeCooldown))"
            pollIntervalText = "\(Int(services.settings.codexMonitorPollInterval))"
            resumeMessage = services.settings.codexResumeMessage
            preferredBundleID = services.settings.codexPreferredApplicationBundleIdentifier ?? ""
            autoResumeAfterManualAuthentication = services.settings.autoResumeAfterManualAuthentication
            autoLoginNextChatGPTAccountOnHandoff =
                services.settings.autoLoginNextChatGPTAccountOnHandoff
            useCodexBrowserOAuthRotation = services.settings.useCodexBrowserOAuthRotation
            selectedChromeProfileDirectories = Set(
                services.settings.accountRotationProfileDirectories
            )
            profileAliases = services.settings.accountRotationProfileAliases
            scanChromeProfiles(selectNewProfiles: selectedChromeProfileDirectories.isEmpty)
        }
    }

    private func numberField(_ title: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: width)
        }
    }

    private func save() {
        guard let cooldown = Double(cooldownText.trimmingCharacters(in: .whitespaces)),
              cooldown >= 5, cooldown <= 3600 else {
            statusMessage = "恢复间隔必须是 5 – 3600 秒"
            statusIsError = true
            return
        }
        guard let poll = Double(pollIntervalText.trimmingCharacters(in: .whitespaces)),
              poll >= 2, poll <= 300 else {
            statusMessage = "轮询间隔必须是 2 – 300 秒"
            statusIsError = true
            return
        }
        let trimmedBundle = preferredBundleID.trimmingCharacters(in: .whitespacesAndNewlines)

        var settings = services.settings
        settings.codexResumeCooldown = cooldown
        settings.codexMonitorPollInterval = poll
        settings.codexResumeMessage = resumeMessage.isEmpty ? "继续" : resumeMessage
        settings.codexPreferredApplicationBundleIdentifier = trimmedBundle.isEmpty ? nil : trimmedBundle
        settings.autoResumeAfterManualAuthentication = autoResumeAfterManualAuthentication
        settings.autoLoginNextChatGPTAccountOnHandoff = autoLoginNextChatGPTAccountOnHandoff
        settings.useCodexBrowserOAuthRotation = useCodexBrowserOAuthRotation
        settings.accountRotationProfileDirectories = availableChromeProfiles
            .filter { selectedChromeProfileDirectories.contains($0.directoryName) }
            .map(\.directoryName)
        settings.accountRotationProfileAliases = profileAliases.reduce(into: [:]) { result, pair in
            let email = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty { result[pair.key] = email }
        }

        if useCodexBrowserOAuthRotation,
           settings.accountRotationProfileDirectories.count < 2 {
            statusMessage = "已保存，但 OAuth 自动轮换还需要至少两个已勾选的 Chrome Profile"
            statusIsError = true
        }

        Task {
            await services.saveSettings(settings)
            await MainActor.run {
                if !(useCodexBrowserOAuthRotation
                     && settings.accountRotationProfileDirectories.count < 2) {
                    statusMessage = "已保存"
                    statusIsError = false
                }
            }
        }
    }

    private func runOAuthLoginSafetyTest() {
        guard !isTestingOAuthLogin else { return }
        guard useCodexBrowserOAuthRotation,
              selectedChromeProfileDirectories.count >= 2 else {
            oauthTestMessage = "请先开启 OAuth 轮换并勾选至少两个 Chrome Profile。"
            oauthTestIsError = true
            return
        }

        isTestingOAuthLogin = true
        oauthTestMessage = "正在确认 Codex 已停止生成…"
        oauthTestIsError = false

        let selectedDirectories = availableChromeProfiles
            .filter { selectedChromeProfileDirectories.contains($0.directoryName) }
            .map(\.directoryName)

        Task {
            // 测试使用界面上当前勾选的 Profile，并立即保存这两项相关设置。
            var settings = services.settings
            settings.useCodexBrowserOAuthRotation = true
            settings.accountRotationProfileDirectories = selectedDirectories
            await services.saveSettings(settings)

            do {
                let outcome = try await services.codexOAuthSafetyTester.run()
                await MainActor.run {
                    oauthTestMessage =
                        "测试成功：已通过“\(outcome.accountLabel)”重新登录 Codex；没有发送任务消息。"
                    oauthTestIsError = false
                    isTestingOAuthLogin = false
                }
            } catch {
                let message = AppError.normalize(error).userMessage
                await MainActor.run {
                    oauthTestMessage = "测试失败：\(message)"
                    oauthTestIsError = true
                    isTestingOAuthLogin = false
                }
            }
        }
    }

    private func scanChromeProfiles(selectNewProfiles: Bool) {
        do {
            let found = try services.chromeProfiles.availableProfiles()
            availableChromeProfiles = found
            if selectNewProfiles {
                selectedChromeProfileDirectories = Set(found.map(\.directoryName))
            } else {
                selectedChromeProfileDirectories = selectedChromeProfileDirectories.intersection(
                    Set(found.map(\.directoryName))
                )
            }
            profileScanMessage = "检测到 \(found.count) 个 Chrome Profile。"
        } catch {
            availableChromeProfiles = []
            profileScanMessage = "检测失败：\(AppError.normalize(error).userMessage)"
        }
    }

    private func profileDisplayName(for profile: ChromeProfile) -> String {
        let alias = profileAliases[profile.directoryName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !alias.isEmpty { return alias }
        return profile.label
    }

    private func profileAliasBinding(for directoryName: String) -> Binding<String> {
        Binding(
            get: { profileAliases[directoryName] ?? "" },
            set: { newValue in
                profileAliases[directoryName] = newValue
            }
        )
    }

}

// MARK: - 凭据自动登录 (兼容回退)

/// 「凭据自动登录」账号编辑器 —— 列表 + 增删改, 凭据存 Keychain。
///
/// UI 只持有账号名称、邮箱与随机 ID。密码仅在用户输入时短暂进入 SecureField，
/// 保存后由 Keychain 管理，不回读到列表状态。
private struct CodexAccountCredentialSection: View {

    let services: AppServices

    @State private var accounts: [SavedChatGPTAccount] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var showingEditor = false
    @State private var editing: SavedChatGPTAccount?
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var confirmDeleteID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("旧版邮箱密码路线（回退）").font(.headline)
                Spacer()
                Button {
                    editing = nil
                    showingEditor = true
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .controlSize(.small)
            }

            Text("关闭上面的浏览器 OAuth 开关后，AIRunner 会使用这套旧流程：点侧边栏登出，再键入下一个账号的邮箱和密码登录。"
                 + "密码只存 macOS 钥匙串，不进设置、数据库或日志；列表不会回读密码。至少添加两个账号。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if accounts.isEmpty {
                Text("还没有配置账号。点「添加账号」一次性录入邮箱和密码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(accounts) { account in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.label).font(.callout)
                                Text(account.email)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label("已存钥匙串", systemImage: "key.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Button {
                                editing = account
                                showingEditor = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help("编辑")
                            Button {
                                confirmDeleteID = account.id
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help("删除")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .background(.quaternary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 8))
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showingEditor) {
            CodexAccountEditorSheet(
                services: services,
                editing: editing,
                onSaved: { await reload() }
            )
        }
        .alert("删除账号凭据", isPresented: Binding(
            get: { confirmDeleteID != nil },
            set: { if !$0 { confirmDeleteID = nil } }
        )) {
            Button("取消", role: .cancel) { confirmDeleteID = nil }
            Button("删除", role: .destructive) {
                if let id = confirmDeleteID { Task { await deleteAccount(id: id) } }
                confirmDeleteID = nil
            }
        } message: {
            Text("该账号的 email + 密码会从 Keychain 永久删除, 并从轮换列表移除。此操作不可撤销。")
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            let ids = services.settings.codexAccountRotationIDs
            var loaded: [SavedChatGPTAccount] = []
            loaded.reserveCapacity(ids.count)
            for id in ids {
                if let rec = try services.codexAccountVault.fetch(id: id) {
                    loaded.append(SavedChatGPTAccount(id: rec.id, label: rec.label, email: rec.email))
                }
            }
            // 清理孤立 id: 若 rotationIDs 里有但 vault 已无记录, 同步移除, 避免越滚越脏
            let validIDs = loaded.map(\.id)
            if validIDs.count != ids.count {
                var settings = services.settings
                settings.codexAccountRotationIDs = validIDs
                await services.saveSettings(settings)
            }
            await MainActor.run {
                accounts = loaded
                isLoading = false
            }
        } catch {
            await MainActor.run {
                loadError = AppError.normalize(error).userMessage
                isLoading = false
            }
        }
    }

    private func deleteAccount(id: String) async {
        do {
            _ = try services.codexAccountVault.delete(id: id)
            var settings = services.settings
            settings.codexAccountRotationIDs.removeAll { $0 == id }
            await services.saveSettings(settings)
            statusMessage = "已删除"
            statusIsError = false
            await reload()
        } catch {
            await MainActor.run {
                statusMessage = AppError.normalize(error).userMessage
                statusIsError = true
            }
        }
    }
}

/// 单个账号的增 / 改表单 (sheet)。
///
/// - 新增: 三个字段都必填, 校验后 `vault.save(...)`, 再把新 id 追加进 `codexAccountRotationIDs`。
/// - 编辑: 名称/邮箱可改; 密码留空 = 保持 vault 里原密码 (不覆盖、不回显明文)。
private struct CodexAccountEditorSheet: View {

    let services: AppServices
    let editing: SavedChatGPTAccount?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var email = ""
    @State private var password = ""
    @State private var errorText: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "添加 ChatGPT 账号" : "编辑账号")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("账号A", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("登录邮箱").font(.caption).foregroundStyle(.secondary)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(editing == nil ? "密码" : "密码 (留空 = 保持原密码)")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "保存" : "更新") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task { loadForEdit() }
    }

    private func loadForEdit() {
        guard let editing else { return }
        label = editing.label
        email = editing.email
        // 密码不回显明文 —— 留空即保持原密码
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLabel.isEmpty else {
            errorText = "名称不能为空"; return
        }
        guard trimmedEmail.contains("@"), !trimmedEmail.contains(" ") else {
            errorText = "邮箱格式看起来不对"; return
        }

        isSaving = true
        errorText = nil
        Task {
            do {
                if let existing = editing {
                    let effectivePassword: String
                    if password.isEmpty {
                        effectivePassword = (try? services.codexAccountVault.fetch(id: existing.id))?.password
                            ?? ""
                    } else {
                        effectivePassword = password
                    }
                    let updated = CodexAccountRecord(
                        id: existing.id,
                        label: trimmedLabel,
                        email: trimmedEmail,
                        password: effectivePassword
                    )
                    try services.codexAccountVault.update(updated)
                    // id 不变, 顺序表无需改动
                } else {
                    guard !password.isEmpty else {
                        await MainActor.run {
                            errorText = "密码不能为空"; isSaving = false
                        }
                        return
                    }
                    let saved = try services.codexAccountVault.save(
                        label: trimmedLabel, email: trimmedEmail, password: password
                    )
                    var settings = services.settings
                    if !settings.codexAccountRotationIDs.contains(saved.id) {
                        settings.codexAccountRotationIDs.append(saved.id)
                    }
                    await services.saveSettings(settings)
                }
                await onSaved()
                await MainActor.run { isSaving = false; dismiss() }
            } catch {
                await MainActor.run {
                    errorText = AppError.normalize(error).userMessage
                    isSaving = false
                }
            }
        }
    }
}

import Foundation
import Combine

/// UI 层状态与动作入口。
///
/// 职责边界 (强制):
/// * 只做「读数据库 → 发布状态」和「调用 JobRunner → 刷新状态」
/// * **不** 包含任何执行循环、重试、路由逻辑 —— 那些全在 JobRunner / ModelRouter 里
/// * 视图不直接碰 Repository
@MainActor
public final class TaskManager: ObservableObject {

    // MARK: - 发布状态

    @Published public private(set) var tasks: [AITask] = []
    @Published public private(set) var activeRunnerTaskIDs: Set<String> = []
    @Published public private(set) var recoverySummary: String?
    @Published public var lastErrorMessage: String?
    /// 最近一次成功操作给用户的提示 (区别于 lastErrorMessage)。
    @Published public var lastInfoMessage: String?
    /// 续跑 prompt 预览 —— 供 UI 显示或用户手动复制。
    @Published public private(set) var promptPreview: String?
    @Published public private(set) var promptPreviewTaskID: String?

    public let services: AppServices

    private var pollingTask: Task<Void, Never>?

    public init(services: AppServices) {
        self.services = services
        refresh()
    }

    // MARK: - 启动恢复

    /// App 启动时调用: 修复残留状态, 并把 running 的任务重新挂上 Runner。
    @discardableResult
    public func recoverOnLaunch(autoStart: Bool = true) -> RecoveryReport? {
        do {
            let report = try services.recovery.recover()
            recoverySummary = report.didRecoverAnything ? report.summary : nil

            refresh()

            // 绑定过 Codex 线程的非终态任务继续接受额度/登录异常监视。
            // 这样应用重启后不会丢失“额度耗尽 → 自动切号”的后台链路；
            // 具体是否执行轮换仍由监视器的 running + idle + 连续信号门控决定。
            if services.settings.autoResumeAfterManualAuthentication {
                let boundTaskIDs = (try? services.tasks.fetchAll())?
                    .filter {
                        $0.status == .running || $0.status == .waitingForUser
                            || $0.status == .waitingForAccount
                    }
                    .compactMap { task in
                        ((try? services.codexBindings.fetchByTask(taskID: task.id)) ?? nil) != nil
                            ? task.id : nil
                    } ?? []
                for taskID in boundTaskIDs {
                    codexQuotaMonitorTaskIDs.insert(taskID)
                    Task { [weak self] in
                        guard let self else { return }
                        await self.services.codexQuotaMonitor.start(taskID: taskID)
                    }
                }
            }

            if autoStart, !report.recoverableTaskIDs.isEmpty {
                for taskID in report.recoverableTaskIDs {
                    Task { [weak self] in
                        await self?.startRunnerWithLogin(
                            taskID: taskID, rotateAccountBeforeStart: false
                        )
                    }
                }
            }
            startPolling()
            return report
        } catch {
            setError(error)
            return nil
        }
    }

    // MARK: - 刷新

    public func refresh() {
        do {
            tasks = try services.tasks.fetchAll()
        } catch {
            setError(error)
        }

        Task { [weak self] in
            guard let self else { return }
            let ids = await self.services.runner.activeTaskIDs()
            self.activeRunnerTaskIDs = Set(ids)
        }
    }

    public func startPolling(interval: Duration = .seconds(1)) {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.tick()
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func tick() async {
        refresh()
        // 刷新所有正在监视的任务的 Codex 监视器状态, 供 UI 实时显示。
        let monitorIDs = Set(codexMonitorStates.keys).union(codexQuotaMonitorTaskIDs)
        for taskID in monitorIDs {
            await refreshCodexMonitorState(taskID: taskID)
        }
    }

    // MARK: - 创建

    @discardableResult
    public func createTask(
        name: String,
        goal: String,
        numberOfSteps: Int
    ) throws -> AITask {

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            throw AppError.invalidRequest("任务名称不能为空")
        }
        guard !trimmedGoal.isEmpty else {
            throw AppError.invalidRequest("任务目标不能为空")
        }
        guard (1...1000).contains(numberOfSteps) else {
            throw AppError.invalidRequest("步骤数必须在 1...1000 之间 (当前 \(numberOfSteps))")
        }

        let currentSettings = services.settings
        let mode = currentSettings.defaultExecutionMode

        // Web 模式（兼容通道）不依赖 API 路由;
        // 只有 API 可选后端才要求至少有一条可用的模型路由。
        let primary: RouteEntry?
        switch mode {
        case .codexDesktop:
            primary = nil
        case .chatGPTWeb:
            primary = currentSettings.primaryRoute
        case .api:
            guard let route = currentSettings.primaryRoute else {
                throw AppError.invalidRequest(
                    "API 模式需要至少一条模型路由, 请先在「设置 → 模型路由」中配置"
                )
            }
            primary = route
        }

        let task = AITask(
            name: trimmedName,
            goal: trimmedGoal,
            status: .queued,
            executionMode: mode,
            primaryProvider: primary?.provider ?? "",
            primaryModel: primary?.model ?? "",
            totalSteps: numberOfSteps
        )

        // 顺序很重要: 先写 tasks, 再写 task_steps (存在外键约束)。
        try services.tasks.insert(task)

        let plan = TaskPlanner.defaultPlan(
            taskID: task.id,
            numberOfSteps: numberOfSteps,
            goal: trimmedGoal
        )
        try services.steps.insertBatch(plan)

        // 起始检查点: nextStep = 0
        try services.checkpoints.insert(Checkpoint.initial(taskID: task.id))

        services.logger.info(
            .taskCreated,
            "创建任务「\(trimmedName)」: \(numberOfSteps) 步, 执行通道 \(mode.displayName)",
            taskID: task.id,
            metadata: .object([
                "totalSteps": .int(numberOfSteps),
                "executionMode": .string(mode.rawValue),
                "provider": .string(primary?.provider ?? ""),
                "model": .string(primary?.model ?? ""),
            ])
        )

        refresh()
        return task
    }

    // MARK: - 生命周期动作

    public func start(_ task: AITask) {
        guard !task.status.isTerminal else {
            lastErrorMessage = "任务已处于「\(task.status.displayName)」, 无法启动"
            return
        }
        if task.executionMode == .codexDesktop {
            Task { [weak self] in
                await self?.startCodexDesktopTask(taskID: task.id, markRunning: true)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.startRunnerWithLogin(
                taskID: task.id, rotateAccountBeforeStart: task.executionMode == .chatGPTWeb
            )
        }
    }

    /// 新建 Web 任务主动打开 ChatGPT、退出当前会话并登录轮换池下一账号；
    /// 崩溃恢复只检查现有登录态，避免每次重启 App 都额外切号。
    private func startRunnerWithLogin(
        taskID: String,
        rotateAccountBeforeStart: Bool
    ) async {
        do {
            guard let task = try services.tasks.fetch(id: taskID) else {
                throw AppError.invalidRequest("找不到任务: \(taskID)")
            }

            // Codex 桌面任务由额度/登录监视器驱动，不启动旧的 Web/API Runner，
            // 也不会在启动时打开普通 ChatGPT 网页。
            if task.executionMode == .codexDesktop {
                await startCodexDesktopTask(taskID: taskID, markRunning: false)
                return
            }

            if task.executionMode == .chatGPTWeb {
                if rotateAccountBeforeStart {
                    let outcome = try await services.accountRotation
                        .rotateChatGPTAccount(taskID: taskID)
                    lastInfoMessage =
                        "已主动切换并登录 ChatGPT 账号「\(outcome.accountLabel)」，正在启动任务…"
                } else if let label = try await services.accountRotation
                    .ensureInitialChatGPTLogin(taskID: taskID) {
                    lastInfoMessage = "已自动恢复 ChatGPT 账号「\(label)」，正在启动任务…"
                }
            }
            await services.runner.start(taskID: taskID)
            refresh()
        } catch {
            setError(error)
            refresh()
        }
    }

    /// 启动 Codex 桌面任务的后台监视。
    ///
    /// Codex 本身负责生成多步对话；AIRunner 只在绑定的线程上做额度/登录
    /// 异常观察，并在安全门通过后执行一次账号切换和续跑。因此这里绝不能
    /// 交给 JobRunner，否则会误走旧的剪贴板 Web 流程。
    private func startCodexDesktopTask(taskID: String, markRunning: Bool) async {
        do {
            guard let task = try services.tasks.fetch(id: taskID) else {
                throw AppError.invalidRequest("找不到任务: \(taskID)")
            }
            guard task.executionMode == .codexDesktop else {
                throw AppError.invalidRequest("该任务不是 Codex 自动执行任务")
            }
            guard (try services.codexBindings.fetchByTask(taskID: taskID)) != nil else {
                throw AppError.invalidRequest("请先绑定一个已存在的 Codex 工作对话")
            }

            if markRunning, task.status != .running, task.status != .waitingForAccount {
                _ = try services.tasks.updateStatus(
                    id: taskID, to: .running, errorMessage: nil, errorClass: nil
                )
            }

            if task.status == .waitingForAccount {
                // 账号交接期间只等待 Codex 恢复，恢复后由 handoff monitor
                // 复用同一个 resume controller 完成定位、核验与发送。
                codexQuotaMonitorTaskIDs.insert(taskID)
                await services.codexQuotaMonitor.start(taskID: taskID)
                await services.codexMonitor.start(taskID: taskID)
                lastInfoMessage = "正在等待 Codex 完成账号切换，恢复后会自动锁定并发送「继续」"
            } else {
                codexQuotaMonitorTaskIDs.insert(taskID)
                await services.codexQuotaMonitor.start(taskID: taskID)
                lastInfoMessage = "已开始监控 Codex 工作对话；不会打开普通 ChatGPT 网页"
            }
            lastErrorMessage = nil
            refresh()
        } catch {
            setError(error)
            refresh()
        }
    }

    public func pause(_ task: AITask) {
        if task.executionMode == .codexDesktop {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try self.services.tasks.updateStatus(
                        id: task.id, to: .paused, errorMessage: nil, errorClass: nil
                    )
                    self.codexQuotaMonitorTaskIDs.remove(task.id)
                    self.codexMonitorStates[task.id] = nil
                    await self.services.codexQuotaMonitor.stop(taskID: task.id, reason: "任务已暂停")
                    await self.services.codexMonitor.stop(taskID: task.id, reason: "任务已暂停")
                    self.lastErrorMessage = nil
                    self.lastInfoMessage = "Codex 任务已暂停监控"
                    self.refresh()
                } catch { self.setError(error) }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.services.runner.pause(taskID: task.id)
            self.refresh()
        }
    }

    public func resume(_ task: AITask) {
        if task.executionMode == .codexDesktop {
            guard task.status != .completed, task.status != .cancelled else {
                lastErrorMessage = "任务已处于「\(task.status.displayName)」，无法恢复"
                return
            }
            Task { [weak self] in
                guard let self else { return }
                await self.startCodexDesktopTask(taskID: task.id, markRunning: true)
            }
            return
        }
        switch task.status {
        case .failed:
            // failed 必须走专门入口: 先重置失败步骤, 否则它们会被跳过。
            retryFailedTask(task)

        case .completed:
            lastErrorMessage = "任务已完成, 无需恢复"

        case .cancelled:
            lastErrorMessage = "任务已取消, 无法恢复。如需重做请新建任务 (历史结果仍在数据库里)。"

        default:
            Task { [weak self] in
                guard let self else { return }
                await self.services.runner.start(taskID: task.id)
                self.refresh()
            }
        }
    }

    /// 「重试失败步骤」
    ///
    /// failed 任务**唯一**合法的恢复路径:
    /// 1. 把失败步骤重置为 `pending`
    /// 2. 清掉任务的错误标记
    /// 3. 转 `running` 并交回 Runner
    ///
    /// 之所以不能直接 `task.status = running`: 那样 Runner 会从下一个 pending 步骤
    /// 继续, 失败的那一步被跳过 —— 后续结果会建立在缺失的输入上。
    public func retryFailedTask(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reset = try self.services.steps.resetFailedSteps(taskID: task.id)
                guard reset > 0 else {
                    throw AppError.invalidRequest("该任务没有处于失败状态的步骤, 无需重试")
                }

                _ = try self.services.tasks.updateStatus(
                    id: task.id, to: .running, errorMessage: nil, errorClass: nil
                )

                self.services.logger.info(
                    .taskResumed,
                    "已重置 \(reset) 个失败步骤, 任务重新执行",
                    taskID: task.id
                )
                self.lastErrorMessage = nil
                self.lastInfoMessage = "已重置 \(reset) 个失败步骤, 正在重新执行…"

                await self.services.runner.start(taskID: task.id)
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    public func cancel(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            await self.services.runner.cancel(taskID: task.id)
            self.codexQuotaMonitorTaskIDs.remove(task.id)
            self.codexMonitorStates[task.id] = nil
            await self.services.codexQuotaMonitor.stop(taskID: task.id, reason: "任务已取消")
            await self.services.codexMonitor.stop(taskID: task.id, reason: "任务已取消")
            self.refresh()
        }
    }

    /// 删除任务。会先取消运行, 数据通过 ON DELETE CASCADE 一并清除。
    public func delete(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            await self.services.runner.cancel(taskID: task.id)
            self.codexQuotaMonitorTaskIDs.remove(task.id)
            self.codexMonitorStates[task.id] = nil
            await self.services.codexQuotaMonitor.stop(taskID: task.id, reason: "任务已删除")
            await self.services.codexMonitor.stop(taskID: task.id, reason: "任务已删除")
            do {
                try self.services.tasks.delete(id: task.id)
                self.services.logger.info(.taskCancelled, "已删除任务「\(task.name)」")
            } catch {
                self.setError(error)
            }
            self.refresh()
        }
    }

    // MARK: - ChatGPT Web 执行动作

    /// 「Copy Continuation Prompt」
    ///
    /// 生成续跑 prompt → 写入剪贴板 → 打开 ChatGPT, 并把步骤标记为 `prepared`、
    /// 任务转入 `waitingForUser`。**绝不阻塞** —— 用户可能几小时后才回来。
    public func copyContinuationPrompt(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            let settings = self.services.settings
            do {
                let delivery = try await self.services.web.deliverPrompt(
                    taskID: task.id,
                    copyToClipboard: settings.copyPromptToClipboard,
                    openBrowser: settings.openBrowserOnPrepare
                )

                let step = delivery.prepared
                var message = "步骤 \(step.ordinal)/\(step.totalSteps) 的续跑 prompt 已生成"
                message += delivery.copiedToClipboard ? ", 并已复制到剪贴板" : " (剪贴板写入失败)"
                if delivery.browserOpened { message += ", 已请求打开 ChatGPT" }
                message += "。请提交给 ChatGPT, 然后点「粘贴结果」。"

                self.lastErrorMessage = nil
                self.lastInfoMessage = message

                _ = try? self.services.tasks.updateStatus(
                    id: task.id, to: .waitingForUser,
                    errorMessage: message, errorClass: "AWAITING_RESULT"
                )

                self.loadPromptPreview(task)
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 「Paste Result」
    ///
    /// 读取剪贴板中的 ChatGPT 回复 → 校验 → 原子提交 → 交给 Runner 决定下一步。
    /// 校验失败时**不会**推进检查点, 会如实报错。
    public func pasteResult(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let imported = try await self.services.web.importClipboardResult(taskID: task.id)

                self.lastErrorMessage = nil
                self.lastInfoMessage = imported.isFinalStep
                    ? "已导入步骤 \(imported.stepIndex + 1) 的结果 —— 这是最后一步, 任务已完成。"
                    : "已导入步骤 \(imported.stepIndex + 1) 的结果, 还剩 \(imported.remainingSteps) 步。"

                // 交给 Runner: 它要么准备下一步的 prompt, 要么判定任务完成。
                await self.services.runner.start(taskID: task.id)
                self.loadPromptPreview(task)
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 「Pause for Account Switch」
    ///
    /// 先把任务安全转入 `waitingForAccount`, 再按设置自动登录下一个账号。
    /// 登录失败时保持等待状态, 检查点不动, 用户可以处理验证后继续。
    public func pauseForAccountSwitch(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.web.pauseForAccountSwitch(
                    taskID: task.id,
                    reason: "ChatGPT 当前账号已无法继续, 准备自动登录下一个账号"
                )
                self.lastErrorMessage = nil
                self.refresh()

                if self.services.settings.autoLoginNextChatGPTAccountOnHandoff {
                    guard !self.isRotatingAccount else { return }
                    self.isRotatingAccount = true
                    defer { self.isRotatingAccount = false }
                    self.lastInfoMessage = "检查点已安全保存，正在自动登录下一个 ChatGPT 账号…"
                    try await self.performChatGPTAccountSwitch(taskID: task.id)
                } else {
                    self.lastInfoMessage =
                        "检查点已安全保存。可点「自动登录下一个账号」，或手动处理后继续。"
                }
            } catch {
                self.setError(error)
            }
        }
    }

    /// 「I've switched account」: 用户完成手动切换后调用。
    public func resumeAfterAccountSwitch(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.web.resumeAfterManualAccountSwitch(taskID: task.id)
                self.lastErrorMessage = nil
                self.lastInfoMessage = "已从检查点恢复, 正在根据数据库重新生成续跑 prompt…"

                await self.services.runner.start(taskID: task.id)
                self.loadPromptPreview(task)
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 丢弃已生成的 prompt, 让下一步重新生成。
    public func discardPreparedPrompt(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.web.discardPreparedPrompt(taskID: task.id)
                self.promptPreview = nil
                self.promptPreviewTaskID = nil
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 异步加载续跑 prompt 预览 (不写库, 不改变任何状态)。
    public func loadPromptPreview(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            let preview = try? await self.services.web.previewPrompt(taskID: task.id)
            self.promptPreview = preview
            self.promptPreviewTaskID = task.id
        }
    }

    /// 当前正在等待用户回填结果的那一步。
    public func awaitingStep(_ task: AITask) -> TaskStep? {
        (try? services.steps.awaitingResultStep(taskID: task.id)) ?? nil
    }

    public func clearInfoMessage() {
        lastInfoMessage = nil
    }

    // MARK: - Codex Existing Thread 自动恢复

    /// 最近一次 Codex 操作的验证报告 (Test Locate / Dry Run / Resume)。
    @Published public private(set) var codexVerification: CodexResumeVerification?
    /// 验证报告所属的任务 ID (防止串到其他任务的详情页)。
    @Published public private(set) var codexVerificationTaskID: String?
    /// 最近一次 Codex Resume 的结果。
    @Published public private(set) var codexResumeResult: CodexResumeResult?
    /// Codex 监视器当前状态 (按任务 ID)。
    @Published public private(set) var codexMonitorStates: [String: AccountHandoffState] = [:]
    /// 已开启 Codex 额度/登录异常监视的任务。
    @Published public private(set) var codexQuotaMonitorTaskIDs: Set<String> = []

    /// 读取某任务绑定的 Codex 线程 (若有)。
    public func codexBinding(for task: AITask) -> CodexTaskBinding? {
        (try? services.codexBindings.fetchByTask(taskID: task.id)) ?? nil
    }

    /// 保存或更新一个 Codex 绑定。返回值让界面只在真正写库成功后收起表单。
    @discardableResult
    public func saveCodexBinding(_ binding: CodexTaskBinding) -> Bool {
        do {
            if (try? services.codexBindings.fetch(id: binding.id)) != nil {
                try services.codexBindings.update(binding)
            } else {
                try services.codexBindings.insert(binding)
            }
            services.logger.info(
                .codexBindingCreated,
                "已保存 Codex 线程绑定「\(binding.displayTitle)」",
                metadata: .object(["bindingID": .string(binding.id)])
            )
            lastErrorMessage = nil
            lastInfoMessage = "已保存 Codex 工作对话「\(binding.displayTitle)」"

            // 绑定时选定的 Profile 是该任务的初始账号。只在任务还没有
            // 轮换状态时写入，避免编辑绑定或重启应用时把已经轮换到的账号
            // 重置回第一个 Profile。
            if let taskID = binding.taskID,
               let profile = binding.chromeProfileDirectory {
                try services.accountRotationRepo.setInitial(
                    taskID: taskID,
                    profile: profile
                )
            }

            // 绑定保存后即开始后台观察，但只有任务真正处于 running 时才会
            // 解释页面异常；waitingForUser / waitingForAccount 只保持待命。
            if services.settings.autoResumeAfterManualAuthentication,
               let taskID = binding.taskID,
               let task = try? services.tasks.fetch(id: taskID),
               (task.status == .running || task.status == .waitingForUser
                || task.status == .waitingForAccount) {
                codexQuotaMonitorTaskIDs.insert(taskID)
                Task { [weak self] in
                    guard let self else { return }
                    await self.services.codexQuotaMonitor.start(taskID: taskID)
                }
            }
            return true
        } catch {
            setError(error)
            return false
        }
    }

    /// 从当前打开的 Codex 主会话区读取工作对话标题，只读，不输入也不发送。
    public func readCurrentCodexThreadTitle() async -> String? {
        do {
            guard await services.codexDriver.checkAccessibilityPermission() == .granted else {
                throw CodexAutomationError.accessibilityPermissionMissing
            }
            let app = try await services.codexDriver.locateApplication(
                bundleIdentifier: "com.openai.codex"
            )
            // “读取当前对话”通常是在 AIRunner 的绑定表单上触发的，此时 Codex
            // 不是前台应用。先激活 Codex，让 Electron 把当前主会话树刷新到
            // AX；驱动随后会在异步刷新期间只读轮询标题，不会输入或发送内容。
            try await services.codexDriver.activate(app)
            try? await Task.sleep(for: .milliseconds(250))
            try await services.codexDriver.ensureCodexViewPresent(app)
            let context = try await services.codexDriver.readOpenThreadContext(app)
            let title = (context.threadTitle ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CodexAutomationError.targetVerificationFailed(
                    "无法从当前 Codex 主会话区读取工作对话标题。请先在 Codex 中打开目标工作对话；登录页或空白新对话没有可绑定标题"
                )
            }
            lastErrorMessage = nil
            lastInfoMessage = "已读取当前 Codex 工作对话标题"
            return title
        } catch {
            setError(error)
            return nil
        }
    }

    /// 删除一个 Codex 绑定。
    public func deleteCodexBinding(_ binding: CodexTaskBinding) {
        let taskID = binding.taskID
        if let taskID {
            codexQuotaMonitorTaskIDs.remove(taskID)
            codexMonitorStates[taskID] = nil
        }
        do {
            try services.codexBindings.delete(id: binding.id)
            lastInfoMessage = "已删除 Codex 绑定「\(binding.displayTitle)」"
            if let taskID {
                Task { [weak self] in
                    guard let self else { return }
                    await self.services.codexQuotaMonitor.stop(
                        taskID: taskID, reason: "Codex 绑定已删除"
                    )
                    await self.services.codexMonitor.stop(
                        taskID: taskID, reason: "Codex 绑定已删除"
                    )
                }
            }
        } catch {
            setError(error)
        }
    }

    /// Test Locate: 定位 + 打开 + 二次验证, **绝不发送**。
    public func testLocateCodex(bindingID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.services.codexController.testLocate(bindingID: bindingID)
                self.codexVerification = result.verification
                self.codexVerificationTaskID = (try? self.services.codexBindings.fetch(id: bindingID))?.taskID
                self.codexResumeResult = nil
                self.lastErrorMessage = nil
                self.lastInfoMessage = result.succeeded
                    ? "Test Locate 成功: 已打开并验证目标线程 (未发送任何消息)。"
                    : "Test Locate 未通过: \(result.verification.compactSummary)"
            } catch {
                self.codexVerification = nil
                self.setError(error)
            }
        }
    }

    /// Dry Run: 定位 + 验证 + 找到 composer, **不输入、不发送**。
    public func dryRunCodex(bindingID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let verification = try await self.services.codexController.dryRun(bindingID: bindingID)
                self.codexVerification = verification
                self.codexVerificationTaskID = (try? self.services.codexBindings.fetch(id: bindingID))?.taskID
                self.codexResumeResult = nil
                self.lastErrorMessage = nil
                self.lastInfoMessage = "Dry Run 完成: \(verification.compactSummary) (未输入、未发送)"
            } catch {
                self.codexVerification = nil
                self.setError(error)
            }
        }
    }

    /// 锁定目标线程并设置、回读模型；不输入提示词，不发送。
    public func prepareCodexExecution(bindingID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let verification = try await self.services.codexController.prepareExecution(
                    bindingID: bindingID
                )
                self.codexVerification = verification
                self.codexVerificationTaskID = (
                    try? self.services.codexBindings.fetch(id: bindingID)
                )?.taskID
                self.codexResumeResult = nil
                self.lastErrorMessage = nil
                self.lastInfoMessage = "已锁定目标对话并确认模型（未输入、未发送）。"
                self.refresh()
            } catch {
                self.codexVerification = nil
                self.codexResumeResult = nil
                self.setError(error)
            }
        }
    }

    /// Resume: 设置模型后发送绑定中保存的提示词。
    public func resumeCodex(bindingID: String, message: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.services.codexController.resume(
                    bindingID: bindingID, message: message
                )
                self.codexVerification = result.verification
                self.codexVerificationTaskID = (try? self.services.codexBindings.fetch(id: bindingID))?.taskID
                self.codexResumeResult = result
                self.lastErrorMessage = nil
                self.lastInfoMessage = result.isConfirmed
                    ? "已发送「\(result.sentMessage)」并观察到发送确认。"
                    : "已触发发送, 但无法确认 Codex 已接收 (sentUnconfirmed)。"
                self.refresh()
            } catch {
                self.codexVerification = nil
                self.codexResumeResult = nil
                self.setError(error)
            }
        }
    }

    /// 启动账号交接自动恢复监视器。
    public func startCodexMonitor(taskID: String) {
        guard services.settings.autoResumeAfterManualAuthentication else {
            lastInfoMessage = "自动恢复已在设置中关闭。仍可使用 Test Locate、Dry Run 或手动发送「继续」。"
            return
        }
        codexQuotaMonitorTaskIDs.insert(taskID)
        Task { [weak self] in
            guard let self else { return }
            await self.services.codexQuotaMonitor.start(taskID: taskID)
            await self.services.codexMonitor.start(taskID: taskID)
            await self.refreshCodexMonitorState(taskID: taskID)
            self.lastInfoMessage =
                "已开始监视账号交接。请在浏览器中完成账号切换或重新认证 —— "
                + "完成后 AIRunner 会自动恢复绑定的 Codex 任务, 无需再点任何按钮。"
        }
    }

    /// 停止账号交接自动恢复监视器。
    public func stopCodexMonitor(taskID: String, reason: String = "用户手动停止") {
        codexQuotaMonitorTaskIDs.remove(taskID)
        Task { [weak self] in
            guard let self else { return }
            await self.services.codexQuotaMonitor.stop(taskID: taskID, reason: reason)
            await self.services.codexMonitor.stop(taskID: taskID, reason: reason)
            await self.refreshCodexMonitorState(taskID: taskID)
        }
    }

    /// 某任务是否正被监视器跟踪。
    public func isMonitoringCodex(taskID: String) -> Bool {
        codexMonitorStates[taskID] != nil || codexQuotaMonitorTaskIDs.contains(taskID)
    }

    /// 刷新某个任务的监视器状态 (供 UI 轮询显示)。
    public func refreshCodexMonitorState(taskID: String) async {
        let monitoring = await services.codexMonitor.isMonitoring(taskID: taskID)
        if monitoring {
            let state = await services.codexMonitor.state
            codexMonitorStates[taskID] = state
        } else if codexQuotaMonitorTaskIDs.contains(taskID) {
            if await services.codexQuotaMonitor.isMonitoring(taskID: taskID) {
                codexMonitorStates[taskID] = .checkingSession
            } else {
                // 任务进入终态后 quota monitor 会自行退出；同步清理 UI 侧集合，
                // 避免“未监视的任务”一直显示为已开启。
                codexQuotaMonitorTaskIDs.remove(taskID)
                codexMonitorStates[taskID] = nil
            }
        } else {
            codexMonitorStates[taskID] = nil
        }
    }

    /// 安全测试“额度耗尽 → 退出 Codex → 切换账号 → 恢复原线程”。
    /// Core 会先读取真实 Codex 忙碌状态；仍在生成时不会执行任何退出操作。
    public func simulateCodexQuotaHandoff(_ task: AITask) {
        guard !isRotatingAccount else { return }
        isRotatingAccount = true
        lastErrorMessage = nil
        lastInfoMessage = task.status == .waitingForAccount
            ? "正在继续上次未完成的账号切换…"
            : "正在确认 Codex 已停止生成…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isRotatingAccount = false }
            do {
                let outcome = try await self.services.codexQuotaMonitor
                    .simulateQuotaExhaustion(taskID: task.id)
                switch outcome {
                case .rotationCompleted:
                    self.lastInfoMessage =
                        "安全模拟已通过：已退出当前 Codex 账号并完成下一个账号授权，正在恢复绑定线程。"
                case .rotationFailed(let message):
                    self.lastErrorMessage = message
                default:
                    self.lastInfoMessage = "安全模拟未执行账号切换，请查看当前 Codex 状态。"
                }
                self.codexQuotaMonitorTaskIDs.insert(task.id)
                await self.refreshCodexMonitorState(taskID: task.id)
                self.refresh()
            } catch {
                self.setError(error)
                self.refresh()
            }
        }
    }

    /// 恢复过期的 Resume 租约 (用户显式操作)。
    public func recoverStaleCodexLease(bindingID: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let released = try await self.services.codexController.recoverStaleLease(bindingID: bindingID)
                self.lastInfoMessage = released
                    ? "已恢复过期的 Resume 锁, 可以重新尝试。"
                    : "没有需要恢复的锁。"
            } catch {
                self.setError(error)
            }
        }
    }

    // MARK: - Chrome Profile 自动账号轮换

    /// 最近一次自动轮换的结果 (供 UI 显示摘要)。
    @Published public private(set) var lastRotationOutcome: AccountRotationOutcome?
    /// 当前任务正在执行自动轮换 (防止连点)。
    @Published public private(set) var isRotatingAccount = false

    /// 查询某任务当前使用的 Chrome profile 显示名。
    public func currentAccountProfileName(for task: AITask) -> String? {
        (try? services.accountRotationRepo.currentProfile(taskID: task.id)) ?? nil
    }

    /// 查询轮换池里的 profile 列表 (设置页用)。
    public func availableChromeProfiles() -> [(browser: ChromeProfileScanner.ChromeKind, profiles: [ChromeProfile])] {
        services.chromeProfiles.availableProfilesAcrossBrowsers()
    }

    /// ★ 自动登录下一个 ChatGPT 账号 ★
    ///
    /// 侧边栏登出 → 从 Keychain 读取并键入下一个账号的 email+密码。
    /// 不换浏览器或 profile。
    ///
    /// 切换成功后自动:
    /// 1. 若任务在 `waitingForAccount` → 从检查点恢复执行 (Runner 重新生成自包含 prompt)
    /// 2. 生成/复制续跑 prompt —— 新账号没有旧会话历史, 自包含 prompt 正好无缝续跑
    public func switchChatGPTAccount(_ task: AITask) {
        guard !isRotatingAccount else { return }
        isRotatingAccount = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isRotatingAccount = false }

            do {
                try await self.performChatGPTAccountSwitch(taskID: task.id)
            } catch {
                self.lastRotationOutcome = nil
                self.setError(error)
            }
        }
    }

    /// 自动登录成功后读取数据库中的最新状态，再恢复检查点。
    private func performChatGPTAccountSwitch(taskID: String) async throws {
        let outcome = try await services.accountRotation.rotateChatGPTAccount(taskID: taskID)
        lastRotationOutcome = AccountRotationOutcome(
            fromProfile: nil,
            toProfile: outcome.accountLabel,
            toProfileDisplayName: outcome.accountLabel,
            browserOpened: true,
            windowFocused: true,
            focusFailureReason: nil
        )
        lastErrorMessage = nil

        var message = "已自动登录 ChatGPT 账号「\(outcome.accountLabel)」。"
        let latest = try services.tasks.fetch(id: taskID)
        if latest?.status == .waitingForAccount {
            try await services.web.resumeAfterManualAccountSwitch(taskID: taskID)
            message += " 已从检查点恢复，正在生成续跑 prompt…"
            await services.runner.start(taskID: taskID)
        } else {
            message += " 可以继续提交当前续跑 prompt。"
        }
        lastInfoMessage = message

        if let refreshedTask = try services.tasks.fetch(id: taskID) {
            loadPromptPreview(refreshedTask)
        }
        refresh()
    }

    /// 枚举浏览器里登录的全部 ChatGPT 账号 (设置页用)。
    public func listChatGPTAccounts() async throws -> [ChatGPTAccountEntry] {
        try await services.accountRotation.listChatGPTAccounts()
    }

    /// 查询某任务当前使用的 ChatGPT 账号。
    public func currentChatGPTAccountName(for task: AITask) -> String? {
        guard let pointer = (try? services.accountRotationRepo
            .currentChatGPTAccount(taskID: task.id)) ?? nil else { return nil }
        if let record = try? services.codexAccountVault.fetch(id: pointer) {
            return record.label
        }
        return pointer
    }

    /// ★ 一键自动切换账号 (Chrome Profile 模式, 备用) ★
    ///
    /// 流程: 选下一个 profile → 用它打开 ChatGPT → AX 把窗口调到前台。
    /// 用户事先在每个 Profile 里登录好账号即可。
    ///
    /// 切换成功后:
    /// - 若任务在 `waitingForAccount`: 自动从检查点恢复执行
    /// - 若任务在 `waitingForUser`: 提示直接在新窗口粘贴
    public func rotateAccount(_ task: AITask) {
        guard !isRotatingAccount else { return }
        isRotatingAccount = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isRotatingAccount = false }

            do {
                let outcome = try await self.services.accountRotation.rotate(taskID: task.id)
                self.lastRotationOutcome = outcome
                self.lastErrorMessage = nil
                self.lastInfoMessage = outcome.summary

                // 账号切换完成后: 从 waitingForAccount 恢复执行
                if task.status == .waitingForAccount {
                    try? await self.services.web.resumeAfterManualAccountSwitch(taskID: task.id)
                    await self.services.runner.start(taskID: task.id)
                    self.loadPromptPreview(task)
                }

                self.refresh()
            } catch {
                self.lastRotationOutcome = nil
                self.setError(error)
            }
        }
    }

    /// 主界面指定一个 Chrome Profile 切换 Codex 账号。
    ///
    /// 这是“账号选择”入口，不会发送提示词。若任务正处于额度耗尽后的
    /// `waitingForAccount`，认证完成后重新启用恢复监视器，由同一个
    /// `CodexResumeController` 完成目标会话核验和一次「继续」发送。
    public func switchCodexAccount(_ task: AITask, to profileDirectory: String) {
        guard task.executionMode == .codexDesktop else {
            lastErrorMessage = "只有 Codex 自动执行任务支持在主界面选择 Profile 账号"
            return
        }
        guard !task.status.isTerminal else {
            lastErrorMessage = "任务已处于「\(task.status.displayName)」，无法切换账号"
            return
        }
        // 手动切号不能打断正在生成的 Codex 对话。额度监视器会在安全门
        // 通过后自动切换；用户手动操作时先暂停监视，避免触发 Codex 的
        // “退出 ChatGPT？”保护弹窗或丢失当前生成。
        guard task.status != .running else {
            lastErrorMessage = "当前 Codex 任务仍在运行，请先暂停监控，再手动切换账号"
            return
        }
        guard !isRotatingAccount else { return }

        isRotatingAccount = true
        lastErrorMessage = nil
        lastInfoMessage = "正在安全退出 Codex 并登录所选账号…"

        Task { [weak self] in
            guard let self else { return }
            defer { self.isRotatingAccount = false }
            do {
                guard let latest = try self.services.tasks.fetch(id: task.id) else {
                    throw AppError.invalidRequest("找不到任务: \(task.id)")
                }
                guard latest.status != .running else {
                    throw AppError.invalidRequest(
                        "当前 Codex 任务仍在运行，请先暂停监控，再手动切换账号"
                    )
                }

                // 任务可能在 AIRunner 刷新间隔内被重新启动；同时检查 Codex
                // 的全部窗口，防止手动切号影响另一条正在生成的对话。
                try await self.ensureCodexHasNoGeneratingTask()

                let outcome = try await self.services.accountRotation.switchCodexAccount(
                    taskID: task.id,
                    to: profileDirectory
                )
                // 认证成功后把所选 Profile 同步写入绑定。这样应用重启、
                // 自动轮换和主界面选择器都会从同一个非敏感指针继续，失败时
                // 不会提前改写绑定。
                if var binding = try self.services.codexBindings.fetchByTask(taskID: task.id) {
                    binding.chromeProfileDirectory = profileDirectory
                    binding.updatedAt = Date()
                    try self.services.codexBindings.update(binding)
                }
                self.lastRotationOutcome = AccountRotationOutcome(
                    fromProfile: nil,
                    toProfile: profileDirectory,
                    toProfileDisplayName: outcome.accountLabel,
                    browserOpened: true,
                    windowFocused: true,
                    focusFailureReason: nil
                )

                let updatedTask = try self.services.tasks.fetch(id: task.id)
                if updatedTask?.status == .waitingForAccount {
                    self.codexQuotaMonitorTaskIDs.insert(task.id)
                    await self.services.codexQuotaMonitor.start(taskID: task.id)
                    await self.services.codexMonitor.start(taskID: task.id)
                    self.lastInfoMessage =
                        "已登录「\(outcome.accountLabel)」，正在等待 Codex 恢复并自动锁定目标对话"
                } else {
                    self.lastInfoMessage =
                        "已切换到「\(outcome.accountLabel)」。未发送消息，任务仍按当前状态等待"
                }
                self.refresh()
            } catch {
                self.lastRotationOutcome = nil
                self.setError(error)
                self.refresh()
            }
        }
    }

    /// 手动账号切换前的全局安全门。不可用时不猜测状态，让认证链路给出
    /// 明确错误；可用时只要任意 Codex 窗口显示生成指示，就拒绝退出。
    private func ensureCodexHasNoGeneratingTask() async throws {
        let probe = await services.codexDriver.probeAvailability(
            bundleIdentifier: "com.openai.codex"
        )
        guard probe.isUsable else { return }
        let app = try await services.codexDriver.locateApplication(
            bundleIdentifier: "com.openai.codex"
        )
        guard try await !services.codexDriver.detectAnyTaskGenerating(app) else {
            throw AppError.invalidRequest(
                "检测到 Codex 仍有对话正在生成，已拒绝退出账号；请等所有对话停止后再试"
            )
        }
    }

    // MARK: - 查询

    public func steps(for task: AITask) -> [TaskStep] {
        (try? services.steps.fetchAll(taskID: task.id)) ?? []
    }

    public func latestCheckpoint(for task: AITask) -> Checkpoint? {
        try? services.checkpoints.latest(taskID: task.id)
    }

    public func checkpoints(for task: AITask, limit: Int = 50) -> [Checkpoint] {
        (try? services.checkpoints.list(taskID: task.id, limit: limit)) ?? []
    }

    public func events(for task: AITask? = nil, limit: Int = 300) -> [AppEvent] {
        (try? services.events.list(taskID: task?.id, limit: limit)) ?? []
    }

    public func stepStatusCounts(for task: AITask) -> [StepStatus: Int] {
        (try? services.steps.statusCounts(taskID: task.id)) ?? [:]
    }

    public func isActive(_ task: AITask) -> Bool {
        activeRunnerTaskIDs.contains(task.id)
    }

    // MARK: - 错误

    private func setError(_ error: Error) {
        if let automationError = error as? CodexAutomationError,
           automationError == .accessibilityPermissionMissing {
            // 由用户点击“开始”触发时请求系统显示正式授权提示。
            // macOS 仍要求用户亲自在系统设置里批准，应用不能自行授予权限。
            _ = services.accessibilityPermission.requestPermission()
        }
        let appError = AppError.normalize(error)
        lastErrorMessage = appError.userMessage
        services.logger.error(.unknown, appError.userMessage)
    }

    public func openAccessibilitySettings() {
        services.accessibilityPermission.openAccessibilitySettings()
    }
}

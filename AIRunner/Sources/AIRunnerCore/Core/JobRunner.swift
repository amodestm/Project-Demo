import Foundation

/// JobRunner 的依赖集合。
///
/// 全部显式注入, 不用单例 —— 这样测试里可以塞入 MockAIProvider 与内存数据库,
/// 且 Runner 本身**不依赖 SwiftUI / Combine**, 可以被纯命令行测试驱动。
public struct JobRunnerDependencies: Sendable {

    public var tasks: TaskRepository
    public var steps: StepRepository
    public var router: ModelRouter
    public var retry: RetryManager
    public var checkpoints: CheckpointManager
    public var factory: ProviderFactory
    public var logger: LoggerService
    public var registry: TaskExecutionRegistry
    /// ChatGPT Web 执行通道 (主流程)。
    public var web: any WebExecutionCoordinating
    public var config: RetryConfiguration
    /// 全局最多同时运行几个任务。
    public var concurrency: Int

    public init(
        tasks: TaskRepository,
        steps: StepRepository,
        router: ModelRouter,
        retry: RetryManager,
        checkpoints: CheckpointManager,
        factory: ProviderFactory,
        logger: LoggerService,
        registry: TaskExecutionRegistry,
        web: any WebExecutionCoordinating,
        config: RetryConfiguration = .default,
        concurrency: Int = 3
    ) {
        self.tasks = tasks
        self.steps = steps
        self.router = router
        self.retry = retry
        self.checkpoints = checkpoints
        self.factory = factory
        self.logger = logger
        self.registry = registry
        self.web = web
        self.config = config
        self.concurrency = concurrency
    }
}

/// 任务执行器 —— 整个系统最核心的部分。
///
/// 执行循环 (单任务):
/// ```
/// 读任务 → 检查取消/暂停 → 取下一个可执行步骤 → 选 backend
///        → 标记 running → 调用模型 → 校验输出
///        → 【单事务】写结果 + 写检查点 + 推进进度 → 下一步
/// ```
///
/// 三条不可动摇的规则:
/// 1. 步骤只有在 **事务提交成功** 后才算完成, 因此重启不会重跑。
/// 2. 每个错误按 `ErrorStrategy` 分派不同动作, 绝不"一律重试"。
/// 3. 同一任务同时最多一个 runner (由 `TaskExecutionRegistry` 保证)。
public actor JobRunner {

    private let deps: JobRunnerDependencies
    private let semaphore: AsyncSemaphore

    private var pauseRequests: Set<String> = []
    private var cancelRequests: Set<String> = []
    private var handles: [String: Task<Void, Never>] = [:]

    public init(dependencies: JobRunnerDependencies) {
        self.deps = dependencies
        self.semaphore = AsyncSemaphore(limit: max(1, dependencies.concurrency))
    }

    // MARK: - 控制面

    /// 启动 (或恢复) 一个任务。非阻塞: 立即返回, 实际执行在后台。
    public func start(taskID: String) async {
        if handles[taskID] != nil {
            deps.logger.warning(
                .runnerRejectedDuplicate,
                "该任务已有 runner 在运行, 忽略重复启动",
                taskID: taskID
            )
            return
        }

        let task: AITask
        do {
            guard let fetched = try deps.tasks.fetch(id: taskID) else {
                deps.logger.error(.runnerStopped, "任务不存在: \(taskID)")
                return
            }
            task = fetched
        } catch {
            deps.logger.record(error, eventType: .taskFailed, taskID: taskID)
            return
        }

        guard !task.status.isTerminal else {
            deps.logger.warning(
                .runnerRejectedDuplicate,
                "任务处于终态 (\(task.status.displayName)), 拒绝启动",
                taskID: taskID
            )
            return
        }

        // ★ A7: failed 任务不能直接 start ★
        //
        // 直接 start 会把状态改成 running, 随后 nextExecutableStep 会返回下一个
        // pending 步骤 —— **失败的那一步被静默跳过**, 后续结果全部建立在缺失的
        // 前置输入上, 而且不报任何错。
        //
        // 唯一合法路径是 `TaskManager.retryFailedTask`: 先重置失败步骤, 再启动。
        guard task.status != .failed else {
            deps.logger.warning(
                .runnerRejectedDuplicate,
                "任务处于失败状态。请使用「重试失败步骤」—— 直接继续会跳过失败的那一步。",
                taskID: taskID
            )
            return
        }

        // ★ 跨 layer 的重复启动防护 ★
        let claimed = await deps.registry.claim(taskID)
        guard claimed else {
            deps.logger.warning(
                .runnerRejectedDuplicate,
                "任务已在执行中 (registry 已被占用), 忽略重复启动",
                taskID: taskID
            )
            return
        }

        pauseRequests.remove(taskID)
        cancelRequests.remove(taskID)

        if task.status != .running {
            do {
                _ = try deps.tasks.updateStatus(id: taskID, to: .running)
            } catch {
                deps.logger.record(error, eventType: .taskFailed, taskID: taskID)
                await deps.registry.release(taskID)
                return
            }
        }

        let handle = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.execute(taskID: taskID)
        }
        handles[taskID] = handle
    }

    /// 请求暂停。
    ///
    /// **优雅暂停语义**: 不中断正在进行中的 HTTP 请求 —— 等它返回并提交结果后,
    /// 在循环边界处转入 paused。这样"成功响应不会因为暂停而丢失"。
    public func pause(taskID: String) async {
        guard handles[taskID] != nil else {
            // 没有活跃 runner: 直接改状态即可
            _ = try? deps.tasks.updateStatus(id: taskID, to: .paused)
            deps.logger.info(.taskPaused, "任务已暂停", taskID: taskID)
            return
        }
        pauseRequests.insert(taskID)
        deps.logger.info(.taskPaused, "已请求暂停, 将在当前步骤提交后生效", taskID: taskID)
    }

    /// 取消。立即中断退避睡眠; 已提交的结果与检查点全部保留, 不删任何数据。
    public func cancel(taskID: String) async {
        cancelRequests.insert(taskID)
        if let handle = handles[taskID] {
            handle.cancel()
        } else {
            _ = try? deps.tasks.updateStatus(id: taskID, to: .cancelled)
            deps.logger.info(.taskCancelled, "任务已取消, 历史数据保留", taskID: taskID)
        }
    }

    public func activeTaskIDs() -> [String] {
        handles.keys.sorted()
    }

    public func isRunning(taskID: String) -> Bool {
        handles[taskID] != nil
    }

    public func isPauseRequested(taskID: String) -> Bool {
        pauseRequests.contains(taskID)
    }

    public func isCancelRequested(taskID: String) -> Bool {
        cancelRequests.contains(taskID)
    }

    /// 等待某个任务跑完 (测试用)。
    public func waitForCompletion(taskID: String) async {
        guard let handle = handles[taskID] else { return }
        await handle.value
    }

    // MARK: - 执行生命周期

    private func execute(taskID: String) async {
        await semaphore.acquire()
        let reason = await runLoop(taskID: taskID)
        await semaphore.release()

        handles.removeValue(forKey: taskID)
        pauseRequests.remove(taskID)
        cancelRequests.remove(taskID)
        await deps.registry.release(taskID)

        deps.logger.info(.runnerStopped, "Runner 退出: \(reason)", taskID: taskID)
    }

    private func runLoop(taskID: String) async -> String {
        guard var task = (try? deps.tasks.fetch(id: taskID)) ?? nil else {
            return "task-missing"
        }

        deps.logger.info(
            .taskStarted,
            "开始执行任务「\(task.name)」, 共 \(task.totalSteps) 步",
            taskID: taskID
        )

        while true {

            // --- 1) 取消检查 ---
            if cancelRequests.contains(taskID) || Task.isCancelled {
                _ = try? deps.tasks.updateStatus(id: taskID, to: .cancelled)
                deps.logger.info(
                    .taskCancelled,
                    "任务已取消。已完成的 \(task.currentStep) 步结果与检查点全部保留。",
                    taskID: taskID
                )
                return "cancelled"
            }

            // --- 2) 暂停检查 (只在步骤边界, 保证不丢已提交结果) ---
            if pauseRequests.contains(taskID) {
                _ = try? deps.tasks.updateStatus(id: taskID, to: .paused)
                deps.logger.info(
                    .taskPaused,
                    "任务已暂停于第 \(task.currentStep)/\(task.totalSteps) 步",
                    taskID: taskID
                )
                return "paused"
            }

            // --- 3) 取下一个可执行步骤 ---
            // 注意: 这里必须区分"没有待执行步骤"和"数据库出错" ——
            // 把 DB 错误误判成"任务完成"会让任务静默变成 completed。
            let nextStep: TaskStep?
            do {
                nextStep = try deps.steps.nextExecutableStep(taskID: taskID)
            } catch {
                deps.logger.record(error, eventType: .taskFailed, taskID: taskID)
                return "db-error"
            }

            guard let step = nextStep else {
                return finishTask(task)
            }

            // --- 4) 执行该步骤 ---
            let outcome = await executeStep(task: task, step: step)

            switch outcome {
            case .success:
                if let refreshed = (try? deps.tasks.fetch(id: taskID)) ?? nil {
                    task = refreshed
                }

            case .awaitingUser(let reason):
                _ = try? deps.tasks.updateStatus(
                    id: taskID, to: .waitingForUser,
                    errorMessage: reason, errorClass: "AWAITING_RESULT"
                )
                deps.logger.info(
                    .taskWaiting,
                    "任务已转入「等待提交结果」并退出 Runner: \(reason)",
                    taskID: taskID
                )
                return "awaiting-user"

            case .awaitingAccount(let reason):
                _ = try? deps.tasks.updateStatus(
                    id: taskID, to: .waitingForAccount,
                    errorMessage: reason, errorClass: "ACCOUNT_HANDOFF"
                )
                deps.logger.warning(
                    .taskWaiting,
                    "任务已转入「等待切换账号」并退出 Runner: \(reason)",
                    taskID: taskID
                )
                return "awaiting-account"

            case .paused(let error):
                _ = try? deps.tasks.updateStatus(
                    id: taskID, to: .paused,
                    errorMessage: error.userMessage, errorClass: error.eventName
                )
                deps.logger.error(
                    .taskPaused,
                    "任务暂停, 需要人工处理: \(error.userMessage)",
                    taskID: taskID
                )
                return "paused-error"

            case .failed(let error):
                _ = try? deps.tasks.updateStatus(
                    id: taskID, to: .failed,
                    errorMessage: error.userMessage, errorClass: error.eventName
                )
                deps.logger.error(
                    .taskFailed,
                    "任务失败于第 \(step.index + 1) 步: \(error.userMessage)",
                    taskID: taskID
                )
                return "failed"

            case .cancelled:
                _ = try? deps.tasks.updateStatus(id: taskID, to: .cancelled)
                return "cancelled"
            }
        }
    }

    private func finishTask(_ task: AITask) -> String {
        let counts = (try? deps.steps.statusCounts(taskID: task.id)) ?? [:]
        let failed = counts[.failed] ?? 0
        let completed = counts[.completed] ?? 0

        do {
            _ = try deps.tasks.updateStatus(id: task.id, to: .completed)
            deps.logger.info(
                .taskCompleted,
                "任务完成: 成功 \(completed) 步, 失败 \(failed) 步, 共 \(task.totalSteps) 步",
                taskID: task.id
            )
            return "completed"
        } catch {
            deps.logger.record(error, eventType: .taskFailed, taskID: task.id)
            return "completed-but-persist-failed"
        }
    }

    // MARK: - 单步执行 (含重试与 fallback)

    private enum StepOutcome {
        case success
        /// Web 模式: 续跑 prompt 已生成并交付, 等用户提交并回填结果。
        case awaitingUser(reason: String)
        /// Web 模式: 当前 ChatGPT session 无法继续, 等用户手动切换账号。
        case awaitingAccount(reason: String)
        case paused(AppError)
        case failed(AppError)
        case cancelled
    }

    /// 按执行通道分派。
    ///
    /// 两条通道**共用**完全相同的持久化与编排设施 (SQLite / TaskStep / Checkpoint /
    /// RecoveryManager / Logs / ResponseValidator), 差别只在"这一步的结果从哪里来"。
    private func executeStep(task: AITask, step: TaskStep) async -> StepOutcome {
        switch task.executionMode {
        case .chatGPTWeb:
            return await executeWebStep(task: task, step: step)
        case .api:
            return await executeAPIStep(task: task, step: step)
        }
    }

    // MARK: - ChatGPT Web 通道 (主流程)

    /// 生成续跑 prompt, 然后把任务转入「等用户」。
    ///
    /// 这条路径**绝不阻塞等待用户** —— 用户可能几小时甚至几天后才回来。
    /// Runner 生成 prompt 后立刻返回 `.awaitingUser`, runLoop 据此把任务转入
    /// `waitingForUser` 并退出; 用户回填结果后由 TaskManager 重新拉起 Runner。
    ///
    /// 这正是"AI = 执行器, 本程序 = 真正的任务控制器"的落点: 账号可以换、
    /// 会话可以断, 但任务状态始终在数据库里。
    private func executeWebStep(task: AITask, step: TaskStep) async -> StepOutcome {
        do {
            let delivery = try await deps.web.deliverPrompt(
                taskID: task.id,
                copyToClipboard: true,
                openBrowser: true
            )
            let prepared = delivery.prepared

            deps.logger.info(
                .webStepPrepared,
                "步骤 \(prepared.ordinal)/\(task.totalSteps) 的续跑 prompt 已生成 "
                + "(\(prepared.prompt.count) 字符)"
                + (delivery.copiedToClipboard ? ", 已复制到剪贴板" : ", 剪贴板写入失败")
                + (delivery.browserOpened ? ", 已请求打开 ChatGPT" : ""),
                taskID: task.id, stepIndex: step.index
            )

            return .awaitingUser(
                reason: "步骤 \(prepared.ordinal) 的续跑 prompt 已就绪, "
                      + "请提交给 ChatGPT 后把回复粘贴回来"
            )

        } catch let error as WebExecutionError {
            if case .noExecutableStep = error {
                // 竞态: 该步骤在此期间已被处理。返回 success 让 runLoop 重新取下一步。
                return .success
            }
            return .failed(AppError.invalidRequest(error.userMessage))

        } catch {
            return .failed(AppError.normalize(error))
        }
    }

    // MARK: - API 通道 (可选后端)

    /// 原有的 router / provider / retry 全流程。默认不参与主流程。
    private func executeAPIStep(task: AITask, step: TaskStep) async -> StepOutcome {
        var attemptedBackends: Set<String> = []
        var budget = StepRetryBudget()
        var lastError: AppError = .fatal("步骤尚未产生任何错误记录")

        // 外层循环: 换 backend
        while true {

            guard let backend = await deps.router.selectBackend(
                excluding: attemptedBackends,
                preferredProvider: task.primaryProvider,
                preferredModel: task.primaryModel
            ) else {
                let explanation = await deps.router.explainNoBackend(excluding: attemptedBackends)
                deps.logger.error(
                    .backendExhausted,
                    "没有可用 backend。诊断: \(explanation)",
                    taskID: task.id, stepIndex: step.index
                )

                // 认证/余额这类问题换谁都救不了 → 暂停等用户。
                if lastError.strategy == .pauseTask {
                    try? deps.steps.markPending(
                        stepID: step.id,
                        error: lastError.userMessage,
                        errorClass: lastError.eventName
                    )
                    return .paused(lastError)
                }

                try? deps.steps.markFailed(
                    stepID: step.id,
                    error: lastError.userMessage,
                    errorClass: lastError.eventName
                )
                return .failed(lastError)
            }

            attemptedBackends.insert(backend.label)

            if attemptedBackends.count > 1 {
                deps.logger.warning(
                    .backendSwitched,
                    "切换到备用 backend: \(backend.label)",
                    taskID: task.id, stepIndex: step.index
                )
            }

            do {
                try deps.steps.markRunning(
                    stepID: step.id,
                    provider: backend.providerID,
                    model: backend.model
                )
                try deps.steps.recordBackendAttempt(
                    stepID: step.id,
                    provider: backend.providerID,
                    model: backend.model,
                    note: nil
                )
            } catch {
                deps.logger.record(error, eventType: .stepFailed, taskID: task.id, stepIndex: step.index)
                return .failed(AppError.normalize(error))
            }

            deps.logger.info(
                .backendSelected,
                "步骤 \(step.index + 1) 使用 \(backend.label)",
                taskID: task.id, stepIndex: step.index
            )

            // 内层循环: 同一 backend 上重试
            inner: while true {

                if cancelRequests.contains(task.id) || Task.isCancelled {
                    try? deps.steps.markPending(stepID: step.id, error: "已取消")
                    return .cancelled
                }

                // 读最新检查点作为上下文 (CheckpointManager 是 actor, 必须 await)
                let checkpoint = (try? await deps.checkpoints.latest(taskID: task.id)) ?? nil

                let request = TaskPlanner.buildRequest(
                    task: task,
                    step: step,
                    checkpoint: checkpoint,
                    responseFormat: TaskPlanner.responseFormat(for: step),
                    maxOutputTokens: deps.factory.config(for: backend.providerID)?.maxOutputTokens ?? 2048,
                    temperature: 0.2,
                    timeout: deps.factory.config(for: backend.providerID)?.timeout ?? 180,
                    contextShrinkFactor: shrinkFactor(for: step)
                )

                let provider: any AIProvider
                do {
                    provider = try deps.factory.makeProvider(
                        providerID: backend.providerID, model: backend.model
                    )
                } catch {
                    let appError = AppError.normalize(error)
                    lastError = appError
                    await deps.router.noteFailure(backend, error: appError)
                    try? deps.steps.appendAttempt(
                        stepID: step.id,
                        attempt: failurePayload(error: appError, backend: backend, delay: nil),
                        bumpRetry: false
                    )
                    break inner   // 换 backend
                }

                let started = Date()

                do {
                    let response = try await provider.execute(request: request)

                    let validator = CompositeResponseValidator.standard(for: request.responseFormat)
                    try validator.validate(response, request: request)

                    let durationMs = max(0, Int(Date().timeIntervalSince(started) * 1000))

                    let output = JSONValue.object([
                        "text": .string(response.text),
                        "provider": .string(response.provider),
                        "model": .string(response.model),
                        "inputTokens": response.inputTokens.map { JSONValue.int($0) } ?? .null,
                        "outputTokens": response.outputTokens.map { JSONValue.int($0) } ?? .null,
                        "latencyMs": .int(response.latencyMilliseconds),
                        "finishReason": response.finishReason.map { JSONValue.string($0) } ?? .null,
                    ])

                    let newCheckpoint = await deps.checkpoints.makeCheckpoint(
                        taskID: task.id,
                        completedStep: step.index,
                        previous: checkpoint,
                        output: output,
                        provider: response.provider,
                        model: response.model
                    )

                    // ★ 原子提交: 结果 + 检查点 + 进度, 一个事务 ★
                    // 走 API 专用入口 —— 强制前置状态必须是 running。
                    do {
                        try deps.steps.commitRunningAPIStep(
                            SuccessfulStepCommit(
                                stepID: step.id,
                                taskID: task.id,
                                output: output,
                                provider: response.provider,
                                model: response.model,
                                durationMs: durationMs,
                                checkpoint: newCheckpoint,
                                newCurrentStep: step.index + 1
                            )
                        )
                    } catch {
                        let appError = AppError.normalize(error)
                        deps.logger.error(
                            .stepFailed,
                            "步骤结果提交失败 (事务回滚, 该步将重跑): \(appError.userMessage)",
                            taskID: task.id, stepIndex: step.index
                        )
                        try? deps.steps.markPending(stepID: step.id, error: appError.userMessage)
                        return .failed(appError)
                    }

                    await deps.router.noteSuccess(backend)

                    deps.logger.info(
                        .stepCompleted,
                        "步骤 \(step.index + 1)/\(task.totalSteps) 完成 (\(durationMs)ms, \(response.backendLabel))",
                        taskID: task.id, stepIndex: step.index
                    )
                    deps.logger.info(
                        .checkpointSaved,
                        "检查点已保存: completedStep=\(newCheckpoint.completedStep) nextStep=\(newCheckpoint.nextStep)",
                        taskID: task.id, stepIndex: step.index
                    )
                    return .success

                } catch {

                    let appError = AppError.normalize(error)
                    lastError = appError

                    // ★ 取消不是失败 ★
                    // 若不单独处理, 用户点 Cancel 会让步骤走 .failTask 分支被标记为 failed,
                    // 任务随之变成 failed —— 而需求要求 cancelled 且完整保留历史。
                    if case .cancelled = appError {
                        try? deps.steps.markPending(stepID: step.id, error: "已取消")
                        return .cancelled
                    }

                    deps.logger.warning(
                        .stepRetry,
                        "步骤 \(step.index + 1) 失败: \(appError.eventName) — \(appError.userMessage)",
                        taskID: task.id, stepIndex: step.index
                    )

                    let health = await deps.router.noteFailure(backend, error: appError)

                    switch appError.strategy {

                    case .pauseTask:
                        // 认证失败 / 余额耗尽: 不重试, 不换 backend 硬撑, 直接交给用户。
                        try? deps.steps.markPending(
                            stepID: step.id,
                            error: appError.userMessage,
                            errorClass: appError.eventName
                        )
                        try? deps.steps.appendAttempt(
                            stepID: step.id,
                            attempt: failurePayload(error: appError, backend: backend, delay: nil)
                        )
                        return .paused(appError)

                    case .failStep, .failTask:
                        try? deps.steps.markFailed(
                            stepID: step.id,
                            error: appError.userMessage,
                            errorClass: appError.eventName
                        )
                        try? deps.steps.appendAttempt(
                            stepID: step.id,
                            attempt: failurePayload(error: appError, backend: backend, delay: nil)
                        )
                        return .failed(appError)

                    case .switchBackend:
                        try? deps.steps.appendAttempt(
                            stepID: step.id,
                            attempt: failurePayload(error: appError, backend: backend, delay: nil)
                        )
                        if health.state == .unavailable {
                            deps.logger.error(
                                .providerUnavailable,
                                "\(backend.label) 已熔断: \(health.statusDescription)",
                                taskID: task.id, stepIndex: step.index
                            )
                        }
                        break inner   // 换 backend

                    case .retrySame, .retryWithBackoff, .shrinkContext:
                        if case .shrinkContext = appError.strategy {
                            // 记录一次 shrink, 让下次构造请求时裁剪上下文
                            markShrinkRequested(stepID: step.id)
                        }

                        let canRetry = await deps.retry.shouldRetry(error: appError, budget: budget)
                        guard canRetry else {
                            try? deps.steps.appendAttempt(
                                stepID: step.id,
                                attempt: failurePayload(error: appError, backend: backend, delay: nil)
                            )
                            deps.logger.warning(
                                .backendSwitched,
                                "步骤 \(step.index + 1) 重试预算耗尽 (\(budget.summary)), 改用备用 backend",
                                taskID: task.id, stepIndex: step.index
                            )
                            break inner
                        }

                        guard let delay = await deps.retry.delay(for: appError, budget: budget) else {
                            break inner
                        }

                        RetryPolicy.consume(&budget, error: appError)

                        try? deps.steps.appendAttempt(
                            stepID: step.id,
                            attempt: failurePayload(error: appError, backend: backend, delay: delay)
                        )

                        if case .rateLimit = appError {
                            deps.logger.warning(
                                .rateLimited,
                                "触发限流, 等待 \(Int(delay))s 后重试 (\(budget.summary))",
                                taskID: task.id, stepIndex: step.index
                            )
                        } else {
                            deps.logger.info(
                                .stepRetry,
                                "\(Int(delay))s 后重试 (\(budget.summary))",
                                taskID: task.id, stepIndex: step.index
                            )
                        }

                        do {
                            try await deps.retry.sleep(delay, isCancelled: { [weak self] in
                                guard let self else { return true }
                                return await self.isInterrupted(taskID: task.id)
                            })
                        } catch {
                            try? deps.steps.markPending(stepID: step.id, error: "退避期间被取消")
                            return .cancelled
                        }

                        continue inner   // 同一 backend 重试
                    }
                }
            }
        }
    }

    /// 暂停或取消都应当中断退避睡眠。
    private func isInterrupted(taskID: String) -> Bool {
        pauseRequests.contains(taskID) || cancelRequests.contains(taskID) || Task.isCancelled
    }

    // MARK: - 上下文裁剪标记

    private var shrinkRequested: Set<String> = []

    private func markShrinkRequested(stepID: String) {
        shrinkRequested.insert(stepID)
    }

    private func shrinkFactor(for step: TaskStep) -> Double? {
        guard shrinkRequested.contains(step.id) else { return nil }
        return deps.config.contextShrinkFactor
    }

    // MARK: - 审计载荷

    private func failurePayload(
        error: AppError,
        backend: BackendRef,
        delay: TimeInterval?
    ) -> JSONValue {
        .object([
            "kind": .string("failure"),
            "errorClass": .string(error.eventName),
            "strategy": .string(error.strategy.rawValue),
            "message": .string(error.userMessage),
            "provider": .string(backend.providerID),
            "model": .string(backend.model),
            "retryAfterSeconds": delay.map { JSONValue.double($0) } ?? .null,
            "at": .string(DateCoding.string(from: Date())),
        ])
    }
}

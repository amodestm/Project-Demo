import Foundation

// MARK: - 错误

/// Web 执行通道的错误。
public enum WebExecutionError: Error, Sendable {
    case taskNotFound(String)
    case stepNotFound(String)
    case stepNotInExpectedState(stepIndex: Int, actual: StepStatus)
    case noExecutableStep(taskName: String)
    /// ★ 没有处于 `prepared` 的步骤时, 结果导入必须被拒绝。
    ///
    /// 存在的意义: 阻止"用户重复点击 Paste Result"把上一轮的结果
    /// 错误地提交到下一条 pending 步骤上 —— 那会污染该步骤之后的所有输出。
    case noStepAwaitingResult(taskID: String)
    case emptyClipboard
    case validationFailed(String)
    case taskNotAwaitingUser(current: TaskStatus)

    public var userMessage: String {
        switch self {
        case .taskNotFound(let id):
            return "找不到任务: \(id)"
        case .stepNotFound(let id):
            return "找不到步骤: \(id)"
        case .stepNotInExpectedState(let index, let actual):
            return "步骤 \(index + 1) 当前状态为「\(actual.displayName)」, 无法执行该操作"
        case .noExecutableStep(let name):
            return "任务「\(name)」没有待执行的步骤 (可能已全部完成)"
        case .noStepAwaitingResult:
            return "当前没有等待回填结果的步骤。请先点「复制续跑 Prompt」生成下一步, 再粘贴结果。"
        case .emptyClipboard:
            return "剪贴板为空, 请先复制 ChatGPT 的回复"
        case .validationFailed(let detail):
            return "结果校验未通过, 检查点未推进: \(detail)"
        case .taskNotAwaitingUser(let current):
            return "任务当前状态为「\(current.displayName)」, 不在等待回填"
        }
    }
}

extension WebExecutionError: LocalizedError {
    public var errorDescription: String? { userMessage }
}

// MARK: - 数据载体

/// 已生成、等待用户提交的 Web 步骤。
public struct PreparedWebStep: Sendable, Equatable {
    public let taskID: String
    public let stepID: String
    public let stepIndex: Int
    public let totalSteps: Int
    public let prompt: String
    public let preparedAt: Date
    /// 该步骤在生成 prompt 之前是否就已经是 prepared
    /// (true 表示这是崩溃恢复后的重新生成)。
    public let wasAlreadyPrepared: Bool

    public init(
        taskID: String,
        stepID: String,
        stepIndex: Int,
        totalSteps: Int,
        prompt: String,
        preparedAt: Date,
        wasAlreadyPrepared: Bool
    ) {
        self.taskID = taskID
        self.stepID = stepID
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
        self.prompt = prompt
        self.preparedAt = preparedAt
        self.wasAlreadyPrepared = wasAlreadyPrepared
    }

    public var ordinal: Int { stepIndex + 1 }
}

/// 「Copy Continuation Prompt」按钮的完整执行结果。
public struct PromptDelivery: Sendable, Equatable {
    public let prepared: PreparedWebStep
    public let copiedToClipboard: Bool
    public let browserOpened: Bool
    public let browserURL: URL?
}

/// 导入结果后的产物。
public struct ImportedResult: Sendable, Equatable {
    public let taskID: String
    public let stepID: String
    public let stepIndex: Int
    public let checkpoint: Checkpoint
    /// 还剩多少个可执行步骤 (0 表示任务已实质完成)。
    public let remainingSteps: Int

    public var isFinalStep: Bool { remainingSteps == 0 }
}

// MARK: - 协议

/// Web 执行通道的契约。
///
/// 所有 ID 使用 `String` —— 本项目全量 ID 都是 `UUID().uuidString`,
/// 保持 String 可以完全不触碰既有的 Model / Repository 层。
public protocol WebExecutionCoordinating: Sendable {

    /// 为下一个可执行步骤生成续跑 prompt, 并把该步骤标记为 `prepared`。
    func prepareStep(taskID: String) async throws -> PreparedWebStep

    /// 生成 prompt → 写入剪贴板 → (可选) 打开 ChatGPT。
    /// 这是 MVP 阶段的主路径。
    func deliverPrompt(
        taskID: String,
        copyToClipboard: Bool,
        openBrowser: Bool
    ) async throws -> PromptDelivery

    /// 从剪贴板读取 ChatGPT 的回复, 校验后提交为结果。
    func importClipboardResult(taskID: String) async throws -> ImportedResult

    /// 记录用户已把 prompt 提交给 ChatGPT (审计用)。
    func markSubmitted(taskID: String, stepID: String) async throws

    /// 接收用户从 ChatGPT 拿回的结果: 校验 → 原子提交 → 推进检查点。
    /// 校验失败**绝不**推进检查点。
    func acceptResult(taskID: String, stepID: String, result: String) async throws -> ImportedResult

    /// 因当前 ChatGPT session 无法继续而暂停, 等待用户手动切换账号。
    /// 只改任务状态, 不动任何已有进度。
    func pauseForAccountSwitch(taskID: String, reason: String) async throws

    /// 用户完成手动账号切换后调用。
    func resumeAfterManualAccountSwitch(taskID: String) async throws
}

// MARK: - 实现

/// ChatGPT Web 执行协调器。
///
/// ## 职责
/// 管理一个任务在 ChatGPT Web 场景下的执行状态, 即:
/// **生成续跑 prompt → 交给用户 → 接回结果 → 原子提交 → 推进检查点**。
///
/// ## ★ 明确不做的事 ★
/// - 不保存账号密码
/// - 不执行登录
/// - 不自动轮换账号
/// - 不绕过任何平台使用限制
///
/// 它只操作用户**已经自己登录并授权**的会话 —— 而且是通过"把 prompt 交给用户"
/// 这种方式, 连浏览器页面都不直接操作。
///
/// ## 状态机
/// ```
/// pending ──prepareStep──► prepared ──acceptResult──► completed (+ checkpoint)
///    ▲                         │
///    └──── clearPrepared ──────┘
///
/// 任意时刻 session 不可用:
///   prepared / pending ──pauseForAccountSwitch──► Task = waitingForAccount
///                        ──用户手动切换──► resumeAfterManualAccountSwitch ──► running
/// ```
public actor WebExecutionCoordinator: WebExecutionCoordinating {

    // 依赖
    private let tasks: TaskRepository
    private let steps: StepRepository
    private let checkpoints: CheckpointRepository
    private let checkpointManager: CheckpointManager
    private let logger: LoggerService
    private let promptBuilder: ContinuationPromptBuilder
    private let clipboard: any ClipboardServicing
    private let browser: any BrowserLaunching
    private let chatGPTURLOverride: @Sendable () -> String?

    public init(
        tasks: TaskRepository,
        steps: StepRepository,
        checkpoints: CheckpointRepository,
        checkpointManager: CheckpointManager,
        logger: LoggerService,
        promptBuilder: ContinuationPromptBuilder = ContinuationPromptBuilder(),
        clipboard: any ClipboardServicing = InMemoryClipboard(),
        browser: any BrowserLaunching = NoopBrowserLauncher(),
        chatGPTURLOverride: @escaping @Sendable () -> String? = { nil }
    ) {
        self.tasks = tasks
        self.steps = steps
        self.checkpoints = checkpoints
        self.checkpointManager = checkpointManager
        self.logger = logger
        self.promptBuilder = promptBuilder
        self.clipboard = clipboard
        self.browser = browser
        self.chatGPTURLOverride = chatGPTURLOverride
    }

    // MARK: - 1. 生成续跑 prompt

    public func prepareStep(taskID: String) async throws -> PreparedWebStep {
        guard let task = try tasks.fetch(id: taskID) else {
            throw WebExecutionError.taskNotFound(taskID)
        }

        guard let step = try steps.nextExecutableStep(taskID: taskID) else {
            throw WebExecutionError.noExecutableStep(taskName: task.name)
        }

        let alreadyPrepared = (step.status == .prepared)

        let checkpoint = try checkpoints.latest(taskID: taskID)
        let completedIndexes = try steps.completedIndexes(taskID: taskID)

        // ★ 纯函数生成 —— 同样的输入必然产出同样的文本。
        //   这是"崩溃后重新生成相同 prompt"的全部依据。
        let prompt = promptBuilder.build(
            ContinuationPromptBuilder.Input(
                goal: task.goal,
                stepIndex: step.index,
                totalSteps: task.totalSteps,
                stepType: step.type,
                checkpoint: checkpoint,
                completedStepIndexes: completedIndexes,
                structuredFacts: ContinuationPromptBuilder.facts(from: checkpoint),
                outputSchema: step.input["outputSchema"]?.stringValue
            )
        )

        try steps.markPrepared(stepID: step.id)

        if alreadyPrepared {
            logger.info(
                .webStepPrepared,
                "恢复: 步骤 \(step.index + 1) 的续跑 prompt 已重新生成 (内容与此前一致, "
                + "因为 prompt 是纯函数输出)",
                taskID: taskID, stepIndex: step.index
            )
        } else {
            logger.info(
                .webStepPrepared,
                "步骤 \(step.index + 1)/\(task.totalSteps) 的续跑 prompt 已生成, 等待提交",
                taskID: taskID, stepIndex: step.index,
                metadata: .object([
                    "promptCharacters": .int(prompt.count),
                    "completedSteps": .int(completedIndexes.count),
                ])
            )
        }

        return PreparedWebStep(
            taskID: taskID,
            stepID: step.id,
            stepIndex: step.index,
            totalSteps: task.totalSteps,
            prompt: prompt,
            preparedAt: Date(),
            wasAlreadyPrepared: alreadyPrepared
        )
    }

    /// 生成 prompt → 写入剪贴板 → 打开 ChatGPT。
    ///
    /// 这是 MVP 阶段的主路径: 不依赖任何浏览器自动化, 只借用用户的剪贴板。
    public func deliverPrompt(
        taskID: String,
        copyToClipboard: Bool = true,
        openBrowser: Bool = true
    ) async throws -> PromptDelivery {

        let prepared = try await prepareStep(taskID: taskID)

        var copied = false
        if copyToClipboard {
            copied = clipboard.writeString(prepared.prompt)
            if copied {
                logger.info(
                    .webPromptCopied,
                    "续跑 prompt 已复制到剪贴板 (步骤 \(prepared.ordinal)/\(prepared.totalSteps))",
                    taskID: taskID, stepIndex: prepared.stepIndex
                )
            }
        }

        var opened = false
        var usedURL: URL?
        if openBrowser {
            let url = ChatGPTWebTarget.resolvedURL(override: chatGPTURLOverride())
            opened = browser.open(url)
            usedURL = url
            if opened {
                logger.info(
                    .browserOpened,
                    "已请求打开 \(url.absoluteString) (请在你自己已登录的浏览器中操作)",
                    taskID: taskID, stepIndex: prepared.stepIndex
                )
            }
        }

        return PromptDelivery(
            prepared: prepared,
            copiedToClipboard: copied,
            browserOpened: opened,
            browserURL: usedURL
        )
    }

    // MARK: - 2. 标记已提交

    public func markSubmitted(taskID: String, stepID: String) async throws {
        guard let step = try steps.fetch(id: stepID), step.taskID == taskID else {
            throw WebExecutionError.stepNotFound(stepID)
        }
        guard step.status == .prepared else {
            throw WebExecutionError.stepNotInExpectedState(
                stepIndex: step.index, actual: step.status
            )
        }
        try steps.markSubmitted(stepID: stepID)
        logger.info(
            .webStepSubmitted,
            "步骤 \(step.index + 1) 已提交给 ChatGPT, 等待回填结果",
            taskID: taskID, stepIndex: step.index
        )
    }

    // MARK: - 3. 接收结果

    public func acceptResult(
        taskID: String,
        stepID: String,
        result: String
    ) async throws -> ImportedResult {

        guard let task = try tasks.fetch(id: taskID) else {
            throw WebExecutionError.taskNotFound(taskID)
        }
        guard let step = try steps.fetch(id: stepID), step.taskID == taskID else {
            throw WebExecutionError.stepNotFound(stepID)
        }

        // ★ A2: 只允许 prepared → completed ★
        //
        // pending / interrupted / completed / failed 一律拒绝。
        // 否则"重复提交同一份结果"会覆盖已有输出并凭空多出一条检查点。
        guard step.status == .prepared else {
            logger.warning(
                .resultImportRejected,
                "步骤 \(step.index + 1) 当前状态为「\(step.status.displayName)」, 拒绝导入结果 "
                + "(只有「已就绪」的步骤才允许提交)",
                taskID: taskID, stepIndex: step.index
            )
            throw WebExecutionError.stepNotInExpectedState(
                stepIndex: step.index, actual: step.status
            )
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebExecutionError.emptyClipboard
        }

        // --- 输出校验: 失败绝不推进 checkpoint ---
        let format = TaskPlanner.responseFormat(for: step)
        let validator = CompositeResponseValidator.standard(for: format)

        let response = AIResponse(
            text: trimmed,
            provider: "chatgpt-web",
            model: "manual-session",
            latencyMilliseconds: 0
        )
        let request = TaskPlanner.buildRequest(
            task: task, step: step, checkpoint: nil, responseFormat: format
        )

        do {
            try validator.validate(response, request: request)
        } catch {
            let appError = AppError.normalize(error)
            logger.warning(
                .resultImportRejected,
                "步骤 \(step.index + 1) 的结果未通过校验, 检查点保持不变: \(appError.userMessage)",
                taskID: taskID, stepIndex: step.index
            )
            throw WebExecutionError.validationFailed(appError.userMessage)
        }

        // --- 组结果 + 原子提交 ---
        let previous = try checkpoints.latest(taskID: taskID)

        let output = JSONValue.object([
            "text": .string(trimmed),
            "provider": .string("chatgpt-web"),
            "model": .string("manual-session"),
            "source": .string("clipboard"),
            "importedAt": .string(DateCoding.string(from: Date())),
        ])

        let newCheckpoint = await checkpointManager.makeCheckpoint(
            taskID: taskID,
            completedStep: step.index,
            previous: previous,
            output: output,
            provider: "chatgpt-web",
            model: "manual-session"
        )

        // ★ A3: 走 Web 专用入口 —— 强制前置状态必须是 prepared ★
        try steps.commitPreparedWebStep(
            SuccessfulStepCommit(
                stepID: stepID,
                taskID: taskID,
                output: output,
                provider: "chatgpt-web",
                model: "manual-session",
                durationMs: elapsedMilliseconds(since: step.preparedAt),
                checkpoint: newCheckpoint,
                newCurrentStep: step.index + 1
            )
        )

        let remaining = try steps.executableCount(taskID: taskID)

        logger.info(
            .resultImported,
            "步骤 \(step.index + 1)/\(task.totalSteps) 结果已导入并提交 "
            + "(\(trimmed.count) 字符)。检查点: completedStep=\(newCheckpoint.completedStep) "
            + "nextStep=\(newCheckpoint.nextStep)。剩余 \(remaining) 步。",
            taskID: taskID, stepIndex: step.index
        )

        return ImportedResult(
            taskID: taskID,
            stepID: stepID,
            stepIndex: step.index,
            checkpoint: newCheckpoint,
            remainingSteps: remaining
        )
    }

    /// 从剪贴板导入结果 —— 「Paste Result」按钮的实现。
    public func importClipboardResult(taskID: String) async throws -> ImportedResult {
        guard let raw = clipboard.readString() else {
            throw WebExecutionError.emptyClipboard
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebExecutionError.emptyClipboard
        }

        // ★ A1: 只允许回填"明确处于 prepared"的那一步 ★
        //
        // 这里**绝不能** fallback 到 nextExecutableStep。
        // 否则用户重复点击「粘贴结果」时, 上一轮的剪贴板内容会被当作下一条 pending
        // 步骤的结果提交 —— 之后所有步骤都建立在错误输入上。
        guard let step = try steps.awaitingResultStep(taskID: taskID) else {
            throw WebExecutionError.noStepAwaitingResult(taskID: taskID)
        }

        return try await acceptResult(taskID: taskID, stepID: step.id, result: trimmed)
    }

    // MARK: - 4. 账号交接

    public func pauseForAccountSwitch(taskID: String, reason: String) async throws {
        guard let task = try tasks.fetch(id: taskID) else {
            throw WebExecutionError.taskNotFound(taskID)
        }

        // ★ 进度安全保证 ★
        // 每个已完成步骤的结果与检查点都是在单个事务里提交的, 所以此刻库里
        // 已经是一致状态。这里**只需要**改任务状态 —— 不需要(也不应该)再写任何进度。
        //
        // 唯一需要收拾的是"处于 running 的步骤": Web 模式下不应出现, 但若存在
        // (例如上一次 API 模式执行被打断), 退回 pending 让它可重新执行。
        if let running = try steps.fetchAll(taskID: taskID).first(where: { $0.status == .running }) {
            try steps.markPending(stepID: running.id, error: "账号交接, 该步未提交")
            logger.warning(
                .accountHandoffRequested,
                "步骤 \(running.index + 1) 处于 running, 已退回待执行状态",
                taskID: taskID, stepIndex: running.index
            )
        }

        if task.status == .waitingForAccount {
            logger.info(.accountHandoffRequested, "任务已在等待账号切换状态 (重复请求被忽略)", taskID: taskID)
            return
        }

        _ = try tasks.updateStatus(
            id: taskID,
            to: .waitingForAccount,
            errorMessage: reason,
            errorClass: "ACCOUNT_HANDOFF"
        )

        let checkpoint = try checkpoints.latest(taskID: taskID)
        logger.warning(
            .accountHandoffRequested,
            "任务已暂停并安全保存至检查点 \(checkpoint.map { "step \($0.completedStep + 1)" } ?? "初始")"
            + "。原因: \(reason)。请手动切换到另一个已授权的 ChatGPT 会话。",
            taskID: taskID,
            metadata: .object([
                "completedSteps": .int((checkpoint?.completedStep ?? -1) + 1),
                "reason": .string(reason),
            ])
        )
    }

    public func resumeAfterManualAccountSwitch(taskID: String) async throws {
        guard let task = try tasks.fetch(id: taskID) else {
            throw WebExecutionError.taskNotFound(taskID)
        }

        guard task.status.requiresUserAction || task.status == .paused || task.status == .failed else {
            logger.info(
                .accountHandoffCompleted,
                "任务状态为「\(task.status.displayName)」, 无需从账号交接恢复",
                taskID: taskID
            )
            return
        }

        _ = try tasks.updateStatus(
            id: taskID,
            to: .running,
            errorMessage: nil,
            errorClass: nil
        )

        let checkpoint = try checkpoints.latest(taskID: taskID)
        let next = try steps.nextExecutableStep(taskID: taskID)

        logger.info(
            .accountHandoffCompleted,
            "账号交接完成, 将从检查点继续: "
            + "completedStep=\(checkpoint?.completedStep ?? -1), "
            + "下一步 = \(next.map { "step \($0.index + 1)" } ?? "无 (已完成)")",
            taskID: taskID
        )
    }

    /// 用户觉得 prompt 不对, 想重新生成。
    public func discardPreparedPrompt(taskID: String) async throws {
        guard let step = try steps.awaitingResultStep(taskID: taskID) else { return }
        try steps.clearPrepared(stepID: step.id)
        logger.info(
            .webStepPrepared,
            "已丢弃步骤 \(step.index + 1) 的 prompt, 将重新生成",
            taskID: taskID, stepIndex: step.index
        )
    }

    // MARK: - 查询

    /// 当前正在等待用户回填结果的那一步 (供 UI 显示)。
    public func awaitingStep(taskID: String) throws -> TaskStep? {
        try steps.awaitingResultStep(taskID: taskID)
    }

    /// 预演下一次 prepareStep 会产出什么, 但**不写库**。
    /// 供 UI 预览或"我想先看看 prompt"用。
    public func previewPrompt(taskID: String) throws -> String? {
        guard let task = try tasks.fetch(id: taskID),
              let step = try steps.nextExecutableStep(taskID: taskID) else {
            return nil
        }
        let checkpoint = try checkpoints.latest(taskID: taskID)
        let completedIndexes = try steps.completedIndexes(taskID: taskID)

        return promptBuilder.build(
            ContinuationPromptBuilder.Input(
                goal: task.goal,
                stepIndex: step.index,
                totalSteps: task.totalSteps,
                stepType: step.type,
                checkpoint: checkpoint,
                completedStepIndexes: completedIndexes,
                structuredFacts: ContinuationPromptBuilder.facts(from: checkpoint),
                outputSchema: step.input["outputSchema"]?.stringValue
            )
        )
    }

    // MARK: - 内部

    private func elapsedMilliseconds(since date: Date?) -> Int {
        guard let date else { return 0 }
        return max(0, Int(Date().timeIntervalSince(date) * 1000))
    }
}

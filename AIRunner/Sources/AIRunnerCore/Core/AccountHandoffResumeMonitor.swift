import Foundation

/// 账号交接后自动恢复的状态机。
public enum AccountHandoffState: String, Codable, Sendable, CaseIterable {
    case idle
    case waitingForUserAuthentication
    case checkingSession
    case targetAvailable
    case resuming
    case resumed
    case failed

    public var displayName: String {
        switch self {
        case .idle:                         return "未监视"
        case .waitingForUserAuthentication: return "等待你完成认证"
        case .checkingSession:              return "正在检查会话"
        case .targetAvailable:              return "目标已可用"
        case .resuming:                     return "正在恢复"
        case .resumed:                      return "已恢复"
        case .failed:                       return "自动恢复失败"
        }
    }
}

/// 一次 tick 的结果。
public enum HandoffTickOutcome: Sendable, Equatable {
    /// 仍在等待用户完成认证 / 目标尚未就绪。**没有发送任何东西。**
    case stillWaiting(reason: String)
    /// 目标可用, 但当前不适合自动发送 (例如线程正在生成)。仍然**没发送**。
    case availableButNotActionable(reason: String)
    /// 已自动发送一次并恢复。
    case resumed(bindingID: String)
    /// 自动恢复失败 —— 需要用户介入。
    case failed(reason: String)
    /// 监视已停止 / 任务已不在等待状态。
    case idle
}

/// 账号交接监视器。
///
/// ## 它解决的问题
///
/// 用户点「暂停以切换账号」之后, 任务进入 `waitingForAccount`。
/// 用户去 Chrome / ChatGPT 里**自己**完成账号切换或重新认证 ——
/// 完成后**不需要再回到 AIRunner 点任何按钮**, 这个监视器会:
///
/// ```
/// 探测 Codex 是否重新可用
///   → 定位绑定的线程
///   → 二次验证确实是那一个
///   → 确认线程没有在生成
///   → 找 composer
///   → 输入「继续」并校验
///   → 发送一次
///   → 任务恢复
/// ```
///
/// ## ★ 它不做的事 ★
///
/// * 不读取当前账号 email
/// * 不检测账号身份 (它无法区分"是否换了账号", 只判断"Codex 是否可用")
/// * 不点击账户菜单
/// * 不执行账号切换
/// * 不填写登录表单
/// * 不触碰浏览器密码管理器
///
/// 也就是说: **认证这件事完全在 AIRunner 之外发生**, 它只负责"认证完了之后接着干活"。
///
/// ## 绝不调用第二套发送逻辑
///
/// 所有发送都走同一个 `CodexResumeController.resume`, 因此
/// 唯一性判定、二次验证、忙碌检查、60 秒冷却、跨进程租约
/// 全部自动继承 —— 这里没有任何重复实现。
public actor AccountHandoffResumeMonitor {

    private let driver: any CodexUIAutomationDriving
    private let resumeController: CodexResumeController
    private let bindings: CodexTaskBindingRepository
    private let tasks: TaskRepository
    private let accountRotation: (any CodexAccountRotating)?
    private let logger: LoggerService
    private let cooldown: TimeInterval
    private let pollInterval: Duration
    private let now: @Sendable () -> Date

    /// 正在监视的任务。
    private var monitored: Set<String> = []
    /// 单次检查的防重入 (actor 在 await 期间可重入, 必须显式挡住)。
    private var inFlight: Set<String> = []
    /// 每个任务对应的后台轮询循环。
    private var loops: [String: Task<Void, Never>] = [:]
    /// 本任务最近一次发送时间 —— 用于本进程内的快速冷却判断。
    private var lastSendAt: [String: Date] = [:]

    public private(set) var state: AccountHandoffState = .idle

    public init(
        driver: any CodexUIAutomationDriving,
        resumeController: CodexResumeController,
        bindings: CodexTaskBindingRepository,
        tasks: TaskRepository,
        accountRotation: (any CodexAccountRotating)? = nil,
        logger: LoggerService,
        cooldown: TimeInterval = 60,
        pollInterval: Duration = .seconds(15),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.driver = driver
        self.resumeController = resumeController
        self.bindings = bindings
        self.tasks = tasks
        self.accountRotation = accountRotation
        self.logger = logger
        self.cooldown = cooldown
        self.pollInterval = pollInterval
        self.now = now
    }

    // MARK: - 生命周期

    public func isMonitoring(taskID: String) -> Bool { monitored.contains(taskID) }
    public func monitoredTaskIDs() -> [String] { monitored.sorted() }

    /// 开始监视某个任务。**不是**阻塞调用 —— 后台循环由 `runLoop` 驱动。
    public func start(taskID: String, autoRun: Bool = true) async {
        guard !monitored.contains(taskID) else { return }
        monitored.insert(taskID)
        state = .waitingForUserAuthentication

        logger.info(
            .accountHandoffMonitoring,
            "已开始监视账号交接。请在 Chrome / ChatGPT 中完成账号切换或重新认证 —— "
            + "完成后 AIRunner 会自动继续绑定的 Codex 任务, 无需再点任何按钮。",
            taskID: taskID
        )

        guard autoRun else { return }

        let loop = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(taskID: taskID)
        }
        loops[taskID] = loop
    }

    /// 停止监视。
    public func stop(taskID: String, reason: String) async {
        guard monitored.contains(taskID) else { return }
        monitored.remove(taskID)
        loops.removeValue(forKey: taskID)?.cancel()
        inFlight.remove(taskID)
        if monitored.isEmpty { state = .idle }

        logger.info(
            .accountHandoffMonitoring,
            "已停止监视账号交接: \(reason)",
            taskID: taskID
        )
    }

    public func stopAll(reason: String) async {
        for taskID in monitored { await stop(taskID: taskID, reason: reason) }
    }

    /// App 启动时调用: 把还挂在 `waitingForAccount` 上的任务重新纳入监视。
    ///
    /// 覆盖的场景是"任务在等待账号交接的期间 App 被重启"。
    @discardableResult
    public func restoreFromDatabase() async -> [String] {
        let waiting = (try? tasks.fetchAll(status: .waitingForAccount)) ?? []
        var restored: [String] = []

        for task in waiting {
            // 没有绑定的任务无法自动恢复 —— 它需要用户手动 Resume。
            guard (try? bindings.fetchByTask(taskID: task.id)) != nil else { continue }
            await start(taskID: task.id)
            restored.append(task.id)
        }

        if !restored.isEmpty {
            logger.info(
                .accountHandoffMonitoring,
                "已恢复 \(restored.count) 个等待账号交接的任务监视",
                metadata: .object(["count": .int(restored.count)])
            )
        }
        return restored
    }

    // MARK: - 轮询循环

    private func runLoop(taskID: String) async {
        while !Task.isCancelled && monitored.contains(taskID) {
            let outcome = await tick(taskID: taskID)

            switch outcome {
            case .resumed, .idle, .failed:
                return
            case .stillWaiting, .availableButNotActionable:
                break
            }

            try? await Task.sleep(for: pollInterval)
        }
    }

    // MARK: - 单次检查（测试直接驱动这个）

    /// 执行一次检查。
    ///
    /// 拆成"可被测试直接驱动"的形式, 是为了不让单元测试依赖真实计时器 ——
    /// 用户列的 8 条测试里有多条需要精确控制 tick 的次序。
    public func tick(taskID: String) async -> HandoffTickOutcome {

        // --- 防重入 ---
        guard !inFlight.contains(taskID) else {
            return .stillWaiting(reason: "上一次检查仍在进行中")
        }
        inFlight.insert(taskID)
        defer { inFlight.remove(taskID) }

        // --- 任务必须仍处于 waitingForAccount ---
        guard let task = (try? tasks.fetch(id: taskID)) ?? nil else {
            await stop(taskID: taskID, reason: "任务不存在")
            return .idle
        }
        guard task.status == .waitingForAccount else {
            await stop(taskID: taskID, reason: "任务状态已变为「\(task.status.displayName)」")
            return .idle
        }

        if let waitingUntil = task.waitingUntil, waitingUntil > now() {
            state = .waitingForUserAuthentication
            return .stillWaiting(reason: "所有账号额度仍在冷却，最早恢复时间：\(DateCoding.string(from: waitingUntil))")
        }

        state = .checkingSession

        // --- 必须有绑定 ---
        guard let binding = (try? bindings.fetchByTask(taskID: taskID)) ?? nil else {
            return .stillWaiting(reason: "该任务还没有绑定 Codex 线程, 无法自动恢复")
        }

        // --- 辅助功能权限 ---
        let permission = await driver.checkAccessibilityPermission()
        guard permission.isUsable else {
            state = .waitingForUserAuthentication
            return .stillWaiting(reason: "缺少辅助功能权限")
        }

        // --- 轻量探测: Codex 是否恢复可用 (无副作用) ---
        let probe = await driver.probeAvailability(
            bundleIdentifier: binding.applicationBundleIdentifier
        )
        guard probe.isUsable else {
            state = .waitingForUserAuthentication
            return .stillWaiting(reason: "Codex 尚未恢复可用 (\(probe.summary))")
        }

        // --- 本进程内的冷却 ---
        if let last = lastSendAt[taskID], now().timeIntervalSince(last) < cooldown {
            state = .targetAvailable
            let remaining = cooldown - now().timeIntervalSince(last)
            return .availableButNotActionable(reason: "刚刚发送过, 冷却中 (还剩 \(Int(remaining))s)")
        }

        state = .targetAvailable
        state = .resuming

        logger.info(
            .accountHandoffDetected,
            "Codex 已恢复可用 (\(probe.summary)), 开始自动恢复绑定线程「\(binding.displayTitle)」",
            taskID: taskID
        )

        // --- ★ 唯一的发送入口 ★ ---
        // 唯一性判定 / 二次验证 / 忙碌检查 / 60s 冷却 / 跨进程租约
        // 全部由 CodexResumeController 内部完成 —— 这里没有第二套逻辑。
        do {
            let result = try await resumeController.resumeAfterAccountHandoff(
                bindingID: binding.id
            )

            if result.isConfirmed {
                lastSendAt[taskID] = result.sentAt
                logger.info(
                    .accountHandoffAutoResumed,
                    "已自动发送「\(result.sentMessage)」到绑定线程并观察到确认。",
                    taskID: taskID
                )
            } else {
                if let outcome = await rotateIfQuotaStillExhausted(
                    after: .sendUnconfirmed,
                    taskID: taskID,
                    binding: binding
                ) {
                    return outcome
                }
                // 不谎报成功 —— 但仍然停止监视, 因为已经发过一次了。
                logger.warning(
                    .codexResumeUnconfirmed,
                    "已自动触发发送, 但无法确认 Codex 已接收 (sentUnconfirmed)。",
                    taskID: taskID
                )
            }

            state = .resumed
            _ = try? tasks.updateStatus(
                id: taskID, to: .running,
                errorMessage: nil, errorClass: nil
            )
            await stop(taskID: taskID, reason: "已完成自动恢复")
            return .resumed(bindingID: binding.id)

        } catch let error as CodexAutomationError {
            if let outcome = await rotateIfQuotaStillExhausted(
                after: error,
                taskID: taskID,
                binding: binding
            ) {
                return outcome
            }
            return await handleResumeFailure(error, taskID: taskID, bindingID: binding.id)
        } catch {
            state = .failed
            await stop(taskID: taskID, reason: "自动恢复失败")
            return .failed(reason: "\(error)")
        }
    }

    /// 新账号本身也可能已经没有额度，此时 Composer 会禁用，导致“继续”无法发送。
    /// 只有发送阶段错误且再次读取到明确额度横幅时才继续切号；定位、标题和模型
    /// 校验错误仍走原来的 fail-closed 分支。
    private func rotateIfQuotaStillExhausted(
        after error: CodexAutomationError,
        taskID: String,
        binding: CodexTaskBinding
    ) async -> HandoffTickOutcome? {
        guard error.canBeCausedByQuotaBlockingSend,
              let accountRotation else { return nil }

        let app: CodexAppHandle
        do {
            app = try await driver.locateApplication(
                bundleIdentifier: binding.applicationBundleIdentifier
            )
            guard try await driver.detectAccountIssue(app) == .quotaExhausted else {
                return nil
            }
        } catch {
            return nil
        }

        logger.warning(
            .accountHandoffDetected,
            "新账号已登录，但页面明确显示额度耗尽；发送「\(binding.resumeMessage)」不可用，继续轮换下一个账号",
            taskID: taskID,
            metadata: .object([
                "issue": .string(CodexAccountIssue.quotaExhausted.eventName),
                "resumeError": .string(error.eventName),
                "automatic": .bool(true),
            ])
        )

        do {
            _ = try await accountRotation.rotateChatGPTAccountAfterQuotaExhaustion(taskID: taskID)
            _ = try? tasks.updateStatus(
                id: taskID,
                to: .waitingForAccount,
                errorMessage: "当前账号额度已耗尽，已切换下一个账号，等待登录完成",
                errorClass: CodexAccountIssue.quotaExhausted.eventName,
                waitingUntil: nil
            )
            state = .waitingForUserAuthentication
            logger.info(
                .accountHandoffCompleted,
                "额度耗尽账号已跳过，等待下一个账号恢复 Codex 后重新锁定并发送",
                taskID: taskID
            )
            return .stillWaiting(reason: "当前账号额度已耗尽，已切换下一个账号")
        } catch let error as CodexQuotaRotationError {
            if case .allAccountsCoolingDown(let until) = error {
                _ = try? tasks.updateStatus(
                    id: taskID,
                    to: .waitingForAccount,
                    errorMessage: "所有账号额度均在冷却中，等待最早账号恢复后自动切换",
                    errorClass: CodexAccountIssue.quotaExhausted.eventName,
                    waitingUntil: until
                )
                state = .waitingForUserAuthentication
                logger.info(
                    .accountHandoffDetected,
                    "所有账号都在额度冷却中，等待至 \(DateCoding.string(from: until))（含网络缓冲）",
                    taskID: taskID
                )
                return .stillWaiting(reason: "所有账号额度均在冷却中，等待至 \(DateCoding.string(from: until))")
            }
            return .failed(reason: error.localizedDescription)
        } catch {
            let message = AppError.normalize(error).userMessage
            state = .failed
            logger.error(
                .accountRotationFailed,
                "继续轮换下一个账号失败: \(message)",
                taskID: taskID
            )
            await stop(taskID: taskID, reason: "账号轮换失败")
            return .failed(reason: message)
        }
    }

    /// 把 Resume 的错误翻译成"继续等"还是"放弃"。
    ///
    /// 这个映射很关键: 把"还没准备好"误判成"失败"会让用户莫名其妙地看到错误;
    /// 把"危险情况"误判成"继续等"则会反复重试一个不该重试的动作。
    private func handleResumeFailure(
        _ error: CodexAutomationError,
        taskID: String,
        bindingID: String
    ) async -> HandoffTickOutcome {

        switch error {

        // ---- 还没准备好 → 继续等 ----
        case .targetTaskNotFound, .applicationNotFound, .codexViewNotFound,
             .modelControlNotFound,
             .composerNotFound, .composerNotEditable, .composerFocusFailed,
             .accessibilityPermissionMissing, .timeout:
            state = .waitingForUserAuthentication
            return .stillWaiting(reason: error.userMessage)

        // ---- 线程正忙 → 等它跑完 ----
        case .threadAlreadyRunning:
            state = .targetAvailable
            return .availableButNotActionable(reason: error.userMessage)

        // ---- 刚刚发过 → 视为本次自动恢复已完成 ----
        case .duplicateResumePrevented:
            state = .resumed
            await stop(taskID: taskID, reason: "冷却期内已有发送记录")
            return .resumed(bindingID: bindingID)

        // ---- 另一个进程/实例在发 → 让出, 不重复 ----
        case .resumeLeaseBusy:
            state = .targetAvailable
            return .availableButNotActionable(reason: error.userMessage)

        // ---- 存在过期租约 → 需要用户显式恢复, 停止自动重试 ----
        case .staleResumeLease:
            state = .failed
            await stop(taskID: taskID, reason: "存在过期 Resume 锁, 需要用户显式恢复")
            return .failed(reason: error.userMessage)

        // ---- ★ 危险情况: 目标不唯一或验证失败 → 立即停止自动恢复 ★ ----
        // 反复重试不会让"有两个同名线程"变好, 只会增加误发风险。
        case .ambiguousTarget, .targetVerificationFailed, .messageInsertionFailed,
             .modelOptionNotFound, .reasoningOptionNotFound,
             .modelSelectionAmbiguous, .modelSelectionFailed,
             .sendControlNotFound, .sendFailed, .sendUnconfirmed, .bindingNotFound:
            state = .failed
            logger.error(
                .codexResumeAborted,
                "自动恢复已停止, 需要你手动处理: \(error.userMessage)",
                taskID: taskID
            )
            await stop(taskID: taskID, reason: error.eventName)
            return .failed(reason: error.userMessage)
        }
    }

    // MARK: - UI 支持

    /// 当前监视状态的一句话说明 (给 UI 显示)。
    public func statusDescription(for taskID: String) -> String {
        guard monitored.contains(taskID) else { return state.displayName }
        return state.displayName
    }
}

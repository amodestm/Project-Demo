import Foundation

/// Codex 额度/认证异常监视结果。
public enum CodexQuotaMonitorOutcome: Sendable, Equatable {
    case waitingForTask
    case waitingForCodex
    case generating
    case observed(CodexAccountIssue)
    case retrySent
    case retryFailed(String)
    case rotationCompleted
    case rotationFailed(String)
    case stopped
}

/// 只在 Codex 已停止生成且连续观察到明确额度/认证信号时轮换账号。
///
/// 额度耗尽会先在原线程补发一次「继续」；等待后仍连续看到额度耗尽才轮换。
/// 监视器不把“任务已停止”单独解释为额度耗尽。
/// 轮换前先将任务安全置为 `waitingForAccount`，因此检查点和未提交步骤都能保留。
public actor CodexQuotaMonitor {

    private struct Candidate: Sendable {
        let issue: CodexAccountIssue
        var observations: Int
        var retrySentAt: Date?
        var postRetryObservations: Int
    }

    private let driver: any CodexUIAutomationDriving
    private let bindings: CodexTaskBindingRepository
    private let tasks: TaskRepository
    private let resumeController: CodexResumeController
    private let accountRotation: any CodexAccountRotating
    private let logger: LoggerService
    private let pollInterval: Duration
    private let retrySettleDelay: TimeInterval
    private let now: @Sendable () -> Date
    private let onRotationComplete: @Sendable (String) async -> Void

    private var monitored: Set<String> = []
    private var inFlight: Set<String> = []
    private var loops: [String: Task<Void, Never>] = [:]
    private var candidates: [String: Candidate] = [:]
    /// 补发后异常文本可能在页面重绘时短暂消失；连续两次无异常才清除补发状态。
    private var issueClearObservations: [String: Int] = [:]
    private var lastObserved: [String: CodexAccountIssue] = [:]

    public init(
        driver: any CodexUIAutomationDriving,
        bindings: CodexTaskBindingRepository,
        tasks: TaskRepository,
        resumeController: CodexResumeController,
        accountRotation: any CodexAccountRotating,
        logger: LoggerService,
        pollInterval: Duration = .seconds(5),
        retrySettleDelay: TimeInterval = 10,
        now: @escaping @Sendable () -> Date = { Date() },
        onRotationComplete: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.driver = driver
        self.bindings = bindings
        self.tasks = tasks
        self.resumeController = resumeController
        self.accountRotation = accountRotation
        self.logger = logger
        self.pollInterval = pollInterval
        self.retrySettleDelay = retrySettleDelay
        self.now = now
        self.onRotationComplete = onRotationComplete
    }

    public func isMonitoring(taskID: String) -> Bool { monitored.contains(taskID) }
    public func monitoredTaskIDs() -> [String] { monitored.sorted() }

    public func start(taskID: String, autoRun: Bool = true) async {
        guard !monitored.contains(taskID) else { return }
        monitored.insert(taskID)
        guard autoRun else { return }
        let loop = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(taskID: taskID)
        }
        loops[taskID] = loop
    }

    public func stop(taskID: String, reason: String = "用户手动停止") async {
        guard monitored.contains(taskID) else { return }
        monitored.remove(taskID)
        loops.removeValue(forKey: taskID)?.cancel()
        inFlight.remove(taskID)
        candidates.removeValue(forKey: taskID)
        issueClearObservations.removeValue(forKey: taskID)
        lastObserved.removeValue(forKey: taskID)
        logger.info(.accountHandoffMonitoring, "已停止 Codex 额度监视: \(reason)", taskID: taskID)
    }

    public func stopAll(reason: String = "应用关闭") async {
        for taskID in monitored { await stop(taskID: taskID, reason: reason) }
    }

    private func runLoop(taskID: String) async {
        while !Task.isCancelled && monitored.contains(taskID) {
            let outcome = await tick(taskID: taskID)
            if case .stopped = outcome { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// 执行一次无副作用检查；第二次连续稳定信号才会启动轮换。
    public func tick(taskID: String) async -> CodexQuotaMonitorOutcome {
        guard !inFlight.contains(taskID) else { return .waitingForCodex }
        guard monitored.contains(taskID) else { return .stopped }
        inFlight.insert(taskID)
        defer { inFlight.remove(taskID) }

        guard let task = (try? tasks.fetch(id: taskID)) ?? nil else {
            await stop(taskID: taskID, reason: "任务不存在")
            return .stopped
        }
        if task.status.isTerminal {
            await stop(taskID: taskID, reason: "任务已进入终态")
            return .stopped
        }
        // Web/Codex 把 prompt 交出去后，AIRunner 会处于 waitingForUser；此时
        // Codex 仍可能正在处理任务。因此 running 与 waitingForUser 都需要监视，
        // 最终是否能切号仍由真实 Codex 的 generating/idle/stopped 门控决定。
        guard task.status == .running || task.status == .waitingForUser else {
            candidates.removeValue(forKey: taskID)
            return .waitingForTask
        }

        guard let binding = (try? bindings.fetchByTask(taskID: taskID)) ?? nil else {
            await stop(taskID: taskID, reason: "任务没有 Codex 线程绑定")
            return .stopped
        }
        guard (await driver.checkAccessibilityPermission()).isUsable else {
            return .waitingForCodex
        }
        let probe = await driver.probeAvailability(
            bundleIdentifier: binding.applicationBundleIdentifier
        )
        guard probe.isUsable else { return .waitingForCodex }

        let app: CodexAppHandle
        do {
            app = try await driver.locateApplication(
                bundleIdentifier: binding.applicationBundleIdentifier
            )
        } catch {
            return .waitingForCodex
        }
        let issue: CodexAccountIssue?
        do {
            issue = try await driver.detectAccountIssue(app)
        } catch {
            if candidates[taskID]?.retrySentAt == nil {
                candidates.removeValue(forKey: taskID)
            }
            return .waitingForCodex
        }
        guard let issue else {
            if candidates[taskID]?.retrySentAt != nil {
                let clearCount = (issueClearObservations[taskID] ?? 0) + 1
                issueClearObservations[taskID] = clearCount
                guard clearCount >= 2 else { return .waitingForCodex }
            }
            candidates.removeValue(forKey: taskID)
            issueClearObservations.removeValue(forKey: taskID)
            lastObserved.removeValue(forKey: taskID)
            return .waitingForCodex
        }
        issueClearObservations.removeValue(forKey: taskID)

        if lastObserved[taskID] != issue {
            lastObserved[taskID] = issue
            logger.warning(
                .accountHandoffDetected,
                "Codex 页面出现信号: \(issue.displayName)，等待确认任务已停止",
                taskID: taskID,
                metadata: .object(["issue": .string(issue.eventName)])
            )
        }

        guard issue.requiresAccountRotation else {
            candidates.removeValue(forKey: taskID)
            return .observed(issue)
        }

        let busy: CodexBusyState
        do {
            busy = try await driver.detectBusyState(app)
        } catch {
            candidates.removeValue(forKey: taskID)
            return .waitingForCodex
        }
        switch busy {
        case .generating:
            // 补发后 Codex 可能短暂进入生成态；不能丢掉“已补发”标记，
            // 否则生成结束后同一条旧限额提示会再次触发补发。
            if candidates[taskID]?.retrySentAt == nil {
                candidates.removeValue(forKey: taskID)
            }
            return .generating
        case .idle:
            break
        case .unknown:
            // 额度横幅本身就是 Codex 已停止生成、要求升级或稍后重试的
            // 终止信号；这类页面经常同时隐藏 Stop/Generating 控件，因此
            // 可以安全进入“同线程补发一次继续”的门控。其他异常仍必须
            // 看到明确“任务已停止”文本，避免未知状态下误退出账号。
            if issue == .quotaExhausted {
                break
            }
            let stopped: Bool
            do {
                stopped = try await driver.detectTaskStopped(app)
            } catch {
                if candidates[taskID]?.retrySentAt == nil {
                    candidates.removeValue(forKey: taskID)
                }
                return .waitingForCodex
            }
            guard stopped else {
                if candidates[taskID]?.retrySentAt == nil {
                    candidates.removeValue(forKey: taskID)
                }
                return .waitingForCodex
            }
        }

        var candidate: Candidate
        if let existing = candidates[taskID], existing.issue == issue {
            candidate = existing
        } else {
            candidate = Candidate(
                issue: issue,
                observations: 0,
                retrySentAt: nil,
                postRetryObservations: 0
            )
        }

        // 额度耗尽先在同一绑定线程真实补发一次。发送完成后保留候选状态，
        // 等页面有时间生成新结果，再以两次稳定观察确认仍然受限。
        if issue == .quotaExhausted, let retrySentAt = candidate.retrySentAt {
            guard now().timeIntervalSince(retrySentAt) >= retrySettleDelay else {
                candidates[taskID] = candidate
                return .observed(issue)
            }
            candidate.postRetryObservations += 1
            candidates[taskID] = candidate
            guard candidate.postRetryObservations >= 2 else {
                return .observed(issue)
            }
            candidates.removeValue(forKey: taskID)
            return await transitionAndRotate(taskID: taskID, issue: issue, simulated: false)
        }

        candidate.observations += 1
        candidates[taskID] = candidate
        guard candidate.observations >= 2 else {
            return .observed(issue)
        }

        if issue == .quotaExhausted {
            do {
                let result = try await resumeController.resumeAfterConfirmedQuota(
                    bindingID: binding.id,
                    message: binding.resumeMessage
                )
                if !result.isConfirmed,
                   (try? await driver.detectAccountIssue(app)) == .quotaExhausted {
                    candidates.removeValue(forKey: taskID)
                    logger.warning(
                        .accountHandoffDetected,
                        "额度耗尽补发未获确认，页面仍明确显示额度耗尽；直接轮换下一个账号",
                        taskID: taskID,
                        metadata: .object([
                            "issue": .string(issue.eventName),
                            "quotaRetry": .bool(true),
                            "sendConfirmed": .bool(false),
                        ])
                    )
                    return await transitionAndRotate(
                        taskID: taskID, issue: issue, simulated: false
                    )
                }
                candidate.retrySentAt = result.sentAt
                candidate.postRetryObservations = 0
                candidates[taskID] = candidate
                logger.warning(
                    .accountHandoffDetected,
                    "额度耗尽已稳定确认；已在原绑定线程补发一次「\(result.sentMessage)」，等待新结果",
                    taskID: taskID,
                    metadata: .object([
                        "issue": .string(issue.eventName),
                        "quotaRetry": .bool(true),
                        "sendConfirmed": .bool(result.isConfirmed),
                    ])
                )
                return .retrySent
            } catch let error as CodexAutomationError {
                candidates.removeValue(forKey: taskID)
                if error.canBeCausedByQuotaBlockingSend,
                   (try? await driver.detectAccountIssue(app)) == .quotaExhausted {
                    logger.warning(
                        .accountHandoffDetected,
                        "额度耗尽导致补发不可用，页面二次确认仍为额度耗尽；直接轮换下一个账号",
                        taskID: taskID,
                        metadata: .object([
                            "issue": .string(issue.eventName),
                            "quotaRetry": .bool(true),
                            "resumeError": .string(error.eventName),
                        ])
                    )
                    return await transitionAndRotate(
                        taskID: taskID, issue: issue, simulated: false
                    )
                }
                let message = error.userMessage
                logger.error(
                    .codexResumeAborted,
                    "额度耗尽后的单次补发失败，未切换账号: \(message)",
                    taskID: taskID,
                    metadata: .object([
                        "issue": .string(issue.eventName),
                        "quotaRetry": .bool(true),
                    ])
                )
                return .retryFailed(message)
            } catch {
                candidates.removeValue(forKey: taskID)
                let message = AppError.normalize(error).userMessage
                logger.error(
                    .codexResumeAborted,
                    "额度耗尽后的单次补发失败，未切换账号: \(message)",
                    taskID: taskID,
                    metadata: .object([
                        "issue": .string(issue.eventName),
                        "quotaRetry": .bool(true),
                    ])
                )
                return .retryFailed(message)
            }
        }

        candidates.removeValue(forKey: taskID)

        return await transitionAndRotate(taskID: taskID, issue: issue, simulated: false)
    }

    /// 显式安全测试入口。用户点击一次相当于注入“额度耗尽”信号，但绝不绕过
    /// Codex 忙碌检查；生成中或状态未知且没有停止信号时会直接拒绝。
    public func simulateQuotaExhaustion(taskID: String) async throws -> CodexQuotaMonitorOutcome {
        guard let task = try tasks.fetch(id: taskID), !task.status.isTerminal else {
            throw AppError.invalidRequest("测试任务不存在或已经结束，请新建一个测试任务")
        }
        // 上一次模拟可能已经安全保存检查点，却在退出、OAuth 或回到 Codex
        // 之前中断。此时任务本来就应保持 waitingForAccount；再次点击测试应
        // 从账号轮换继续，而不是要求用户手动篡改任务状态或重新建任务。
        if task.status == .waitingForAccount {
            guard try bindings.fetchByTask(taskID: taskID) != nil else {
                throw AppError.invalidRequest("请先给测试任务绑定一个 Codex 线程")
            }
            logger.warning(
                .accountHandoffRequested,
                "用户继续上次未完成的安全模拟：检查点已保存，重新执行账号轮换",
                taskID: taskID,
                metadata: .object([
                    "issue": .string(CodexAccountIssue.quotaExhausted.eventName),
                    "automatic": .bool(true),
                    "simulated": .bool(true),
                    "resumedPendingRotation": .bool(true),
                ])
            )
            return await performRotation(
                taskID: taskID,
                issue: .quotaExhausted,
                simulated: true
            )
        }
        guard [.running, .waiting, .waitingForUser, .waitingForBrowser, .queued]
            .contains(task.status) else {
            throw AppError.invalidRequest("任务当前为「\(task.status.displayName)」，不能执行额度模拟")
        }
        guard let binding = try bindings.fetchByTask(taskID: taskID) else {
            throw AppError.invalidRequest("请先给测试任务绑定一个 Codex 线程")
        }
        guard (await driver.checkAccessibilityPermission()).isUsable else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }
        let probe = await driver.probeAvailability(
            bundleIdentifier: binding.applicationBundleIdentifier
        )
        guard probe.isUsable else {
            throw AppError.invalidRequest("Codex 当前不可用：\(probe.summary)")
        }
        let app = try await driver.locateApplication(
            bundleIdentifier: binding.applicationBundleIdentifier
        )
        let busy = try await driver.detectBusyState(app)
        switch busy {
        case .generating:
            throw AppError.invalidRequest("Codex 仍在生成中，安全测试已拒绝退出账号；请等本轮生成停止")
        case .idle:
            break
        case .unknown:
            guard try await driver.detectTaskStopped(app) else {
                throw AppError.invalidRequest(
                    "无法确认 Codex 已停止生成，安全测试没有退出账号；请打开已停止且输入框可用的绑定线程"
                )
            }
        }

        logger.warning(
            .accountHandoffDetected,
            "用户启动安全测试：模拟 Codex 额度耗尽，忙碌检查已通过",
            taskID: taskID,
            metadata: .object(["issue": .string(CodexAccountIssue.quotaExhausted.eventName),
                               "simulated": .bool(true)])
        )
        return await transitionAndRotate(
            taskID: taskID, issue: .quotaExhausted, simulated: true
        )
    }

    private func transitionAndRotate(
        taskID: String,
        issue: CodexAccountIssue,
        simulated: Bool
    ) async -> CodexQuotaMonitorOutcome {
        let prefix = simulated ? "安全测试模拟" : "Codex 检测到"
        let reason = "\(prefix)\(issue.displayName)，且当前线程已停止生成；已保存检查点，准备切换账号"
        do {
            _ = try tasks.updateStatus(
                id: taskID,
                to: .waitingForAccount,
                errorMessage: reason,
                errorClass: issue.eventName
            )
            logger.warning(
                .accountHandoffRequested,
                reason,
                taskID: taskID,
                metadata: .object(["issue": .string(issue.eventName),
                                   "automatic": .bool(true),
                                   "simulated": .bool(simulated)])
            )
        } catch {
            let message = AppError.normalize(error).userMessage
            logger.error(.accountRotationFailed, "无法安全暂停任务，未执行账号轮换: \(message)", taskID: taskID)
            return .rotationFailed(message)
        }

        return await performRotation(taskID: taskID, issue: issue, simulated: simulated)
    }

    /// 任务进入 waitingForAccount 后唯一的账号轮换入口。首次轮换与用户重试
    /// 共用这一段，确保两条路径都在授权成功后启动同一个恢复监视器。
    private func performRotation(
        taskID: String,
        issue: CodexAccountIssue,
        simulated: Bool
    ) async -> CodexQuotaMonitorOutcome {
        do {
            _ = try await (issue == .quotaExhausted
                ? accountRotation.rotateChatGPTAccountAfterQuotaExhaustion(taskID: taskID)
                : accountRotation.rotateChatGPTAccount(taskID: taskID))
            // OAuth 已经确认进入新的 Profile。下一账号若仍然显示额度耗尽，
            // 必须允许它重新走“补发一次 → 二次确认 → 再轮换”；否则只要
            // 连续两个账号都没额度，旧的永久锁存就会把流程卡死。稳定观察、
            // 单次补发和任务状态门控已经足以过滤登录后的短暂旧页面。
            candidates.removeValue(forKey: taskID)
            issueClearObservations.removeValue(forKey: taskID)
            lastObserved.removeValue(forKey: taskID)
            _ = try? tasks.updateStatus(
                id: taskID,
                to: .waitingForAccount,
                errorMessage: "已切换账号，等待新账号登录完成",
                errorClass: issue.eventName,
                waitingUntil: nil
            )
            logger.info(
                .accountHandoffCompleted,
                "已自动退出当前 Codex 账号并完成下一个账号授权，等待恢复绑定线程",
                taskID: taskID,
                metadata: .object(["issue": .string(issue.eventName),
                                   "automatic": .bool(true),
                                   "simulated": .bool(simulated)])
            )
            await onRotationComplete(taskID)
            return .rotationCompleted
        } catch let error as CodexQuotaRotationError {
            if case .allAccountsCoolingDown(let until) = error {
                _ = try? tasks.updateStatus(
                    id: taskID,
                    to: .waitingForAccount,
                    errorMessage: "所有账号额度均在冷却中，等待最早账号恢复后自动切换",
                    errorClass: issue.eventName,
                    waitingUntil: until
                )
                candidates.removeValue(forKey: taskID)
                logger.info(
                    .accountHandoffDetected,
                    "所有账号都在额度冷却中，等待至 \(DateCoding.string(from: until))（含网络缓冲）",
                    taskID: taskID
                )
                await onRotationComplete(taskID)
                return .rotationCompleted
            }
            return .rotationFailed(error.localizedDescription)
        } catch {
            let message = AppError.normalize(error).userMessage
            logger.error(
                .accountRotationFailed,
                "账号轮换失败，任务仍保持等待账号状态: \(message)",
                taskID: taskID,
                metadata: .object(["issue": .string(issue.eventName),
                                   "automatic": .bool(true),
                                   "simulated": .bool(simulated)])
            )
            return .rotationFailed(message)
        }
    }
}

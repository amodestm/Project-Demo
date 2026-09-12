import Foundation

/// Resume 行为的可调参数。
public struct CodexResumeConfiguration: Sendable, Equatable {
    /// 同一 binding 两次 Resume 之间的最小间隔。
    public var cooldown: TimeInterval = 60
    /// 租约有效期 (Monitor 长跑时会续租)。
    public var leaseTTL: TimeInterval = 120
    /// 默认发送内容。
    public var defaultMessage: String = "继续"

    public init() {}
    public static let `default` = CodexResumeConfiguration()
}

/// Test Locate 的结果。
public struct CodexLocateResult: Sendable, Equatable {
    public let bindingID: String
    public let candidateCount: Int
    public let opened: Bool
    public let verification: CodexResumeVerification
    public let report: String

    public var succeeded: Bool { opened && verification.passesLocateGate }
}

/// Resume 的结果。
public struct CodexResumeResult: Sendable, Equatable {
    public let bindingID: String
    public let verification: CodexResumeVerification
    public let confirmation: SendConfirmation
    public let sentMessage: String
    public let sentAt: Date

    /// 是否观察到了发送确认。
    ///
    /// 为 false 时状态是 `sentUnconfirmed` —— **不得**上报为"完成"。
    /// 只是"点了发送", 不代表 Codex 收到了。
    public var isConfirmed: Bool { confirmation != .unconfirmed }
}

/// Codex 绑定线程的恢复编排器。
///
/// ## 顺序是硬性的
///
/// ```
/// load binding → cooldown → lease → 权限 → 找 App → 激活 → 确认 Codex 视图
///   → 找候选线程 → 唯一性判定 → 打开 → **二次验证** → 确认不忙
///   → 找 composer → 聚焦 → 输入 → 校验输入 → 找发送控件
///   → ★最终 Gate★ → 发送 → 观察确认 → 落盘 → 释放租约
/// ```
///
/// 任何一步失败: **STOP**, 不跳过、不降级、不猜测。
///
/// ## 它与 Web Clipboard 模式的关系
///
/// 两者解决的是**不同**问题, 刻意分开:
/// * `ContinuationPromptBuilder` → **新会话恢复**: 生成自包含 prompt, 交给一个
///   没有历史的新对话。适用于"换账号后开新会话"。
/// * `CodexResumeController` → **同一线程续跑**: 线程本身已有全部历史,
///   只需要发一句「继续」。**绝不**把自包含 prompt 发进已有线程。
public actor CodexResumeController {

    private let driver: any CodexUIAutomationDriving
    private let bindings: CodexTaskBindingRepository
    private let leases: CodexResumeLeaseRepository
    private let logger: LoggerService
    private let matcher: CodexTaskMatcher
    private let configuration: CodexResumeConfiguration
    private let ownerID: String
    private let now: @Sendable () -> Date

    public init(
        driver: any CodexUIAutomationDriving,
        bindings: CodexTaskBindingRepository,
        leases: CodexResumeLeaseRepository,
        logger: LoggerService,
        matcher: CodexTaskMatcher = CodexTaskMatcher(),
        configuration: CodexResumeConfiguration = .default,
        ownerID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.driver = driver
        self.bindings = bindings
        self.leases = leases
        self.logger = logger
        self.matcher = matcher
        self.configuration = configuration
        self.ownerID = ownerID
        self.now = now
    }

    public nonisolated var configurationSnapshot: CodexResumeConfiguration { configuration }

    // MARK: - Test Locate（绝不发送）

    /// 定位 + 打开 + 验证, 然后**停住**。
    ///
    /// 这个方法永远不输入、不发送。它的全部意义是让用户在真机上确认
    /// "它每次都能找到正确的那一个线程"。
    public func testLocate(bindingID: String) async throws -> CodexLocateResult {
        let binding = try requireBinding(bindingID)

        logger.info(.codexLocateStarted, "Test Locate: 开始定位绑定线程「\(binding.displayTitle)」",
                    metadata: .object(["bindingID": .string(bindingID)]))

        let located = try await locateAndOpen(binding: binding)

        // ★ 到此为止, 绝不发送 ★
        logger.info(
            .codexTargetVerified,
            "Test Locate 成功: 已打开并验证「\(located.context.threadTitle ?? "?")」"
            + " (未发送任何消息)",
            metadata: .object(["bindingID": .string(bindingID)])
        )
        try? bindings.markVerified(bindingID: bindingID, at: now())

        return CodexLocateResult(
            bindingID: bindingID,
            candidateCount: located.candidateCount,
            opened: true,
            verification: located.verification,
            report: located.verification.report
        )
    }

    // MARK: - Dry Run（绝不发送）

    /// 定位 + 验证 + 找到 composer, 但**不输入、不发送**。
    public func dryRun(bindingID: String) async throws -> CodexResumeVerification {
        let binding = try requireBinding(bindingID)
        let located = try await locateAndOpen(binding: binding)
        var verification = located.verification

        let busy = try await driver.detectBusyState(located.app)
        verification.notCurrentlyGenerating = busy.isSafeToSend

        if let composer = try? await driver.locateComposer(located.app) {
            verification.composerFound = true
            verification.composerEditable = composer.isEditable
        }

        logger.info(
            .codexComposerFound,
            "Dry Run 完成: \(verification.compactSummary) (未输入、未发送)",
            metadata: .object(["bindingID": .string(bindingID)])
        )
        return verification
    }

    // MARK: - Resume（真正发送）

    public func resume(
        bindingID: String,
        message: String? = nil
    ) async throws -> CodexResumeResult {

        let binding = try requireBinding(bindingID)
        let timestamp = now()

        // --- 冷却 ---
        if let remaining = binding.cooldownRemaining(
            cooldown: configuration.cooldown, at: timestamp
        ) {
            logger.warning(
                .codexResumeDuplicateBlocked,
                "冷却中, 拒绝重复 Resume (还剩 \(Int(remaining))s)",
                metadata: .object(["bindingID": .string(bindingID)])
            )
            throw CodexAutomationError.duplicateResumePrevented(retryAfter: remaining)
        }

        // --- 跨进程租约 ---
        let claim = try leases.claim(
            bindingID: bindingID,
            ownerID: ownerID,
            ttl: configuration.leaseTTL,
            now: timestamp
        )
        switch claim {
        case .busy(let existing):
            logger.warning(
                .codexResumeDuplicateBlocked,
                "该绑定已被另一个 Resume 占用 (owner=\(existing.ownerID.prefix(8)))",
                metadata: .object(["bindingID": .string(bindingID)])
            )
            throw CodexAutomationError.resumeLeaseBusy(ownerID: existing.ownerID)

        case .staleRequiresExplicitRecovery(let existing):
            logger.warning(
                .codexResumeDuplicateBlocked,
                "存在过期租约, 需要用户显式恢复",
                metadata: .object(["bindingID": .string(bindingID)])
            )
            throw CodexAutomationError.staleResumeLease(acquiredAt: existing.acquiredAt)

        case .acquired:
            break
        }

        defer { _ = try? leases.release(bindingID: bindingID, ownerID: ownerID) }

        return try await performResume(
            binding: binding,
            text: message ?? binding.resumeMessage
        )
    }

    // MARK: - 用户显式恢复过期锁

    @discardableResult
    public func recoverStaleLease(bindingID: String) throws -> Bool {
        let released = try leases.forceRelease(bindingID: bindingID)
        if released {
            logger.warning(
                .codexResumeAborted,
                "用户强制释放了过期的 Resume 锁",
                metadata: .object(["bindingID": .string(bindingID)])
            )
        }
        return released
    }

    // MARK: - 定位 + 打开 + 二次验证（Test Locate / Dry Run / Resume 共用）

    private struct LocatedTarget {
        let app: CodexAppHandle
        let context: CodexOpenThreadContext
        let candidateCount: Int
        let verification: CodexResumeVerification
    }

    private func requireBinding(_ bindingID: String) throws -> CodexTaskBinding {
        guard let binding = try bindings.fetch(id: bindingID) else {
            throw CodexAutomationError.bindingNotFound(bindingID)
        }
        return binding
    }

    private func locateAndOpen(binding: CodexTaskBinding) async throws -> LocatedTarget {

        // 1) 辅助功能权限 —— 没有权限绝不开始
        let permission = await driver.checkAccessibilityPermission()
        guard permission.isUsable else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }

        // 2) 找目标 App (bundle id 来自绑定时的真实读取, 不硬编码)
        let app = try await driver.locateApplication(
            bundleIdentifier: binding.applicationBundleIdentifier
        )

        // 3) 激活 + 确认 Codex 视图存在
        try await driver.activate(app)
        try await driver.ensureCodexViewPresent(app)

        // 4) 找候选线程
        let candidates = try await driver.locateThreadCandidates(
            app, fingerprint: binding.fingerprint
        )

        var verification = CodexResumeVerification()
        verification.applicationMatched = true
        verification.codexViewMatched = true

        // 5) 唯一性判定 —— 绝不 candidates.first
        let outcome = matcher.match(fingerprint: binding.fingerprint, candidates: candidates)

        let chosen: CodexThreadCandidate
        switch outcome {
        case .notFound:
            logger.error(.codexTargetAmbiguous, "找不到绑定的线程: \(binding.displayTitle)",
                         metadata: .object(["bindingID": .string(binding.id)]))
            throw CodexAutomationError.targetTaskNotFound

        case .onlyWeakMatches(let list):
            logger.error(
                .codexTargetAmbiguous,
                "找到 \(list.count) 个候选, 但都与绑定不匹配 —— 停止",
                metadata: .object(["bindingID": .string(binding.id)])
            )
            throw CodexAutomationError.targetVerificationFailed(
                "找到 \(list.count) 个候选, 但没有一个与绑定匹配"
            )

        case .ambiguous(let list):
            logger.error(
                .codexTargetAmbiguous,
                "匹配到 \(list.count) 个候选, 无法唯一确定 —— 停止",
                metadata: .object([
                    "bindingID": .string(binding.id),
                    "count": .int(list.count),
                ])
            )
            throw CodexAutomationError.ambiguousTarget(count: list.count)

        case .unique(let scored):
            chosen = scored.candidate
            verification.uniqueTargetConfirmed = true
            logger.info(
                .codexTargetFound,
                "唯一匹配 (\(scored.strength.displayName)): \(scored.candidate.title)",
                metadata: .object(["bindingID": .string(binding.id)])
            )
        }

        // 6) 打开
        try await driver.openThread(chosen, in: app)
        logger.info(.codexTargetOpened, "已打开候选线程, 准备二次验证",
                    metadata: .object(["bindingID": .string(binding.id)]))

        // 7) ★二次验证★ —— 回到主会话区重新确认
        let context = try await driver.readOpenThreadContext(app)
        let verified = matcher.verifyOpenedThread(
            context: context, against: binding.fingerprint
        )

        verification.threadMatched = verified.passed
        verification.secondaryContextMatched = verified.secondaryMatched
        verification.failureReason = verified.reason

        guard verified.passed else {
            logger.error(
                .codexTargetVerified,
                "二次验证失败: \(verified.reason ?? "未知") —— 停止, 不发送",
                metadata: .object(["bindingID": .string(binding.id)])
            )
            throw CodexAutomationError.targetVerificationFailed(
                verified.reason ?? "打开后的线程与绑定不一致"
            )
        }

        guard verification.passesLocateGate else {
            throw CodexAutomationError.targetVerificationFailed(
                "定位门槛未通过: \(verification.compactSummary)"
            )
        }

        return LocatedTarget(
            app: app,
            context: context,
            candidateCount: candidates.count,
            verification: verification
        )
    }

    // MARK: - 完整发送流程

    private func performResume(
        binding: CodexTaskBinding,
        text: String
    ) async throws -> CodexResumeResult {

        var verification = CodexResumeVerification()

        do {
            let located = try await locateAndOpen(binding: binding)
            verification = located.verification
            let app = located.app

            // 8) 确认线程当前不在生成
            let busy = try await driver.detectBusyState(app)
            verification.notCurrentlyGenerating = busy.isSafeToSend
            guard busy.isSafeToSend else {
                throw CodexAutomationError.threadAlreadyRunning
            }

            // 9) 找 composer
            let composer = try await driver.locateComposer(app)
            verification.composerFound = true
            verification.composerEditable = composer.isEditable
            guard composer.isEditable else {
                throw CodexAutomationError.composerNotEditable
            }

            try await driver.focusComposer(composer, in: app)
            verification.composerFocused = true

            // 10) 输入并校验
            try await driver.insertMessage(text, into: composer, in: app)
            let actual = try await driver.readComposerValue(composer, in: app)
            let inserted = (actual ?? "").contains(text)
            verification.messageInserted = inserted
            guard inserted else {
                throw CodexAutomationError.messageInsertionFailed(
                    expected: text, actual: actual
                )
            }
            logger.info(.codexMessageInserted, "已输入「\(text)」并校验通过",
                        metadata: .object(["bindingID": .string(binding.id)]))

            // 11) 找发送控件
            let sendControl = try await driver.locateSendControl(app)
            verification.sendControlFound = true

            // 12) ★最终 Gate★ —— 12 项里除 sendConfirmed 外全部必须通过
            guard verification.passesSendGate else {
                throw CodexAutomationError.targetVerificationFailed(
                    "发送门槛未通过: \(verification.compactSummary)"
                )
            }

            // 13) 发送
            try await driver.pressSend(sendControl, in: app)

            // 14) 观察确认
            let confirmation = try await driver.observeSendConfirmation(app, composer: composer)
            verification.sendConfirmed = (confirmation != .unconfirmed)

            let sentAt = now()
            try bindings.markResumeSent(bindingID: binding.id, at: sentAt)
            try bindings.markVerified(bindingID: binding.id, at: sentAt)

            if verification.sendConfirmed {
                logger.info(
                    .codexResumeSent,
                    "已发送「\(text)」并观察到确认 (\(confirmation.rawValue))",
                    metadata: .object(["bindingID": .string(binding.id)])
                )
            } else {
                // ★ 不谎报成功 ★
                logger.warning(
                    .codexResumeUnconfirmed,
                    "已触发发送, 但无法确认 Codex 已接收 —— 状态记为 sentUnconfirmed",
                    metadata: .object(["bindingID": .string(binding.id)])
                )
            }

            logger.info(
                .codexResumeCompleted,
                "Resume 流程结束: \(verification.compactSummary)",
                metadata: .object(["bindingID": .string(binding.id)])
            )

            return CodexResumeResult(
                bindingID: binding.id,
                verification: verification,
                confirmation: confirmation,
                sentMessage: text,
                sentAt: sentAt
            )

        } catch {
            let codexError = (error as? CodexAutomationError) ?? .sendFailed("\(error)")
            logger.error(
                .codexResumeAborted,
                "Resume 中止于 \(codexError.eventName): \(codexError.userMessage)",
                metadata: .object(["bindingID": .string(binding.id)])
            )
            throw codexError
        }
    }
}

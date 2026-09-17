import Foundation

/// 一条来自 MCP server 的控制请求。字段名与 Python 侧写入的 JSON 对齐。
public struct MCPControlRequest: Decodable, Sendable {

    public let id: String
    public let action: String
    public let source: String?
    public let taskID: String?
    public let reason: String?
    public let message: String?
    public let detail: String?
    public let targetProfileDirectory: String?
    public let resumeMessage: String?
    public let resumeAfterSwitch: Bool?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, action, source, reason, message, detail
        case taskID = "task_id"
        case targetProfileDirectory = "target_profile_directory"
        case resumeMessage = "resume_message"
        case resumeAfterSwitch = "resume_after_switch"
        case createdAt = "created_at"
    }
}

/// 写回给 MCP server 的执行结果。
public struct MCPControlResult: Encodable, Sendable {

    public var id: String
    public var ok: Bool
    public var action: String
    public var summary: String?
    public var error: String?
    public var details: [String: String]?
    public var completedAt: String

    public init(
        id: String,
        ok: Bool,
        action: String,
        summary: String? = nil,
        error: String? = nil,
        details: [String: String]? = nil,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.ok = ok
        self.action = action
        self.summary = summary
        self.error = error
        self.details = details
        self.completedAt = ISO8601DateFormatter().string(from: completedAt)
    }
}

/// MCP 控制请求的落地执行者。
///
/// ## 为什么走文件队列而不是本地端口
///
/// 切号与续跑需要辅助功能权限下的 GUI 自动化，而且必须改动任务状态、检查点与
/// 轮换指针 —— 这些只有正在运行的 AIRunner 应用才能安全完成。MCP server 是
/// Codex 拉起的独立子进程，若直接操作同一份状态会出现两个写者。
///
/// 文件队列的写者只有一个（本 actor），请求用「临时文件 + 原子改名」投递，
/// 因此不需要端口、不需要共享密钥，也不会暴露任何本地监听面。
///
/// 报文只是邮箱、Profile 目录名和任务 ID —— 都是公开信息，**不含凭据**。
public actor MCPRequestRouter {

    /// `~/Library/Application Support/AIRunner/mcp-inbox`
    public static func defaultInboxURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AIRunner", isDirectory: true)
            .appendingPathComponent("mcp-inbox", isDirectory: true)
    }

    private let inboxURL: URL
    private let tasks: TaskRepository
    private let bindings: CodexTaskBindingRepository
    private let rotationRepo: AccountRotationRepository
    private let quotaSnapshots: CodexQuotaSnapshotRepository
    private let probe: any CodexQuotaProbing
    private let resumeController: CodexResumeController
    private let quotaMonitor: CodexQuotaMonitor
    private let logger: LoggerService
    private let pollInterval: Duration
    private let now: @Sendable () -> Date

    private var loop: Task<Void, Never>?
    private var inFlight: Set<String> = []

    public init(
        inboxURL: URL = MCPRequestRouter.defaultInboxURL(),
        tasks: TaskRepository,
        bindings: CodexTaskBindingRepository,
        rotationRepo: AccountRotationRepository,
        quotaSnapshots: CodexQuotaSnapshotRepository,
        probe: any CodexQuotaProbing,
        resumeController: CodexResumeController,
        quotaMonitor: CodexQuotaMonitor,
        logger: LoggerService,
        pollInterval: Duration = .seconds(1),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inboxURL = inboxURL
        self.tasks = tasks
        self.bindings = bindings
        self.rotationRepo = rotationRepo
        self.quotaSnapshots = quotaSnapshots
        self.probe = probe
        self.resumeController = resumeController
        self.quotaMonitor = quotaMonitor
        self.logger = logger
        self.pollInterval = pollInterval
        self.now = now
    }

    // MARK: - 生命周期

    public var isRunning: Bool { loop != nil }

    public func start() {
        guard loop == nil else { return }
        try? FileManager.default.createDirectory(
            at: inboxURL, withIntermediateDirectories: true
        )
        logger.info(
            .mcpRequestReceived,
            "MCP 请求通道已启动：\(inboxURL.path)"
        )
        loop = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    public func stop(reason: String = "应用关闭") async {
        guard let loop else { return }
        self.loop = nil
        loop.cancel()
        await loop.value
        logger.info(.mcpRequestReceived, "MCP 请求通道已停止：\(reason)")
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await drainOnce()

            // Codex 关闭 MCP server 时可能留下半条请求；超过 10 分钟的直接归档，
            // 避免陈旧请求在很久之后突然切号。
            await expireStaleRequests(olderThan: 600)
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    // MARK: - 扫描

    private func drainOnce() async {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: inboxURL, includingPropertiesForKeys: nil
        ) else { return }

        for url in entries
            .filter({ $0.pathExtension == "json" })
            .filter({ !$0.lastPathComponent.hasSuffix(".result.json") })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            await process(url)
        }
    }

    private func expireStaleRequests(olderThan seconds: TimeInterval) async {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: inboxURL, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in entries
            .filter({ $0.pathExtension == "json" })
            .filter({ !$0.lastPathComponent.hasSuffix(".result.json") }) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now().timeIntervalSince(modified) > seconds else { continue }
            let identifier = url.deletingPathExtension().lastPathComponent
            guard !inFlight.contains(identifier) else { continue }
            let result = MCPControlResult(
                id: identifier,
                ok: false,
                action: "expired",
                error: "请求已过期（未在 10 分钟内被处理）。",
                completedAt: now()
            )
            write(result, for: url)
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - 单条处理

    private func process(_ url: URL) async {
        let identifier = url.deletingPathExtension().lastPathComponent
        guard !inFlight.contains(identifier) else { return }
        inFlight.insert(identifier)
        defer { inFlight.remove(identifier) }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return
        }

        let request: MCPControlRequest
        do {
            request = try JSONDecoder().decode(MCPControlRequest.self, from: data)
        } catch {
            let failed = MCPControlResult(
                id: identifier,
                ok: false,
                action: "unknown",
                error: "请求格式无法解析：\(error.localizedDescription)"
            )
            write(failed, for: url)
            try? FileManager.default.removeItem(at: url)
            return
        }

        logger.info(
            .mcpRequestReceived,
            "收到 MCP 请求: \(request.action)（来源 \(request.source ?? "unknown")）",
            taskID: request.taskID,
            metadata: .object([
                "mcpRequestID": .string(request.id),
                "action": .string(request.action),
                "reason": .string(request.reason ?? ""),
            ])
        )

        let result = await execute(request)

        logger.info(
            result.ok ? .mcpRequestCompleted : .mcpRequestFailed,
            "MCP 请求 \(request.action) \(result.ok ? "完成" : "失败"): "
            + (result.summary ?? result.error ?? ""),
            taskID: request.taskID,
            metadata: .object([
                "mcpRequestID": .string(request.id),
                "action": .string(request.action),
                "ok": .bool(result.ok),
            ])
        )

        // 结果先落盘、再删除请求 —— 反过来会让 MCP server 永远等不到结果。
        write(result, for: url)
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ result: MCPControlResult, for requestURL: URL) {
        let identifier = requestURL.deletingPathExtension().lastPathComponent
        let target = requestURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(identifier).result.json")
        guard let data = try? JSONEncoder().encode(result) else { return }
        let temporary = target.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            try? data.write(to: target, options: .atomic)
        }
    }

    // MARK: - 动作分发

    private func execute(_ request: MCPControlRequest) async -> MCPControlResult {
        do {
            switch request.action {
            case "status":
                return try await executeStatus(request)
            case "snapshotQuota":
                return try await executeSnapshot(request)
            case "resumeTask":
                return try await executeResume(request)
            case "switchAccount":
                return try await executeSwitch(request)
            case "reportQuotaExhausted":
                return try await executeReportedExhaustion(request)
            default:
                return MCPControlResult(
                    id: request.id, ok: false, action: request.action,
                    error: "未知动作：\(request.action)"
                )
            }
        } catch {
            return MCPControlResult(
                id: request.id, ok: false, action: request.action,
                error: AppError.normalize(error).userMessage
            )
        }
    }

    private func executeStatus(_ request: MCPControlRequest) async throws -> MCPControlResult {
        let unfinished = try tasks.fetchUnfinished()
        var lines: [String] = []
        for task in unfinished.prefix(10) {
            let binding = try bindings.fetchByTask(taskID: task.id)
            let profile = binding?.chromeProfileDirectory ?? "(未绑定)"
            lines.append("\(task.name) [\(task.status.displayName)] · \(profile)")
        }
        let monitorRunning = await quotaMonitor.monitoredTaskIDs()
        return MCPControlResult(
            id: request.id, ok: true, action: request.action,
            summary: lines.isEmpty
                ? "当前没有未结束的 AIRunner 任务。"
                : "未结束任务 \(unfinished.count) 个：\n" + lines.joined(separator: "\n"),
            details: [
                "unfinished": String(unfinished.count),
                "monitored": monitorRunning.joined(separator: ","),
            ]
        )
    }

    private func executeSnapshot(_ request: MCPControlRequest) async throws -> MCPControlResult {
        let profile = try resolveProfileForSnapshot(request.targetProfileDirectory)
        let usage = try await probe.probe()
        let snapshot = usage.snapshot(
            profileDirectory: profile, source: "mcp", at: now()
        )
        try quotaSnapshots.record(snapshot)
        try? quotaSnapshots.prune()
        return MCPControlResult(
            id: request.id, ok: true, action: request.action,
            summary: Self.describe(usage),
            details: [
                "profileDirectory": profile,
                "email": usage.email ?? "",
                "primaryUsedPercent": usage.primaryUsedPercent.map { String($0) } ?? "",
                "primaryResetAt": usage.primaryResetAt.map { String($0) } ?? "",
                "limitReached": usage.limitReached.map { String($0) } ?? "",
            ]
        )
    }

    private func executeResume(_ request: MCPControlRequest) async throws -> MCPControlResult {
        guard let taskID = request.taskID, !taskID.isEmpty else {
            return MCPControlResult(
                id: request.id, ok: false, action: request.action,
                error: "缺少 task_id。"
            )
        }
        guard let binding = try bindings.fetchByTask(taskID: taskID) else {
            return MCPControlResult(
                id: request.id, ok: false, action: request.action,
                error: "任务 \(taskID) 还没有绑定 Codex 线程，无法续跑。"
            )
        }
        let result = try await resumeController.resume(
            bindingID: binding.id,
            message: request.message ?? binding.resumeMessage
        )
        return MCPControlResult(
            id: request.id, ok: true, action: request.action,
            summary: result.isConfirmed
                ? "已向线程「\(binding.displayTitle)」补发「\(result.sentMessage)」并收到确认。"
                : "已向线程「\(binding.displayTitle)」发出「\(result.sentMessage)」，但没有观察到确认。",
            details: [
                "bindingID": binding.id,
                "sentMessage": result.sentMessage,
                "confirmed": String(result.isConfirmed),
            ]
        )
    }

    /// 复用额度监视器的完整安全链路：忙碌检查 → 保存检查点 → 切号 → 启动恢复监视器。
    ///
    /// 这里**不**自己调 AccountRotationManager，避免绕过「Codex 是否仍在生成」这条
    /// 门控 —— 在推理中途退出账号会中断本地聊天与计划任务。
    private func executeSwitch(_ request: MCPControlRequest) async throws -> MCPControlResult {
        guard let taskID = request.taskID, !taskID.isEmpty else {
            return MCPControlResult(
                id: request.id, ok: false, action: request.action,
                error: "缺少 task_id。请先用 task_status 查到任务 ID。"
            )
        }
        let outcome = try await quotaMonitor.handleReportedQuotaExhaustion(
            taskID: taskID,
            source: request.source ?? "codex-mcp",
            detail: request.detail ?? request.reason
        )
        return MCPControlResult(
            id: request.id, ok: true, action: request.action,
            summary: Self.describe(outcome),
            details: ["taskID": taskID, "role": request.reason ?? ""]
        )
    }

    private func executeReportedExhaustion(
        _ request: MCPControlRequest
    ) async throws -> MCPControlResult {
        guard let taskID = request.taskID, !taskID.isEmpty else {
            return MCPControlResult(
                id: request.id, ok: false, action: request.action,
                error: "缺少 task_id。"
            )
        }
        let key = "profile:\(try resolveProfileForSnapshot(nil))"
        let at = now()
        try rotationRepo.recordQuotaExhaustion(
            accountKey: key,
            exhaustedAt: at,
            availableAt: at.addingTimeInterval(5 * 60 * 60 + 2 * 60)
        )
        logger.warning(
            .accountHandoffDetected,
            "Codex 通过 MCP 上报额度耗尽：\(request.reason ?? "未说明")",
            taskID: taskID,
            metadata: .object([
                "source": .string(request.source ?? "codex-mcp"),
                "accountKey": .string(key),
                "detail": .string(request.detail ?? ""),
            ])
        )
        return MCPControlResult(
            id: request.id, ok: true, action: request.action,
            summary: "已记录该账号额度耗尽；可用 request_account_switch 立即切换账号。",
            details: ["accountKey": key]
        )
    }

    // MARK: - 辅助

    private func resolveProfileForSnapshot(_ explicit: String?) throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let latest = try rotationRepo.mostRecentChatGPTAccount(),
           latest.hasPrefix("profile:") {
            let directory = String(latest.dropFirst("profile:".count))
            if !directory.isEmpty { return directory }
        }
        return "unknown"
    }

    static func describe(_ usage: CodexQuotaUsage) -> String {
        var parts: [String] = []
        if let email = usage.email { parts.append(email) }
        if let plan = usage.planType { parts.append("套餐 \(plan)") }
        if let remaining = usage.primaryRemainingPercent {
            parts.append("5 小时窗口剩余 \(Int(remaining.rounded()))%")
        }
        if let reset = usage.primaryResetAt {
            parts.append("恢复于 \(Self.localText(reset))")
        }
        if let allowed = usage.allowed, !allowed {
            parts.append("当前不可用")
        }
        return parts.isEmpty ? "额度信息为空。" : parts.joined(separator: " · ")
    }

    static func describe(_ outcome: CodexQuotaMonitorOutcome) -> String {
        switch outcome {
        case .waitingForTask:
            return "任务当前不在运行态，没有执行切号。"
        case .waitingForCodex:
            return "等待 Codex 进入可操作状态，本次没有切号。"
        case .generating:
            return "Codex 仍在生成中，为保护当前推理没有退出账号。等本轮结束后重试。"
        case .observed(let issue):
            return "已观察到信号「\(issue.displayName)」，但还未达到切号门槛。"
        case .retrySent:
            return "已先在同一线程补发一次「继续」，等页面出现新结果。"
        case .retryFailed(let message):
            return "补发失败，未切换账号：\(message)"
        case .rotationCompleted:
            return "已完成账号切换，正在等待新账号恢复绑定线程。"
        case .rotationFailed(let message):
            return "账号切换失败：\(message)"
        case .stopped:
            return "监视已停止（任务已结束或不存在）。"
        }
    }

    static func localText(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

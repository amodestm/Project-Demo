import Foundation

/// 任务状态。
///
/// 分三组:
/// * **流程态**: queued / running / waiting / paused
/// * **等用户态**: waitingForAccount / waitingForBrowser / waitingForUser
///   —— checkpoint 已安全落盘, 只差用户做一个手动动作 (切账号 / 打开页面 / 提交 prompt)
/// * **终态**: completed / failed / cancelled
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waiting

    /// ★ ChatGPT Web 兼容流程: 当前 session 无法继续, 需要切换到另一个
    /// **自己已授权**的 ChatGPT session。任务详情可从 macOS Keychain 读取用户
    /// 保存的凭据并自动登录下一个账号；程序不读 Cookie 或 session token。
    case waitingForAccount
    /// 需要用户把浏览器/页面准备好 (例如 ChatGPT 页面被关闭, 或需要新开一个对话)。
    case waitingForBrowser
    /// prompt 已生成并交给用户, 等用户把 ChatGPT 的输出贴回来。
    case waitingForUser

    case paused
    case completed
    case failed
    case cancelled

    /// 终态: 不再有任何自动执行。
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running, .waiting, .paused,
             .waitingForAccount, .waitingForBrowser, .waitingForUser: return false
        }
    }

    /// 是否处于"非终态且可被 Runner 接管"。
    public var isRunnable: Bool {
        self == .running || self == .queued
    }

    /// 是否需要用户到手动操作才能继续。
    ///
    /// Runner 遇到这些状态会立刻退出, 不做任何轮询等待 —— 用户可能几小时后才回来。
    public var requiresUserAction: Bool {
        switch self {
        case .waitingForAccount, .waitingForBrowser, .waitingForUser: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued:            return "排队中"
        case .running:           return "运行中"
        case .waiting:           return "等待中"
        case .waitingForAccount: return "等待切换账号"
        case .waitingForBrowser: return "等待浏览器"
        case .waitingForUser:    return "等待提交结果"
        case .paused:            return "已暂停"
        case .completed:         return "已完成"
        case .failed:            return "已失败"
        case .cancelled:         return "已取消"
        }
    }

    /// 合法状态迁移表。
    ///
    /// 存在的意义: 阻止"已完成的任务被 Resume"这类会把 checkpoint 逻辑搞乱的非法迁移。
    public var allowedTransitions: Set<TaskStatus> {
        let awaiting: Set<TaskStatus> = [.waitingForAccount, .waitingForBrowser, .waitingForUser]
        // 从任意非终态出发都允许转往的状态
        let awaken: Set<TaskStatus> = [.running, .paused, .cancelled, .failed]

        switch self {
        case .queued:
            return awaken.union(awaiting)

        case .running:
            var result = awaken.union(awaiting)
            result.formUnion([.waiting, .completed, .queued])
            return result

        case .waiting:
            return awaken.union(awaiting)

        // 等用户态之间可以互相切换 (例如「等待浏览器」→「等待切换账号」);
        // 用户做完动作后 → running, 也可以转 paused / cancelled / failed。
        case .waitingForAccount, .waitingForBrowser, .waitingForUser:
            return awaken.union(awaiting)

        case .paused:
            let base: Set<TaskStatus> = [.running, .cancelled, .failed]
            return base

        case .completed:
            return []                       // 终态

        case .failed:
            // 允许 → running, 但**必须**经由 `TaskManager.retryFailedTask`:
            // 那条路径会先把失败步骤重置为 pending, 再启动 Runner。
            // 直接 start 会让失败的步骤被静默跳过 (见 JobRunner.start 的守卫)。
            let base: Set<TaskStatus> = [.running]
            return base

        case .cancelled:
            // ★ 终态, 不可恢复 ★
            //
            // 取消是用户的明确决定, 不该被一个「继续」按钮直接复活。
            // 若将来确实需要重做, 应当从检查点 Clone 出一个**新任务**,
            // 而不是把原任务拉起来 —— 那样才能保持"取消就是取消"的语义清晰。
            //
            // 之前这里声明了 `.running`, 但 TaskManager.resume 又拒绝 cancelled,
            // 造成"状态表说可以、实际操作被拒"的矛盾。现在两边一致了。
            return []
        }
    }

    public func canTransition(to next: TaskStatus) -> Bool {
        if next == self { return true }
        return allowedTransitions.contains(next)
    }
}

/// 一个长任务。
public struct AITask: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public var name: String
    public var goal: String
    public var status: TaskStatus

    /// 执行通道。新任务默认走 Codex 桌面自动执行；`chatgpt_web` 和 `api`
    /// 是保留的兼容/可选后端。
    public var executionMode: ExecutionMode

    /// 这两个字段只在 `executionMode == .api` 时有意义。
    /// Web 模式下不参与主流程, 保留是为了让已有的 API 后端仍然可用。
    public var primaryProvider: String
    public var primaryModel: String

    public var currentStep: Int
    public var totalSteps: Int

    public var retryCount: Int
    public var maxRetries: Int

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: 扩展字段

    /// 失败/暂停原因 (用户可读)。
    public var errorMessage: String?
    /// AppError.eventName, 便于 UI 分类展示。
    public var errorClass: String?
    /// waiting 状态的目标解除时间。
    public var waitingUntil: Date?
    /// 规划方式: explicit / uniform (MVP 用 uniform)。
    public var planType: String
    /// 任意扩展元数据。
    public var meta: JSONValue

    public init(
        id: String = UUID().uuidString,
        name: String,
        goal: String,
        status: TaskStatus = .queued,
        executionMode: ExecutionMode = .codexDesktop,
        primaryProvider: String = "",
        primaryModel: String = "",
        currentStep: Int = 0,
        totalSteps: Int = 0,
        retryCount: Int = 0,
        maxRetries: Int = 8,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        errorMessage: String? = nil,
        errorClass: String? = nil,
        waitingUntil: Date? = nil,
        planType: String = "uniform",
        meta: JSONValue = .emptyObject
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.status = status
        self.executionMode = executionMode
        self.primaryProvider = primaryProvider
        self.primaryModel = primaryModel
        self.currentStep = currentStep
        self.totalSteps = totalSteps
        self.retryCount = retryCount
        self.maxRetries = maxRetries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.errorClass = errorClass
        self.waitingUntil = waitingUntil
        self.planType = planType
        self.meta = meta
    }

    /// 0.0 ... 1.0
    public var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return min(1.0, max(0.0, Double(currentStep) / Double(totalSteps)))
    }

    public var progressText: String {
        "\(currentStep) / \(totalSteps)"
    }

    public var isFinished: Bool { status.isTerminal }

    /// 当前是否需要用户做一个手动动作。
    public var needsUserAction: Bool { status.requiresUserAction }

    /// 人类可读的下一步动作提示。
    public var actionHint: String {
        switch status {
        case .queued:
            return executionMode == .codexDesktop
                ? "绑定 Codex 工作对话后点击「开始监控」"
                : "点击「开始执行」"
        case .running:
            switch executionMode {
            case .codexDesktop: return "正在监控绑定的 Codex 工作对话"
            case .chatGPTWeb: return "正在准备下一步的续跑 prompt"
            case .api: return "正在执行"
            }
        case .waiting:
            return waitingUntil.map { "等待至 \(DateCoding.string(from: $0))" } ?? "等待中"
        case .waitingForAccount:
            return "已安全保存检查点。正在自动登录下一个 ChatGPT 账号；若遇到验证码或安全挑战，请处理后继续。"
        case .waitingForBrowser:
            return "请在浏览器中打开 ChatGPT, 然后点「我已完成」。"
        case .waitingForUser:
            return "续跑 prompt 已复制。请提交给 ChatGPT, 再把回复贴回来。"
        case .paused:
            return errorMessage ?? "已暂停, 可继续"
        case .completed:
            return "全部步骤已完成"
        case .failed:
            return errorMessage ?? "执行失败"
        case .cancelled:
            return "已取消, 历史结果保留"
        }
    }
}

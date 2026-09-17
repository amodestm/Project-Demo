import Foundation

public enum CodexQuotaRotationError: Error, Sendable, Equatable {
    case allAccountsCoolingDown(until: Date)
}

extension CodexQuotaRotationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .allAccountsCoolingDown(let until):
            return "所有账号仍在额度冷却中，最早恢复时间为 \(DateCoding.string(from: until))"
        }
    }
}

// MARK: - 错误

/// Codex 自动化相关错误。
///
/// 任何 `ambiguous` / `verification` 类错误都意味着 **fail closed** ——
/// 不发送、不重试、交由用户重新绑定。
public enum CodexAutomationError: Error, Sendable, Equatable {

    case accessibilityPermissionMissing
    case applicationNotFound(String)
    case codexViewNotFound

    case targetTaskNotFound
    case ambiguousTarget(count: Int)
    case targetVerificationFailed(String)

    case threadAlreadyRunning
    case modelControlNotFound
    case modelOptionNotFound(String)
    case reasoningOptionNotFound(String)
    case modelSelectionAmbiguous(label: String, count: Int)
    case modelSelectionFailed(expected: String, actual: String?)
    case composerNotFound
    case composerNotEditable
    case composerFocusFailed
    case messageInsertionFailed(expected: String, actual: String?)
    case sendControlNotFound
    case sendFailed(String)
    /// 发送被触发了, 但观察不到任何确认信号。**不得**上报为成功。
    case sendUnconfirmed

    case duplicateResumePrevented(retryAfter: TimeInterval)
    case resumeLeaseBusy(ownerID: String)
    case staleResumeLease(acquiredAt: Date)

    case bindingNotFound(String)
    case timeout(String)

    public var userMessage: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "需要辅助功能权限。请在「系统设置 → 隐私与安全性 → 辅助功能」中授权 AIRunner。"
        case .applicationNotFound(let id):
            return "找不到目标应用 (\(id))。请确认它已经打开。"
        case .codexViewNotFound:
            return "目标应用里没有找到 Codex 界面。"
        case .targetTaskNotFound:
            return "找不到绑定的 Codex 线程。"
        case .ambiguousTarget(let count):
            return "匹配到 \(count) 个候选线程, 无法唯一确定。请重新绑定或手动选择。"
        case .targetVerificationFailed(let detail):
            return "目标验证未通过: \(detail)"
        case .threadAlreadyRunning:
            return "目标线程正在生成中, 不发送「继续」。"
        case .modelControlNotFound:
            return "找不到 Codex 模型选择器。"
        case .modelOptionNotFound(let model):
            return "模型列表中找不到「\(model)」。"
        case .reasoningOptionNotFound(let effort):
            return "思考程度列表中找不到「\(effort)」。"
        case .modelSelectionAmbiguous(let label, let count):
            return "模型菜单中匹配到 \(count) 个「\(label)」选项, 无法唯一确定。"
        case .modelSelectionFailed(let expected, let actual):
            return "模型设置校验失败 (期望「\(expected)」, 实际「\(actual ?? "无法读取")」)。"
        case .composerNotFound:
            return "找不到消息输入框。"
        case .composerNotEditable:
            return "消息输入框当前不可编辑。"
        case .composerFocusFailed:
            return "无法让输入框获得焦点。"
        case .messageInsertionFailed(let expected, let actual):
            return "输入内容校验失败 (期望含「\(expected)」, 实际「\(actual ?? "nil")」)。"
        case .sendControlNotFound:
            return "找不到发送按钮。"
        case .sendFailed(let detail):
            return "发送失败: \(detail)"
        case .sendUnconfirmed:
            return "已触发发送, 但无法确认 Codex 已接收。"
        case .duplicateResumePrevented(let after):
            return "刚刚已经发送过, 请在 \(Int(after)) 秒后再试。"
        case .resumeLeaseBusy(let owner):
            return "该绑定正被另一个 Resume 操作占用 (\(owner.prefix(8)))。"
        case .staleResumeLease(let at):
            return "上一次 Resume 可能异常退出 (获取于 \(DateCoding.string(from: at)))。"
                + "请点「恢复 Resume 锁」后再试。"
        case .bindingNotFound(let id):
            return "找不到绑定: \(id)"
        case .timeout(let detail):
            return "操作超时: \(detail)"
        }
    }

    public var eventName: String {
        switch self {
        case .accessibilityPermissionMissing: return "ACCESSIBILITY_PERMISSION_MISSING"
        case .applicationNotFound:             return "APPLICATION_NOT_FOUND"
        case .codexViewNotFound:               return "CODEX_VIEW_NOT_FOUND"
        case .targetTaskNotFound:              return "TARGET_TASK_NOT_FOUND"
        case .ambiguousTarget:                 return "TARGET_AMBIGUOUS"
        case .targetVerificationFailed:        return "TARGET_VERIFICATION_FAILED"
        case .threadAlreadyRunning:            return "THREAD_ALREADY_RUNNING"
        case .modelControlNotFound:             return "MODEL_CONTROL_NOT_FOUND"
        case .modelOptionNotFound:              return "MODEL_OPTION_NOT_FOUND"
        case .reasoningOptionNotFound:          return "REASONING_OPTION_NOT_FOUND"
        case .modelSelectionAmbiguous:          return "MODEL_SELECTION_AMBIGUOUS"
        case .modelSelectionFailed:             return "MODEL_SELECTION_FAILED"
        case .composerNotFound:                return "COMPOSER_NOT_FOUND"
        case .composerNotEditable:             return "COMPOSER_NOT_EDITABLE"
        case .composerFocusFailed:             return "COMPOSER_FOCUS_FAILED"
        case .messageInsertionFailed:          return "MESSAGE_INSERTION_FAILED"
        case .sendControlNotFound:             return "SEND_CONTROL_NOT_FOUND"
        case .sendFailed:                       return "SEND_FAILED"
        case .sendUnconfirmed:                 return "SEND_UNCONFIRMED"
        case .duplicateResumePrevented:        return "RESUME_DUPLICATE_BLOCKED"
        case .resumeLeaseBusy:                 return "RESUME_LEASE_BUSY"
        case .staleResumeLease:                return "STALE_RESUME_LEASE"
        case .bindingNotFound:                 return "BINDING_NOT_FOUND"
        case .timeout:                         return "CODEX_TIMEOUT"
        }
    }

    /// 这些错误可能是额度耗尽页面禁用了 Composer / 发送按钮造成的。
    /// 只有上层重新读取页面并再次确认额度横幅后，才允许据此继续轮换账号。
    public var canBeCausedByQuotaBlockingSend: Bool {
        switch self {
        case .composerNotFound, .composerNotEditable, .composerFocusFailed,
             .messageInsertionFailed, .sendControlNotFound, .sendFailed,
             .sendUnconfirmed:
            return true
        default:
            return false
        }
    }
}

extension CodexAutomationError: LocalizedError {
    public var errorDescription: String? { userMessage }
}

// MARK: - 权限

public enum AccessibilityPermissionStatus: String, Sendable, Equatable, CaseIterable {
    case granted
    case denied
    /// 无法判定 (非 macOS, 或 API 不可用)。
    case unknown

    public var isUsable: Bool { self == .granted }
}

// MARK: - 不透明句柄

/// 目标 App 的句柄。
///
/// ## ★ 绝不持久化 ★
///
/// `processIdentifier` 与窗口编号在 App 重启后全部失效。
/// 它们**只**在单次 resume 会话内作为临时值使用。
/// 数据库里只允许保存可重建的 fingerprint (见 `CodexTaskBinding`)。
public struct CodexAppHandle: Sendable, Equatable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String
    public let applicationName: String?

    public init(processIdentifier: Int32, bundleIdentifier: String, applicationName: String? = nil) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }

    public var label: String { applicationName ?? bundleIdentifier }
}

/// 消息输入框句柄。同样不持久化。
public struct CodexComposerHandle: Sendable, Equatable {
    public let identifier: String
    public let isEditable: Bool

    public init(identifier: String, isEditable: Bool) {
        self.identifier = identifier
        self.isEditable = isEditable
    }
}

/// 发送控件句柄。同样不持久化。
public struct CodexSendControlHandle: Sendable, Equatable {
    public let identifier: String
    public let label: String?

    public init(identifier: String, label: String? = nil) {
        self.identifier = identifier
        self.label = label
    }
}

/// 目标 App 的可用性探测结果 (Monitor 用的轻量检查, 不产生任何副作用)。
public struct CodexAvailabilityProbe: Sendable, Equatable {
    public let applicationRunning: Bool
    public let codexViewPresent: Bool
    public let accessibilityGranted: Bool

    public init(applicationRunning: Bool, codexViewPresent: Bool, accessibilityGranted: Bool) {
        self.applicationRunning = applicationRunning
        self.codexViewPresent = codexViewPresent
        self.accessibilityGranted = accessibilityGranted
    }

    public var isUsable: Bool {
        accessibilityGranted && applicationRunning && codexViewPresent
    }

    public var summary: String {
        "accessibility=\(accessibilityGranted) app=\(applicationRunning) codexView=\(codexViewPresent)"
    }
}

// MARK: - 驱动协议

/// UI 自动化驱动。
///
/// ## 为什么要这层抽象
///
/// `CodexResumeController` 的全部编排逻辑 (顺序、Gate、fail-closed 判定) 都依赖本协议,
/// 因此可以用 `FakeCodexUIAutomationDriver` 做完整单元测试 —— 不需要真机、
/// 不需要辅助功能权限、不依赖 Codex 的 UI 结构。
///
/// **真实实现 (AXUIElement) 是唯一需要随 Codex UI 变化而修改的地方。**
/// 它不污染 Controller。
///
/// ## ★ 边界 ★
///
/// 实现方**只允许**通过 macOS Accessibility API 读写 UI。
/// 明确禁止: 固定屏幕坐标、OCR 作为正常路径、截图模板匹配作为正常路径、
/// 读取 Codex 私有数据库、读写认证数据、逆向私有网络 API。
public protocol CodexUIAutomationDriving: Sendable {

    func checkAccessibilityPermission() async -> AccessibilityPermissionStatus

    /// 轻量探测: 目标 App 是否可用。**不得**产生任何副作用。
    func probeAvailability(bundleIdentifier: String) async -> CodexAvailabilityProbe

    func locateApplication(bundleIdentifier: String) async throws -> CodexAppHandle
    func activate(_ app: CodexAppHandle) async throws
    func ensureCodexViewPresent(_ app: CodexAppHandle) async throws

    /// 关闭登录后偶发出现、会遮挡侧边栏和 Composer 的产品介绍弹窗。
    /// 只能在弹窗语义明确且关闭按钮唯一时执行；没有弹窗时返回 false。
    func dismissBlockingWelcomeOverlay(_ app: CodexAppHandle) async throws -> Bool

    /// 在 sidebar / 列表中找出候选线程。
    func locateThreadCandidates(
        _ app: CodexAppHandle,
        fingerprint: CodexTaskFingerprint
    ) async throws -> [CodexThreadCandidate]

    /// 选中一个候选线程 (点击 / AXPress)。
    func openThread(_ candidate: CodexThreadCandidate, in app: CodexAppHandle) async throws

    /// 打开之后**重新读取主会话区** —— 二次验证的依据。
    func readOpenThreadContext(_ app: CodexAppHandle) async throws -> CodexOpenThreadContext

    func detectBusyState(_ app: CodexAppHandle) async throws -> CodexBusyState

    /// 检查 Codex 的任意可见窗口是否仍在生成。设置页的真实退出测试必须先过
    /// 这道全局门，避免只检查当前焦点窗口而漏掉另一个正在运行的任务。
    func detectAnyTaskGenerating(_ app: CodexAppHandle) async throws -> Bool

    /// 在忙碌状态无法明确判定时，读取页面是否出现“任务已停止”的终止信号。
    /// 额度错误页通常会移除 Stop 按钮，因此这是自动切号前的第二道安全门。
    func detectTaskStopped(_ app: CodexAppHandle) async throws -> Bool

    /// 读取 Codex 当前窗口的额度耗尽 / 登录失效 / 任务停止信号。
    /// 没有稳定信号时返回 nil；调用方必须等待，不能猜测并切号。
    func detectAccountIssue(_ app: CodexAppHandle) async throws -> CodexAccountIssue?

    /// 设置模型与思考程度，并回读模型按钮确认最终状态。
    func applyExecutionPreference(
        _ preference: CodexExecutionPreference,
        in app: CodexAppHandle
    ) async throws -> CodexExecutionSelection

    /// 只读当前模型按钮状态；Dry Run 使用，不改变任何设置。
    func readExecutionSelection(_ app: CodexAppHandle) async throws -> CodexExecutionSelection

    func locateComposer(_ app: CodexAppHandle) async throws -> CodexComposerHandle
    func focusComposer(_ composer: CodexComposerHandle, in app: CodexAppHandle) async throws
    func insertMessage(
        _ text: String,
        into composer: CodexComposerHandle,
        in app: CodexAppHandle
    ) async throws
    func readComposerValue(_ composer: CodexComposerHandle, in app: CodexAppHandle) async throws -> String?

    func locateSendControl(_ app: CodexAppHandle) async throws -> CodexSendControlHandle
    func pressSend(_ control: CodexSendControlHandle, in app: CodexAppHandle) async throws

    /// 发送后观察一个确认信号。
    func observeSendConfirmation(
        _ app: CodexAppHandle,
        composer: CodexComposerHandle
    ) async throws -> SendConfirmation
}

public extension CodexUIAutomationDriving {
    func dismissBlockingWelcomeOverlay(_ app: CodexAppHandle) async throws -> Bool {
        false
    }

    /// 兼容测试替身和第三方实现；真实 AX 驱动会扫描全部 Codex 窗口。
    func detectAnyTaskGenerating(_ app: CodexAppHandle) async throws -> Bool {
        try await detectBusyState(app) == .generating
    }
}

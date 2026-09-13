import Foundation

/// Codex 任务发送前需要锁定的模型与思考程度。
///
/// `modelID` 用稳定的 API 名称持久化；`modelDisplayName` 只用于匹配 Codex
/// 界面上的可见文字。AIRunner 不读取 Codex 私有数据。
public struct CodexExecutionPreference: Codable, Sendable, Equatable, Hashable {
    public var modelID: String
    public var reasoningEffort: CodexReasoningEffort

    public init(modelID: String, reasoningEffort: CodexReasoningEffort) {
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
    }

    public static let gpt56SolHigh = CodexExecutionPreference(
        modelID: "gpt-5.6-sol",
        reasoningEffort: .high
    )

    public var modelDisplayName: String {
        switch modelID.lowercased() {
        case "gpt-5.6-sol": return "GPT-5.6 Sol"
        case "gpt-5.6-terra": return "GPT-5.6 Terra"
        case "gpt-5.6-luna": return "GPT-5.6 Luna"
        case "gpt-6-astra": return "GPT-6 Astra"
        case "gpt-5.5": return "GPT-5.5"
        default: return modelID
        }
    }

    public var displayName: String {
        "\(modelDisplayName) · \(reasoningEffort.displayName)"
    }
}

public enum CodexReasoningEffort: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    public var displayName: String {
        switch self {
        case .low: return "轻度"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "极高"
        case .max: return "最高"
        case .ultra: return "ultra"
        }
    }

    /// Codex 可能随界面语言变化；真实驱动只在弹出的模型菜单中匹配这些完整标签。
    public var uiLabels: [String] {
        switch self {
        case .low: return ["轻度", "低", "Low", "low"]
        case .medium: return ["中", "中等", "Medium", "medium"]
        case .high: return ["高", "High", "high"]
        case .xhigh: return ["极高", "超高", "Extra high", "XHigh", "xhigh"]
        // “Ultra” 是第六个滑杆档位；不能再把它作为“最高”的别名，
        // 否则回读时无法区分第五个和第六个点。
        case .max: return ["最高", "最大", "Max", "Maximum", "max"]
        case .ultra: return ["ultra", "Ultra"]
        }
    }

    /// 滑杆从左到右的稳定序号。顺序与 Codex 当前六个离散点一致。
    public var sliderIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// 六个离散点在归一化滑杆上的位置 (左端 0，右端 1)。
    public var sliderFraction: Double {
        guard Self.allCases.count > 1 else { return 0 }
        return Double(sliderIndex) / Double(Self.allCases.count - 1)
    }

    /// 将滑杆归一化位置映射到最近的离散档位。
    public static func fromSliderFraction(_ fraction: Double) -> Self {
        let last = Swift.max(0, allCases.count - 1)
        let clamped = Swift.min(1, Swift.max(0, fraction))
        let index = Int((clamped * Double(last)).rounded())
        return allCases[Swift.min(last, Swift.max(0, index))]
    }

    /// 将 AXSlider 的真实 min/max 数值映射到离散档位。
    public static func fromSliderValue(
        _ value: Double, min minValue: Double, max maxValue: Double
    ) -> Self? {
        guard maxValue > minValue else { return nil }
        let fraction = (value - minValue) / (maxValue - minValue)
        return fromSliderFraction(fraction)
    }

    /// 从 Codex 当前界面可能显示的单个档位文案回读档位。
    public static func fromUILabel(_ label: String) -> Self? {
        let normalized = label.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let aliases: [(effort: Self, label: String)] = allCases.flatMap { effort in
            effort.uiLabels.map { candidate in
                (
                    effort,
                    candidate.lowercased()
                        .split(whereSeparator: \.isWhitespace)
                        .joined(separator: " ")
                )
            }
        }
        // 先匹配更长的档位名，避免“Extra high”被尾部的“high”提前吞掉。
        // 中文也必须要求档位前是分隔符，因此“高”不会命中“极高/最高”。
        let ordered = aliases.sorted { $0.label.count > $1.label.count }
        if let exact = ordered.first(where: { $0.label == normalized }) {
            return exact.effort
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "·•:：|/—-()（）[]【】")
        )
        for alias in ordered where normalized.hasSuffix(alias.label) {
            let prefix = normalized.dropLast(alias.label.count)
            guard let last = prefix.unicodeScalars.last,
                  separators.contains(last) else { continue }
            return alias.effort
        }
        return nil
    }
}

/// 从 Codex 模型按钮回读的可见状态。
public struct CodexExecutionSelection: Sendable, Equatable {
    public let visibleTitle: String
    /// 某些 Codex 版本把思考程度作为 AXSlider 的数值暴露，模型按钮标题
    /// 只包含模型名；驱动会把滑块值离散化后填入这里。
    public let reasoningEffort: CodexReasoningEffort?

    public init(
        visibleTitle: String,
        reasoningEffort: CodexReasoningEffort? = nil
    ) {
        self.visibleTitle = visibleTitle
        self.reasoningEffort = reasoningEffort
    }

    public func matches(_ preference: CodexExecutionPreference) -> Bool {
        let normalized = Self.normalize(visibleTitle)
        let model = Self.normalize(preference.modelDisplayName)
        guard normalized.hasPrefix(model) else {
            return false
        }
        if let reasoningEffort {
            return reasoningEffort == preference.reasoningEffort
        }
        let effortText = String(normalized.dropFirst(model.count))
        return CodexReasoningEffort.fromUILabel(effortText)
            == preference.reasoningEffort
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

/// 用户手动绑定的一个"已存在的 Codex 长任务线程"。
///
/// ## ★ 这个模型里不存在任何认证信息 ★
///
/// 没有 email、没有 password、没有 cookie、没有 session token、
/// 没有 authentication storage。存的全是"如何在自己的 UI 里重新找到那个线程"
/// 的可重建定位信息。
///
/// 之所以强调这点: 程序要能在用户**自己**完成登录之后接着干活,
/// 但它永远不需要、也不应该知道"当前是哪个账号"。
public struct CodexTaskBinding: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    /// 关联的 AIRunner 任务。可为空 —— 允许先绑定再建任务。
    public var taskID: String?

    /// 线程标题 (UI 上可见的那个)。
    public var displayTitle: String
    public var projectName: String?
    public var repositoryPath: String?
    public var worktreePath: String?

    /// 目标 App 的 bundle id —— **绑定那一刻从真实 App 读取**, 不硬编码。
    public var applicationBundleIdentifier: String
    public var applicationName: String?
    public var windowTitleHint: String?

    /// 该绑定使用的 Chrome Profile 目录名 (如 "Default" / "Profile 1")。
    ///
    /// ## 为什么用它实现"自动切换账号"
    ///
    /// 每个 Chrome Profile 是**独立的登录环境**。用户在每个 profile 里手动登录一次后,
    /// session 长期有效。切换账号 = 用另一个 profile 打开 ChatGPT ——
    /// **不读密码、不读 Cookie、不碰 token**, 只调用 Chrome 自己的 `--profile-directory`。
    public var chromeProfileDirectory: String?

    /// 重新识别同一线程所需的信号集合。
    public var fingerprint: CodexTaskFingerprint

    /// 自动恢复时发送的内容。默认「继续」。
    public var resumeMessage: String

    /// 发送提示词前要在 Codex UI 中设置并回读确认的模型配置。
    /// nil 表示沿用当前 Codex 设置，兼容旧绑定。
    public var executionPreference: CodexExecutionPreference?

    public var lastVerifiedAt: Date?
    public var lastResumeSentAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        taskID: String? = nil,
        displayTitle: String,
        projectName: String? = nil,
        repositoryPath: String? = nil,
        worktreePath: String? = nil,
        applicationBundleIdentifier: String,
        applicationName: String? = nil,
        windowTitleHint: String? = nil,
        chromeProfileDirectory: String? = nil,
        fingerprint: CodexTaskFingerprint,
        resumeMessage: String = "继续",
        executionPreference: CodexExecutionPreference? = nil,
        lastVerifiedAt: Date? = nil,
        lastResumeSentAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.displayTitle = displayTitle
        self.projectName = projectName
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationName = applicationName
        self.windowTitleHint = windowTitleHint
        self.chromeProfileDirectory = chromeProfileDirectory
        self.fingerprint = fingerprint
        self.resumeMessage = resumeMessage
        self.executionPreference = executionPreference
        self.lastVerifiedAt = lastVerifiedAt
        self.lastResumeSentAt = lastResumeSentAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 距离上次发送是否已经超过冷却期。
    public func isCoolingDown(cooldown: TimeInterval, at now: Date = Date()) -> Bool {
        guard let last = lastResumeSentAt else { return false }
        return now.timeIntervalSince(last) < cooldown
    }

    /// 冷却剩余时间。返回 nil 表示不在冷却中。
    public func cooldownRemaining(cooldown: TimeInterval, at now: Date = Date()) -> TimeInterval? {
        guard let last = lastResumeSentAt else { return nil }
        let remaining = cooldown - now.timeIntervalSince(last)
        return remaining > 0 ? remaining : nil
    }

    public var displayTarget: String {
        applicationName ?? applicationBundleIdentifier
    }
}

/// 用于**重新识别同一个线程**的信号集合。
///
/// ## 两条硬规则
///
/// 1. **拿不到就不填。** 绝不用猜测值或占位值填充 ——
///    一个假信号会让匹配错误地"成功", 而错误地把消息发给别的线程是本项目
///    最不可接受的失败模式。
/// 2. **匹配分档。** `exact` / `strong` / `weak` 三档, 只有唯一且非 weak 的匹配
///    才允许自动发送; 其余一律 fail closed。
public struct CodexTaskFingerprint: Codable, Sendable, Equatable, Hashable {

    /// 线程标题 —— 最可靠的单一信号。
    public var threadTitle: String?
    /// 项目 / 工作区名称。
    public var projectName: String?
    public var repositoryPath: String?
    public var worktreePath: String?
    /// 目标 App bundle id。
    public var applicationBundleIdentifier: String?
    /// 辅助信号: 会话开头的一段摘要 (仅当 UI 上确实能读到才填)。
    public var conversationPreview: String?

    public init(
        threadTitle: String? = nil,
        projectName: String? = nil,
        repositoryPath: String? = nil,
        worktreePath: String? = nil,
        applicationBundleIdentifier: String? = nil,
        conversationPreview: String? = nil
    ) {
        self.threadTitle = threadTitle
        self.projectName = projectName
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.conversationPreview = conversationPreview
    }

    /// 主信号 (标题) 是否可用。
    public var hasPrimarySignal: Bool {
        !(threadTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 除标题外的辅助信号数量。
    public var secondarySignalCount: Int {
        secondarySignals.count
    }

    /// 辅助信号键值对 (非空项)。
    public var secondarySignals: [(key: String, value: String)] {
        var result: [(String, String)] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            result.append((key, value))
        }
        add("projectName", projectName)
        add("repositoryPath", repositoryPath)
        add("worktreePath", worktreePath)
        add("applicationBundleIdentifier", applicationBundleIdentifier)
        add("conversationPreview", conversationPreview)
        return result
    }

    /// 是否具备足以做自动发送判定的信号。
    ///
    /// 只有标题是不够的 —— 标题相同的线程完全可能存在两个。
    /// 因此要求至少 1 个辅助信号, 否则即使匹配上也只能算 weak。
    public var isSufficientForAutoResume: Bool {
        hasPrimarySignal && secondarySignalCount >= 1
    }

    public var summary: String {
        var parts: [String] = []
        if let threadTitle, !threadTitle.isEmpty { parts.append("title=\(threadTitle)") }
        for signal in secondarySignals { parts.append("\(signal.key)=\(signal.value)") }
        return parts.isEmpty ? "(无信号)" : parts.joined(separator: " · ")
    }
}

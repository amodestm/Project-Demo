import Foundation
import ApplicationServices
import AppKit

/// 驱动的可调参数 —— 全部是**候选集合**, 不是"唯一正确值"。
///
/// 之所以做成列表: Codex 的 UI 会变, 而且它可能在 ChatGPT 桌面版里。
/// 硬编码一个 role 或一句 label, 一旦 UI 改版就整体失效;
/// 而"按顺序尝试候选 + 找不到就 fail closed"的设计, 至少不会**误操作**。
public struct CodexDriverConfiguration: Sendable, Equatable {

    /// 可能承载线程列表的容器 role。
    public var threadContainerRoles: [String] = [
        "AXOutline", "AXList", "AXTable", "AXScrollArea", "AXSplitGroup"
    ]

    /// 可能表示"一条线程"的 role。
    public var threadRowRoles: [String] = [
        "AXRow", "AXCell", "AXButton", "AXStaticText", "AXGroup", "AXLink"
    ]

    /// composer 的候选 role。
    public var composerRoles: [String] = [
        "AXTextArea", "AXTextField", "AXComboBox"
    ]

    /// 明确要**排除**的 text 控件 —— 侧边栏搜索 / 项目搜索 / 命令面板。
    public var composerExcludedIdentifierHints: [String] = [
        "search", "Search", "palette", "Palette", "filter", "Filter", "find", "Find"
    ]

    /// Composer 的稳定占位/描述文案，用于在多个 AXTextArea 中选出真正的
    /// ChatGPT 输入框。不同语言版本至少会命中其中一个。
    public var composerIdentityHints: [String] = [
        "随心输入", "开始输入", "输入消息", "输入内容", "问我任何问题",
        "ask anything", "message chatgpt", "send a message"
    ]

    /// 发送控件的候选文案 (多语言)。
    public var sendControlLabels: [String] = [
        // ChatGPT 的中文网页目前常把无障碍 label 写成“发送提示/发送消息”，
        // 视觉上仍只是右下角的向上箭头。保留短标签以兼容旧版，同时加入
        // 完整文案，避免 locateSendControl 只能看到箭头却找不到动作。
        "Send", "Send message", "Send prompt", "Submit",
        "发送", "发送消息", "发送提示", "发送讯息", "提交",
        "送出", "送信", "送出訊息", "Senden", "Envoyer", "Enviar"
    ]

    /// 发送控件的候选 identifier。
    public var sendControlIdentifierHints: [String] = [
        "send", "Send", "composer-send", "send-button", "submit"
    ]

    /// 表明"正在生成"的文案。
    public var busyIndicators: [String] = [
        "Stop", "停止", "Cancel", "取消", "Generating", "生成中", "正在生成", "Pause", "暫停"
    ]

    /// 只有这些稳定语义才会触发账号轮换；普通“停止”按钮不在其中。
    public var quotaIssueHints: [String] = [
        "usage limit", "usage limits", "rate limit", "quota exceeded",
        "out of credits", "credits exhausted", "limit reached", "you've hit your limit",
        "monthly limit", "daily limit", "too many requests",
        "额度不足", "额度已用尽", "额度耗尽", "达到使用上限", "用量上限",
        "超出限额", "请求过多",
        // ChatGPT 的额度横幅常把“达到使用上限”放在富文本 AXValue 中，
        // 并且在不同版本改写成“升级套餐或充值额度以继续”。保留这段
        // 稳定语义，兼容带“某日期后重试”的完整提示。
        "升级套餐或充值额度以继续", "upgrade your plan to continue",
    ]

    public var authenticationIssueHints: [String] = [
        "session expired", "登录已过期", "会话已过期", "重新登录",
        "authentication required", "sign in to continue", "log in to continue",
    ]

    public var stoppedIssueHints: [String] = [
        "task stopped", "execution stopped", "generation stopped",
        "任务已停止", "执行已停止", "生成已停止",
    ]

    /// 只检查当前窗口 AX 文本序列的最后一小段。旧对话里的额度报错不能再次
    /// 触发轮换；真正触发信号必须出现在最新输出附近。
    public var accountIssueTailLimit: Int = 16

    /// 单次 AX 遍历的节点预算。
    public var traversalNodeBudget: Int = 20_000
    /// 单次 AX 遍历的深度上限。
    /// Codex 152 的正文控件位于窗口树约 25-30 层，低于这个深度只能看到菜单和外壳。
    public var traversalMaxDepth: Int = 40

    /// 模型菜单是网页弹层；点击后按语义轮询，等待动画和异步加载完成。
    public var modelMenuTimeout: TimeInterval = 8

    /// 思考程度滑杆是异步弹层；点击离散点后允许网页完成状态回写的时间。
    public var reasoningSelectionTimeout: TimeInterval = 8

    /// Composer 的 AXValue/粘贴操作完成后，等待实际文本回读的时间。
    public var composerInputTimeout: TimeInterval = 4

    /// 剪贴板和 AXValue 都没有触发网页 input 事件时，逐字符键入的间隔。
    /// 这是最后的真实键盘事件后备路径；正常情况下不会执行。
    public var composerTypingInterval: Duration = .milliseconds(8)

    /// 逐字符后备输入的最长验证时间。长提示词会按字符数动态延长，仍受
    /// 该上限约束，避免异常页面让 Resume 无限等待。
    public var composerTypingTimeout: TimeInterval = 45

    /// 发送箭头在输入事件后才出现时，允许重新扫描 AX 树的时间。
    public var sendControlTimeout: TimeInterval = 4

    /// 发送后观察 Composer 清空或消息提交的最长时间。
    public var sendConfirmationTimeout: TimeInterval = 5

    /// 打开对话后 Electron 可能先保留旧页面树，再异步刷新主会话标题。
    /// 标题读取在这段时间内只读重试，不输入、不点击、不发送。
    public var threadContextTimeout: TimeInterval = 10

    /// 登录后偶发出现的模型介绍弹窗。必须同时命中介绍语义和操作语义，
    /// 才允许在同一容器内寻找右上角关闭按钮。
    public var welcomeOverlayIntroHints: [String] = [
        "简介", "introducing", "introduction",
    ]
    public var welcomeOverlayActionHints: [String] = [
        "继续使用当前模型", "立即试用", "continue with current model", "try gpt-",
    ]
    public var welcomeOverlayCloseLabels: [String] = [
        "关闭", "close", "dismiss",
    ]

    public init() {}
    public static let `default` = CodexDriverConfiguration()
}

/// 基于 macOS Accessibility API 的真实驱动。
///
/// ## ★ 绝不使用固定屏幕坐标 ★
///
/// 所有元素定位都通过 AX 属性遍历完成。没有固定屏幕坐标、OCR 或截图模板匹配；
/// Electron 对 AXPress 不响应时，只使用目标元素此刻的 AXFrame 中心补发一次鼠标点击。
///
/// ## ★ 拿不到就报拿不到 ★
///
/// 任何一个环节不确定, 就抛对应的 `CodexAutomationError`, 让上层 fail closed。
/// 绝不返回"大概是的那个"。
///
/// ## 如果真实 UI 结构与预期不同
///
/// 用 `AXElementInspector` 导出脱敏后的 AX tree, 按真实结构调整
/// `CodexDriverConfiguration` 或本文件的遍历策略 —— **不要猜坐标**。
public struct CodexUIAutomationDriver: CodexUIAutomationDriving {

    /// 命令搜索候选不会持久化 AX 元素句柄；Controller 紧接着调用
    /// `openThread` 时用这个内部标记重新读取当前搜索结果。
    private static let commandSearchDebugMarker = "codex-command-search"

    private let configuration: CodexDriverConfiguration
    private let permission: AccessibilityPermissionManaging

    public init(
        configuration: CodexDriverConfiguration = .default,
        permission: AccessibilityPermissionManaging = AccessibilityPermissionManager()
    ) {
        self.configuration = configuration
        self.permission = permission
    }

    // MARK: - 权限

    public func checkAccessibilityPermission() async -> AccessibilityPermissionStatus {
        permission.currentStatus()
    }

    public func probeAvailability(bundleIdentifier: String) async -> CodexAvailabilityProbe {
        let granted = permission.currentStatus() == .granted
        guard granted else {
            return CodexAvailabilityProbe(
                applicationRunning: false, codexViewPresent: false, accessibilityGranted: false
            )
        }
        guard let app = Self.runningApplication(bundleIdentifier: bundleIdentifier) else {
            return CodexAvailabilityProbe(
                applicationRunning: false, codexViewPresent: false, accessibilityGranted: true
            )
        }
        // 只做最轻的检查: 是否存在可交互的窗口。不读取任何内容。
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let hasWindow = windowCount(of: element) > 0
        return CodexAvailabilityProbe(
            applicationRunning: true, codexViewPresent: hasWindow, accessibilityGranted: true
        )
    }

    // MARK: - 定位与激活

    public func locateApplication(bundleIdentifier: String) async throws -> CodexAppHandle {
        guard let app = Self.runningApplication(bundleIdentifier: bundleIdentifier) else {
            throw CodexAutomationError.applicationNotFound(bundleIdentifier)
        }
        return CodexAppHandle(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationName: app.localizedName
        )
    }

    public func activate(_ app: CodexAppHandle) async throws {
        guard let running = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            throw CodexAutomationError.applicationNotFound(app.bundleIdentifier)
        }
        // 绑定表单、额度监视器和 Resume 都可能从 AIRunner 后台触发；
        // 仅调用无参数 activate() 在 Electron 有隐藏窗口时不会把主窗口带回前台。
        // 先解除隐藏，再请求恢复全部窗口。这里不把返回值当作“页面已就绪”，
        // 真正的就绪状态仍由调用方随后读取 AX 窗口和标题确认。
        _ = running.unhide()
        _ = running.activate(options: [.activateAllWindows])
    }

    public func ensureCodexViewPresent(_ app: CodexAppHandle) async throws {
        // Codex/Electron 在切换前台或刚完成登录时，AXWindows 可能先返回空数组，
        // 随后才把真实 AXWindow 挂回应用树。这里等待同一个只读条件，避免把
        // 正在渲染的登录/主界面误报成“没有 Codex 视图”。
        let deadline = Date().addingTimeInterval(configuration.threadContextTimeout)
        repeat {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            if windowCount(of: element) > 0 { return }
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        throw CodexAutomationError.codexViewNotFound
    }

    public func dismissBlockingWelcomeOverlay(_ app: CodexAppHandle) async throws -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var matches: [(element: AXUIElement, frame: CGRect)] = []

        for surface in contentSurfaces(of: root) {
            var budget = configuration.traversalNodeBudget
            let containers = collectElements(
                in: surface,
                matching: ["AXDialog", "AXSheet", "AXGroup"],
                maxDepth: configuration.traversalMaxDepth,
                budget: &budget,
                containerRole: nil
            )
            for container in containers {
                let texts = allTexts(of: container, maxDepth: 12)
                guard Self.isBlockingWelcomeOverlay(
                    texts,
                    introHints: configuration.welcomeOverlayIntroHints,
                    actionHints: configuration.welcomeOverlayActionHints
                ), let frame = CodexLoginAutomator.frame(of: container),
                frame.width >= 260, frame.height >= 220 else { continue }
                if !matches.contains(where: { CFEqual($0.element, container) }) {
                    matches.append((container, frame))
                }
            }
        }

        // 多层 AXGroup 往往包含同一弹窗；最小的语义完整容器最接近弹窗本身。
        guard let overlay = matches.min(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { return false }

        var buttonBudget = configuration.traversalNodeBudget
        let buttons = collectElements(
            in: overlay.element,
            matching: ["AXButton"],
            maxDepth: 12,
            budget: &buttonBudget,
            containerRole: nil
        ).filter { bool($0, kAXEnabledAttribute) != false }

        let closeNeedles = Set(configuration.welcomeOverlayCloseLabels.map(normalized))
        let labeled = buttons.filter { button in
            [
                string(button, kAXTitleAttribute),
                textValue(button, kAXValueAttribute),
                string(button, kAXDescriptionAttribute),
                string(button, kAXIdentifierAttribute),
            ].compactMap { $0 }.map(normalized).contains(where: closeNeedles.contains)
        }
        let unlabeledTopRight = buttons.filter { button in
            guard string(button, kAXTitleAttribute) == nil,
                  textValue(button, kAXValueAttribute) == nil,
                  string(button, kAXDescriptionAttribute) == nil,
                  let frame = CodexLoginAutomator.frame(of: button),
                  frame.width >= 14, frame.width <= 64,
                  frame.height >= 14, frame.height <= 64 else { return false }
            return frame.midX >= overlay.frame.maxX - max(80, overlay.frame.width * 0.25)
                && frame.midY <= overlay.frame.minY + max(80, overlay.frame.height * 0.25)
        }
        let candidates = labeled.isEmpty ? unlabeledTopRight : labeled
        guard candidates.count == 1, let close = candidates.first else { return false }

        if supportsPress(close),
           AXUIElementPerformAction(close, kAXPressAction as CFString) == .success {
            try? await Task.sleep(for: .milliseconds(350))
            return true
        }
        guard CodexLoginAutomator.clickCenter(close) else { return false }
        try? await Task.sleep(for: .milliseconds(350))
        return true
    }

    static func isBlockingWelcomeOverlay(
        _ texts: [String],
        introHints: [String] = CodexDriverConfiguration.default.welcomeOverlayIntroHints,
        actionHints: [String] = CodexDriverConfiguration.default.welcomeOverlayActionHints
    ) -> Bool {
        let normalized = texts.map {
            $0.lowercased().split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        }
        func containsAny(_ hints: [String]) -> Bool {
            hints.contains { hint in
                let needle = hint.lowercased()
                    .split(whereSeparator: \Character.isWhitespace)
                    .joined(separator: " ")
                return normalized.contains { $0.contains(needle) }
            }
        }
        return containsAny(introHints) && containsAny(actionHints)
    }

    // MARK: - 找线程

    public func locateThreadCandidates(
        _ app: CodexAppHandle,
        fingerprint: CodexTaskFingerprint
    ) async throws -> [CodexThreadCandidate] {

        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surfaces = contentSurfaces(of: root)
        // 先按真实的导航语义取侧边栏列表。一个线程在 Chromium AX 树里通常
        // 是「AXList -> AXGroup(行) -> AXButton(标题)」，如果把所有后代 role
        // 都当成行，就会把同一线程暴露成 2~3 个候选；主区域标题按钮也会被
        // 混进来。这里只读取列表的直接子项，并且只接受导航/侧边栏分支。
        let sidebarRows = surfaces.flatMap { threadRowDescriptors(in: $0) }
        let uniqueSidebarRows = deduplicatedThreadRows(sidebarRows)
        if !uniqueSidebarRows.isEmpty {
            let visible = uniqueSidebarRows.map {
                CodexThreadCandidate(
                    title: $0.title,
                    projectName: $0.projectName,
                    repositoryPath: nil,
                    worktreePath: nil,
                    debugPath: nil
                )
            }
            if let expected = fingerprint.threadTitle,
               !visible.contains(where: { CodexTaskMatcher.equal($0.title, expected) }),
               let searched = try await commandSearchCandidates(
                   title: expected, in: app
               ) {
                return searched
            }
            return visible
        }

        // 旧版 Codex 有时没有 AXLandmarkNavigation 或 AXList 的直接子项。
        // 兼容性回退仍然遍历配置的 row roles，但会做可视行级去重，并排除
        // 主会话区，不能因为回退而重新引入同一线程的重复候选。
        let perSurfaceBudget = max(
            1, configuration.traversalNodeBudget / max(1, surfaces.count)
        )
        let fallback = surfaces.flatMap { surface -> [ThreadRowDescriptor] in
            var localBudget = perSurfaceBudget
            let rows = collectElements(
                in: surface, matching: configuration.threadRowRoles,
                maxDepth: configuration.traversalMaxDepth, budget: &localBudget,
                containerRole: nil
            ).filter { isInThreadSidebar($0, from: surface) }
            return rows.compactMap { makeThreadRowDescriptor(for: $0, in: surface) }
        }
        let visible = deduplicatedThreadRows(fallback).map {
            CodexThreadCandidate(
                title: $0.title,
                projectName: $0.projectName,
                repositoryPath: nil,
                worktreePath: nil,
                debugPath: nil
            )
        }
        if let expected = fingerprint.threadTitle,
           !visible.contains(where: { CodexTaskMatcher.equal($0.title, expected) }),
           let searched = try await commandSearchCandidates(title: expected, in: app) {
            return searched
        }
        return visible
    }

    public func openThread(_ candidate: CodexThreadCandidate, in app: CodexAppHandle) async throws {
        if candidate.debugPath == Self.commandSearchDebugMarker {
            try await openCommandSearchResult(candidate, in: app)
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let descriptors = contentSurfaces(of: root).flatMap {
            threadRowDescriptors(in: $0)
        }
        let matches = descriptors.filter {
            CodexTaskMatcher.equal($0.title, candidate.title)
                && secondarySignalsMatch($0, candidate)
        }
        guard matches.count == 1, let descriptor = matches.first else {
            if matches.isEmpty {
                throw CodexAutomationError.targetTaskNotFound
            }
            throw CodexAutomationError.targetVerificationFailed(
                "侧边栏中仍有多个同名线程，无法安全点击"
            )
        }

        // 优先对整行执行 AXPress/坐标点击。部分 Codex 版本把标题按钮的
        // AXPress 绑定到当前焦点，而不是该行；直接点行的几何中心才会
        // 真正触发导航。标题子控件仅作为兼容回退。
        let targets: [(element: AXUIElement, directRow: Bool)] =
            [(descriptor.row, true), (descriptor.actionable, false)].compactMap { item in
                guard let element = item.0 else { return nil }
                return (element, item.1)
            }
        var didClick = false
        for target in targets {
            let actionable: AXUIElement?
            if target.directRow {
                actionable = supportsPress(target.element) ? target.element : nil
            } else {
                actionable = actionableAncestor(of: target.element)
                    ?? (supportsPress(target.element) ? target.element : nil)
            }
            guard let actionable else {
                if target.directRow, CodexLoginAutomator.clickCenter(target.element) {
                    didClick = true
                }
                continue
            }
            let status = AXUIElementPerformAction(actionable, kAXPressAction as CFString)
            if status != .success {
                guard CodexLoginAutomator.clickCenter(target.directRow ? target.element : actionable) else { continue }
            }
            didClick = true
            try? await Task.sleep(for: .milliseconds(900))
            if let context = try? await readOpenThreadContext(app),
               contextTitleMatches(context.threadTitle, candidate.title) {
                break
            }
        }
        guard didClick else {
            throw CodexAutomationError.targetTaskNotFound
        }
        // 给 Electron 额外的渲染时间；上层会继续以 250ms 间隔做最终二次验证。
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// 侧栏只挂载当前可见的一小段会话。标题不在其中时，使用 Codex 自己的
    /// 命令搜索查找完整会话列表。搜索框和结果均由实时 AX 语义定位；AXPress
    /// 没有真正打开 Electron 弹层时，才在该控件当前 AXFrame 中心补一次点击。
    private func commandSearchCandidates(
        title: String,
        in app: CodexAppHandle
    ) async throws -> [CodexThreadCandidate]? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var input = commandSearchInput(in: root)
        if input == nil {
            guard let search = uniqueCommandSearchButton(in: root) else {
                return nil
            }
            _ = AXUIElementPerformAction(search, kAXPressAction as CFString)
            input = await waitForCommandSearchInput(in: app, timeout: 0.8)
            if input == nil {
                guard CodexLoginAutomator.clickCenter(search) else { return nil }
                input = await waitForCommandSearchInput(in: app, timeout: 3)
            }
        }
        guard let input else { return nil }

        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard await replaceCommandSearchText(query, input: input, in: app) else {
            Self.postEscape(to: app.processIdentifier)
            throw CodexAutomationError.targetVerificationFailed(
                "Codex 命令搜索框未接收到绑定标题"
            )
        }

        let deadline = Date().addingTimeInterval(5)
        repeat {
            let currentRoot = AXUIElementCreateApplication(app.processIdentifier)
            let matches = commandSearchResultActions(title: query, in: currentRoot)
            if !matches.isEmpty {
                return matches.map { result in
                    CodexThreadCandidate(
                        title: query,
                        projectName: commandSearchProjectName(
                            in: result, excluding: query
                        ),
                        repositoryPath: nil,
                        worktreePath: nil,
                        debugPath: Self.commandSearchDebugMarker
                    )
                }
            }
            if commandSearchHasNoResults(in: currentRoot) {
                Self.postEscape(to: app.processIdentifier)
                return []
            }
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline

        Self.postEscape(to: app.processIdentifier)
        return []
    }

    /// 打开前重新从当前命令菜单读取唯一结果，避免保存瞬态 AX 句柄，也避免
    /// 搜索结果在页面异步刷新后点击到别的行。
    private func openCommandSearchResult(
        _ candidate: CodexThreadCandidate,
        in app: CodexAppHandle
    ) async throws {
        var root = AXUIElementCreateApplication(app.processIdentifier)
        var matches = commandSearchResultActions(title: candidate.title, in: root)
        if matches.isEmpty {
            guard let refreshed = try await commandSearchCandidates(
                title: candidate.title, in: app
            ), !refreshed.isEmpty else {
                throw CodexAutomationError.targetTaskNotFound
            }
            root = AXUIElementCreateApplication(app.processIdentifier)
            matches = commandSearchResultActions(title: candidate.title, in: root)
        }

        if let expectedProject = candidate.projectName {
            let projectMatches = matches.filter {
                guard let actual = commandSearchProjectName(
                    in: $0, excluding: candidate.title
                ) else { return false }
                return CodexTaskMatcher.equal(actual, expectedProject)
            }
            if !projectMatches.isEmpty { matches = projectMatches }
        }
        let unique = deduplicateByFrame(matches)
        guard unique.count == 1, let result = unique.first else {
            Self.postEscape(to: app.processIdentifier)
            if unique.isEmpty { throw CodexAutomationError.targetTaskNotFound }
            throw CodexAutomationError.ambiguousTarget(count: unique.count)
        }

        let status = AXUIElementPerformAction(result, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(450))
        // Chromium 有时对搜索结果返回 AXPress 成功，但页面没有消费动作。
        // 只有命令菜单仍存在时才对同一结果的实时边框补点，避免双重导航。
        let menuStillOpen = commandSearchInput(
            in: AXUIElementCreateApplication(app.processIdentifier)
        ) != nil
        if menuStillOpen {
            guard CodexLoginAutomator.clickCenter(result) else {
                Self.postEscape(to: app.processIdentifier)
                throw CodexAutomationError.targetVerificationFailed(
                    "Codex 命令搜索结果无法点击 (AXError=\(status.rawValue))"
                )
            }
        }
        try? await Task.sleep(for: .milliseconds(1_150))
    }

    private func uniqueCommandSearchButton(in root: AXUIElement) -> AXUIElement? {
        var budget = configuration.traversalNodeBudget
        let buttons = collectElements(
            in: root, matching: ["AXButton"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget, containerRole: nil
        ).filter { button in
            let labels = [
                string(button, kAXTitleAttribute),
                string(button, kAXDescriptionAttribute),
            ].compactMap { $0 }.map(normalized)
            return labels.contains("搜索") || labels.contains("search")
        }
        let unique = deduplicateByFrame(buttons)
        guard unique.count == 1 else { return nil }
        return unique[0]
    }

    private func commandSearchInput(in root: AXUIElement) -> AXUIElement? {
        var budget = configuration.traversalNodeBudget
        let inputs = collectElements(
            in: root, matching: ["AXComboBox", "AXSearchField"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget, containerRole: nil
        ).filter { isInsideCommandMenu($0, from: root) }
        let unique = deduplicateByFrame(inputs)
        guard unique.count == 1 else { return nil }
        return unique[0]
    }

    private func waitForCommandSearchInput(
        in app: CodexAppHandle,
        timeout: TimeInterval
    ) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let input = commandSearchInput(in: root) { return input }
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return nil
    }

    private func replaceCommandSearchText(
        _ text: String,
        input: AXUIElement,
        in app: CodexAppHandle
    ) async -> Bool {
        _ = AXUIElementSetAttributeValue(
            input, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        _ = CodexLoginAutomator.clickCenter(input)
        await CodexLoginAutomator.clearField(input, pid: app.processIdentifier)

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            if let previous { pasteboard.setString(previous, forType: .string) }
            return false
        }
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }

        if Self.postPaste(to: app.processIdentifier),
           await waitForCommandSearchText(text, in: app) {
            return true
        }
        // AXValue 是辅助回退。成功仍需回读，不能把 API 返回值当作网页已接收。
        _ = AXUIElementSetAttributeValue(
            input, kAXValueAttribute as CFString, text as CFTypeRef
        )
        return await waitForCommandSearchText(text, in: app)
    }

    private func waitForCommandSearchText(
        _ expected: String,
        in app: CodexAppHandle
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let input = commandSearchInput(in: root),
               let value = textValue(input, kAXValueAttribute),
               CodexTaskMatcher.equal(value, expected) {
                return true
            }
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    private func commandSearchResultActions(
        title: String,
        in root: AXUIElement
    ) -> [AXUIElement] {
        var budget = configuration.traversalNodeBudget
        let nodes = collectElements(
            in: root,
            matching: ["AXStaticText", "AXButton", "AXLink", "AXHeading"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget, containerRole: nil
        )
        var results: [AXUIElement] = []
        for node in nodes where isInsideCommandMenu(node, from: root) {
            let texts = [
                string(node, kAXTitleAttribute),
                textValue(node, kAXValueAttribute),
                string(node, kAXDescriptionAttribute),
            ].compactMap { $0 }
            guard texts.contains(where: { CodexTaskMatcher.equal($0, title) }),
                  let actionable = actionableAncestor(of: node),
                  isInsideCommandMenu(actionable, from: root) else { continue }
            if !results.contains(where: { CFEqual($0, actionable) }) {
                results.append(actionable)
            }
        }
        return deduplicateByFrame(results)
    }

    private func commandSearchProjectName(
        in result: AXUIElement,
        excluding title: String
    ) -> String? {
        let values = allTexts(of: result, maxDepth: 5).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values.first { value in
            guard !value.isEmpty,
                  !CodexTaskMatcher.equal(value, title) else { return false }
            let normalizedValue = normalized(value)
            let normalizedTitle = normalized(title)
            return normalizedValue != "命令菜单"
                && normalizedValue != "command menu"
                && !normalizedValue.contains(normalizedTitle)
                && !normalizedValue.hasPrefix("⌘")
        }
    }

    private func commandSearchHasNoResults(in root: AXUIElement) -> Bool {
        var budget = configuration.traversalNodeBudget
        return collectElements(
            in: root, matching: ["AXStaticText"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget, containerRole: nil
        ).contains { node in
            guard isInsideCommandMenu(node, from: root) else { return false }
            let texts = [
                string(node, kAXTitleAttribute),
                textValue(node, kAXValueAttribute),
                string(node, kAXDescriptionAttribute),
            ].compactMap { $0 }.map(normalized)
            return texts.contains("无匹配项")
                || texts.contains("no matches")
                || texts.contains("no results")
        }
    }

    private func isInsideCommandMenu(
        _ element: AXUIElement,
        from root: AXUIElement
    ) -> Bool {
        var current = element
        for _ in 0..<configuration.traversalMaxDepth {
            let labels = [
                string(current, kAXTitleAttribute),
                string(current, kAXDescriptionAttribute),
            ].compactMap { $0 }.map(normalized)
            if labels.contains("命令菜单") || labels.contains("command menu") {
                return true
            }
            if CFEqual(current, root) { break }
            guard let next = parent(of: current) else { break }
            current = next
        }
        return false
    }

    private func contextTitleMatches(_ actual: String?, _ expected: String) -> Bool {
        guard let actual else { return false }
        let lhs = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if CodexTaskMatcher.equal(lhs, rhs) { return true }
        guard let range = lhs.range(of: #"\s+\(\d+\)$"#, options: .regularExpression) else {
            return false
        }
        return CodexTaskMatcher.equal(String(lhs[..<range.lowerBound]), rhs)
    }

    public func readOpenThreadContext(_ app: CodexAppHandle) async throws -> CodexOpenThreadContext {
        let deadline = Date().addingTimeInterval(configuration.threadContextTimeout)
        var lastContext = CodexOpenThreadContext(
            applicationBundleIdentifier: app.bundleIdentifier
        )
        repeat {
            lastContext = readOpenThreadContextSnapshot(app)
            if lastContext.threadTitle != nil {
                return lastContext
            }
            if Date() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        return lastContext
    }

    /// 单次无副作用读取。外层负责在页面异步加载期间重试；单独保留这个
    /// 快照函数，避免每一轮重复等待，并让“读取当前对话”和“打开后验证”
    /// 使用完全相同的识别逻辑。
    private func readOpenThreadContextSnapshot(
        _ app: CodexAppHandle
    ) -> CodexOpenThreadContext {
        // Electron 的 AXWebArea.title 通常只是“ChatGPT”，不是当前对话名称。
        // 真正的工作对话标题同时出现在主区域顶部的标题按钮和左侧列表中；
        // 先沿着模型选择器所在的主区域分支取顶部按钮，避免把侧边栏项目、
        // 页面标题或正文第一行误当成线程标题。
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surfaces = contentSurfaces(of: root)
        for surface in surfaces {
            if let title = threadHeaderTitle(in: surface) {
                return CodexOpenThreadContext(
                    threadTitle: title,
                    applicationBundleIdentifier: app.bundleIdentifier
                )
            }
        }

        // 不再退回 AXWebArea.title。当前 Codex 的 WebArea 标题不具备线程身份，
        // 页面恢复或滚动时可能短暂暴露正文控件名称。主导航标题缺失就返回 nil，
        // 让外层继续等待并最终 fail closed，不能拿正文按钮凑一个“标题”。
        return CodexOpenThreadContext(
            applicationBundleIdentifier: app.bundleIdentifier
        )
    }

    // MARK: - 忙碌检测

    public func detectBusyState(_ app: CodexAppHandle) async throws -> CodexBusyState {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surface = focusedWindow(of: root) ?? root
        let texts = Set(allTexts(of: surface, maxDepth: configuration.traversalMaxDepth))

        for indicator in configuration.busyIndicators {
            if texts.contains(indicator) { return .generating }
        }
        // 没有 Stop/Generating，且能找到可编辑的真实 composer，说明当前线程
        // 已经可以接受新输入。搜索框等控件由 locateComposer 的排除规则过滤。
        if let composer = try? await locateComposer(app), composer.isEditable {
            return .idle
        }
        // 读不到明确信号 —— 按"不确定"处理, 上层会拒绝发送。
        return .unknown
    }

    public func detectAnyTaskGenerating(_ app: CodexAppHandle) async throws -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surfaces = windows(of: root)
        let generationIndicators: Set<String> = [
            "Stop", "停止", "Generating", "生成中", "正在生成", "Pause", "暫停",
        ]
        let targets = surfaces.isEmpty ? [root] : surfaces
        return targets.contains { surface in
            let texts = Set(allTexts(
                of: surface,
                maxDepth: configuration.traversalMaxDepth
            ))
            return !texts.isDisjoint(with: generationIndicators)
        }
    }

    public func detectTaskStopped(_ app: CodexAppHandle) async throws -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surface = focusedWindow(of: root) ?? root
        let texts = Self.latestIssueTexts(allTexts(
            of: surface,
            maxDepth: configuration.traversalMaxDepth
        ), configuration: configuration)
        let normalized = texts.map(Self.normalizeIssueText)
        return configuration.stoppedIssueHints.contains { hint in
            let needle = Self.normalizeIssueText(hint)
            return normalized.contains { $0.contains(needle) }
        }
    }

    public func detectAccountIssue(_ app: CodexAppHandle) async throws -> CodexAccountIssue? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surface = focusedWindow(of: root) ?? root
        let texts = allTexts(of: surface, maxDepth: configuration.traversalMaxDepth)
        return Self.classifyLatestAccountIssue(texts, configuration: configuration)
    }

    static func classifyLatestAccountIssue(
        _ texts: [String],
        configuration: CodexDriverConfiguration = .default
    ) -> CodexAccountIssue? {
        classifyAccountIssue(
            latestIssueTexts(texts, configuration: configuration),
            configuration: configuration
        )
    }

    private static func latestIssueTexts(
        _ texts: [String], configuration: CodexDriverConfiguration
    ) -> [String] {
        let meaningful = texts.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var latest = Array(meaningful.suffix(max(1, configuration.accountIssueTailLimit)))

        // 额度横幅通常位于正文顶部，而 Electron 会把 Composer、工具栏和
        // 辅助控件追加到 AX 文本序列末尾，单纯取最后 16 项会漏掉它。只有
        // 同时包含“升级/充值”和“重试”语义的完整横幅才从尾部窗口外补回，
        // 避免把旧对话里孤立的一句“使用上限”重新当成当前信号。
        let currentQuotaBanner = meaningful.filter { text in
            let normalized = normalizeIssueText(text)
            let upgrade = normalized.contains("升级套餐或充值额度以继续")
                || normalized.contains("upgrade your plan to continue")
                || normalized.contains("upgrade your plan")
            let retry = normalized.contains("后重试")
                || normalized.contains("稍后再试")
                || normalized.contains("try again")
                || normalized.contains("retry")
            return upgrade && retry
        }
        for banner in currentQuotaBanner where !latest.contains(banner) {
            latest.append(banner)
        }
        return latest
    }

    /// 纯函数便于在没有真实 Codex 窗口的测试里锁住 fail-closed 规则。
    static func classifyAccountIssue(
        _ texts: [String],
        configuration: CodexDriverConfiguration = .default
    ) -> CodexAccountIssue? {
        let normalized = texts.map { normalizeIssueText($0) }
        func containsAny(_ hints: [String]) -> Bool {
            hints.contains { hint in
                let needle = normalizeIssueText(hint)
                return normalized.contains { $0.contains(needle) }
            }
        }

        if containsAny(configuration.quotaIssueHints) { return .quotaExhausted }
        if containsAny(configuration.authenticationIssueHints) {
            return .authenticationRequired
        }
        if containsAny(configuration.stoppedIssueHints) { return .taskStopped }
        return nil
    }

    private static func normalizeIssueText(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: - 模型与思考程度

    public func readExecutionSelection(
        _ app: CodexAppHandle
    ) async throws -> CodexExecutionSelection {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surfaces = contentSurfaces(of: root)
        let focused = focusedWindow(of: root)
        let focusedPickers = focused.map(modelPickers(in:)) ?? []
        let picker: AXUIElement
        if focusedPickers.count == 1, let first = focusedPickers.first {
            picker = first
        } else {
            let allPickers = deduplicateByFrame(
                surfaces.flatMap { modelPickers(in: $0) }
            )
            guard allPickers.count == 1, let first = allPickers.first else {
                throw CodexAutomationError.modelControlNotFound
            }
            picker = first
        }
        guard let title = string(picker, kAXTitleAttribute) else {
            throw CodexAutomationError.modelControlNotFound
        }

        // 弹层打开时滑杆可能挂在另一个 AXWindow；按当前焦点优先、其余窗口
        // 回退的顺序读取，并在滑杆不可见时尝试读取“选择强度”控件的文案。
        var effort: CodexReasoningEffort?
        for surface in surfaces {
            if let value = reasoningEffortFromSlider(in: surface, picker: picker) {
                effort = value
                break
            }
        }
        if effort == nil {
            effort = visibleReasoningEffort(in: surfaces, picker: picker)
        }
        return CodexExecutionSelection(
            visibleTitle: title,
            reasoningEffort: effort
        )
    }

    public func applyExecutionPreference(
        _ preference: CodexExecutionPreference,
        in app: CodexAppHandle
    ) async throws -> CodexExecutionSelection {
        var current = try await readExecutionSelection(app)
        if current.matches(preference) { return current }

        let modelName = preference.modelDisplayName
        if !normalized(current.visibleTitle).contains(normalized(modelName)) {
            try await openModelPicker(in: app)
            do {
                try await openModelSubmenu(in: app, expectedModel: modelName)
                try await pressUniqueMenuOption(
                    labels: [modelName], missing: .modelOptionNotFound(modelName), in: app
                )
            } catch {
                Self.postEscape(to: app.processIdentifier)
                throw error
            }
            guard let selected = try await waitForSelection(in: app, matching: {
                self.normalized($0.visibleTitle).contains(self.normalized(modelName))
            }) else {
                Self.postEscape(to: app.processIdentifier)
                let actual = try? await readExecutionSelection(app).visibleTitle
                throw CodexAutomationError.modelSelectionFailed(
                    expected: preference.displayName, actual: actual
                )
            }
            current = selected
            Self.postEscape(to: app.processIdentifier)
        }

        if !current.matches(preference) {
            do {
                // 新版 Codex 的思考程度入口是独立的“选择强度”弹层，
                // 先走六点滑杆路径，避免把模型按钮再次点击成关闭动作。
                try await setReasoningSlider(preference.reasoningEffort, in: app)
            } catch {
                // 旧版仍可能把思考程度暴露为语义菜单；滑杆路径失败后才
                // 回退到旧菜单，并在两条路径都要求最终回读确认。
                Self.postEscape(to: app.processIdentifier)
                try await openModelPicker(in: app)
                try await openReasoningSubmenu(in: app, expected: preference.reasoningEffort)
                try await pressUniqueMenuOption(
                    labels: preference.reasoningEffort.uiLabels,
                    missing: .reasoningOptionNotFound(preference.reasoningEffort.displayName),
                    in: app
                )
            }
            guard let selected = try await waitForSelection(
                in: app, matching: { $0.matches(preference) }
            ) else {
                Self.postEscape(to: app.processIdentifier)
                let actual = try? await readExecutionSelection(app).visibleTitle
                throw CodexAutomationError.modelSelectionFailed(
                    expected: preference.displayName, actual: actual
                )
            }
            current = selected
            Self.postEscape(to: app.processIdentifier)
        }

        guard current.matches(preference) else {
            throw CodexAutomationError.modelSelectionFailed(
                expected: preference.displayName, actual: current.visibleTitle
            )
        }
        return current
    }

    private func openModelPicker(in app: CodexAppHandle) async throws {
        guard let running = NSRunningApplication(processIdentifier: app.processIdentifier),
              !running.isTerminated else {
            throw CodexAutomationError.applicationNotFound(app.bundleIdentifier)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surface = focusedWindow(of: root) ?? root
        let pickers = modelPickers(in: surface)
        guard pickers.count == 1 else {
            throw CodexAutomationError.modelControlNotFound
        }

        // 先把 Codex 窗口提升到前台。Electron 对 AXPress 的返回值并不可靠，
        // 仅凭 status == success 不能证明网页菜单真的展开。
        _ = running.activate(options: [.activateAllWindows])

        // 如果上一次动作留下了同一个“模型”菜单，直接复用已出现的语义节点，
        // 避免再点一次把菜单关闭。这里不能把“选择强度”作为模型菜单标记：
        // 新版 Codex 在菜单关闭时也会一直显示独立的“选择强度”入口，若把它
        // 当成弹层标记，模型菜单实际上没有打开却会被误判为已打开。
        if !menuMarkers(in: app, labels: ["选择模型", "Select model"]).isEmpty {
            return
        }

        let status = AXUIElementPerformAction(pickers[0], kAXPressAction as CFString)
        if await waitForMenuMarkers(
            in: app,
            labels: ["选择模型", "Select model"],
            timeout: min(1.5, configuration.modelMenuTimeout)
        ) {
            return
        }

        // 真实 Codex 界面常出现“AXPress 返回成功但没有弹层”的情况。这里
        // 使用控件实时 AXFrame 的中心执行一次完整鼠标点击；坐标来自 AX，
        // 没有固定屏幕坐标，也不会点击当前窗口之外的区域。
        guard CodexLoginAutomator.clickCenter(pickers[0]) else {
            throw CodexAutomationError.modelControlNotFound
        }
        guard await waitForMenuMarkers(
            in: app,
            labels: ["选择模型", "Select model"],
            timeout: configuration.modelMenuTimeout
        ) else {
            // status 仅用于调试时判断 AX 是否响应过；对外仍按“菜单未展开”
            // 处理，避免把虚假的 success 当成可继续操作。
            _ = status
            throw CodexAutomationError.modelControlNotFound
        }
    }

    /// 打开“选择模型”二级菜单，并确认目标模型项已经出现在 AX 树中。
    private func openModelSubmenu(
        in app: CodexAppHandle,
        expectedModel: String
    ) async throws {
        let deadline = Date().addingTimeInterval(configuration.modelMenuTimeout)
        var didRetryWithMouse = false

        while Date() < deadline {
            let markers = menuMarkers(in: app, labels: ["选择模型"])
            if markers.count > 1 {
                throw CodexAutomationError.modelSelectionAmbiguous(
                    label: "选择模型", count: markers.count
                )
            }
            if let marker = markers.first {
                let status = AXUIElementPerformAction(marker, kAXPressAction as CFString)
                if await waitForMenuOptions(
                    labels: [expectedModel], in: app,
                    timeout: min(1.0, configuration.modelMenuTimeout)
                ) {
                    return
                }

                // 同样处理二级菜单的“虚假 AXPress”。只对仍然能在当前树中
                // 精确找到的同一个语义节点做一次真实点击。
                if !didRetryWithMouse {
                    didRetryWithMouse = true
                    guard CodexLoginAutomator.clickCenter(marker) else {
                        throw CodexAutomationError.modelOptionNotFound(expectedModel)
                    }
                    if await waitForMenuOptions(
                        labels: [expectedModel], in: app,
                        timeout: min(1.5, configuration.modelMenuTimeout)
                    ) {
                        return
                    }
                }
                _ = status
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        throw CodexAutomationError.modelOptionNotFound(expectedModel)
    }

    /// 打开思考程度二级菜单。不同版本把入口暴露为“强度”菜单项或
    /// “选择强度”弹出按钮，因此两种语义都支持，后续仍要求精确回读。
    private func openReasoningSubmenu(
        in app: CodexAppHandle,
        expected: CodexReasoningEffort
    ) async throws {
        let deadline = Date().addingTimeInterval(configuration.modelMenuTimeout)
        var didRetryWithMouse = false

        while Date() < deadline {
            // 同一入口可能同时暴露“强度”和“选择强度”两个节点；优先
            // 选择更具体的“选择强度”，只有同一文案重复才算歧义。
            let preferred = menuMarkers(in: app, labels: ["选择强度"])
            let markers = preferred.isEmpty
                ? menuMarkers(in: app, labels: ["强度"])
                : preferred
            if markers.count > 1 {
                throw CodexAutomationError.modelSelectionAmbiguous(
                    label: preferred.isEmpty ? "强度" : "选择强度", count: markers.count
                )
            }
            if let marker = markers.first {
                _ = AXUIElementPerformAction(marker, kAXPressAction as CFString)
                if await waitForMenuOptions(
                    labels: expected.uiLabels, in: app,
                    timeout: min(1.0, configuration.modelMenuTimeout)
                ) {
                    return
                }
                if !didRetryWithMouse {
                    didRetryWithMouse = true
                    guard CodexLoginAutomator.clickCenter(marker) else {
                        throw CodexAutomationError.reasoningOptionNotFound(
                            expected.displayName
                        )
                    }
                    if await waitForMenuOptions(
                        labels: expected.uiLabels, in: app,
                        timeout: min(1.5, configuration.modelMenuTimeout)
                    ) {
                        return
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        throw CodexAutomationError.reasoningOptionNotFound(expected.displayName)
    }

    private func waitForMenuMarkers(
        in app: CodexAppHandle,
        labels: [String],
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !menuMarkers(in: app, labels: labels).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !menuMarkers(in: app, labels: labels).isEmpty
    }

    private func waitForMenuOptions(
        labels: [String],
        in app: CodexAppHandle,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !matchingActionableOptions(labels: labels, in: app).isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !matchingActionableOptions(labels: labels, in: app).isEmpty
    }

    private func modelPickers(in surface: AXUIElement) -> [AXUIElement] {
        var budget = configuration.traversalNodeBudget
        return collectElements(
            in: surface, matching: ["AXPopUpButton"],
            maxDepth: configuration.traversalMaxDepth, budget: &budget,
            containerRole: nil
        ).filter {
            guard let title = string($0, kAXTitleAttribute) else { return false }
            return normalized(title).hasPrefix("gpt-")
        }
    }

    /// 当前 Codex 的思考程度控件。有的版本提供“高/中/低”菜单，有的版本
    /// 在“选择强度”弹层中只暴露 AXSlider；两者都必须最终通过 UI 回读确认。
    private func reasoningSliders(
        in surface: AXUIElement,
        picker: AXUIElement? = nil,
        control: AXUIElement? = nil
    ) -> [AXUIElement] {
        var budget = configuration.traversalNodeBudget
        let sliders = collectElements(
            in: surface, matching: ["AXSlider"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget, containerRole: nil
        )
        let anchorFrame = picker.flatMap(CodexLoginAutomator.frame(of:))
            ?? control.flatMap(CodexLoginAutomator.frame(of:))
        guard let anchorFrame else { return sliders }
        // 滑杆弹层通常紧邻 Composer；把范围放大到整个当前窗口，仍以
        // 实时 AXFrame 为锚点，避免把侧栏滚动条误当成思考程度滑杆。
        let expanded = anchorFrame.insetBy(dx: -520, dy: -620)
        return sliders.filter { slider in
            guard let frame = CodexLoginAutomator.frame(of: slider) else { return true }
            return expanded.intersects(frame)
        }
    }

    /// 新版 Codex 的“选择强度”不是 AXSlider，而是 SwiftUI/Chromium 弹层里
    /// 一条没有语义子节点的六点轨道。弹层本身会暴露为带 AXCancel 的 AXGroup，
    /// 轨道是其下方最窄、最靠下的横向 AXGroup。只接受同时满足这些几何条件
    /// 的节点，避免把消息正文或滚动条当成强度控件。
    private func reasoningTrack(
        in surface: AXUIElement,
        picker: AXUIElement? = nil,
        control: AXUIElement? = nil
    ) -> AXUIElement? {
        let anchor = picker ?? control
        guard let anchorFrame = anchor.flatMap(CodexLoginAutomator.frame(of:)) else {
            return nil
        }
        var budget = configuration.traversalNodeBudget
        let groups = collectElements(
            in: surface,
            matching: ["AXGroup"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget,
            containerRole: nil
        )
        let popovers = groups.compactMap { group -> (AXUIElement, CGRect)? in
            guard let frame = CodexLoginAutomator.frame(of: group),
                  frame.width >= max(120, anchorFrame.width * 1.5),
                  frame.height >= 60, frame.height <= 360,
                  frame.maxY >= anchorFrame.minY - 8,
                  frame.minY <= anchorFrame.minY + 8,
                  frame.midX >= anchorFrame.minX - frame.width * 0.25,
                  frame.midX <= anchorFrame.maxX + frame.width * 0.25,
                  supportsAction(group, action: "AXCancel")
            else { return nil }
            return (group, frame)
        }
        guard let popover = popovers.min(by: { $0.1.height < $1.1.height }) else {
            return nil
        }

        var innerBudget = configuration.traversalNodeBudget
        let tracks = collectElements(
            in: popover.0,
            matching: ["AXGroup"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &innerBudget,
            containerRole: nil
        ).compactMap { group -> (AXUIElement, CGRect)? in
            guard let frame = CodexLoginAutomator.frame(of: group),
                  frame.width >= popover.1.width * 0.65,
                  frame.height >= 12, frame.height <= 80,
                  frame.minY >= popover.1.minY + popover.1.height * 0.42,
                  frame.maxY <= popover.1.maxY + 3 else { return nil }
            return (group, frame)
        }
        // 轨道的可点击范围是底部最薄的横向组；外层容器会更高，故按高度、
        // 再按宽度排序后取唯一最佳候选。
        return tracks.sorted {
            if $0.1.height != $1.1.height { return $0.1.height < $1.1.height }
            return $0.1.width > $1.1.width
        }.first?.0
    }

    private func reasoningTracks(
        in app: CodexAppHandle,
        picker: AXUIElement? = nil,
        control: AXUIElement? = nil
    ) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        return deduplicateByFrame(contentSurfaces(of: root).compactMap {
            reasoningTrack(in: $0, picker: picker, control: control)
        })
    }

    private func rawNumber(_ element: AXUIElement, _ attribute: String) -> Double? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw else { return nil }
        return (raw as? NSNumber)?.doubleValue
    }

    private func reasoningEffortFromSlider(
        in surface: AXUIElement, picker: AXUIElement
    ) -> CodexReasoningEffort? {
        guard let slider = reasoningSliders(in: surface, picker: picker).first,
              let value = rawNumber(slider, kAXValueAttribute),
              let minValue = rawNumber(slider, kAXMinValueAttribute),
              let maxValue = rawNumber(slider, kAXMaxValueAttribute) else { return nil }
        return CodexReasoningEffort.fromSliderValue(
            value, min: minValue, max: maxValue
        )
    }

    /// 在当前 AX 窗口中找到“选择强度”入口。新版 Codex 将它作为与模型
    /// 选择器并列的 AXPopUpButton；不能复用模型按钮，否则第二次点击会把
    /// 模型弹层关闭，后续自然找不到滑杆。
    private func reasoningControls(
        in surface: AXUIElement,
        picker: AXUIElement?
    ) -> [AXUIElement] {
        var budget = configuration.traversalNodeBudget
        let nodes = collectElements(
            in: surface,
            matching: ["AXPopUpButton", "AXMenuButton", "AXButton"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget,
            containerRole: nil
        )
        let exactEntrances: Set<String> = [
            "选择强度", "思考程度", "reasoning effort", "thinking effort",
            "select strength", "select intensity", "reasoning"
        ].map(normalized).reduce(into: Set<String>()) { $0.insert($1) }
        let levelLabels = Set(
            CodexReasoningEffort.allCases.flatMap { $0.uiLabels.map(normalized) }
        )
        let pickerFrame = picker.flatMap(CodexLoginAutomator.frame(of:))

        let exact = nodes.filter { node in
            let values = [
                string(node, kAXTitleAttribute),
                string(node, kAXDescriptionAttribute),
                string(node, kAXValueAttribute),
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map(normalized)
            guard values.contains(where: exactEntrances.contains) else { return false }
            return isNearModelPicker(node, pickerFrame: pickerFrame)
        }
        if !exact.isEmpty { return deduplicateByFrame(exact) }

        // 部分语言版本只显示当前档位（例如“高”），没有“选择强度”文案。
        // 仅接受 AXPopUpButton/AXMenuButton，并按距离模型按钮排序；普通正文
        // 按钮即使写着“高”也不会进入这里。
        let fallback = nodes.filter { node in
            let role = string(node, kAXRoleAttribute) ?? ""
            // 在弹层打开时，Chromium 有时把当前档位暴露成 AXButton，
            // 而关闭状态则通常是 AXPopUpButton/AXMenuButton。两者都可
            // 作为“选择强度”的入口，但仍要求文案是六档之一且靠近模型控件。
            guard role == "AXPopUpButton" || role == "AXMenuButton"
                    || role == "AXButton" || role == "AXRadioButton"
                    || role == "AXOption" else { return false }
            let values = [
                string(node, kAXTitleAttribute),
                string(node, kAXDescriptionAttribute),
                string(node, kAXValueAttribute),
            ].compactMap { $0 }.map(normalized)
            guard values.contains(where: levelLabels.contains) else { return false }
            return isNearModelPicker(node, pickerFrame: pickerFrame)
        }
        let unique = deduplicateByFrame(fallback)
        // 如果网页给出了 AXSelected/AXChecked，优先保留当前档位；这样
        // 弹层同时列出六个选项时不会把它们误判成六个“入口”。没有
        // 选中态时再把全部候选交给上层的唯一性门槛。
        let selected = unique.filter {
            bool($0, kAXSelectedAttribute) == true
                || bool($0, "AXChecked") == true
        }
        return selected.isEmpty ? unique : selected
    }

    /// 从已经可见的强度控件回读当前档位；这只读 AX，不会触发点击。
    private func visibleReasoningEffort(
        in surfaces: [AXUIElement], picker: AXUIElement
    ) -> CodexReasoningEffort? {
        for surface in surfaces {
            for control in reasoningControls(in: surface, picker: picker) {
                let values = [
                    string(control, kAXTitleAttribute),
                    string(control, kAXDescriptionAttribute),
                    string(control, kAXValueAttribute),
                ].compactMap { $0 }
                for value in values {
                    if let effort = CodexReasoningEffort.fromUILabel(value) {
                        return effort
                    }
                }
            }
        }
        return nil
    }

    /// 重新读取所有当前窗口中的滑杆。弹层在 Electron 中偶尔会作为新的
    /// AXWindow 挂载，因此不能只扫描第一次拿到的 focusedWindow。
    private func reasoningSliders(
        in app: CodexAppHandle,
        picker: AXUIElement? = nil,
        control: AXUIElement? = nil
    ) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surfaces = contentSurfaces(of: root)
        if let primary = surfaces.first {
            let focusedResult = reasoningSliders(
                in: primary, picker: picker, control: control
            )
            if !focusedResult.isEmpty {
                return deduplicateByFrame(focusedResult)
            }
        }
        let result = surfaces.dropFirst().flatMap {
            reasoningSliders(in: $0, picker: picker, control: control)
        }
        return deduplicateByFrame(result)
    }

    private func openReasoningPicker(in app: CodexAppHandle) async throws {
        guard let running = NSRunningApplication(processIdentifier: app.processIdentifier),
              !running.isTerminated else {
            throw CodexAutomationError.applicationNotFound(app.bundleIdentifier)
        }

        let deadline = Date().addingTimeInterval(configuration.reasoningSelectionTimeout)
        var didRetryWithMouse = false
        var openedModelMenu = false
        while Date() < deadline {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            let surfaces = contentSurfaces(of: root)
            let focused = focusedWindow(of: root)
            let picker = focused.flatMap { modelPickers(in: $0).first }
                ?? surfaces.flatMap { modelPickers(in: $0) }.first

            let openSliders = reasoningSliders(in: app, picker: picker)
            if !openSliders.isEmpty || !reasoningTracks(in: app, picker: picker).isEmpty {
                return
            }

            let primarySurfaces = focused.map { [$0] } ?? surfaces
            var controls = primarySurfaces.flatMap {
                reasoningControls(in: $0, picker: picker)
            }
            if controls.isEmpty, primarySurfaces.count != surfaces.count {
                controls = surfaces.flatMap {
                    reasoningControls(in: $0, picker: picker)
                }
            }
            let uniqueControls = deduplicateByFrame(controls)
            if uniqueControls.count > 1 {
                throw CodexAutomationError.modelSelectionAmbiguous(
                    label: "选择强度", count: uniqueControls.count
                )
            }
            // 选中模型后，Codex 会把“选择强度”入口合并回同一个模型按钮；
            // 此时没有独立 control，直接使用 picker 作为弹层入口。
            guard let control = uniqueControls.first ?? picker else {
                if !openedModelMenu {
                    try await openModelPicker(in: app)
                    openedModelMenu = true
                }
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }

            _ = running.activate(options: [.activateAllWindows])
            let status = AXUIElementPerformAction(control, kAXPressAction as CFString)
            if await waitForReasoningInteraction(
                in: app, picker: picker, control: control,
                timeout: min(1.5, configuration.reasoningSelectionTimeout)
            ) { return }

            // Electron 有时返回 AXPress=success 但网页没有收到事件；只对
            // 仍然存在的同一控件补一次由实时 AXFrame 驱动的鼠标点击。
            if !didRetryWithMouse {
                didRetryWithMouse = true
                guard CodexLoginAutomator.clickCenter(control) else {
                    throw CodexAutomationError.reasoningOptionNotFound("选择强度")
                }
                if await waitForReasoningInteraction(
                    in: app, picker: picker, control: control,
                    timeout: min(2.0, configuration.reasoningSelectionTimeout)
                ) { return }
            }
            _ = status
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw CodexAutomationError.reasoningOptionNotFound("选择强度")
    }

    private func waitForReasoningInteraction(
        in app: CodexAppHandle,
        picker: AXUIElement?,
        control: AXUIElement?,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !reasoningSliders(in: app, picker: picker, control: control).isEmpty
                || !reasoningTracks(in: app, picker: picker, control: control).isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !reasoningSliders(in: app, picker: picker, control: control).isEmpty
            || !reasoningTracks(in: app, picker: picker, control: control).isEmpty
    }

    private func waitForReasoningSelection(
        _ expected: CodexReasoningEffort,
        in app: CodexAppHandle,
        picker: AXUIElement?,
        control: AXUIElement?
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(configuration.reasoningSelectionTimeout)
        while Date() < deadline {
            let sliders = reasoningSliders(in: app, picker: picker, control: control)
            for slider in sliders {
                guard let value = rawNumber(slider, kAXValueAttribute),
                      let minValue = rawNumber(slider, kAXMinValueAttribute),
                      let maxValue = rawNumber(slider, kAXMaxValueAttribute),
                      let actual = CodexReasoningEffort.fromSliderValue(
                          value, min: minValue, max: maxValue
                      ) else { continue }
                if actual == expected { return true }
            }
            if let selection = try? await readExecutionSelection(app),
               (selection.reasoningEffort == expected
                || selectionTitleMatchesEffort(selection.visibleTitle, expected)) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return false
    }

    private func selectionTitleMatchesEffort(
        _ title: String,
        _ expected: CodexReasoningEffort
    ) -> Bool {
        CodexReasoningEffort.fromUILabel(title) == expected
    }

    private func sliderClickPoint(
        frame: CGRect, fraction: Double, stopCount: Int
    ) -> CGPoint? {
        guard frame.width > 2, frame.height > 2, stopCount > 1 else { return nil }
        let clamped = min(1, max(0, fraction))
        if frame.width >= frame.height {
            // AXFrame 包含圆形滑块本身；把点击范围内缩半个滑块直径，
            // 才会落在六个小点的中心，而不是轨道外缘。
            let inset = min(frame.height / 2, frame.width / CGFloat(stopCount * 2))
            let start = frame.minX + inset
            let end = frame.maxX - inset
            return CGPoint(x: start + (end - start) * clamped, y: frame.midY)
        }
        let inset = min(frame.width / 2, frame.height / CGFloat(stopCount * 2))
        let start = frame.minY + inset
        let end = frame.maxY - inset
        return CGPoint(x: frame.midX, y: start + (end - start) * clamped)
    }

    private func setReasoningSlider(
        _ effort: CodexReasoningEffort, in app: CodexAppHandle
    ) async throws {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surfaces = contentSurfaces(of: root)
        let focused = focusedWindow(of: root)
        let primarySurfaces = focused.map { [$0] } ?? surfaces
        let picker = primarySurfaces.flatMap { modelPickers(in: $0) }.first
            ?? surfaces.flatMap { modelPickers(in: $0) }.first
        var controls = primarySurfaces.flatMap {
            reasoningControls(in: $0, picker: picker)
        }
        if controls.isEmpty, primarySurfaces.count != surfaces.count {
            controls = surfaces.flatMap {
                reasoningControls(in: $0, picker: picker)
            }
        }
        let control = controls.first

        if reasoningSliders(in: app, picker: picker, control: control).isEmpty
            && reasoningTracks(in: app, picker: picker, control: control).isEmpty {
            try await openReasoningPicker(in: app)
        }

        let sliderDeadline = Date().addingTimeInterval(configuration.reasoningSelectionTimeout)
        var sliders: [AXUIElement] = []
        repeat {
            sliders = reasoningSliders(in: app, picker: picker, control: control)
            if !sliders.isEmpty
                || !reasoningTracks(in: app, picker: picker, control: control).isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < sliderDeadline

        let fraction = effort.sliderFraction

        if sliders.count == 1, let slider = sliders.first,
           let minValue = rawNumber(slider, kAXMinValueAttribute),
           let maxValue = rawNumber(slider, kAXMaxValueAttribute),
           maxValue > minValue {
            let target = minValue + fraction * (maxValue - minValue)

            // 先点击实际的离散点（六个点包含左右端点），让网页收到真实输入
            // 事件；AXValue 仅作为 Electron/AX 不接受鼠标事件时的后备方式。
            var clicked = false
            if let frame = CodexLoginAutomator.frame(of: slider),
               let point = sliderClickPoint(
                   frame: frame, fraction: fraction,
                   stopCount: CodexReasoningEffort.allCases.count
               ) {
                clicked = CodexLoginAutomator.click(point: point)
            }
            if clicked {
                let selected = await waitForReasoningSelection(
                    effort, in: app, picker: picker, control: control
                )
                if selected { return }
            }

            let status = AXUIElementSetAttributeValue(
                slider, kAXValueAttribute as CFString, NSNumber(value: target)
            )
            if status == .success {
                let selected = await waitForReasoningSelection(
                    effort, in: app, picker: picker, control: control
                )
                if selected { return }
            }

            // 最后再用同一个实时 frame 重试一次鼠标点；不会使用固定坐标，也
            // 不会在未确认目标滑杆时向窗口外点击。
            if let frame = CodexLoginAutomator.frame(of: slider),
               let point = sliderClickPoint(
                   frame: frame, fraction: fraction,
                   stopCount: CodexReasoningEffort.allCases.count
               ) {
                let retryClicked = CodexLoginAutomator.click(point: point)
                if retryClicked {
                    let selected = await waitForReasoningSelection(
                        effort, in: app, picker: picker, control: control
                    )
                    if selected { return }
                }
            }
        } else {
            // 当前生产版 Codex 使用没有 AXSlider role 的自定义轨道。轨道
            // 必须来自带 AXCancel 的强度弹层，且只能有一个；点击位置由该
            // 轨道实时 frame 计算，六个点严格对应 low…ultra。
            let tracks = reasoningTracks(in: app, picker: picker, control: control)
            guard tracks.count == 1, let track = tracks.first,
                  let frame = CodexLoginAutomator.frame(of: track),
                  let point = sliderClickPoint(
                      frame: frame, fraction: fraction,
                      stopCount: CodexReasoningEffort.allCases.count
                  ), CodexLoginAutomator.click(point: point) else {
                throw CodexAutomationError.reasoningOptionNotFound(effort.displayName)
            }
            if await waitForReasoningSelection(
                effort, in: app, picker: picker, control: control
            ) { return }
        }

        throw CodexAutomationError.reasoningOptionNotFound(effort.displayName)
    }

    private func pressUniqueMenuOption(
        labels: [String],
        missing: CodexAutomationError,
        in app: CodexAppHandle
    ) async throws {
        let deadline = Date().addingTimeInterval(configuration.modelMenuTimeout)
        while Date() < deadline {
            let matches = matchingActionableOptions(labels: labels, in: app)
            if matches.count > 1 {
                throw CodexAutomationError.modelSelectionAmbiguous(
                    label: labels[0], count: matches.count
                )
            }
            if let option = matches.first {
                let status = AXUIElementPerformAction(option, kAXPressAction as CFString)
                if status == .success {
                    // AXPress 可能返回成功但网页没有收到事件。若同一个精确
                    // 选项仍然在实时树中，补一次由 AXFrame 驱动的鼠标点击；
                    // 菜单已经消失时不再点击，避免落到下面的正文。
                    try? await Task.sleep(for: .milliseconds(350))
                    let stillVisible = matchingActionableOptions(labels: labels, in: app)
                    if stillVisible.isEmpty { return }
                    guard stillVisible.count == 1,
                          CodexLoginAutomator.clickCenter(stillVisible[0]) else {
                        throw missing
                    }
                    return
                }
                guard CodexLoginAutomator.clickCenter(option) else { throw missing }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw missing
    }

    /// 读取当前展开的模型弹层中，文案完全相等的节点。所有结果都必须位于
    /// 当前模型选择器附近，排除对话正文和 macOS 应用菜单中的同名文本。
    private func menuMarkers(
        in app: CodexAppHandle,
        labels: [String]
    ) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surface = focusedWindow(of: root) ?? root
        var budget = configuration.traversalNodeBudget
        let nodes = collectElements(
            in: surface,
            matching: [
                "AXMenuItem", "AXPopUpButton", "AXButton", "AXRadioButton",
                "AXOption", "AXStaticText",
            ],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget,
            containerRole: nil
        )
        let needles = Set(labels.map(normalized))
        let pickerFrame = modelPickers(in: surface).count == 1
            ? modelPickers(in: surface).first.flatMap(CodexLoginAutomator.frame(of:))
            : nil
        let matches = nodes.filter { node in
            guard exactNodeText(node, needles: needles) else { return false }
            return isNearModelPicker(node, pickerFrame: pickerFrame)
        }
        return deduplicateByFrame(matches)
    }

    private func exactNodeText(_ node: AXUIElement, needles: Set<String>) -> Bool {
        let values = [
            string(node, kAXTitleAttribute),
            string(node, kAXValueAttribute),
            string(node, kAXDescriptionAttribute),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map(normalized)
        return values.contains(where: needles.contains)
    }

    private func isNearModelPicker(
        _ element: AXUIElement,
        pickerFrame: CGRect?
    ) -> Bool {
        guard let pickerFrame,
              let frame = CodexLoginAutomator.frame(of: element) else {
            return true
        }
        // 菜单会出现在按钮上方或下方，尺寸随窗口和语言变化。这里使用相对
        // 于实时模型按钮的扩展区域，不使用固定屏幕坐标。
        let expanded = pickerFrame.insetBy(dx: -420, dy: -520)
        return expanded.intersects(frame)
    }

    private func deduplicateByFrame(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen: Set<String> = []
        return elements.filter { element in
            let key: String
            if let frame = CodexLoginAutomator.frame(of: element) {
                key = "\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width)):\(Int(frame.height))"
            } else {
                key = "\(string(element, kAXRoleAttribute) ?? ""):\(allTexts(of: element, maxDepth: 0).joined(separator: "|"))"
            }
            return seen.insert(key).inserted
        }
    }

    private func matchingActionableOptions(
        labels: [String], in app: CodexAppHandle
    ) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surface = focusedWindow(of: root) ?? root
        var budget = configuration.traversalNodeBudget
        let textNodes = collectElements(
            in: surface,
            matching: [
                "AXButton", "AXMenuItem", "AXRadioButton", "AXCheckBox",
                "AXOption", "AXStaticText", "AXHeading", "AXGroup",
            ],
            maxDepth: configuration.traversalMaxDepth, budget: &budget,
            containerRole: nil
        )
        let needles = Set(labels.map(normalized))
        let pickerFrame = modelPickers(in: surface).count == 1
            ? modelPickers(in: surface).first.flatMap(CodexLoginAutomator.frame(of:))
            : nil
        var result: [AXUIElement] = []

        for node in textNodes {
            guard isNearModelPicker(node, pickerFrame: pickerFrame) else { continue }
            let texts = [
                string(node, kAXTitleAttribute),
                string(node, kAXValueAttribute),
                string(node, kAXDescriptionAttribute),
            ].compactMap { $0 }.map(normalized)
            guard texts.contains(where: needles.contains),
                  let actionable = actionableAncestor(of: node) else { continue }
            if !result.contains(where: { CFEqual($0, actionable) }) {
                result.append(actionable)
            }
        }
        return result
    }

    private func waitForSelection(
        in app: CodexAppHandle,
        matching predicate: (CodexExecutionSelection) -> Bool
    ) async throws -> CodexExecutionSelection? {
        let deadline = Date().addingTimeInterval(configuration.modelMenuTimeout)
        while Date() < deadline {
            if let selection = try? await readExecutionSelection(app), predicate(selection) {
                return selection
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: - Composer

    public func locateComposer(_ app: CodexAppHandle) async throws -> CodexComposerHandle {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let candidates = contentSurfaces(of: root).flatMap { surface in
            var budget = configuration.traversalNodeBudget
            return collectElements(
                in: surface, matching: configuration.composerRoles,
                maxDepth: configuration.traversalMaxDepth, budget: &budget,
                containerRole: nil
            )
        }

        // 排除搜索框 / 命令面板
        let usable = candidates.filter { element in
            let identifier = string(element, kAXIdentifierAttribute) ?? ""
            let description = string(element, kAXDescriptionAttribute) ?? ""
            let placeholder = string(element, kAXPlaceholderValueAttribute) ?? ""
            let haystack = "\(identifier) \(description) \(placeholder)"
            return !configuration.composerExcludedIdentifierHints.contains {
                haystack.localizedCaseInsensitiveContains($0)
            }
        }

        guard let chosen = usable.max(by: {
            composerScore($0) < composerScore($1)
        }) else {
            throw CodexAutomationError.composerNotFound
        }

        let editable = composerEditableState(chosen)
        return CodexComposerHandle(
            identifier: string(chosen, kAXIdentifierAttribute) ?? "composer",
            isEditable: editable
        )
    }

    public func focusComposer(
        _ composer: CodexComposerHandle,
        in app: CodexAppHandle
    ) async throws {
        guard let element = findComposer(composer, app) else {
            throw CodexAutomationError.composerFocusFailed
        }

        // 模型/思考程度弹层关闭后，Codex 可能仍把前台焦点留在弹层的
        // AXWindow。先激活真实 Codex 进程，确保后面的键盘事件不会落到
        // AIRunner 或 Chrome；激活只改变前台状态，不会发送任何内容。
        try await activate(app)

        let status = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, true as CFTypeRef
        )

        // 不能把 AXFocused=nil 当成“已经聚焦”。Chromium 的 contenteditable
        // 经常不回读这个属性，但只有一次真实 DOM 点击才能保证 Cmd+V/键盘
        // 事件进入网页。点击位置来自当前 AXFrame，绝不使用固定坐标。
        let clicked = CodexLoginAutomator.clickCenter(element)
        try? await Task.sleep(for: .milliseconds(120))
        if bool(element, kAXFocusedAttribute) == true || clicked {
            // clicked 只代表事件已投递；insertMessage 会再用文本回读确认，
            // 因此这里可以安全返回，不会把“焦点成功”误报成“已输入”。
            return
        }

        // 某些窗口没有可读 AXFrame，但仍支持 AXPress；保留一次语义回退。
        let pressed = CodexLoginAutomator.press(element)
        if pressed {
            try? await Task.sleep(for: .milliseconds(120))
            if bool(element, kAXFocusedAttribute) != false { return }
            return
        }

        // AXSetValue 成功且明确回读为 true 也是可接受的无坐标路径。
        if status == .success, bool(element, kAXFocusedAttribute) == true { return }
        throw CodexAutomationError.composerFocusFailed
    }

    public func insertMessage(
        _ text: String,
        into composer: CodexComposerHandle,
        in app: CodexAppHandle
    ) async throws {
        guard !text.isEmpty else {
            throw CodexAutomationError.messageInsertionFailed(expected: text, actual: nil)
        }
        guard let element = findComposer(composer, app) else {
            throw CodexAutomationError.composerNotFound
        }

        // 自动恢复不应覆盖用户已经输入的草稿；同一内容已经在框内时可
        // 直接复用，否则把它作为明确失败交给上层，避免误拼接/误发送。
        if let existing = composerContentValue(element), !existing.isEmpty {
            if Self.composerContentMatches(actual: existing, expected: text) { return }
            throw CodexAutomationError.messageInsertionFailed(
                expected: text, actual: existing
            )
        }

        // 模型弹层关闭后焦点可能回到正文；重新激活并点击输入框，确保
        // Cmd+V 和后备键盘事件进入网页的 contenteditable，而不是停在 AX
        // 缓存或 AIRunner 自己的窗口里。
        try await focusComposer(composer, in: app)

        // Chromium 的 AXValue 写入可能只改变辅助功能缓存而没有触发网页
        // input 事件。因此先走剪贴板 + Cmd+V 的真实输入路径；AXValue
        // 只作为辅助功能事件被系统拦截时的后备路径。
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            if let previous { pasteboard.setString(previous, forType: .string) }
            throw CodexAutomationError.messageInsertionFailed(expected: text, actual: nil)
        }
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }

        if Self.postPaste(to: app.processIdentifier),
           await waitForComposerText(text, composer: composer, in: app) {
            return
        }

        // 粘贴不可用时再尝试 AXValue。即使 AX 返回 success，也必须等到
        // Composer 实际回读包含完整提示词才算输入成功。
        let directStatus = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFTypeRef
        )
        if directStatus == .success,
           await waitForComposerText(text, composer: composer, in: app) {
            return
        }

        // 最后的网页事件路径：先清空可能由失败的粘贴/AX 写入留下的
        // 部分草稿，再逐字符投递 Unicode 键盘事件。这里仍然不记录文本；
        // 成功标准是 AX 回读到完整提示词，而不是 CGEvent 调用返回成功。
        await CodexLoginAutomator.clearField(
            element, pid: app.processIdentifier
        )
        await CodexLoginAutomator.typeText(
            text,
            to: app.processIdentifier,
            interval: configuration.composerTypingInterval
        )
        let typingTimeout = min(
            configuration.composerTypingTimeout,
            max(
                configuration.composerInputTimeout,
                2 + Double(text.utf16.count) * 0.02
            )
        )
        if await waitForComposerText(
            text, composer: composer, in: app, timeout: typingTimeout
        ) {
            return
        }

        let actual = try? await readComposerValue(composer, in: app)
        throw CodexAutomationError.messageInsertionFailed(expected: text, actual: actual ?? nil)
    }

    public func readComposerValue(
        _ composer: CodexComposerHandle,
        in app: CodexAppHandle
    ) async throws -> String? {
        guard let element = findComposer(composer, app) else { return nil }
        return composerContentValue(element)
    }

    // MARK: - 发送

    public func locateSendControl(_ app: CodexAppHandle) async throws -> CodexSendControlHandle {
        let deadline = Date().addingTimeInterval(configuration.sendControlTimeout)
        repeat {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            let surfaces = contentSurfaces(of: root)
            let composerFrame = surfaces.lazy
                .flatMap { surface -> [AXUIElement] in
                    var budget = configuration.traversalNodeBudget
                    return collectElements(
                        in: surface, matching: configuration.composerRoles,
                        maxDepth: configuration.traversalMaxDepth, budget: &budget,
                        containerRole: nil
                    )
                }
                .compactMap(CodexLoginAutomator.frame(of:))
                .max { lhs, rhs in lhs.maxY < rhs.maxY }

            let buttons = surfaces.flatMap { surface in
                var budget = configuration.traversalNodeBudget
                return collectElements(
                    in: surface, matching: ["AXButton"],
                    maxDepth: configuration.traversalMaxDepth, budget: &budget,
                    containerRole: nil
                )
            }
            let matching = buttons.filter { button in
                let title = string(button, kAXTitleAttribute)
                let description = string(button, kAXDescriptionAttribute)
                let identifier = string(button, kAXIdentifierAttribute)
                let labelMatch = [title, description].compactMap { $0 }.contains {
                    configuration.sendControlLabels.map(normalized).contains(normalized($0))
                }
                let identifierMatch = identifier.map { id in
                    configuration.sendControlIdentifierHints.contains {
                        id.localizedCaseInsensitiveContains($0)
                    }
                } ?? false
                guard labelMatch || identifierMatch else { return false }
                guard let composerFrame,
                      let buttonFrame = CodexLoginAutomator.frame(of: button) else {
                    return true
                }
                // 发送箭头与 Composer 相邻；扩展范围覆盖语言/窗口缩放差异，
                // 同时排除消息气泡里的“发送/提交”按钮。
                return composerFrame.insetBy(dx: -520, dy: -220).intersects(buttonFrame)
            }
            let candidates = matching.isEmpty
                ? unlabeledSendCandidates(buttons, composerFrame: composerFrame)
                : matching
            if matching.isEmpty, candidates.count != 1 {
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            if let button = candidates.max(by: { sendButtonScore($0, composerFrame: composerFrame)
                < sendButtonScore($1, composerFrame: composerFrame) }) {
                let title = string(button, kAXTitleAttribute)
                let description = string(button, kAXDescriptionAttribute)
                let identifier = string(button, kAXIdentifierAttribute)
                return CodexSendControlHandle(
                    identifier: identifier ?? title ?? description ?? "send-geometry",
                    label: title ?? description
                )
            }
            try? await Task.sleep(for: .milliseconds(120))
        } while Date() < deadline
        throw CodexAutomationError.sendControlNotFound
    }

    public func pressSend(
        _ control: CodexSendControlHandle,
        in app: CodexAppHandle
    ) async throws {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surfaces = contentSurfaces(of: root)
        let composerFrame = surfaces.lazy
            .flatMap { surface -> [AXUIElement] in
                var budget = configuration.traversalNodeBudget
                return collectElements(
                    in: surface, matching: configuration.composerRoles,
                    maxDepth: configuration.traversalMaxDepth, budget: &budget,
                    containerRole: nil
                )
            }
            .compactMap(CodexLoginAutomator.frame(of:))
            .max { lhs, rhs in lhs.maxY < rhs.maxY }
        let buttons = surfaces.flatMap { surface in
            var budget = configuration.traversalNodeBudget
            return collectElements(
                in: surface, matching: ["AXButton"],
                maxDepth: configuration.traversalMaxDepth, budget: &budget,
                containerRole: nil
            )
        }
        let matching = buttons.filter { button in
            // Disabled按钮可能还保留“发送”文案，不能把它当成可发送控件。
            if bool(button, kAXEnabledAttribute) == false { return false }
            let identifier = string(button, kAXIdentifierAttribute)
            let title = string(button, kAXTitleAttribute)
            let description = string(button, kAXDescriptionAttribute)
            return identifier == control.identifier
                || title == control.label
                || description == control.label
                || (control.label.map { label in
                    configuration.sendControlLabels.map(normalized).contains(normalized(label))
                    && [title, description].compactMap { $0 }
                        .contains { normalized($0) == normalized(label) }
                } ?? false)
        }
        // locateSendControl 已经按 Composer 右下角选过一次，但菜单动画或
        // 输入事件可能让旧句柄失效。重新按同一几何关系选最近的候选，避免
        // 命中消息气泡里的“发送/提交”按钮；没有 frame 时才退回稳定顺序。
        let candidates = matching.isEmpty && control.identifier == "send-geometry"
            ? unlabeledSendCandidates(buttons, composerFrame: composerFrame)
            : matching
        if control.identifier == "send-geometry", candidates.count != 1 {
            throw CodexAutomationError.sendControlNotFound
        }
        let match = candidates.max {
            sendButtonScore($0, composerFrame: composerFrame)
                < sendButtonScore($1, composerFrame: composerFrame)
        }
        guard let target = match else {
            throw CodexAutomationError.sendControlNotFound
        }
        // Chromium 的发送按钮会出现 AXPress 返回 success、网页却完全没有
        // 收到 click 的假成功。目标已通过 Composer 右下角语义/几何双重锁定，
        // 因此优先对它此刻的 AXFrame 中心投递一次真实鼠标点击。只能投递
        // 一次；随后由 observeSendConfirmation 等待 Composer 清空，避免重发。
        if CodexLoginAutomator.clickCenter(target) { return }

        // 无可用 frame 时才退回 AXPress；这条路径同样只执行一次。
        let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard status == .success else {
            throw CodexAutomationError.sendFailed(
                "实时按钮点击/AXPress 均失败 (AXError=\(status.rawValue))"
            )
        }
    }

    public func observeSendConfirmation(
        _ app: CodexAppHandle,
        composer: CodexComposerHandle
    ) async throws -> SendConfirmation {
        // 轮询 Composer 清空；Codex 发送后可能先显示消息气泡，再异步清空。
        // 观察不到就如实返回 unconfirmed —— 由上层记为 sentUnconfirmed。
        let interval = 0.25
        let attempts = max(1, Int(ceil(configuration.sendConfirmationTimeout / interval)))
        for _ in 0..<attempts {
            if let value = try? await readComposerValue(composer, in: app),
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .composerCleared
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return .unconfirmed
    }

    /// 向已聚焦的目标进程发送一次 Cmd+V。
    ///
    /// 只接受调用方已经通过 AX 定位并聚焦的输入框; 这里不做坐标点击,
    /// 也不把剪贴板内容写进日志或持久化层。
    private static func postPaste(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source, virtualKey: 0x09, keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source, virtualKey: 0x09, keyDown: false
              ) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    /// 关闭仍然展开的模型菜单。只向已锁定的 Codex 进程发送 Escape。
    private static func postEscape(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source, virtualKey: 0x35, keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source, virtualKey: 0x35, keyDown: false
              ) else { return }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    // MARK: - 内部: 元素查找

    /// 侧边栏中一条可见线程的语义描述。
    ///
    /// AX 树里的“行”不一定真的使用 AXRow：当前 Codex 用 AXGroup 包住一个
    /// 带 AXPress 的 AXButton。保留行元素和真正可点击的后代，既能避免重复
    /// 候选，也能让 openThread 点击到正确的语义控件。
    private struct ThreadRowDescriptor {
        let row: AXUIElement
        let actionable: AXUIElement?
        let title: String
        let projectName: String?
        let frame: CGRect?
    }

    /// 只从导航/侧边栏的列表直接子项产生线程候选。
    ///
    /// 不再把一个列表项的所有后代 AXButton/AXGroup 都当成独立线程；这正是
    /// 当前 Codex 把同一标题暴露成三个候选的原因。主区域的 AXSectionHeader
    /// 也不属于导航分支，因此不会参与侧边栏匹配。
    private func threadRowDescriptors(in surface: AXUIElement) -> [ThreadRowDescriptor] {
        let listRoles = configuration.threadContainerRoles.filter {
            $0 == "AXOutline" || $0 == "AXList" || $0 == "AXTable"
        }
        guard !listRoles.isEmpty else { return [] }

        var budget = configuration.traversalNodeBudget
        let containers = collectElements(
            in: surface,
            matching: listRoles,
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget,
            containerRole: nil
        ).filter { isInThreadSidebar($0, from: surface) }

        let descriptors = containers.flatMap { container -> [ThreadRowDescriptor] in
            directChildren(of: container).compactMap {
                makeThreadRowDescriptor(for: $0, in: surface)
            }
        }
        return deduplicatedThreadRows(descriptors)
    }

    /// 判断元素是否位于 Codex 左侧导航/侧边栏分支。
    private func isInThreadSidebar(_ element: AXUIElement, from surface: AXUIElement) -> Bool {
        let subroles = ancestorChain(of: element, from: surface).compactMap {
            string($0, kAXSubroleAttribute)
        }
        let sidebar = subroles.contains("AXLandmarkNavigation")
            || subroles.contains("AXLandmarkComplementary")
        let main = subroles.contains("AXLandmarkMain")
        return sidebar && !main
    }

    private func makeThreadRowDescriptor(
        for row: AXUIElement,
        in surface: AXUIElement
    ) -> ThreadRowDescriptor? {
        guard let title = threadTitle(in: row, from: surface) else { return nil }
        let texts = allTexts(of: row, maxDepth: 6)
        let projectName = secondaryText(from: texts, excluding: title)
        let actionable = actionableThreadElement(
            in: row, title: title, from: surface
        )
        let frame = CodexLoginAutomator.frame(of: row)
            ?? actionable.flatMap(CodexLoginAutomator.frame(of:))
        return ThreadRowDescriptor(
            row: row,
            actionable: actionable,
            title: title,
            projectName: projectName,
            frame: frame
        )
    }

    /// 在一个列表直接子项内找标题。标题只从能表达文字的语义 role 读取，
    /// 并沿用通用文案过滤，避免把“置顶聊天”“随心输入”等控件说明当标题。
    private func threadTitle(
        in row: AXUIElement,
        from surface: AXUIElement
    ) -> String? {
        let titleRoles: Set<String> = [
            "AXButton", "AXLink", "AXHeading", "AXStaticText",
            "AXRow", "AXCell", "AXGroup",
        ]
        var budget = configuration.traversalNodeBudget
        var result: String?
        walk(
            row,
            depth: 0,
            maxDepth: min(configuration.traversalMaxDepth, 8),
            budget: &budget
        ) { element in
            guard result == nil,
                  let role = string(element, kAXRoleAttribute),
                  titleRoles.contains(role),
                  !isInsideEditableControl(element, from: surface) else {
                return result != nil
            }
            let values = [
                string(element, kAXTitleAttribute),
                string(element, kAXDescriptionAttribute),
            ]
            if let value = values.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: isLikelyThreadTitle) {
                result = value
            }
            return result != nil
        }
        return result
    }

    /// 找到列表项中标题对应的可点击元素。行本身常是 AXGroup，真正的
    /// AXPress 在其下方的 AXButton；只沿当前行向下搜，不跨到别的列表项。
    private func actionableThreadElement(
        in row: AXUIElement,
        title: String,
        from surface: AXUIElement
    ) -> AXUIElement? {
        var budget = configuration.traversalNodeBudget
        var result: AXUIElement?
        walk(
            row,
            depth: 0,
            maxDepth: min(configuration.traversalMaxDepth, 8),
            budget: &budget
        ) { element in
            guard result == nil,
                  !isInsideEditableControl(element, from: surface),
                  let role = string(element, kAXRoleAttribute),
                  ["AXButton", "AXLink", "AXRow", "AXCell", "AXGroup"].contains(role),
                  supportsPress(element) else {
                return false
            }
            let values = [
                string(element, kAXTitleAttribute),
                string(element, kAXDescriptionAttribute),
            ]
            if values.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .contains(where: { CodexTaskMatcher.equal($0, title) }) {
                result = element
            }
            return result != nil
        }
        return result
    }

    /// AX 树可能重复返回同一个对象，也可能同时暴露一行的 wrapper 和内部
    /// button。只有对象相同或标题/可视几何明确属于同一行时才合并；两个
    /// 分隔开的同名线程不会被吞掉，仍然交给 matcher 报歧义。
    private func deduplicatedThreadRows(
        _ rows: [ThreadRowDescriptor]
    ) -> [ThreadRowDescriptor] {
        var result: [ThreadRowDescriptor] = []
        for row in rows {
            guard let index = result.firstIndex(where: {
                sameVisualThreadRow($0, row)
            }) else {
                result.append(row)
                continue
            }
            if result[index].actionable == nil, row.actionable != nil {
                result[index] = row
            }
        }
        return result
    }

    private func sameVisualThreadRow(
        _ lhs: ThreadRowDescriptor,
        _ rhs: ThreadRowDescriptor
    ) -> Bool {
        guard CodexTaskMatcher.equal(lhs.title, rhs.title) else { return false }
        if CFEqual(lhs.row, rhs.row) { return true }
        if let leftAction = lhs.actionable,
           let rightAction = rhs.actionable,
           CFEqual(leftAction, rightAction) {
            return true
        }
        guard let lhsFrame = lhs.frame, let rhsFrame = rhs.frame else {
            // 没有几何证据时宁可保留两个候选，不能把真正的同名线程合并。
            return false
        }
        let tolerance: CGFloat = 3
        let sameFrame = abs(lhsFrame.minX - rhsFrame.minX) <= tolerance
            && abs(lhsFrame.minY - rhsFrame.minY) <= tolerance
            && abs(lhsFrame.width - rhsFrame.width) <= tolerance
            && abs(lhsFrame.height - rhsFrame.height) <= tolerance
        if sameFrame { return true }

        // wrapper 和内部标题按钮有时尺寸不同，但仍处于同一条可视行；用
        // 水平重叠 + 垂直中心距离判断。相邻的两条同名行通常相隔整行高度，
        // 不会满足这个条件。
        let overlap = max(
            0,
            min(lhsFrame.maxX, rhsFrame.maxX) - max(lhsFrame.minX, rhsFrame.minX)
        )
        let minWidth = min(lhsFrame.width, rhsFrame.width)
        let yDistance = abs(lhsFrame.midY - rhsFrame.midY)
        let yTolerance = max(8, min(lhsFrame.height, rhsFrame.height) * 0.5)
        return minWidth > 0 && overlap >= minWidth * 0.8 && yDistance <= yTolerance
    }

    private func secondarySignalsMatch(
        _ descriptor: ThreadRowDescriptor,
        _ candidate: CodexThreadCandidate
    ) -> Bool {
        func matches(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let rhs, !rhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return true
            }
            guard let lhs, !lhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return true
            }
            return CodexTaskMatcher.equal(lhs, rhs)
        }
        return matches(descriptor.projectName, candidate.projectName)
    }

    /// 从主区域顶部的标题按钮读取当前工作对话名称。
    ///
    /// Codex 的侧边栏和主区域会各自暴露一个同名 AXButton。模型选择器只在
    /// 主区域分支中，因此以它为锚点比较祖先链，优先选择同一分支中位置最靠
    /// 上的标题按钮；这样不会把侧边栏的同名条目当成“当前已打开”对话。
    private func threadHeaderTitle(in surface: AXUIElement) -> String? {
        let surfaceFrame = CodexLoginAutomator.frame(of: surface)
        var budget = configuration.traversalNodeBudget
        let titleNodes = collectElements(
            in: surface,
            // 工作对话标题在当前 Codex 中是 AXButton。保留 AXLink/AXHeading
            // 兼容旧版，但不再把 AXGroup/AXStaticText 的描述或值当成标题；
            // 输入框的“随心输入”正是以 AXTextArea/AXDescription 暴露的。
            matching: ["AXButton", "AXLink", "AXHeading"],
            maxDepth: configuration.traversalMaxDepth,
            budget: &budget,
            containerRole: nil
        ).compactMap { element -> (element: AXUIElement, title: String)? in
            guard !isInsideEditableControl(element, from: surface) else { return nil }
            // 当前 Codex 的真实会话标题位于窗口最上方的导航栏。Composer
            // 附件也可能以 AXButton 暴露“移除‘文件名’”，而且偶尔被 Chromium
            // 错挂到 AXSectionHeader。只接受窗口顶部带状区域中的候选，避免
            // 把附件操作重新保存成线程标题。
            if let surfaceFrame,
               let elementFrame = CodexLoginAutomator.frame(of: element) {
                guard Self.isInThreadHeaderBand(
                    elementFrame: elementFrame, surfaceFrame: surfaceFrame
                ) else {
                    return nil
                }
            }
            // 当前 Codex 的真实会话标题必须在主导航栏直属的 AXSectionHeader
            // 中。正文“复制”按钮没有 SectionHeader，右侧“输出内容”则位于
            // 深层 SectionHeader；两者都必须排除。加载中尚未出现主导航标题时
            // 返回 nil 并等待，不能退回正文按钮。
            guard let depth = sectionHeaderDepthFromMain(element, from: surface),
                  depth <= 2 else { return nil }
            // 线程身份只读取 AXTitle。AXDescription 是按钮的辅助说明，正文
            // 工具栏会把“复制”等动作暴露在这里；把它当标题会覆盖已保存绑定。
            // 如果导航标题尚未产生 AXTitle，就返回 nil 等待 UI 稳定。
            guard let title = string(element, kAXTitleAttribute)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  isLikelyThreadTitle(title) else { return nil }
            return (element, title.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard !titleNodes.isEmpty else { return nil }

        // 这一集合已全部通过直属主导航 SectionHeader 门槛；仍要求顶部唯一，
        // 多个不同标题时继续 fail closed。
        return topmostUniqueThreadTitle(in: titleNodes)
    }

    private func topmostUniqueThreadTitle(
        in nodes: [(element: AXUIElement, title: String)]
    ) -> String? {
        guard !nodes.isEmpty else { return nil }
        let known = nodes.compactMap { node -> (String, CGFloat)? in
            guard let y = CodexLoginAutomator.frame(of: node.element)?.minY else {
                return nil
            }
            return (node.title, y)
        }
        guard let topY = known.map(\.1).min() else { return nil }
        let topmost = known.filter { $0.1 <= topY + 2 }
        let unique = Set(topmost.map { normalized($0.0) })
        guard unique.count == 1, let key = unique.first else { return nil }
        return topmost.first { normalized($0.0) == key }?.0
    }

    private func isLikelyThreadTitle(_ title: String) -> Bool {
        Self.isLikelyThreadTitleText(title)
    }

    /// 纯文本层的标题候选过滤，供回归测试锁定通用控件/输入占位文案。
    /// AX 元素是否位于可编辑祖先中由 `isInsideEditableControl` 另行判断。
    static func isLikelyThreadTitleText(_ title: String) -> Bool {
        let value = title.lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !value.isEmpty else { return false }
        let commonControls: Set<String> = [
            "chatgpt", "openai", "返回", "前进", "back", "forward", "分享", "share",
            "发送", "send", "新对话", "new chat", "登录", "继续登录", "注册", "cancel",
            "取消", "退出登录", "log out", "sign out", "选择模型", "选择强度",
            // Codex 输入框的占位文案。它可能通过 AXDescription 或旧版
            // AXWebArea.title 暴露，绝不能被当成工作对话标题。
            "随心输入", "开始输入", "输入消息", "输入内容", "问我任何问题",
            "ask anything", "message chatgpt", "send a message",
            "置顶聊天", "取消置顶聊天", "归档聊天", "删除聊天",
            "pin chat", "unpin chat", "archive chat", "delete chat",
            "输出内容", "output", "output contents",
            "复制", "复制消息", "copy", "copy message",
        ]
        guard !commonControls.contains(value) else { return false }
        let operationPrefixes = [
            "移除“", "移除\"", "移除附件", "remove “", "remove \"",
            "remove attachment", "删除附件", "delete attachment",
        ]
        guard !operationPrefixes.contains(where: value.hasPrefix) else { return false }
        guard !value.hasPrefix("gpt-") else { return false }
        return true
    }

    /// 线程标题必须位于窗口顶部导航带。使用窗口相对位置而非屏幕坐标，
    /// 窗口移动、缩放或换显示器后仍保持同一判定。
    static func isInThreadHeaderBand(
        elementFrame: CGRect,
        surfaceFrame: CGRect
    ) -> Bool {
        guard surfaceFrame.width > 0, surfaceFrame.height > 0,
              elementFrame.width > 0, elementFrame.height > 0 else {
            return false
        }
        let headerHeight = min(140, max(80, surfaceFrame.height * 0.14))
        return elementFrame.midY >= surfaceFrame.minY
            && elementFrame.midY <= surfaceFrame.minY + headerHeight
    }

    /// 返回最近的 AXSectionHeader 到 AXLandmarkMain 的父级距离。
    /// nil 表示元素不在 SectionHeader 中，供旧版 Codex 的标题回退继续使用。
    private func sectionHeaderDepthFromMain(
        _ element: AXUIElement,
        from surface: AXUIElement
    ) -> Int? {
        var current = element
        var foundSectionHeader = false
        var depth = 0
        for _ in 0..<configuration.traversalMaxDepth {
            if string(current, kAXSubroleAttribute) == "AXSectionHeader" {
                foundSectionHeader = true
                depth = 0
            } else if foundSectionHeader {
                depth += 1
            }
            if foundSectionHeader,
               string(current, kAXSubroleAttribute) == "AXLandmarkMain" {
                return depth
            }
            if CFEqual(current, surface) { break }
            guard let next = parent(of: current) else { break }
            current = next
        }
        return foundSectionHeader ? Int.max : nil
    }

    /// 判断候选标题是否位于输入框、搜索框等可编辑控件内部。
    ///
    /// Electron/Chromium 的 AX 树会把输入框的 placeholder 挂在
    /// `AXDescription` 上；即使它被包装在若干 AXGroup 中，也必须沿祖先链
    /// 排除，否则切换对话或页面刷新期间可能把 placeholder 当成线程标题。
    private func isInsideEditableControl(
        _ element: AXUIElement,
        from surface: AXUIElement
    ) -> Bool {
        let editableRoles: Set<String> = [
            "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"
        ]
        var current = element
        for _ in 0..<configuration.traversalMaxDepth {
            if let role = string(current, kAXRoleAttribute), editableRoles.contains(role) {
                return true
            }
            if CFEqual(current, surface) { break }
            guard let next = parent(of: current) else { break }
            current = next
        }
        return false
    }

    private func ancestorChain(
        of element: AXUIElement,
        from surface: AXUIElement
    ) -> [AXUIElement] {
        var chain: [AXUIElement] = [element]
        var current = element
        for _ in 0..<configuration.traversalMaxDepth {
            if CFEqual(current, surface) { break }
            guard let next = parent(of: current) else { break }
            chain.append(next)
            current = next
            if CFEqual(current, surface) { break }
        }
        return chain.reversed()
    }

    private func findComposer(
        _ composer: CodexComposerHandle,
        _ app: CodexAppHandle
    ) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let candidates = contentSurfaces(of: root).flatMap { surface in
            var budget = configuration.traversalNodeBudget
            return collectElements(
                in: surface, matching: configuration.composerRoles,
                maxDepth: configuration.traversalMaxDepth, budget: &budget,
                containerRole: nil
            )
        }
        let identified = candidates.filter {
            (string($0, kAXIdentifierAttribute) ?? "composer") == composer.identifier
        }
        if let chosen = identified.max(by: {
            composerScore($0) < composerScore($1)
        }) {
            return chosen
        }
        // 旧版 AX 树不给 TextArea identifier；绑定句柄使用了占位名
        // “composer” 时按同一套候选排序重新取真实 Composer。
        guard composer.identifier == "composer" else { return nil }
        return candidates.max(by: { composerScore($0) < composerScore($1) })
    }

    private func composerScore(_ element: AXUIElement) -> Int {
        let role = string(element, kAXRoleAttribute) ?? ""
        let identifier = string(element, kAXIdentifierAttribute) ?? ""
        let description = string(element, kAXDescriptionAttribute) ?? ""
        let placeholder = string(element, kAXPlaceholderValueAttribute) ?? ""
        let value = composerContentValue(element) ?? ""
        let haystack = normalized("\(identifier) \(description) \(placeholder)")
        var score = role == "AXTextArea" ? 20 : 10
        if configuration.composerIdentityHints.contains(where: {
            haystack.contains(normalized($0))
        }) {
            score += 100
        }
        if !value.isEmpty { score += 2 }
        if composerEditableState(element) { score += 5 }
        return score
    }

    private func composerEditableState(_ element: AXUIElement) -> Bool {
        // Chromium/WebKit 有的版本暴露 AXEditable，有的只暴露 AXEnabled；
        // 读取不到时，AXTextArea + AXSetValue 仍可作为可编辑证据。
        if let editable = bool(element, "AXEditable") { return editable }
        if let enabled = bool(element, kAXEnabledAttribute) { return enabled }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success,
           let list = actions as? [String], list.contains("AXSetValue") {
            return true
        }
        return string(element, kAXRoleAttribute) == "AXTextArea"
    }

    private func waitForComposerText(
        _ expected: String,
        composer: CodexComposerHandle,
        in app: CodexAppHandle,
        timeout: TimeInterval? = nil
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(
            timeout ?? configuration.composerInputTimeout
        )
        while Date() < deadline {
            if let actual = try? await readComposerValue(composer, in: app),
               Self.composerContentMatches(actual: actual, expected: expected) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let value = try? await readComposerValue(composer, in: app) else {
            return false
        }
        return Self.composerContentMatches(actual: value, expected: expected)
    }

    /// Chromium 当前会把空 contenteditable 的灰色占位文案同时暴露为
    /// AXDescription 和 AXValue（例如 AXValue="\n随心输入"）。它不是用户
    /// 输入，必须在所有草稿检查、写入回读和发送确认之前统一归一为空。
    private func composerContentValue(_ element: AXUIElement) -> String? {
        let value = textValue(element, kAXValueAttribute)
        let placeholder = textValue(element, kAXPlaceholderValueAttribute)
        let description = textValue(element, kAXDescriptionAttribute)
        return Self.normalizedComposerContent(
            value: value,
            placeholder: placeholder,
            description: description
        )
    }

    static func normalizedComposerContent(
        value: String?,
        placeholder: String?,
        description: String?
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let placeholderTexts = [placeholder, description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if placeholderTexts.contains(where: {
            $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return nil
        }
        return value
    }

    static func composerContentMatches(actual: String, expected: String) -> Bool {
        actual.trimmingCharacters(in: .whitespacesAndNewlines)
            == expected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendButtonScore(
        _ button: AXUIElement,
        composerFrame: CGRect?
    ) -> Int {
        guard let composerFrame,
              let frame = CodexLoginAutomator.frame(of: button) else { return 0 }
        let distance = abs(frame.midX - composerFrame.maxX)
            + abs(frame.midY - composerFrame.midY)
        // 越接近 Composer 的右侧，分数越高。
        return max(0, 10_000 - Int(distance.rounded()))
    }

    /// 当 Codex 只给发送箭头绘制图标、完全不暴露 AXTitle/Description/Identifier
    /// 时的保守几何回退。它必须是 Composer 右下角唯一的可用小按钮；多个候选
    /// 时保持 fail-closed，绝不凭“最像”去点听写/语音或添加文件。
    private func unlabeledSendCandidates(
        _ buttons: [AXUIElement], composerFrame: CGRect?
    ) -> [AXUIElement] {
        guard let composerFrame else { return [] }
        let rightEdge = composerFrame.maxX - 12
        let bottomEdge = composerFrame.maxY - 8
        return buttons.filter { button in
            guard bool(button, kAXEnabledAttribute) != false,
                  string(button, kAXTitleAttribute) == nil,
                  string(button, kAXDescriptionAttribute) == nil,
                  string(button, kAXIdentifierAttribute) == nil,
                  let frame = CodexLoginAutomator.frame(of: button),
                  frame.width >= 18, frame.width <= 96,
                  frame.height >= 18, frame.height <= 96 else { return false }
            // 发送按钮通常贴近输入框右端和底边；左侧的“添加文件”和中部
            // 权限/强度控件不会同时满足这两个条件。
            return frame.maxX >= rightEdge - 110
                && frame.maxY >= bottomEdge - 82
                && composerFrame.insetBy(dx: -8, dy: -8).intersects(frame)
        }
    }

    /// 沿 parent 向上找第一个支持 AXPress / 可设置 AXSelected 的元素。
    private func actionableAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < 8 {
            var names: CFArray?
            if AXUIElementCopyActionNames(node, &names) == .success,
               let list = names as? [String], list.contains(kAXPressAction as String) {
                return node
            }
            current = parent(of: node)
            hops += 1
        }
        return nil
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXParentAttribute as CFString, &raw
        )
        guard status == .success, let value = raw else { return nil }
        // 需要手动桥接到 AXUIElement
        return (value as! AXUIElement)
    }

    private func directChildren(of element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &raw
        ) == .success else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func supportsPress(_ element: AXUIElement) -> Bool {
        supportsAction(element, action: kAXPressAction as String)
    }

    private func supportsAction(_ element: AXUIElement, action: String) -> Bool {
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success,
              let actions = raw as? [String] else {
            return false
        }
        return actions.contains(action)
    }

    /// 在树中收集 role 匹配的元素。
    ///
    /// - Parameter containerRole: 非 nil 时, 只在该 role 的容器内收集。
    private func collectElements(
        in root: AXUIElement,
        matching roles: [String],
        maxDepth: Int,
        budget: inout Int,
        containerRole: String?
    ) -> [AXUIElement] {

        if let containerRole {
            // 先定位容器, 再在其内部收集
            var found: [AXUIElement] = []
            walk(root, depth: 0, maxDepth: maxDepth, budget: &budget) { element in
                if string(element, kAXRoleAttribute) == containerRole {
                    var subBudget = configuration.traversalNodeBudget
                    walk(element, depth: 0, maxDepth: maxDepth, budget: &subBudget) { child in
                        if let role = string(child, kAXRoleAttribute), roles.contains(role) {
                            found.append(child)
                        }
                        return false
                    }
                    return true   // 已经处理该容器, 不再深入
                }
                return false
            }
            return found
        }

        var found: [AXUIElement] = []
        walk(root, depth: 0, maxDepth: maxDepth, budget: &budget) { element in
            if let role = string(element, kAXRoleAttribute), roles.contains(role) {
                found.append(element)
            }
            return false
        }
        return found
    }

    /// 深度优先遍历。`handler` 返回 true 表示不再深入该子树。
    private func walk(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        budget: inout Int,
        handler: (AXUIElement) -> Bool
    ) {
        guard budget > 0, depth <= maxDepth else { return }
        budget -= 1

        if handler(element) { return }

        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &raw
        )
        guard status == .success, let children = raw as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, maxDepth: maxDepth, budget: &budget, handler: handler)
        }
    }

    // MARK: - 内部: 属性读取

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }

    /// 将 AXValue/NSAttributedString 等 Composer 常见值统一转成文本。
    private func textValue(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw else { return nil }
        if let value = raw as? String, !value.isEmpty { return value }
        if let value = raw as? NSAttributedString, !value.string.isEmpty {
            return value.string
        }
        if let value = raw as? NSNumber { return value.stringValue }
        return nil
    }

    private func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let value = raw as? NSNumber else { return nil }
        return value.boolValue
    }

    private func firstText(of element: AXUIElement, maxDepth: Int) -> String? {
        if let title = string(element, kAXTitleAttribute), !title.isEmpty { return title }
        if let description = string(element, kAXDescriptionAttribute), !description.isEmpty {
            return description
        }
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &raw
        )
        guard status == .success, let children = raw as? [AXUIElement] else { return nil }
        if maxDepth <= 0 { return nil }
        for child in children {
            if let text = firstText(of: child, maxDepth: maxDepth - 1) { return text }
        }
        return nil
    }

    private func allTexts(of element: AXUIElement, maxDepth: Int) -> [String] {
        var result: [String] = []
        var budget = configuration.traversalNodeBudget
        collectTexts(
            element, depth: 0, maxDepth: maxDepth,
            budget: &budget, into: &result
        )
        return result
    }

    private func collectTexts(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        budget: inout Int,
        into result: inout [String]
    ) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1

        if let title = string(element, kAXTitleAttribute), !title.isEmpty {
            result.append(title)
        }
        // Electron/Chromium 的 AXStaticText 经常以 NSAttributedString 暴露
        // AXValue。这里必须走 textValue，否则额度横幅和正文都会被漏掉，
        // 监视器看不到“达到使用上限”而不会进入确认/切号流程。
        if let value = textValue(element, kAXValueAttribute), !value.isEmpty, value.count < 200 {
            result.append(value)
        }
        if let description = string(element, kAXDescriptionAttribute), !description.isEmpty {
            result.append(description)
        }

        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &raw
        )
        guard status == .success, let children = raw as? [AXUIElement] else { return }
        for child in children {
            collectTexts(
                child, depth: depth + 1, maxDepth: maxDepth,
                budget: &budget, into: &result
            )
        }
    }

    private func secondaryText(from texts: [String], excluding primary: String) -> String? {
        texts.first { $0 != primary && !$0.isEmpty }
    }

    private func windowCount(of appElement: AXUIElement) -> Int {
        windows(of: appElement).count
    }

    private func windows(of appElement: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &raw
        )
        if status == .success, let windows = raw as? [AXUIElement] {
            let usable = windows.filter(isContentWindow)
            if !usable.isEmpty { return usable }
        }

        // 某些 Electron 状态会短暂把 AXWindows 暴露为 AXHelpTag 或重复的
        // AXApplication。真实窗口仍可能已经在应用的直接 AXChildren 中，
        // 所以只把 role 明确为 AXWindow/AXDialog 的节点作为回退。
        var childrenRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXChildrenAttribute as CFString, &childrenRaw
        ) == .success,
        let children = childrenRaw as? [AXUIElement] else { return [] }
        return children.filter(isContentWindow)
    }

    /// Electron 的 Codex 窗口通过 AXWindows 暴露，通常不在 AXApplication 的
    /// 普通 AXChildren 中。正文控件必须从窗口根节点遍历；拿不到窗口时才回退应用根。
    private func contentSurfaces(of appElement: AXUIElement) -> [AXUIElement] {
        let appWindows = windows(of: appElement)
        // Chromium 的网页弹层大多挂在 AXWindow 下面，但部分版本会把
        // “选择强度”单独暴露成 AXPopover/AXSheet，既不出现在 AXWindows，
        // 也不属于主窗口。把这两类辅助表面纳入扫描，才能读取滑杆和
        // 发送按钮的真实 AX 节点；仍然不把普通 AXChildren 当窗口。
        var auxiliaryBudget = configuration.traversalNodeBudget
        let auxiliary = collectElements(
            in: appElement,
            matching: ["AXPopover", "AXSheet"],
            maxDepth: 4,
            budget: &auxiliaryBudget,
            containerRole: nil
        )
        var surfaces: [AXUIElement] = []
        if let focused = focusedWindow(of: appElement), isContentWindow(focused) {
            surfaces.append(focused)
        }
        surfaces.append(contentsOf: appWindows)
        surfaces.append(contentsOf: auxiliary)
        if surfaces.isEmpty { return [appElement] }
        return deduplicateByFrame(surfaces)
    }

    private func isContentWindow(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute)
        return role == kAXWindowRole || role == "AXDialog"
    }

    private func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement, attribute as CFString, &raw
            ) == .success, let raw {
                let candidate = unsafeDowncast(raw, to: AXUIElement.self)
                if isContentWindow(candidate) { return candidate }
            }
        }
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &raw
        ) == .success, let windows = raw as? [AXUIElement] {
            return windows.first
        }
        return nil
    }

    private static func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
    }
}

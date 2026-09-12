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

    /// 发送控件的候选文案 (多语言)。
    public var sendControlLabels: [String] = [
        "Send", "发送", "送出", "送信", "送出訊息", "Senden", "Envoyer", "Enviar"
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
    public var traversalNodeBudget: Int = 6000
    /// 单次 AX 遍历的深度上限。
    public var traversalMaxDepth: Int = 14

    public init() {}
    public static let `default` = CodexDriverConfiguration()
}

/// 基于 macOS Accessibility API 的真实驱动。
///
/// ## ★ 绝不使用固定屏幕坐标 ★
///
/// 所有元素定位都通过 AX 属性遍历完成。没有 `click(x:y)`, 没有 OCR, 没有截图模板匹配。
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
        running.activate()
    }

    public func ensureCodexViewPresent(_ app: CodexAppHandle) async throws {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard windowCount(of: element) > 0 else {
            throw CodexAutomationError.codexViewNotFound
        }
    }

    // MARK: - 找线程

    public func locateThreadCandidates(
        _ app: CodexAppHandle,
        fingerprint: CodexTaskFingerprint
    ) async throws -> [CodexThreadCandidate] {

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var budget = configuration.traversalNodeBudget

        // 先在容器 role 下找行, 找不到再退回到全局遍历。
        var rows: [AXUIElement] = []
        for containerRole in configuration.threadContainerRoles {
            rows = collectElements(
                in: root, matching: configuration.threadRowRoles,
                maxDepth: configuration.traversalMaxDepth, budget: &budget,
                containerRole: containerRole
            )
            if !rows.isEmpty { break }
        }
        if rows.isEmpty {
            budget = configuration.traversalNodeBudget
            rows = collectElements(
                in: root, matching: configuration.threadRowRoles,
                maxDepth: configuration.traversalMaxDepth, budget: &budget,
                containerRole: nil
            )
        }

        // 把每个"行"转成一个候选: 标题取自身或其后代的第一个非空 AXTitle /
        // AXStaticText 值; 项目名取同层可识别的文本之一。
        return rows.compactMap { row in
            let title = firstText(of: row, maxDepth: 4)
            guard let title, !title.isEmpty else { return nil }
            let siblings = allTexts(of: row, maxDepth: 4)
            return CodexThreadCandidate(
                title: title,
                projectName: secondaryText(from: siblings, excluding: title),
                debugPath: nil
            )
        }
    }

    public func openThread(_ candidate: CodexThreadCandidate, in app: CodexAppHandle) async throws {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var budget = configuration.traversalNodeBudget

        let rows = collectElements(
            in: root, matching: configuration.threadRowRoles,
            maxDepth: configuration.traversalMaxDepth, budget: &budget,
            containerRole: nil
        )

        let target = rows.first { firstText(of: $0, maxDepth: 4) == candidate.title }
        guard let matched = target else {
            throw CodexAutomationError.targetTaskNotFound
        }

        // ★ 不假设"行本身就可按" ★
        // 沿 parent 向上找第一个支持 AXPress 或者能设置 AXSelected 的祖先。
        guard let actionable = actionableAncestor(of: matched) else {
            throw CodexAutomationError.targetVerificationFailed(
                "找到线程行, 但它及其祖先都不支持可点击的 action"
            )
        }

        let status = AXUIElementPerformAction(actionable, kAXPressAction as CFString)
        guard status == .success else {
            throw CodexAutomationError.sendFailed("无法选中目标线程 (AXError=\(status.rawValue))")
        }
    }

    public func readOpenThreadContext(_ app: CodexAppHandle) async throws -> CodexOpenThreadContext {
        // 主会话区的判定很依赖具体 UI。这里取当前窗口下**最深层级**里的
        // 第一个标题类文本作为候选 —— 无法可靠读到时如实返回 nil,
        // 由 matcher 判定为"缺少第二个信号"从而拒绝发送。
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let texts = allTexts(of: root, maxDepth: configuration.traversalMaxDepth)

        guard let first = texts.first, !first.isEmpty else {
            return CodexOpenThreadContext()
        }
        return CodexOpenThreadContext(threadTitle: first)
    }

    // MARK: - 忙碌检测

    public func detectBusyState(_ app: CodexAppHandle) async throws -> CodexBusyState {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let surface = focusedWindow(of: root) ?? root
        let texts = Set(allTexts(of: surface, maxDepth: min(configuration.traversalMaxDepth, 10)))

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
                maxDepth: min(configuration.traversalMaxDepth, 10)
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
        return Array(meaningful.suffix(max(1, configuration.accountIssueTailLimit)))
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

    // MARK: - Composer

    public func locateComposer(_ app: CodexAppHandle) async throws -> CodexComposerHandle {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var budget = configuration.traversalNodeBudget
        let candidates = collectElements(
            in: root, matching: configuration.composerRoles,
            maxDepth: configuration.traversalMaxDepth, budget: &budget,
            containerRole: nil
        )

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

        guard let chosen = usable.first else {
            throw CodexAutomationError.composerNotFound
        }

        let editable = bool(chosen, kAXEnabledAttribute) ?? false
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
        let status = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, true as CFTypeRef
        )
        guard status == .success else {
            throw CodexAutomationError.composerFocusFailed
        }
    }

    public func insertMessage(
        _ text: String,
        into composer: CodexComposerHandle,
        in app: CodexAppHandle
    ) async throws {
        guard let element = findComposer(composer, app) else {
            throw CodexAutomationError.composerNotFound
        }
        var status = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFTypeRef
        )

        if status != .success {
            // Fallback: 剪贴板 + Cmd+V。
            // ★ 只允许在"composer 已经定位到"之后使用, 且执行前必须确认焦点。 ★
            let pasteboard = NSPasteboard.general
            let previous = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            // AXPress 只会把输入框聚焦, 不会把剪贴板内容插入。
            // Chromium/SwiftUI 的某些输入框拒绝直接设置 AXValue, 这时必须
            // 给已经定位并聚焦的真实目标发送一次 Cmd+V。
            let focusStatus = AXUIElementSetAttributeValue(
                element, kAXFocusedAttribute as CFString, true as CFTypeRef
            )
            if focusStatus != .success {
                // 某些 AX 实现不支持设置 focused, 但支持 press 作为同等的聚焦动作。
                status = AXUIElementPerformAction(element, kAXPressAction as CFString)
            }

            if status == .success || focusStatus == .success {
                status = Self.postPaste(to: app.processIdentifier)
                    ? .success
                    : .actionUnsupported
                // 给目标应用一个事件循环处理粘贴的机会, 再恢复用户原来的剪贴板。
                try? await Task.sleep(for: .milliseconds(100))
            }

            // 尽量还原剪贴板, 不占用用户的地方
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }

        guard status == .success else {
            throw CodexAutomationError.messageInsertionFailed(expected: text, actual: nil)
        }
    }

    public func readComposerValue(
        _ composer: CodexComposerHandle,
        in app: CodexAppHandle
    ) async throws -> String? {
        guard let element = findComposer(composer, app) else { return nil }
        return string(element, kAXValueAttribute)
    }

    // MARK: - 发送

    public func locateSendControl(_ app: CodexAppHandle) async throws -> CodexSendControlHandle {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var budget = configuration.traversalNodeBudget
        let buttons = collectElements(
            in: root, matching: ["AXButton"],
            maxDepth: configuration.traversalMaxDepth, budget: &budget,
            containerRole: nil
        )

        for button in buttons {
            let title = string(button, kAXTitleAttribute)
            let description = string(button, kAXDescriptionAttribute)
            let identifier = string(button, kAXIdentifierAttribute)

            if let title, configuration.sendControlLabels.contains(title) {
                return CodexSendControlHandle(
                    identifier: identifier ?? title, label: title
                )
            }
            if let description, configuration.sendControlLabels.contains(description) {
                return CodexSendControlHandle(
                    identifier: identifier ?? description, label: description
                )
            }
            if let identifier,
               configuration.sendControlIdentifierHints.contains(where: {
                   identifier.localizedCaseInsensitiveContains($0)
               }) {
                return CodexSendControlHandle(identifier: identifier, label: title)
            }
        }

        throw CodexAutomationError.sendControlNotFound
    }

    public func pressSend(
        _ control: CodexSendControlHandle,
        in app: CodexAppHandle
    ) async throws {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var budget = configuration.traversalNodeBudget
        let buttons = collectElements(
            in: root, matching: ["AXButton"],
            maxDepth: configuration.traversalMaxDepth, budget: &budget,
            containerRole: nil
        )
        let match = buttons.first { button in
            let identifier = string(button, kAXIdentifierAttribute)
            let title = string(button, kAXTitleAttribute)
            return identifier == control.identifier || title == control.label
        }
        guard let target = match else {
            throw CodexAutomationError.sendControlNotFound
        }
        let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard status == .success else {
            throw CodexAutomationError.sendFailed("AXPress 失败 (AXError=\(status.rawValue))")
        }
    }

    public func observeSendConfirmation(
        _ app: CodexAppHandle,
        composer: CodexComposerHandle
    ) async throws -> SendConfirmation {
        // 轮询最多 3 秒, 观察 composer 是否被清空。
        // 观察不到就如实返回 unconfirmed —— 由上层记为 sentUnconfirmed。
        for _ in 0..<12 {
            if let value = try? await readComposerValue(composer, in: app),
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .composerCleared
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
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

    // MARK: - 内部: 元素查找

    private func findComposer(
        _ composer: CodexComposerHandle,
        _ app: CodexAppHandle
    ) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var budget = configuration.traversalNodeBudget
        let candidates = collectElements(
            in: root, matching: configuration.composerRoles,
            maxDepth: configuration.traversalMaxDepth, budget: &budget,
            containerRole: nil
        )
        return candidates.first {
            (string($0, kAXIdentifierAttribute) ?? "composer") == composer.identifier
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
        collectTexts(element, depth: 0, maxDepth: maxDepth, into: &result)
        return result
    }

    private func collectTexts(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        into result: inout [String]
    ) {
        guard depth <= maxDepth else { return }

        if let title = string(element, kAXTitleAttribute), !title.isEmpty {
            result.append(title)
        }
        if let value = string(element, kAXValueAttribute), !value.isEmpty, value.count < 200 {
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
            collectTexts(child, depth: depth + 1, maxDepth: maxDepth, into: &result)
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
        guard status == .success, let windows = raw as? [AXUIElement] else { return [] }
        return windows
    }

    private func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement, attribute as CFString, &raw
            ) == .success, let raw {
                return unsafeDowncast(raw, to: AXUIElement.self)
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

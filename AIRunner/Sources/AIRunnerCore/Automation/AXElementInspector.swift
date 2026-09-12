import Foundation
import ApplicationServices
import AppKit

/// 一次 AX tree 导出的参数。
public struct AXTreeSnapshotOptions: Sendable, Equatable {
    /// 最大递归深度。
    public var maxDepth: Int = 12
    /// 最大节点数 (防止某些 App 的 AX 树爆炸)。
    public var maxNodes: Int = 4000
    /// 整体超时。
    public var timeout: TimeInterval = 20
    /// 文本值的预览长度。
    ///
    /// **默认 0 = 完全不显示内容**, 只报告长度。
    /// AI 对话类 App 的 AXValue 往往就是消息正文 —— 默认把它们写进日志是不可接受的。
    public var valuePreviewLength: Int = 0
    /// 单个 title / description 的最大长度。
    public var labelMaxLength: Int = 80

    public init() {}
}

/// AX 节点快照 (已脱敏)。
public struct AXNodeSnapshot: Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let description: String?
    public let identifier: String?
    /// 值的**脱敏**表示。默认只含长度, 不含内容。
    public let valueInfo: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let selected: Bool?
    /// 该元素支持的 AX action 名称 (如 AXPress)。
    public let actions: [String]
    public let childCount: Int
    public let children: [AXNodeSnapshot]
    /// 因为预算/深度/超时而被截断。
    public let truncated: Bool

    /// 渲染成缩进文本树。
    public func render(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        var line = "\(pad)\(role)"
        if let subrole { line += " subrole=\(subrole)" }
        if let identifier, !identifier.isEmpty { line += " id=\(identifier)" }
        if let title, !title.isEmpty { line += " title=\"\(title)\"" }
        if let description, !description.isEmpty { line += " desc=\"\(description)\"" }
        if let valueInfo { line += " value=\(valueInfo)" }
        if enabled == true { line += " [enabled]" }
        if focused == true { line += " [focused]" }
        if selected == true { line += " [selected]" }
        if !actions.isEmpty { line += " actions=[\(actions.joined(separator: ","))]" }
        if childCount > 0 { line += " children=\(childCount)" }
        if truncated { line += " (truncated)" }

        var lines = [line]
        for child in children {
            lines.append(child.render(indent: indent + 1))
        }
        return lines.joined(separator: "\n")
    }

    /// 该节点是否"可交互" —— 有助于快速定位 sidebar 行 / 按钮 / 输入框。
    public var isInteractive: Bool {
        !actions.isEmpty || role == "AXTextField" || role == "AXTextArea"
            || role == "AXButton" || role == "AXRow"
    }
}

/// AX tree 导出。
public protocol AXTreeInspecting: Sendable {
    func inspect(
        bundleIdentifier: String,
        options: AXTreeSnapshotOptions
    ) async throws -> AXNodeSnapshot
}

/// 基于 `AXUIElement` 的真实实现。
///
/// ## ★ 脱敏规则 ★
///
/// * `AXValue` 默认**只报长度**, 不报内容 —— 对话类 App 的 value 常常就是消息正文
/// * `title` / `description` 截断到 `labelMaxLength`
/// * 只读 UI 属性, 不读任何文件、不读任何凭据
public struct AXElementInspector: AXTreeInspecting {

    public init() {}

    public func inspect(
        bundleIdentifier: String,
        options: AXTreeSnapshotOptions = AXTreeSnapshotOptions()
    ) async throws -> AXNodeSnapshot {

        guard AXIsProcessTrusted() else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }
        guard let application = Self.findRunningApplication(
            bundleIdentifier: bundleIdentifier
        ) else {
            throw CodexAutomationError.applicationNotFound(bundleIdentifier)
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var budget = options.maxNodes
        let deadline = Date().addingTimeInterval(options.timeout)

        return Self.snapshot(
            of: appElement,
            depth: 0,
            options: options,
            budget: &budget,
            deadline: deadline
        )
    }

    // MARK: - 递归

    private static func snapshot(
        of element: AXUIElement,
        depth: Int,
        options: AXTreeSnapshotOptions,
        budget: inout Int,
        deadline: Date
    ) -> AXNodeSnapshot {

        let role = stringAttribute(element, kAXRoleAttribute) ?? "?"
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let identifier = stringAttribute(element, kAXIdentifierAttribute)
        let title = truncate(stringAttribute(element, kAXTitleAttribute), options.labelMaxLength)
        let description = truncate(
            stringAttribute(element, kAXDescriptionAttribute), options.labelMaxLength
        )

        let valueInfo = describeValue(element, options: options)
        let enabled = boolAttribute(element, kAXEnabledAttribute)
        let focused = boolAttribute(element, kAXFocusedAttribute)
        let selected = boolAttribute(element, kAXSelectedAttribute)
        let actions = actionNames(element)

        // ---- 预算 / 深度 / 超时 三重截断 ----
        guard budget > 0, depth < options.maxDepth, Date() < deadline else {
            return AXNodeSnapshot(
                role: role, subrole: subrole, title: title, description: description,
                identifier: identifier, valueInfo: valueInfo,
                enabled: enabled, focused: focused, selected: selected,
                actions: actions, childCount: 0, children: [], truncated: true
            )
        }
        budget -= 1

        let children = childElements(element)
        var snapshots: [AXNodeSnapshot] = []
        var childTruncated = false

        for child in children {
            if budget <= 0 || Date() >= deadline {
                childTruncated = true
                break
            }
            snapshots.append(
                snapshot(
                    of: child, depth: depth + 1, options: options,
                    budget: &budget, deadline: deadline
                )
            )
        }

        return AXNodeSnapshot(
            role: role, subrole: subrole, title: title, description: description,
            identifier: identifier, valueInfo: valueInfo,
            enabled: enabled, focused: focused, selected: selected,
            actions: actions,
            childCount: children.count,
            children: snapshots,
            truncated: childTruncated
        )
    }

    // MARK: - 属性读取

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let value = raw else { return nil }
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let value = raw else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// 描述 AXValue —— **默认不含内容**。
    private static func describeValue(
        _ element: AXUIElement,
        options: AXTreeSnapshotOptions
    ) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw)
        guard status == .success, let value = raw else { return nil }

        let text: String?
        if let string = value as? String {
            text = string
        } else if let attributed = value as? NSAttributedString {
            text = attributed.string
        } else if let number = value as? NSNumber {
            text = number.stringValue
        } else {
            text = nil
        }

        guard let text, !text.isEmpty else { return "[empty]" }

        // ★ 长度总是报告; 内容只在显式配置了预览长度时才给出 ★
        guard options.valuePreviewLength > 0 else {
            return "[\(text.count) chars]"
        }
        let preview = String(text.prefix(options.valuePreviewLength))
        return "\"\(preview)…\" (\(text.count) chars)"
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        guard status == .success, let list = names as? [String] else { return [] }
        return list.sorted()
    }

    private static func childElements(_ element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &raw
        )
        guard status == .success, let children = raw as? [AXUIElement] else { return [] }
        return children
    }

    private static func truncate(_ text: String?, _ limit: Int) -> String? {
        guard let text else { return nil }
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }

    // MARK: - 找 App

    static func findRunningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
    }

    /// 列出当前正在运行的、可能承载 Codex 的候选 App。
    ///
    /// 绑定时用它来**读取真实 bundle id**, 而不是硬编码 ——
    /// Codex 可能在 ChatGPT 桌面版里, 也可能是独立 App, 甚至以后改名。
    public static func candidateCodexApplications() -> [(bundleIdentifier: String, name: String)] {
        let knownPrefixes = ["com.openai.", "com.openai", "ai.openai"]
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
            let name = app.localizedName ?? bundleID
            let looksRelevant = knownPrefixes.contains { bundleID.hasPrefix($0) }
                || name.localizedCaseInsensitiveContains("chatgpt")
                || name.localizedCaseInsensitiveContains("codex")
            guard looksRelevant else { return nil }
            return (bundleID, name)
        }
    }
}

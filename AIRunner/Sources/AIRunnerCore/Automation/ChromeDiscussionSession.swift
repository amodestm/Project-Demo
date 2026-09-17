import AppKit
import ApplicationServices
import Foundation

/// 真实 ChatGPT 网页讨论会话的参数。
public struct ChromeDiscussionSessionConfiguration: Sendable, Equatable {
    public var browserKind: ChromeProfileScanner.ChromeKind = .chrome
    public var chatGPTURL: URL = URL(string: "https://chatgpt.com/")!
    public var windowOpenTimeout: TimeInterval = 30
    public var pageReadyTimeout: TimeInterval = 45
    public var responseTimeout: TimeInterval = 300
    public var pollInterval: Duration = .seconds(1)
    public var traversalNodeBudget = 18_000
    public var traversalMaxDepth = 22

    public init() {}
    public static let `default` = ChromeDiscussionSessionConfiguration()
}

/// 为每位讨论成员保留一扇独立的 Chrome Profile 窗口。
///
/// 会话按 participantID 缓存，因此同一场讨论换人时只是提升对应窗口，
/// 不会退出账号，也不会触碰其他成员的窗口。
public actor ChromeDiscussionSessionProvider: DiscussionSessionProviding {
    private let configuration: ChromeDiscussionSessionConfiguration
    private var sessions: [String: ChromeDiscussionSession] = [:]

    public init(configuration: ChromeDiscussionSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func session(
        for participant: DiscussionParticipant
    ) async throws -> DiscussionSessionDriving {
        let profile = participant.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = participant.emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionKey = "\(participant.id)|\(profile)|\(email.lowercased())"
        if let existing = sessions[sessionKey] { return existing }
        guard !profile.isEmpty else {
            throw AppError.invalidRequest("成员「\(participant.displayName)」没有绑定 Chrome Profile。")
        }
        guard !email.isEmpty else {
            throw AppError.invalidRequest("成员「\(participant.displayName)」没有配置账号邮箱，无法安全校验身份。")
        }

        let available = try ChromeProfileScanner().availableProfiles(kind: configuration.browserKind)
        guard let selected = available.first(where: { $0.directoryName == profile }) else {
            throw AppError.invalidRequest(
                "找不到成员「\(participant.displayName)」绑定的 Chrome Profile：\(profile)。"
            )
        }

        let created = try await ChromeDiscussionSession.open(
            profile: selected,
            expectedAccount: email,
            configuration: configuration
        )
        sessions[sessionKey] = created
        return created
    }
}

/// 一扇已经锁定的 Chrome 窗口。
///
/// AXUIElement 本身没有 Sendable 标注，但所有调用都由串行讨论编排器依次执行；
/// 实例不会在两个成员之间共享。
public final class ChromeDiscussionSession: DiscussionSessionDriving, @unchecked Sendable {
    private let application: NSRunningApplication
    private let window: AXUIElement
    private let expectedAccount: String
    private let configuration: ChromeDiscussionSessionConfiguration
    private var verifiedAccount: String?

    private init(
        application: NSRunningApplication,
        window: AXUIElement,
        expectedAccount: String,
        configuration: ChromeDiscussionSessionConfiguration
    ) {
        self.application = application
        self.window = window
        self.expectedAccount = expectedAccount
        self.configuration = configuration
    }

    public static func open(
        profile: ChromeProfile,
        expectedAccount: String,
        configuration: ChromeDiscussionSessionConfiguration = .default
    ) async throws -> ChromeDiscussionSession {
        guard AXIsProcessTrusted() else {
            throw CodexAutomationError.accessibilityPermissionMissing
        }

        let marker = UUID().uuidString.lowercased()
        guard let markedURL = markedURL(configuration.chatGPTURL, marker: marker) else {
            throw AppError.invalidRequest("ChatGPT 地址无效：\(configuration.chatGPTURL.absoluteString)")
        }
        guard ChromeProfileScanner().open(
            url: markedURL,
            profile: profile,
            kind: configuration.browserKind,
            newWindow: true
        ) else {
            throw AppError.invalidRequest("无法用 \(profile.directoryName) 打开 ChatGPT 窗口。")
        }

        let deadline = Date().addingTimeInterval(configuration.windowOpenTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: configuration.browserKind.rawValue
            ).first(where: { !$0.isTerminated }),
               let target = AX.findWindow(in: app, documentContaining: marker) {
                let session = ChromeDiscussionSession(
                    application: app,
                    window: target,
                    expectedAccount: expectedAccount,
                    configuration: configuration
                )
                try await session.waitUntilPageReady()
                return session
            }
            try await Task.sleep(for: configuration.pollInterval)
        }

        throw AppError.invalidRequest(
            "Chrome 已收到打开请求，但 \(Int(configuration.windowOpenTimeout)) 秒内没有找到"
            + " \(profile.directoryName) 对应的 ChatGPT 窗口。"
        )
    }

    public func verifyIdentity(emailHint: String) async throws -> Bool {
        let expected = emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }
        try raise()

        if AX.allTexts(in: window, configuration: configuration)
            .contains(where: { AX.identityMatches($0, expected: expected) }) {
            rememberVerified(expected)
            return true
        }

        guard let accountButton = AX.findAccountButton(
            in: window, configuration: configuration
        ) else { return false }
        guard AX.pressOrClick(accountButton) else { return false }

        defer { AX.postEscape(to: application.processIdentifier) }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try Task.checkCancellation()
            let root = AXUIElementCreateApplication(application.processIdentifier)
            let texts = AX.allTexts(in: root, configuration: configuration)
            if texts.contains(where: { AX.identityMatches($0, expected: expected) }) {
                rememberVerified(expected)
                return true
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    public func currentAccount() async throws -> String? {
        return verifiedAccount
    }

    public func send(prompt: String) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidRequest("讨论提示词为空，已停止发送。")
        }
        guard try await verifyIdentity(emailHint: expectedAccount) else {
            throw AppError.invalidRequest(
                "目标 Chrome 窗口无法确认账号 \(expectedAccount)，已停止发送。"
            )
        }

        try raise()
        let composer = try await waitForComposer()
        if let existing = AX.textValue(composer, kAXValueAttribute),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.invalidRequest("目标 ChatGPT 输入框中已有草稿，已停止以免覆盖。")
        }

        let baselineCopyCount = AX.copyButtons(
            in: window, configuration: configuration
        ).count
        try await insert(prompt, into: composer)
        try await pressSend(near: composer)
        try await waitForComposerToClear(composer)
        return try await waitForResponse(
            baselineCopyCount: baselineCopyCount,
            prompt: prompt
        )
    }

    // MARK: - 页面操作

    private func waitUntilPageReady() async throws {
        _ = try await waitForComposer(timeout: configuration.pageReadyTimeout)
    }

    private func waitForComposer(timeout: TimeInterval? = nil) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout ?? configuration.pageReadyTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let composer = AX.findComposer(in: window, configuration: configuration) {
                return composer
            }
            try await Task.sleep(for: configuration.pollInterval)
        }
        throw AppError.invalidRequest(
            "ChatGPT 页面已打开，但没有找到消息输入框。请确认该 Profile 已登录且页面加载完成。"
        )
    }

    private func insert(_ text: String, into composer: AXUIElement) async throws {
        _ = AXUIElementSetAttributeValue(
            composer, kAXFocusedAttribute as CFString, true as CFTypeRef
        )
        _ = AX.pressOrClick(composer)

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            if let previous { pasteboard.setString(previous, forType: .string) }
            throw AppError.invalidRequest("无法准备讨论提示词。")
        }
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }

        AX.postPaste(to: application.processIdentifier)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try Task.checkCancellation()
            if let actual = AX.textValue(composer, kAXValueAttribute),
               AX.normalized(actual).contains(AX.normalized(text)) {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        let status = AXUIElementSetAttributeValue(
            composer, kAXValueAttribute as CFString, text as CFTypeRef
        )
        if status == .success {
            try await Task.sleep(for: .milliseconds(300))
            if let actual = AX.textValue(composer, kAXValueAttribute),
               AX.normalized(actual).contains(AX.normalized(text)) {
                return
            }
        }
        throw AppError.invalidRequest("提示词没有完整写入 ChatGPT 输入框，已停止发送。")
    }

    private func pressSend(near composer: AXUIElement) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try Task.checkCancellation()
            if let button = AX.findSendButton(
                in: window, near: composer, configuration: configuration
            ), AX.pressOrClick(button) {
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw AppError.invalidRequest("没有找到 ChatGPT 发送按钮，提示词未发送。")
    }

    private func waitForComposerToClear(_ composer: AXUIElement) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            try Task.checkCancellation()
            let value = AX.textValue(composer, kAXValueAttribute) ?? ""
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AppError.invalidRequest(
            "已点击发送，但输入框没有清空，发送状态无法确认。为避免重复发送，讨论已停止。"
        )
    }

    private func waitForResponse(
        baselineCopyCount: Int,
        prompt: String
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(configuration.responseTimeout)
        var stableCandidate: String?
        var stableCount = 0

        while Date() < deadline {
            try Task.checkCancellation()
            let generating = AX.hasGeneratingControl(
                in: window, configuration: configuration
            )
            let copyButtons = AX.copyButtons(in: window, configuration: configuration)

            if !generating, copyButtons.count > baselineCopyCount,
               let response = AX.copyResponse(
                   using: copyButtons.last!, pid: application.processIdentifier
               ),
               !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               AX.normalized(response) != AX.normalized(prompt) {
                if response == stableCandidate {
                    stableCount += 1
                } else {
                    stableCandidate = response
                    stableCount = 1
                }
                if stableCount >= 2 { return response }
            }
            try await Task.sleep(for: configuration.pollInterval)
        }

        throw AppError.invalidRequest(
            "ChatGPT 在 \(Int(configuration.responseTimeout)) 秒内没有产生可确认的完整回复。"
        )
    }

    private func raise() throws {
        guard !application.isTerminated else {
            throw AppError.invalidRequest("讨论使用的 Chrome 已关闭。")
        }
        _ = application.activate(options: [.activateAllWindows])
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw AppError.invalidRequest("无法前置讨论成员对应的 Chrome 窗口。")
        }
    }

    private func rememberVerified(_ account: String) {
        verifiedAccount = account
    }

    private static func markedURL(_ source: URL, marker: String) -> URL? {
        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        components?.fragment = "airunner_discussion=\(marker)"
        return components?.url
    }
}

// MARK: - 局部 AX 工具

private enum AX {
    static func findWindow(
        in application: NSRunningApplication,
        documentContaining marker: String
    ) -> AXUIElement? {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        return children(root, attribute: kAXWindowsAttribute).first { window in
            let document = string(window, kAXDocumentAttribute) ?? ""
            return document.localizedCaseInsensitiveContains(marker)
        }
    }

    static func findComposer(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration
    ) -> AXUIElement? {
        let candidates = collect(in: root, configuration: configuration) { element in
            let role = string(element, kAXRoleAttribute) ?? ""
            guard role == "AXTextArea" || role == "AXTextField" else { return false }
            let text = searchableText(element)
            if text.contains("search") || text.contains("搜索") { return false }
            let editable = bool(element, kAXEnabledAttribute) != false
            let semantic = ["prompt-textarea", "message", "消息", "询问", "chatgpt"]
                .contains { text.contains($0) }
            return editable && (semantic || role == "AXTextArea")
        }
        return candidates.max { composerScore($0) < composerScore($1) }
    }

    static func findAccountButton(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration
    ) -> AXUIElement? {
        let hints = [
            "open profile menu", "open account menu", "profile menu", "account menu",
            "个人资料菜单", "账户菜单", "帐号菜单", "账号菜单", "用户菜单"
        ]
        return collect(in: root, configuration: configuration) { element in
            guard (string(element, kAXRoleAttribute) ?? "") == "AXButton" else { return false }
            let text = searchableText(element)
            return hints.contains { text.contains($0) }
        }.last
    }

    static func findSendButton(
        in root: AXUIElement,
        near composer: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration
    ) -> AXUIElement? {
        let composerFrame = frame(composer)
        let candidates = collect(in: root, configuration: configuration) { element in
            guard (string(element, kAXRoleAttribute) ?? "") == "AXButton",
                  bool(element, kAXEnabledAttribute) != false else { return false }
            let text = searchableText(element)
            let semantic = ["send", "发送", "submit", "提交", "composer-submit"]
                .contains { text == $0 || text.contains($0) }
            guard semantic else { return false }
            guard let composerFrame, let buttonFrame = frame(element) else { return true }
            return composerFrame.insetBy(dx: -500, dy: -220).intersects(buttonFrame)
        }
        return candidates.max { sendScore($0, composer: composerFrame) < sendScore($1, composer: composerFrame) }
    }

    static func hasGeneratingControl(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration
    ) -> Bool {
        let exact = [
            "stop generating", "停止生成", "stop streaming", "停止回答", "停止响应"
        ]
        return collect(in: root, configuration: configuration) { element in
            guard (string(element, kAXRoleAttribute) ?? "") == "AXButton" else { return false }
            let text = searchableText(element)
            return exact.contains { text.contains($0) }
        }.isEmpty == false
    }

    static func copyButtons(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration
    ) -> [AXUIElement] {
        collect(in: root, configuration: configuration) { element in
            guard (string(element, kAXRoleAttribute) ?? "") == "AXButton" else { return false }
            let text = searchableText(element)
            return text == "copy" || text == "复制" || text == "复制回答" || text == "copy response"
        }
    }

    static func copyResponse(using button: AXUIElement, pid: pid_t) -> String? {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
        guard pressOrClick(button) else { return nil }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let value = pasteboard.string(forType: .string), !value.isEmpty { return value }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    static func allTexts(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration
    ) -> [String] {
        collect(in: root, configuration: configuration) { _ in true }.flatMap { element in
            [
                string(element, kAXTitleAttribute),
                textValue(element, kAXValueAttribute),
                string(element, kAXDescriptionAttribute),
                string(element, kAXIdentifierAttribute),
            ].compactMap { $0 }
        }
    }

    static func identityMatches(_ text: String, expected: String) -> Bool {
        normalized(text).contains(normalized(expected))
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    static func pressOrClick(_ element: AXUIElement) -> Bool {
        if CodexLoginAutomator.clickCenter(element) { return true }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func postPaste(to pid: pid_t) {
        postKey(0x09, flags: .maskCommand, to: pid)
    }

    static func postEscape(to pid: pid_t) {
        postKey(0x35, flags: [], to: pid)
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags; up.flags = flags
        down.postToPid(pid); up.postToPid(pid)
    }

    static func textValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw else { return nil }
        if let value = raw as? String { return value }
        if let value = raw as? NSAttributedString { return value.string }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return nil
        }
        return raw as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let number = raw as? NSNumber else { return nil }
        return number.boolValue
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        CodexLoginAutomator.frame(of: element)
    }

    private static func searchableText(_ element: AXUIElement) -> String {
        normalized([
            string(element, kAXTitleAttribute),
            string(element, kAXDescriptionAttribute),
            string(element, kAXIdentifierAttribute),
            string(element, kAXPlaceholderValueAttribute),
        ].compactMap { $0 }.joined(separator: " "))
    }

    private static func composerScore(_ element: AXUIElement) -> Double {
        let text = searchableText(element)
        var score = 0.0
        if text.contains("prompt-textarea") { score += 1000 }
        if text.contains("message") || text.contains("消息") { score += 500 }
        if let rect = frame(element) {
            score += Double(rect.minY) + min(Double(rect.width), 800) * 0.1
        }
        return score
    }

    private static func sendScore(_ element: AXUIElement, composer: CGRect?) -> Double {
        guard let a = frame(element), let composer else { return 0 }
        let dx = a.midX - composer.maxX
        let dy = a.midY - composer.midY
        return -sqrt(dx * dx + dy * dy)
    }

    private static func children(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return []
        }
        return raw as? [AXUIElement] ?? []
    }

    private static func collect(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration,
        matching predicate: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var budget = configuration.traversalNodeBudget
        walk(
            root, depth: 0, maxDepth: configuration.traversalMaxDepth,
            budget: &budget, result: &result, matching: predicate
        )
        return result
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        budget: inout Int,
        result: inout [AXUIElement],
        matching predicate: (AXUIElement) -> Bool
    ) {
        guard budget > 0, depth <= maxDepth else { return }
        budget -= 1
        if predicate(element) { result.append(element) }
        for child in children(element, attribute: kAXChildrenAttribute) {
            walk(
                child, depth: depth + 1, maxDepth: maxDepth,
                budget: &budget, result: &result, matching: predicate
            )
        }
    }
}

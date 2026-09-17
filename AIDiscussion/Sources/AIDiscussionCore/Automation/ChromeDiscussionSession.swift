import AppKit
import ApplicationServices
import Foundation

/// 真实 ChatGPT 网页讨论会话的参数。
public struct ChromeDiscussionSessionConfiguration: Sendable, Equatable {
    public var browserKind: ChromeProfileScanner.ChromeKind = .chrome
    public var chatGPTURL: URL = URL(string: "https://chatgpt.com/")!
    public var windowOpenTimeout: TimeInterval = 45
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
    private var isWindowsVisible: Bool = false

    public init(configuration: ChromeDiscussionSessionConfiguration = .default) {
        self.configuration = configuration
    }

    /// 切换所有被管理的 Chrome 窗口是否在屏幕内显示（默认 false 为屏幕外完全静默隐形）
    public func setAllVisible(_ visible: Bool) {
        self.isWindowsVisible = visible
        for session in sessions.values {
            session.setWindowVisible(visible)
        }
    }

    /// 当"窗口已显示"模式下，将正在发言的成员窗口提升到 Chrome 窗口栈顶（第一个）。
    /// 仅在 isWindowsVisible = true 时生效；静默模式下窗口在屏幕外，无需也不应调整层级。
    public func raiseSpeakingSession(for participant: DiscussionParticipant) {
        guard isWindowsVisible else { return }
        let profile = participant.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = participant.emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionKey = "\(participant.id)|\(profile)|\(email.lowercased())"
        sessions[sessionKey]?.raiseFront()
    }

    public func session(
        for participant: DiscussionParticipant
    ) async throws -> DiscussionSessionDriving {
        let profile = participant.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = participant.emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionKey = "\(participant.id)|\(profile)|\(email.lowercased())"
        if let existing = sessions[sessionKey] {
            if existing.isValid {
                existing.setWindowVisible(isWindowsVisible)
                return existing
            } else {
                sessions.removeValue(forKey: sessionKey)
            }
        }
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
        created.setWindowVisible(isWindowsVisible)
        sessions[sessionKey] = created
        return created
    }

    public func reset() {
        sessions.removeAll()
    }
}

/// 一扇已经锁定的 Chrome 窗口。
///
/// AXUIElement 本身没有 Sendable 标注，但所有调用都由串行讨论编排器依次执行；
/// 实例不会在两个成员之间共享。
public final class ChromeDiscussionSession: DiscussionSessionDriving, @unchecked Sendable {
    private let application: NSRunningApplication
    private let window: AXUIElement
    public let profile: ChromeProfile
    private let expectedAccount: String
    private let configuration: ChromeDiscussionSessionConfiguration
    private var verifiedAccount: String?

    public var isValid: Bool {
        guard !application.isTerminated else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid == application.processIdentifier else {
            return false
        }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &raw) == .success else {
            return false
        }
        return true
    }

    private init(
        application: NSRunningApplication,
        window: AXUIElement,
        profile: ChromeProfile,
        expectedAccount: String,
        configuration: ChromeDiscussionSessionConfiguration
    ) {
        self.application = application
        self.window = window
        self.profile = profile
        self.expectedAccount = expectedAccount
        self.configuration = configuration
    }

    public static func open(
        profile: ChromeProfile,
        expectedAccount: String,
        configuration: ChromeDiscussionSessionConfiguration = .default
    ) async throws -> ChromeDiscussionSession {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw AppError.invalidRequest("macOS 辅助功能 (Accessibility) 权限未开启，请在「系统设置 -> 隐私与安全性 -> 辅助功能」中为 AIDiscussion 开启授权。")
        }

        // 1. 优先在已运行的 Chrome 窗口中寻找匹配该账号或 Profile 的已有窗口 (实现即时复用，彻底避免重复弹窗与超时)
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: configuration.browserKind.rawValue
        ).first(where: { !$0.isTerminated }) {
            for window in AX.windows(in: app) {
                let title = AX.string(window, kAXTitleAttribute) ?? ""
                let doc = AX.string(window, kAXDocumentAttribute) ?? ""
                let matchesAccount = AX.identityMatches(title, expected: expectedAccount)
                    || AX.identityMatches(doc, expected: expectedAccount)
                    || (!profile.displayName.isEmpty && AX.identityMatches(title, expected: profile.displayName))
                let isChatGPT = doc.localizedCaseInsensitiveContains("chatgpt")
                    || doc.localizedCaseInsensitiveContains("openai")
                    || title.localizedCaseInsensitiveContains("chatgpt")
                if matchesAccount && isChatGPT {
                    let session = ChromeDiscussionSession(
                        application: app,
                        window: window,
                        profile: profile,
                        expectedAccount: expectedAccount,
                        configuration: configuration
                    )
                    do {
                        // 快速探测已有窗口是否就绪可用（3秒轻量级探测），若该已有窗口卡死、未加载或不含输入框，则尝试下一个或回退至新开干净窗口
                        try await session.waitUntilPageReady(timeout: 3.0)
                        session.setWindowVisible(false)
                        return session
                    } catch {
                        continue
                    }
                }
            }
        }

        // 2. 若没有现成匹配的窗口，生成标记并请求启动/打开窗口
        let marker = UUID().uuidString.lowercased()
        guard let markedURL = markedURL(configuration.chatGPTURL, marker: marker) else {
            throw AppError.invalidRequest("ChatGPT 地址无效：\(configuration.chatGPTURL.absoluteString)")
        }

        let existingHashes: Set<CFHashCode>
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: configuration.browserKind.rawValue
        ).first(where: { !$0.isTerminated }) {
            existingHashes = Set(AX.windows(in: app).map { CFHash($0 as CFTypeRef) })
        } else {
            existingHashes = []
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
            ).first(where: { !$0.isTerminated }) {
                // A. 优先匹配带一次性 marker 的窗口
                if let target = AX.findWindow(in: app, documentContaining: marker) {
                    let session = ChromeDiscussionSession(
                        application: app,
                        window: target,
                        profile: profile,
                        expectedAccount: expectedAccount,
                        configuration: configuration
                    )
                    try await session.waitUntilPageReady()
                    session.setWindowVisible(false)
                    return session
                }

                // B. 遍历所有窗口，检查匹配账号或新弹出的 ChatGPT 窗口
                for window in AX.windows(in: app) {
                    let hash = CFHash(window as CFTypeRef)
                    let title = AX.string(window, kAXTitleAttribute) ?? ""
                    let doc = AX.string(window, kAXDocumentAttribute) ?? ""
                    let isChatGPT = doc.localizedCaseInsensitiveContains("chatgpt")
                        || doc.localizedCaseInsensitiveContains("openai")
                        || title.localizedCaseInsensitiveContains("chatgpt")

                    let matchesAccount = AX.identityMatches(title, expected: expectedAccount)
                        || AX.identityMatches(doc, expected: expectedAccount)
                        || (!profile.displayName.isEmpty && AX.identityMatches(title, expected: profile.displayName))

                    let isNewChatGPTWindow = !existingHashes.contains(hash) && isChatGPT

                    if isChatGPT && (matchesAccount || isNewChatGPTWindow) {
                        let session = ChromeDiscussionSession(
                            application: app,
                            window: window,
                            profile: profile,
                            expectedAccount: expectedAccount,
                            configuration: configuration
                        )
                        do {
                            try await session.waitUntilPageReady(timeout: 4.0)
                            session.setWindowVisible(false)
                            return session
                        } catch {
                            continue
                        }
                    }
                }
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
        try checkSessionHealth()

        // 0. 优先检查窗口标题 (Chrome 标题通常包含: "... - Google Chrome - <account>")
        if let windowTitle = AX.string(window, kAXTitleAttribute),
           AX.identityMatches(windowTitle, expected: expected) {
            rememberVerified(expected)
            return true
        }

        if AX.allTexts(in: window, configuration: configuration)
            .contains(where: { AX.identityMatches($0, expected: expected) }) {
            rememberVerified(expected)
            return true
        }

        guard let accountButton = AX.findAccountButton(
            in: window, configuration: configuration
        ) else {
            try checkSessionHealth()
            return false
        }
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
        try checkSessionHealth()
        return false
    }

    public func currentAccount() async throws -> String? {
        if let verified = verifiedAccount {
            return verified
        }
        if let title = AX.string(window, kAXTitleAttribute) {
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 2 {
                return parts.last?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    public func send(prompt: String) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidRequest("讨论提示词为空，已停止发送。")
        }
        try raise()
        try checkSessionHealth()

        // 1. 发送前先守卫：确保前一轮思考或回答已彻底完成，解除生成锁定
        try await waitUntilReadyForSend()

        AX.dismissPromptsAndModals(
            in: window, pid: application.processIdentifier, configuration: configuration
        )

        guard try await verifyIdentity(emailHint: expectedAccount) else {
            throw AppError.invalidRequest(
                "目标 Chrome 窗口无法确认账号 \(expectedAccount)，已停止发送。"
            )
        }

        // 2. 自动检测并切换网页端思考强度为“高”（深度思考模式）
        AX.ensureHighReasoningEffort(
            in: window, configuration: configuration, pid: application.processIdentifier
        )

        let composer = try await waitForComposer()
        if let existing = AX.textValue(composer, kAXValueAttribute),
           !AX.isComposerEmptyOrPlaceholder(existing) {
            await DiscussionEventAutomator.clearField(composer, pid: application.processIdentifier)
            try await Task.sleep(for: .milliseconds(150))
        }

        let baselineCopyCount = AX.copyButtons(
            in: window, configuration: configuration
        ).count
        try await insert(prompt, into: composer)
        try await executeSend(composer: composer)
        return try await waitForResponse(
            baselineCopyCount: baselineCopyCount,
            prompt: prompt
        )
    }

    private func waitUntilReadyForSend() async throws {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            try Task.checkCancellation()
            if !AX.hasGeneratingControl(in: window, configuration: configuration) {
                return
            }
            try await Task.sleep(for: .milliseconds(800))
        }
    }

    // MARK: - 页面操作

    private func checkSessionHealth() throws {
        if let doc = AX.string(window, kAXDocumentAttribute) {
            let lower = doc.lowercased()
            if lower.contains("/auth/") || lower.contains("/uc/") || lower.contains("/login")
                || lower.contains("/mfa") || lower.contains("/challenge") {
                let loginURL = URL(string: doc) ?? URL(string: "https://chatgpt.com/auth/login")!
                throw AppError.loginRequired(
                    DiscussionLoginIssue(
                        participantName: "",
                        profileDirectory: profile.directoryName,
                        accountHint: expectedAccount,
                        loginURL: loginURL
                    )
                )
            }
        }
        if let webArea = AX.findWebArea(in: window) {
            let buttons = AX.allButtonsText(in: webArea)
            if buttons.contains(where: { $0 == "登录" || $0 == "log in" || $0 == "sign in" }) {
                throw AppError.loginRequired(
                    DiscussionLoginIssue(
                        participantName: "",
                        profileDirectory: profile.directoryName,
                        accountHint: expectedAccount,
                        loginURL: URL(string: "https://chatgpt.com/auth/login")!
                    )
                )
            }
        }
    }

    private func waitUntilPageReady(timeout: TimeInterval? = nil) async throws {
        try checkSessionHealth()
        AX.dismissPromptsAndModals(in: window, pid: application.processIdentifier, configuration: configuration)
        _ = try await waitForComposer(timeout: timeout ?? configuration.pageReadyTimeout)
        try checkSessionHealth()
    }

    private func waitForComposer(timeout: TimeInterval? = nil) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout ?? configuration.pageReadyTimeout)
        var ticks = 0
        while Date() < deadline {
            try Task.checkCancellation()
            if let composer = AX.findComposer(in: window, configuration: configuration) {
                return composer
            }
            try checkSessionHealth()
            ticks += 1
            if ticks >= 3 {
                AX.dismissPromptsAndModals(in: window, pid: application.processIdentifier, configuration: configuration)
            }
            try await Task.sleep(for: configuration.pollInterval)
        }
        try checkSessionHealth()
        throw AppError.invalidRequest(
            "ChatGPT 页面已打开，但没有找到消息输入框（页面加载超时或被遮挡）。"
        )
    }

    private func insert(_ text: String, into composer: AXUIElement) async throws {
        // 先确保清理页面可能的营销浮层遮挡
        AX.dismissPromptsAndModals(in: window, pid: application.processIdentifier, configuration: configuration)

        _ = AXUIElementSetAttributeValue(
            composer, kAXFocusedAttribute as CFString, true as CFTypeRef
        )
        _ = AX.pressOrClick(composer)
        try await Task.sleep(for: .milliseconds(100))

        // 1. 优先尝试直接通过 AX 属性写入（完全不碰系统剪贴板，最高效最稳定）
        let status = AXUIElementSetAttributeValue(
            composer, kAXValueAttribute as CFString, text as CFTypeRef
        )
        if status == .success {
            try await Task.sleep(for: .milliseconds(150))
            let actual = AX.composerText(in: composer)
            if AX.normalized(actual).contains(AX.normalized(text)) || actual.count >= min(text.count, 20) {
                // 向 Chrome 进程投递轻量级的 Space + Backspace，激活 React DOM input 监听
                AX.postKey(0x31, flags: [], to: application.processIdentifier) // Space
                try? await Task.sleep(for: .milliseconds(30))
                AX.postKey(0x33, flags: [], to: application.processIdentifier) // Backspace
                try? await Task.sleep(for: .milliseconds(80))
                return
            }
        }

        // 2. 尝试选区替换写入
        let selStatus = AXUIElementSetAttributeValue(
            composer, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        if selStatus == .success {
            try await Task.sleep(for: .milliseconds(150))
            let actual = AX.composerText(in: composer)
            if AX.normalized(actual).contains(AX.normalized(text)) || actual.count >= min(text.count, 20) {
                return
            }
        }

        // 3. 剪贴板粘贴，但使用 PasteboardGuard 完整备份并在离开时立即复原用户剪贴板
        let pbGuard = PasteboardGuard()
        defer { pbGuard.restore() }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw AppError.invalidRequest("无法准备讨论提示词。")
        }

        AX.postPaste(to: application.processIdentifier)
        let pasteDeadline = Date().addingTimeInterval(3.0)
        while Date() < pasteDeadline {
            try Task.checkCancellation()
            let actual = AX.composerText(in: composer)
            if AX.normalized(actual).contains(AX.normalized(text)) || actual.count >= min(text.count, 20) {
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }

        // 4. 再次检查输入框内实际内容：只要内容已大体存在，直接放行让 executeSend 发送
        let finalCheck = AX.composerText(in: composer)
        if !finalCheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        throw AppError.invalidRequest("提示词没有完整写入 ChatGPT 输入框，已停止发送。")
    }

    private func executeSend(composer: AXUIElement) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try Task.checkCancellation()

            // 成功标志 1：页面已经开始生成回复（出现了停止生成按钮）
            if AX.hasGeneratingControl(in: window, configuration: configuration) {
                return
            }

            // 成功标志 2：输入框已经清空或还原为占位符
            let currentVal = AX.textValue(composer, kAXValueAttribute) ?? ""
            if AX.isComposerEmptyOrPlaceholder(currentVal) {
                return
            }

            // 动作 A：优先点击/按压发送按钮
            if let button = AX.findSendButton(
                in: window, near: composer, configuration: configuration
            ) {
                _ = AX.pressOrClick(button)
            }

            try await Task.sleep(for: .milliseconds(600))
            if AX.hasGeneratingControl(in: window, configuration: configuration) {
                return
            }
            let checkVal = AX.textValue(composer, kAXValueAttribute) ?? ""
            if AX.isComposerEmptyOrPlaceholder(checkVal) {
                return
            }

            // 动作 B：键盘 Return (Enter) 键提交回退
            _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, true as CFTypeRef)
            AX.postReturn(to: application.processIdentifier)

            try await Task.sleep(for: .milliseconds(800))
        }

        // 超时最后检查一次生成状态
        if AX.hasGeneratingControl(in: window, configuration: configuration) {
            return
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

            // 若仍在思考或流式生成中，绝对不结算采样，强制重置稳定计数器
            if generating {
                stableCandidate = nil
                stableCount = 0
                try await Task.sleep(for: configuration.pollInterval)
                continue
            }

            var candidate: String?
            // 1. 优先且首选：直接从 AX 树提取最新 Assistant 回复
            if let response = AX.extractLatestAssistantText(
                in: window, configuration: configuration, prompt: prompt
            ), AX.isValidAssistantResponse(response, prompt: prompt) {
                candidate = response
            } else {
                // 2. 备用兜底：仅在语义树未命中时，尝试一次无障碍 AXPress 复制
                let copyButtons = AX.copyButtons(in: window, configuration: configuration)
                if copyButtons.count > baselineCopyCount,
                   let response = AX.copyResponse(
                       using: copyButtons.last!, pid: application.processIdentifier
                   ), AX.isValidAssistantResponse(response, prompt: prompt) {
                    candidate = response
                }
            }

            if let response = candidate {
                if response == stableCandidate {
                    stableCount += 1
                } else {
                    stableCandidate = response
                    stableCount = 1
                }
                // 连续 2 次采样完全一致且脱离生成/思考态，确认为最终完整正文
                if stableCount >= 2 { return response }
            } else {
                stableCandidate = nil
                stableCount = 0
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
        guard isValid else {
            throw AppError.invalidRequest("讨论成员对应的 Chrome 窗口已失效或关闭。")
        }
        // 静默运行：绝不抢占前台输入焦点，绝不调用 yieldActivation 与 activateIgnoringOtherApps 强行弹窗
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
    }

    /// 将 Chrome 窗口移出屏幕视野（实现 100% 静默无弹窗后台）或移回主屏幕（供用户随时查看）
    public func setWindowVisible(_ visible: Bool) {
        var point: CGPoint = visible ? CGPoint(x: 100, y: 80) : CGPoint(x: -3000, y: -3000)
        if let posVal = AXValueCreate(.cgPoint, &point) {
            _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if visible {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    /// 将此窗口提升到 Chrome 所有窗口栈的最顶层（不移动位置、不抢 app 焦点）。
    /// 适用于"显示模式"下让正在发言的成员窗口自动跳到第一个，
    /// 用户切换到 Chrome 时直接看到正在输入/思考的那个页面。
    public func raiseFront() {
        guard isValid else { return }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func rememberVerified(_ account: String) {
        verifiedAccount = account
    }

    private static func markedURL(_ source: URL, marker: String) -> URL? {
        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        components?.fragment = "aidiscussion_session=\(marker)"
        return components?.url
    }
}

// MARK: - 局部 AX 工具

enum AX {
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
        let searchRoot = findWebArea(in: root) ?? root
        var queue = [searchRoot]
        var candidates: [AXUIElement] = []
        var budget = 1500
        while !queue.isEmpty && budget > 0 {
            let element = queue.removeFirst()
            budget -= 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == "AXTextArea" || role == "AXTextField" {
                let text = searchableText(element)
                let isExcluded: Bool
                if role == "AXTextField" {
                    isExcluded = text.contains("地址") || text.contains("address") || text.contains("omnibox")
                        || text.contains("search") || text.contains("搜索")
                } else {
                    isExcluded = text.contains("地址") || text.contains("address") || text.contains("omnibox")
                }
                let editable = bool(element, kAXEnabledAttribute) != false
                let semantic = ["prompt-textarea", "message", "消息", "询问", "chatgpt", "聊天", "与 chatgpt 聊天", "问问 chatgpt"]
                    .contains { text.contains($0) }
                if !isExcluded && editable && (semantic || role == "AXTextArea") {
                    candidates.append(element)
                }
            }
            let subrole = string(element, kAXSubroleAttribute) ?? ""
            if role == "AXGroup" && (subrole == "AXNavigation" || searchableText(element).contains("历史记录")) {
                continue
            }
            queue.append(contentsOf: children(element, attribute: kAXChildrenAttribute))
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
        let searchRoot = findWebArea(in: root) ?? root
        let composerFrame = frame(composer)
        var candidates: [AXUIElement] = []
        var queue = [searchRoot]
        var visited = 0

        while !queue.isEmpty && visited < 1500 {
            visited += 1
            let el = queue.removeFirst()
            let r = string(el, kAXRoleAttribute) ?? ""

            if r == "AXButton", bool(el, kAXEnabledAttribute) != false {
                let text = searchableText(el)
                let semantic = ["send", "发送", "submit", "提交", "composer-submit"]
                    .contains { text == $0 || text.contains($0) }
                if semantic {
                    if let composerFrame, let buttonFrame = frame(el) {
                        if composerFrame.insetBy(dx: -500, dy: -220).intersects(buttonFrame) {
                            candidates.append(el)
                        }
                    } else {
                        candidates.append(el)
                    }
                }
            }

            if r != "AXNavigation" {
                queue.append(contentsOf: children(el, attribute: kAXChildrenAttribute))
            }
        }

        return candidates.max { sendScore($0, composer: composerFrame) < sendScore($1, composer: composerFrame) }
    }

    static func hasGeneratingControl(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration
    ) -> Bool {
        let searchRoot = findWebArea(in: root) ?? root
        let stopHints = [
            "stop generating", "停止生成", "stop streaming", "停止回答", "停止响应",
            "停止思考", "stop reasoning", "停止", "stop"
        ]

        var queue = [searchRoot]
        var visited = 0

        while !queue.isEmpty && visited < 1500 {
            visited += 1
            let el = queue.removeFirst()
            let r = string(el, kAXRoleAttribute) ?? ""

            if r == "AXButton" {
                let text = searchableText(el)
                if stopHints.contains(where: { text == $0 || text.contains($0) }) {
                    return true
                }
            }

            if r == "AXStaticText" || r == "AXHeading" || r == "AXButton" {
                let text = (textValue(el, kAXValueAttribute) ?? string(el, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if text == "正在思考" || text == "thinking..." || text == "●" {
                    return true
                }
                if text.contains("正在搜索")
                    || text.contains("搜索网站")
                    || text.contains("搜索网页")
                    || text.contains("searching the web")
                    || text.contains("searching...") {
                    return true
                }
            }

            if r != "AXNavigation" {
                queue.append(contentsOf: children(el, attribute: kAXChildrenAttribute))
            }
        }

        return false
    }

    static func isValidAssistantResponse(_ text: String, prompt: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return false }

        let lower = trimmed.lowercased()
        // 排除思考与搜索过渡占位符
        let transientPlaceholders = [
            "正在思考", "thinking", "thinking...", "●", "已思考", "thought for",
            "正在搜索", "searching", "searching the web", "searching...", "已搜索", "searched",
            "搜索网站", "搜索网页"
        ]
        if transientPlaceholders.contains(where: { lower == $0 || (lower.hasPrefix($0) && trimmed.count < 40) }) {
            return false
        }

        // 排除 ChatGPT 常见瞬态错误
        if lower.contains("something went wrong while generating")
            || lower.contains("if this issue persists please") {
            return false
        }

        // 排除营销/推广浮层与底部推荐卡片文案（如 ChatGPT Work / Canvas 宣传语）
        let marketingBanners = [
            "精美的文档", "演示文稿", "电子表格", "chatgpt work", "在 chatgpt work 中",
            "打造成精美的文档", "将你的工作内容打造成"
        ]
        if marketingBanners.contains(where: { lower.contains($0) }) {
            return false
        }

        // 排除单纯的提示词回显
        if normalized(trimmed) == normalized(prompt) {
            return false
        }

        return true
    }

    /// 自动检测并关闭营销/引导/模板等推广浮窗（如“将你的工作内容打造成精美的文档…”）
    static func dismissPromptsAndModals(
        in root: AXUIElement,
        pid: pid_t,
        configuration: ChromeDiscussionSessionConfiguration
    ) {
        // 核心防护：必须且仅在 AXWebArea 网页内容区域内部查找，严禁触碰外部浏览器窗口或标签页按钮！
        guard let webArea = findWebArea(in: root) else { return }

        let dismissHints = [
            "关闭", "知道了", "稍后", "以后再说", "跳过", "close", "dismiss",
            "not now", "got it", "取消", "skip", "stay logged out", "保持退出状态"
        ]

        var queue = [webArea]
        var visited = 0
        var buttons: [AXUIElement] = []

        while !queue.isEmpty && visited < 400 {
            visited += 1
            let el = queue.removeFirst()
            let r = string(el, kAXRoleAttribute) ?? ""

            if r == "AXButton" {
                let text = searchableText(el)
                if !text.isEmpty &&
                    !text.contains("侧边栏") &&
                    !text.contains("sidebar") &&
                    !text.contains("标签页") &&
                    !text.contains("tab") &&
                    !text.contains("全屏") {
                    let matched = dismissHints.contains { h in
                        text == h || (text.contains(h) && text.count <= 8)
                    }
                    if matched {
                        buttons.append(el)
                    }
                }
            }

            if r != "AXNavigation" {
                queue.append(contentsOf: children(el, attribute: kAXChildrenAttribute))
            }
        }

        for button in buttons.prefix(2) {
            _ = pressOrClick(button)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func ensureHighReasoningEffort(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration,
        pid: pid_t
    ) {
        dismissPromptsAndModals(in: root, pid: pid, configuration: configuration)
        let searchRoot = findWebArea(in: root) ?? root

        // 寻找思考强度触发按钮（例如包含“即时”、“低”、“标准”、“思考强度”、“Reasoning”）
        let effortButtons = collect(in: searchRoot, configuration: configuration) { element in
            guard (string(element, kAXRoleAttribute) ?? "") == "AXButton" else { return false }
            let text = searchableText(element)
            // 如果已经是“高”或“深入思考”，无需切换
            if text.contains("深入思考") || text.contains("思考：高") || text.contains("high") {
                return false
            }
            return text.contains("即时")
                || text.contains("思考强度")
                || text.contains("reasoning")
                || text.contains("标准")
                || text.contains("中等")
        }

        guard let button = effortButtons.first else { return }

        // 点击展开思考强度菜单
        if pressOrClick(button) {
            Thread.sleep(forTimeInterval: 0.3)
            let appRoot = AXUIElementCreateApplication(pid)
            // 在应用树中寻找“高”或“深入思考”或“High”选项
            let highOptions = collect(in: appRoot, configuration: configuration) { element in
                let r = string(element, kAXRoleAttribute) ?? ""
                guard r == "AXMenuItem" || r == "AXButton" || r == "AXStaticText" else { return false }
                let text = searchableText(element)
                return text == "高" || text.contains("高 (") || text.contains("深入思考") || text == "high" || text.contains("extended")
            }
            if let target = highOptions.first {
                _ = pressOrClick(target)
            }
        }
    }

    static func copyButtons(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration
    ) -> [AXUIElement] {
        collect(in: root, configuration: configuration) { element in
            guard (string(element, kAXRoleAttribute) ?? "") == "AXButton" else { return false }
            let text = searchableText(element)
            // 排除用户消息复制按钮和代码块复制按钮
            if text.contains("消息") || text.contains("message") || text.contains("提示")
                || text.contains("prompt") || text.contains("代码") || text.contains("code") {
                return false
            }
            return text.contains("复制回复")
                || text.contains("复制回答")
                || text.contains("copy response")
                || text.contains("copy reply")
                || text == "复制"
                || text == "copy"
        }
    }

    static func copyResponse(using button: AXUIElement, pid: pid_t) -> String? {
        let pbGuard = PasteboardGuard()
        defer { pbGuard.restore() }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // 仅使用无障碍 AXPress 动作触发复制，不移动用户鼠标，不抢占物理光标
        if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            let deadline = Date().addingTimeInterval(0.4)
            while Date() < deadline {
                if let value = pasteboard.string(forType: .string),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return nil
    }

    static func extractLatestAssistantText(
        in root: AXUIElement,
        configuration: ChromeDiscussionSessionConfiguration,
        prompt: String? = nil
    ) -> String? {
        let searchRoot = findWebArea(in: root) ?? root

        struct TextElement {
            let role: String
            let text: String
        }

        // 收集 AXWebArea 中所有文本与标题节点
        let elements = collect(in: searchRoot, configuration: configuration) { el in
            let r = string(el, kAXRoleAttribute) ?? ""
            return r == "AXStaticText" || r == "AXHeading"
        }.compactMap { el -> TextElement? in
            let r = string(el, kAXRoleAttribute) ?? ""
            let val = textValue(el, kAXValueAttribute)
                ?? string(el, kAXTitleAttribute)
                ?? string(el, kAXDescriptionAttribute)
            guard let text = val?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return TextElement(role: r, text: text)
        }

        guard !elements.isEmpty else { return nil }

        // 策略 1：定位最后一个明确的 ChatGPT 消息头
        var startIdx: Int?
        for (i, el) in elements.enumerated().reversed() {
            let lower = el.text.lowercased()
            let isDisclaimerOrInput = lower.contains("可能会犯错")
                || lower.contains("核查重要信息")
                || lower.contains("can make mistakes")
                || lower.contains("问问")
                || lower.contains("message")
            if isDisclaimerOrInput { continue }

            // 严格排除营销卡片/功能推广的标题（例如“在 ChatGPT Work 中进一步推进”、“ChatGPT Plus”等）
            let isMarketing = lower.contains("work")
                || lower.contains("plus")
                || lower.contains("team")
                || lower.contains("推进")
                || lower.contains("精美")
                || lower.contains("打造成")
                || lower.contains("新功能")
                || lower.contains("what's new")
                || lower.contains("canvas")
                || lower.contains("探索")
            if isMarketing { continue }

            // 真实的 ChatGPT 回复头
            if lower.starts(with: "chatgpt 说") || lower.starts(with: "chatgpt said") {
                startIdx = i
                break
            }
            if el.role == "AXHeading" && (lower == "chatgpt" || lower == "chatgpt:" || lower == "chatgpt：") {
                startIdx = i
                break
            }
        }

        // 策略 2：若无显式 Header，以 prompt 前缀定位用户提问之后的内容
        if startIdx == nil, let prompt = prompt {
            let normPrompt = normalized(prompt)
            let promptPrefix = String(normPrompt.prefix(20))
            if !promptPrefix.isEmpty {
                startIdx = elements.lastIndex { el in
                    normalized(el.text).contains(promptPrefix)
                }
            }
        }

        guard let validStart = startIdx, validStart + 1 < elements.count else {
            return nil
        }

        var parts: [String] = []
        for el in elements[(validStart + 1)...] {
            let lower = el.text.lowercased()
            // 遇到页面底部免责声明、输入框、或底部营销推荐卡片时立即截断，防止混入外部提示
            if lower.contains("可能会犯错")
                || lower.contains("核查重要信息")
                || lower.contains("can make mistakes")
                || lower.contains("问问 chatgpt")
                || lower.contains("message chatgpt")
                || lower.contains("给 chatgpt 发送消息")
                || lower.contains("chatgpt work")
                || lower.contains("在 chatgpt work")
                || lower.contains("打造成精美的文档") {
                break
            }
            // 遇到下一个“你说：”或“ChatGPT 说：”等对话块头部时截断
            if el.role == "AXHeading" && (lower.starts(with: "你说") || lower.starts(with: "you said") || lower.starts(with: "chatgpt")) {
                break
            }
            // 排除与 Header 完全重复的文本
            if el.text == elements[validStart].text { continue }
            // 排除营销文本自身
            if lower.contains("精美的文档") || lower.contains("打造成精美的文档") {
                continue
            }
            // 排除按钮文本
            if el.text == "复制" || el.text == "copy" || el.text == "分享" || el.text == "share" {
                continue
            }
            parts.append(el.text)
        }

        guard !parts.isEmpty else { return nil }
        return combineContentParts(parts)
    }

    static func combineContentParts(_ parts: [String]) -> String {
        var combined = ""
        for (idx, part) in parts.enumerated() {
            if idx == 0 {
                combined = part
                continue
            }
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPart.isEmpty else { continue }

            let firstChar = trimmedPart.first!
            let isPunctuation = "，。！？、：；”’）】》…,".contains(firstChar)
            let isListMarker = trimmedPart.starts(with: "- ")
                || trimmedPart.starts(with: "* ")
                || (firstChar.isNumber && trimmedPart.contains("."))

            let lastChar = combined.trimmingCharacters(in: .whitespacesAndNewlines).last
            let lastEndsParagraph = lastChar.map { "。！？；：\n".contains($0) } ?? false

            if isPunctuation {
                combined += trimmedPart
            } else if isListMarker || lastEndsParagraph {
                combined += "\n" + trimmedPart
            } else if let last = lastChar, (last.isASCII && firstChar.isASCII) {
                combined += " " + trimmedPart
            } else {
                combined += trimmedPart
            }
        }
        return combined
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
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
        return DiscussionEventAutomator.clickCenter(element)
    }

    static func composerText(in composer: AXUIElement) -> String {
        var texts: [String] = []
        if let val = textValue(composer, kAXValueAttribute) {
            texts.append(val)
        }
        for child in children(composer, attribute: kAXChildrenAttribute) {
            if let val = textValue(child, kAXValueAttribute) {
                texts.append(val)
            }
            if let title = string(child, kAXTitleAttribute) {
                texts.append(title)
            }
            if let desc = string(child, kAXDescriptionAttribute) {
                texts.append(desc)
            }
        }
        return texts.joined(separator: " ")
    }

    static func postPaste(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.02)

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)

        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.02)

        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        cmdUp?.flags = []
        cmdUp?.postToPid(pid)
    }

    static func postReturn(to pid: pid_t) {
        postKey(0x24, flags: [], to: pid)
    }

    static func postEscape(to pid: pid_t) {
        postKey(0x35, flags: [], to: pid)
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
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

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
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
        DiscussionEventAutomator.frame(of: element)
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

    static func windows(in application: NSRunningApplication) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        return children(root, attribute: kAXWindowsAttribute)
    }

    static func findWebArea(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        while !queue.isEmpty {
            let el = queue.removeFirst()
            var rRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &rRef) == .success,
               let r = rRef as? String, r == "AXWebArea" {
                return el
            }
            queue.append(contentsOf: children(el, attribute: kAXChildrenAttribute))
        }
        return nil
    }

    static func allButtonsText(in root: AXUIElement, budget: Int = 400) -> [String] {
        var result: [String] = []
        var queue = [root]
        var remaining = budget
        while !queue.isEmpty && remaining > 0 {
            let el = queue.removeFirst()
            remaining -= 1
            var rRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &rRef) == .success,
               let r = rRef as? String, r == "AXButton" {
                result.append(searchableText(el))
            }
            queue.append(contentsOf: children(el, attribute: kAXChildrenAttribute))
        }
        return result
    }

    static func isComposerEmptyOrPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        let placeholders = [
            "问问 chatgpt", "message chatgpt", "ask chatgpt",
            "给 chatgpt 发送消息", "向 chatgpt 发送消息", "与 chatgpt 聊天",
            "问问"
        ]
        return placeholders.contains { lower == $0 || lower.contains($0) }
    }
}

// MARK: - 剪贴板保护

/// 剪贴板守卫：在自动化操作需要临时借用剪贴板时，完整保存并无缝还原用户的原有剪贴板内容。
final class PasteboardGuard: @unchecked Sendable {
    private struct Item {
        let types: [(NSPasteboard.PasteboardType, Data)]
    }
    private let savedItems: [Item]

    init() {
        let pb = NSPasteboard.general
        if let items = pb.pasteboardItems {
            self.savedItems = items.map { item in
                let types = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type, data)
                }
                return Item(types: types)
            }
        } else {
            self.savedItems = []
        }
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !savedItems.isEmpty else { return }
        var newItems: [NSPasteboardItem] = []
        for item in savedItems {
            let pbItem = NSPasteboardItem()
            for (type, data) in item.types {
                pbItem.setData(data, forType: type)
            }
            newItems.append(pbItem)
        }
        pb.writeObjects(newItems)
    }
}

// MARK: - CGEvent / AX 自动化辅助

enum DiscussionEventAutomator {

    static func rawAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return result == .success ? value : nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let rawPosition = rawAttribute(element, kAXPositionAttribute as CFString),
              let rawSize = rawAttribute(element, kAXSizeAttribute as CFString) else { return nil }
        let positionValue = unsafeDowncast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeDowncast(rawSize, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    static func clickCenter(_ element: AXUIElement) -> Bool {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0,
              let frame = frame(of: element), frame.width > 1, frame.height > 1 else {
            return false
        }
        return click(point: CGPoint(x: frame.midX, y: frame.midY), to: pid)
    }

    @discardableResult
    static func click(point: CGPoint, to pid: pid_t) -> Bool {
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return false
        }
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.04)
        up.postToPid(pid)
        return true
    }

    static func clearField(_ element: AXUIElement, pid: pid_t) async {
        let empty = "" as CFString
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, empty)
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, empty)

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let aDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        aDown?.flags = .maskCommand
        aDown?.postToPid(pid)
        let aUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        aUp?.flags = .maskCommand
        aUp?.postToPid(pid)
        try? await Task.sleep(for: .milliseconds(60))

        let bsDown = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
        bsDown?.postToPid(pid)
        let bsUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
        bsUp?.postToPid(pid)
        try? await Task.sleep(for: .milliseconds(60))
    }

    static func typeText(_ text: String, to pid: pid_t, interval: Duration = .milliseconds(15)) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for scalar in text.unicodeScalars {
            var chars = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            chars.withUnsafeMutableBufferPointer { buffer in
                down?.keyboardSetUnicodeString(
                    stringLength: buffer.count, unicodeString: buffer.baseAddress
                )
            }
            down?.postToPid(pid)

            try? await Task.sleep(for: interval)

            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            chars.withUnsafeMutableBufferPointer { buffer in
                up?.keyboardSetUnicodeString(
                    stringLength: buffer.count, unicodeString: buffer.baseAddress
                )
            }
            up?.postToPid(pid)
            try? await Task.sleep(for: interval)
        }
    }
}


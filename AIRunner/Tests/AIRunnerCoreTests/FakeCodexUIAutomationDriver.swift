import Foundation
@testable import AIRunnerCore

/// 可编程的假 UI 驱动。
///
/// 存在的意义: Codex 编排逻辑的**全部**分支 (唯一匹配 / 歧义 / 验证失败 / 忙碌 /
/// composer 缺失 / 发送失败 …) 都应该能被测试覆盖, 而不需要真机、不需要辅助功能权限、
/// 也不依赖 Codex 的具体 UI 结构。
///
/// ## 为什么状态访问要包一层
///
/// `CodexUIAutomationDriving` 的方法都是 `async`。Swift 6 禁止在 async 函数体内
/// 直接调用 `NSLock.lock()` (可能阻塞线程)。所以这里把所有状态读写都收进
/// **同步**私有方法 `read` / `mutate`, async 方法只负责调用它们。
final class FakeCodexUIAutomationDriver: CodexUIAutomationDriving, @unchecked Sendable {

    // MARK: - 状态

    struct Box {
        var permission: AccessibilityPermissionStatus = .granted
        var appRunning = true
        var codexViewPresent = true

        var candidates: [CodexThreadCandidate] = []
        var openContext = CodexOpenThreadContext()
        var busyState: CodexBusyState = .idle
        var anyTaskGenerating = false
        var accountIssue: CodexAccountIssue?
        var taskStoppedSignal = false

        var composerAvailable = true
        var composerEditable = true
        var composerValue: String?
        var insertSucceeds = true
        var sendControlAvailable = true
        var confirmation: SendConfirmation = .composerCleared

        var throwOnLocate: CodexAutomationError?
        var throwOnSend: CodexAutomationError?

        // 调用记录
        var sendCount = 0
        var insertedMessages: [String] = []
        var openedThreads: [String] = []
        var probeCount = 0
        var focusCount = 0
        var activateCount = 0
    }

    private var box = Box()
    private let lock = NSLock()

    private func read<T>(_ body: (Box) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(box)
    }

    private func mutate<T>(_ body: (inout Box) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&box)
    }

    // MARK: - 对外可编程接口（同步，测试直接用）

    var permission: AccessibilityPermissionStatus {
        get { read { $0.permission } }
        set { mutate { $0.permission = newValue } }
    }

    var appRunning: Bool {
        get { read { $0.appRunning } }
        set { mutate { $0.appRunning = newValue } }
    }

    var codexViewPresent: Bool {
        get { read { $0.codexViewPresent } }
        set { mutate { $0.codexViewPresent = newValue } }
    }

    var candidates: [CodexThreadCandidate] {
        get { read { $0.candidates } }
        set { mutate { $0.candidates = newValue } }
    }

    var openContext: CodexOpenThreadContext {
        get { read { $0.openContext } }
        set { mutate { $0.openContext = newValue } }
    }

    var busyState: CodexBusyState {
        get { read { $0.busyState } }
        set { mutate { $0.busyState = newValue } }
    }

    var anyTaskGenerating: Bool {
        get { read { $0.anyTaskGenerating } }
        set { mutate { $0.anyTaskGenerating = newValue } }
    }

    var accountIssue: CodexAccountIssue? {
        get { read { $0.accountIssue } }
        set { mutate { $0.accountIssue = newValue } }
    }

    var taskStoppedSignal: Bool {
        get { read { $0.taskStoppedSignal } }
        set { mutate { $0.taskStoppedSignal = newValue } }
    }

    var composerAvailable: Bool {
        get { read { $0.composerAvailable } }
        set { mutate { $0.composerAvailable = newValue } }
    }

    var composerEditable: Bool {
        get { read { $0.composerEditable } }
        set { mutate { $0.composerEditable = newValue } }
    }

    var composerValue: String? {
        get { read { $0.composerValue } }
        set { mutate { $0.composerValue = newValue } }
    }

    var insertSucceeds: Bool {
        get { read { $0.insertSucceeds } }
        set { mutate { $0.insertSucceeds = newValue } }
    }

    var sendControlAvailable: Bool {
        get { read { $0.sendControlAvailable } }
        set { mutate { $0.sendControlAvailable = newValue } }
    }

    var confirmation: SendConfirmation {
        get { read { $0.confirmation } }
        set { mutate { $0.confirmation = newValue } }
    }

    var throwOnLocate: CodexAutomationError? {
        get { read { $0.throwOnLocate } }
        set { mutate { $0.throwOnLocate = newValue } }
    }

    var throwOnSend: CodexAutomationError? {
        get { read { $0.throwOnSend } }
        set { mutate { $0.throwOnSend = newValue } }
    }

    var sendCount: Int { read { $0.sendCount } }
    var insertedMessages: [String] { read { $0.insertedMessages } }
    var openedThreads: [String] { read { $0.openedThreads } }
    var probeCount: Int { read { $0.probeCount } }
    var activateCount: Int { read { $0.activateCount } }
    var composerFocusCount: Int { read { $0.focusCount } }

    func reset() {
        mutate {
            $0.sendCount = 0
            $0.insertedMessages = []
            $0.openedThreads = []
            $0.probeCount = 0
            $0.focusCount = 0
            $0.activateCount = 0
        }
    }

    /// 让"找到一个精确匹配的线程"成为可用的初始状态。
    func configureHappyPath(
        title: String = "长对话任务",
        projectName: String = "airunner"
    ) {
        let repo = "/Users/dev/\(projectName)"
        mutate {
            $0.candidates = [
                CodexThreadCandidate(
                    title: title,
                    projectName: projectName,
                    repositoryPath: repo,
                    debugPath: "AXWindow > AXOutline > AXRow[0]"
                )
            ]
            $0.openContext = CodexOpenThreadContext(
                threadTitle: title,
                projectName: projectName,
                repositoryPath: repo
            )
            $0.busyState = .idle
            $0.accountIssue = nil
            $0.taskStoppedSignal = false
            $0.composerAvailable = true
            $0.composerEditable = true
            $0.composerValue = nil
            $0.insertSucceeds = true
            $0.sendControlAvailable = true
            $0.confirmation = .composerCleared
            $0.throwOnLocate = nil
            $0.throwOnSend = nil
        }
    }

    // MARK: - CodexUIAutomationDriving

    func checkAccessibilityPermission() async -> AccessibilityPermissionStatus {
        read { $0.permission }
    }

    func probeAvailability(bundleIdentifier: String) async -> CodexAvailabilityProbe {
        let snapshot = mutate { box -> (Bool, Bool, Bool) in
            box.probeCount += 1
            return (box.permission == .granted, box.appRunning, box.codexViewPresent)
        }
        return CodexAvailabilityProbe(
            applicationRunning: snapshot.1,
            codexViewPresent: snapshot.2,
            accessibilityGranted: snapshot.0
        )
    }

    func locateApplication(bundleIdentifier: String) async throws -> CodexAppHandle {
        guard read({ $0.appRunning }) else {
            throw CodexAutomationError.applicationNotFound(bundleIdentifier)
        }
        return CodexAppHandle(
            processIdentifier: 4321,
            bundleIdentifier: bundleIdentifier,
            applicationName: "ChatGPT"
        )
    }

    func activate(_ app: CodexAppHandle) async throws {
        mutate { $0.activateCount += 1 }
    }

    func ensureCodexViewPresent(_ app: CodexAppHandle) async throws {
        guard read({ $0.codexViewPresent }) else {
            throw CodexAutomationError.codexViewNotFound
        }
    }

    func locateThreadCandidates(
        _ app: CodexAppHandle,
        fingerprint: CodexTaskFingerprint
    ) async throws -> [CodexThreadCandidate] {
        if let error = read({ $0.throwOnLocate }) { throw error }
        return read { $0.candidates }
    }

    func openThread(_ candidate: CodexThreadCandidate, in app: CodexAppHandle) async throws {
        mutate { $0.openedThreads.append(candidate.title) }
    }

    func readOpenThreadContext(_ app: CodexAppHandle) async throws -> CodexOpenThreadContext {
        read { $0.openContext }
    }

    func detectBusyState(_ app: CodexAppHandle) async throws -> CodexBusyState {
        read { $0.busyState }
    }

    func detectAnyTaskGenerating(_ app: CodexAppHandle) async throws -> Bool {
        read { $0.anyTaskGenerating || $0.busyState == .generating }
    }

    func detectTaskStopped(_ app: CodexAppHandle) async throws -> Bool {
        read { $0.taskStoppedSignal || $0.accountIssue == .taskStopped }
    }

    func detectAccountIssue(_ app: CodexAppHandle) async throws -> CodexAccountIssue? {
        read { $0.accountIssue }
    }

    func locateComposer(_ app: CodexAppHandle) async throws -> CodexComposerHandle {
        let snapshot = read { ($0.composerAvailable, $0.composerEditable) }
        guard snapshot.0 else { throw CodexAutomationError.composerNotFound }
        return CodexComposerHandle(identifier: "composer-1", isEditable: snapshot.1)
    }

    func focusComposer(_ composer: CodexComposerHandle, in app: CodexAppHandle) async throws {
        mutate { $0.focusCount += 1 }
    }

    func insertMessage(
        _ text: String,
        into composer: CodexComposerHandle,
        in app: CodexAppHandle
    ) async throws {
        mutate {
            $0.insertedMessages.append(text)
            // 模拟输入生效 / 未生效 —— 后者用于复现 messageInsertionFailed
            $0.composerValue = $0.insertSucceeds ? text : nil
        }
    }

    func readComposerValue(
        _ composer: CodexComposerHandle,
        in app: CodexAppHandle
    ) async throws -> String? {
        read { $0.composerValue }
    }

    func locateSendControl(_ app: CodexAppHandle) async throws -> CodexSendControlHandle {
        guard read({ $0.sendControlAvailable }) else {
            throw CodexAutomationError.sendControlNotFound
        }
        return CodexSendControlHandle(identifier: "send-1", label: "Send")
    }

    func pressSend(_ control: CodexSendControlHandle, in app: CodexAppHandle) async throws {
        if let error = read({ $0.throwOnSend }) { throw error }
        mutate {
            $0.sendCount += 1
            // 发送后 composer 通常会被清空
            $0.composerValue = nil
        }
    }

    func observeSendConfirmation(
        _ app: CodexAppHandle,
        composer: CodexComposerHandle
    ) async throws -> SendConfirmation {
        read { $0.confirmation }
    }
}

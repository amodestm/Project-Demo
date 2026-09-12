import Foundation
import Combine
import AIRunnerCore

/// 应用根状态。
///
/// 负责: 装配 `AppServices` → 创建 `TaskManager` → 执行崩溃恢复。
/// 启动失败时把错误留在 `bootstrapError` 里, 由 UI 显示可重试的错误页,
/// 而不是让 App 直接崩溃 —— 长任务程序最忌讳"打不开"。
@MainActor
final class AppState: ObservableObject {

    @Published private(set) var services: AppServices?
    @Published private(set) var taskManager: TaskManager?
    @Published private(set) var bootstrapError: String?
    @Published private(set) var recoverySummary: String?
    @Published var selectedTaskID: String?

    private var didHandleRequestedTask = false

    init() {
        bootstrap()
    }

    func bootstrap() {
        do {
            // 注入 App 层的剪贴板与浏览器实现 —— Core 本身不依赖 AppKit。
            let services = try AppServices.bootstrap(
                clipboard: PasteboardClipboard(),
                browser: WorkspaceBrowserLauncher()
            )
            let manager = TaskManager(services: services)

            self.services = services
            self.taskManager = manager
            self.bootstrapError = nil

            // AIRunner 的网页执行依赖辅助功能。首次安装或签名身份升级后，
            // 主动触发 macOS 的正式授权提示；已授权时不会显示任何内容。
            if services.accessibilityPermission.currentStatus() == .denied {
                _ = services.accessibilityPermission.requestPermission()
            }

            // 启动恢复: 修复运行中被强杀留下的 running 步骤, 并自动接续 running 的任务。
            let report = manager.recoverOnLaunch(autoStart: Self.requestedTaskID() == nil)
            self.recoverySummary = (report?.didRecoverAnything == true) ? report?.summary : nil

            // 外部调度入口优先在服务初始化完成后立即处理；ContentView.task 仍保留为
            // SwiftUI 场景恢复时的兜底。didHandleRequestedTask 保证只启动一次。
            startRequestedTaskIfNeeded()

            // 恢复 Codex 账号交接监视器: 仍处于 waitingForAccount 且有绑定的任务重新纳入监视。
            // 该行为由设置里的全局开关控制；关闭后仍可在任务详情里手动 Resume。
            if services.settings.autoResumeAfterManualAuthentication {
                Task {
                    let restored = await services.codexMonitor.restoreFromDatabase()
                    if !restored.isEmpty {
                        services.logger.info(
                            .accountHandoffMonitoring,
                            "启动时已恢复 \(restored.count) 个等待账号交接的任务监视"
                        )
                    }
                }
            }

        } catch {
            self.services = nil
            self.taskManager = nil
            self.recoverySummary = nil
            self.bootstrapError = AppError.normalize(error).userMessage
        }
    }

    func refresh() {
        taskManager?.refresh()
    }

    var databasePath: String? {
        services?.database.databasePath
    }

    /// 窗口出现后处理一次命令行启动请求，确保 SwiftUI 生命周期和 TaskManager
    /// 均已稳定就绪。最终仍调用与界面按钮相同的 `TaskManager.start`。
    func startRequestedTaskIfNeeded() {
        guard !didHandleRequestedTask,
              let requestedTaskID = Self.requestedTaskID(),
              let manager = taskManager else { return }
        didHandleRequestedTask = true

        services?.logger.info(
            .taskStarted,
            "已接收外部启动请求，准备启动指定任务",
            taskID: requestedTaskID
        )

        manager.refresh()
        if let task = manager.tasks.first(where: { $0.id == requestedTaskID }) {
            manager.start(task)
        } else {
            manager.lastErrorMessage = "找不到命令行指定的任务: \(requestedTaskID)"
        }
    }

    private static func requestedTaskID(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        let environmentTaskID = ProcessInfo.processInfo.environment["AIRUNNER_START_TASK_ID"]
        let argumentTaskID: String?
        if let flagIndex = arguments.firstIndex(of: "--start-task"),
           arguments.indices.contains(flagIndex + 1) {
            argumentTaskID = arguments[flagIndex + 1]
        } else {
            argumentTaskID = nil
        }

        let taskID = (argumentTaskID ?? environmentTaskID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return taskID.isEmpty ? nil : taskID
    }
}

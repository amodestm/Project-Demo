import SwiftUI

@main
struct AIRunnerApp: App {

    @StateObject private var appState = AppState()
    private let displayName = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleDisplayName"
    ) as? String ?? "AIRunner"

    var body: some Scene {
        WindowGroup(displayName) {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1020, minHeight: 660)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建任务…") {
                    NotificationCenter.default.post(name: .airunnerCreateTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .appSettings) {
                Divider()
                Button("开始/继续当前任务") {
                    NotificationCenter.default.post(name: .airunnerStartSelectedTask, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("打开 ChatGPT") {
                    NotificationCenter.default.post(name: .airunnerOpenChatGPT, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 720, height: 560)
        }
    }
}

extension Notification.Name {
    /// ⌘N —— 请求主界面打开「新建任务」表单。
    static let airunnerCreateTask = Notification.Name("AIRunner.CreateTask")

    /// ⇧⌘G —— 用系统默认浏览器打开 ChatGPT（不涉及任何自动化操作）。
    static let airunnerOpenChatGPT = Notification.Name("AIRunner.OpenChatGPT")

    /// ⌘↩ —— 启动或继续主界面当前选中的任务。
    static let airunnerStartSelectedTask = Notification.Name("AIRunner.StartSelectedTask")
}

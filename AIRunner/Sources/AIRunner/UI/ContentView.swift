import SwiftUI
import AIRunnerCore

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let message = appState.bootstrapError {
                BootstrapErrorView(message: message) {
                    appState.bootstrap()
                }
            } else if let manager = appState.taskManager,
                      let services = appState.services {
                MainSplitView(manager: manager, services: services)
            } else {
                ProgressView("正在初始化 AIRunner…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .task {
            appState.startRequestedTaskIfNeeded()
        }
    }
}

/// 启动失败页。
///
/// 刻意做成"可重试"而不是直接退出 —— 长任务程序必须是用户能自己救回来的,
/// 数据库损坏 / 权限问题都应该能在界面上看到原因。
struct BootstrapErrorView: View {

    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("无法启动 AIRunner")
                .font(.title2.bold())

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)

            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

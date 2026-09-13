import SwiftUI
import Combine
import AppKit
import AIRunnerCore

/// 主界面: 左任务列表 + 右任务详情。
struct MainSplitView: View {

    @ObservedObject var manager: TaskManager
    let services: AppServices

    @State private var selection: String?
    @State private var showingCreate = false

    var body: some View {
        NavigationSplitView {
            TaskListView(
                manager: manager,
                selection: $selection,
                showingCreate: $showingCreate
            )
            .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 420)
        } detail: {
            if let taskID = selection,
               let task = manager.tasks.first(where: { $0.id == taskID }) {
                TaskDetailView(manager: manager, services: services, task: task)
            } else {
                ContentUnavailableView(
                    "未选择任务",
                    systemImage: "rectangle.stack",
                    description: Text("从左侧选择一个任务查看详情, 或按 ⌘N 新建任务。")
                )
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateTaskView(manager: manager, isPresented: $showingCreate)
        }
        .onReceive(NotificationCenter.default.publisher(for: .airunnerCreateTask)) { _ in
            showingCreate = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .airunnerOpenChatGPT)) { _ in
            let url = ChatGPTWebTarget.resolvedURL(override: services.settings.chatGPTURL)
            WorkspaceBrowserLauncher().open(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .airunnerStartSelectedTask)) { _ in
            guard let taskID = selection,
                  let task = manager.tasks.first(where: { $0.id == taskID }) else { return }

            switch task.status {
            case .queued:
                manager.start(task)
            case .paused, .waiting, .failed,
                 .waitingForAccount, .waitingForBrowser, .waitingForUser:
                manager.resume(task)
            case .running, .completed, .cancelled:
                break
            }
        }
    }
}

// MARK: - 任务列表

enum TaskFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case finished

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:      return "全部"
        case .active:   return "进行中"
        case .finished: return "已结束"
        }
    }
}

struct TaskListView: View {

    @ObservedObject var manager: TaskManager
    @Binding var selection: String?
    @Binding var showingCreate: Bool

    @State private var filter: TaskFilter = .all

    private var visibleTasks: [AITask] {
        switch filter {
        case .all:
            return manager.tasks
        case .active:
            return manager.tasks.filter { !$0.status.isTerminal }
        case .finished:
            return manager.tasks.filter { $0.status.isTerminal }
        }
    }

    var body: some View {
        Group {
            if manager.tasks.isEmpty {
                ContentUnavailableView(
                    "还没有任务",
                    systemImage: "tray",
                    description: Text("点击下方的「新建任务」创建第一个长任务。")
                )
            } else {
                List(selection: $selection) {
                    ForEach(visibleTasks) { task in
                        TaskRowView(task: task, isActive: manager.isActive(task))
                            .tag(task.id)
                            .contextMenu {
                                contextMenu(for: task)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
                as? String ?? "AIRunner"
        )
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("打开设置（也可按 ⌘,）")
            }

            ToolbarItem(placement: .principal) {
                Picker("", selection: $filter) {
                    ForEach(TaskFilter.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { manager.lastErrorMessage != nil },
                set: { if !$0 { manager.lastErrorMessage = nil } }
            )
        ) {
            if manager.lastErrorMessage?.contains("辅助功能权限") == true {
                Button("打开辅助功能设置") {
                    manager.lastErrorMessage = nil
                    manager.openAccessibilitySettings()
                }
            }
            Button("好") { manager.lastErrorMessage = nil }
        } message: {
            Text(manager.lastErrorMessage ?? "")
        }
    }

    // MARK: 底部操作栏

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let summary = manager.recoverySummary {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.blue)
                    Text(summary)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10)
            }

            HStack(spacing: 10) {
                Button {
                    showingCreate = true
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if let selected = selectedTask {
                    actionButtons(for: selected)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func actionButtons(for task: AITask) -> some View {
        switch task.status {
        case .queued:
            Button(task.executionMode == .codexDesktop ? "开始监控" : "开始") { manager.start(task) }
                .buttonStyle(.borderedProminent)

        case .running:
            Button(task.executionMode == .codexDesktop ? "暂停监控" : "暂停") { manager.pause(task) }
            Button("取消", role: .destructive) { manager.cancel(task) }

        case .paused, .waiting, .failed,
             .waitingForAccount, .waitingForBrowser, .waitingForUser:
            Button(task.executionMode == .codexDesktop ? "恢复监控" : "继续") { manager.resume(task) }
                .buttonStyle(.borderedProminent)
            Button("取消", role: .destructive) { manager.cancel(task) }

        case .completed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private func contextMenu(for task: AITask) -> some View {
        Button("开始") { manager.start(task) }
        Button("暂停") { manager.pause(task) }
        Button("继续") { manager.resume(task) }
        Divider()
        Button("取消", role: .destructive) { manager.cancel(task) }
        Button("删除任务", role: .destructive) { manager.delete(task) }
    }

    private var selectedTask: AITask? {
        guard let selection else { return nil }
        return manager.tasks.first { $0.id == selection }
    }
}

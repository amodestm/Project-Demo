import SwiftUI
import AIRunnerCore

/// 事件日志视图。
struct LogView: View {

    @ObservedObject var manager: TaskManager
    /// nil 表示显示全部任务的日志。
    let task: AITask?
    @Binding var isPresented: Bool

    @State private var events: [AppEvent] = []
    @State private var levelFilter: LogLevel? = nil
    @State private var searchText = ""
    @State private var isLive = true

    private var filtered: [AppEvent] {
        events.filter { event in
            if let levelFilter, event.level != levelFilter { return false }
            guard !searchText.isEmpty else { return true }
            let needle = searchText.lowercased()
            return event.message.lowercased().contains(needle)
                || event.eventType.rawValue.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(width: 920, height: 600)
        .task {
            while !Task.isCancelled {
                reload()
                if !isLive { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.map { "日志 — \($0.name)" } ?? "全部日志")
                    .font(.headline)
                Text("共 \(filtered.count) 条\(events.count != filtered.count ? " (已过滤 / 总 \(events.count))" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $levelFilter) {
                Text("全部级别").tag(LogLevel?.none)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(LogLevel?.some(level))
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField("搜索…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            Toggle("实时", isOn: $isLive)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")

            Button("关闭") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                "没有日志",
                systemImage: "text.alignleft",
                description: Text(events.isEmpty
                                  ? "任务还没有产生任何事件。"
                                  : "当前过滤条件没有匹配到记录。")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { event in
                        LogRowView(event: event)
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.15))
        }
    }

    private func reload() {
        events = manager.events(for: task, limit: 800)
    }
}

struct LogRowView: View {

    let event: AppEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {

            Text(event.timestampText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Text(event.level.displayName)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(event.level.tintColor)
                .frame(width: 60, alignment: .leading)

            Text(event.eventType.rawValue)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 190, alignment: .leading)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let metadata = event.metadata, case .object(let dict) = metadata, !dict.isEmpty {
                    Text(dict.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value.stringValue ?? "…")" }
                        .joined(separator: "  "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if let index = event.stepIndex {
                Text("step \(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

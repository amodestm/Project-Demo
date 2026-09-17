import SwiftUI
import AIRunnerCore

/// 讨论组总览 —— 左侧讨论组列表, 右侧选中讨论的运行界面。
struct DiscussionHubView: View {

    let services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [DiscussionGroup] = []
    @State private var selection: String?
    @State private var errorMessage: String?

    private var selectedGroup: DiscussionGroup? {
        groups.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let group = selectedGroup {
                DiscussionRunView(
                    services: services,
                    group: group,
                    onGroupUpdated: { updated in
                        if let index = groups.firstIndex(where: { $0.id == updated.id }) {
                            groups[index] = updated
                        }
                    }
                )
                .id("\(group.id)-\(group.updatedAt.timeIntervalSince1970)")
            } else {
                ContentUnavailableView(
                    "未选择讨论组",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("从左侧选择一个讨论组, 或新建一个。")
                )
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
                .help("关闭讨论组")
            }
        }
        .onAppear(perform: reload)
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView(
                    "还没有讨论组",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("点下方「新建」创建一个多人讨论。")
                )
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        DiscussionGroupRow(group: group)
                            .tag(group.id)
                            .contextMenu {
                                Button("删除", role: .destructive) {
                                    delete(group)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    createGroup()
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .controlSize(.small)

                Button {
                    dismiss()
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
                .controlSize(.small)
                .help("关闭讨论组")

                Spacer()

                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("刷新")
            }
            .padding(10)
        }
        .navigationTitle("讨论组")
    }

    // MARK: - 动作

    private func reload() {
        groups = (try? services.discussionRepo.fetchAllGroups()) ?? []
        if selection == nil { selection = groups.first?.id }
    }

    private func createGroup() {
        var group = DiscussionPresets.starterGroup(
            name: "讨论 \(groups.count + 1)"
        )
        // 让新组立刻可编辑: 给个空议题, 用户填完才能开始
        group.topic = ""
        do {
            try services.discussionRepo.save(group)
            reload()
            selection = group.id
        } catch {
            errorMessage = AppError.normalize(error).userMessage
        }
    }

    private func delete(_ group: DiscussionGroup) {
        do {
            try services.discussionRepo.deleteGroup(id: group.id)
            if selection == group.id { selection = nil }
            reload()
        } catch {
            errorMessage = AppError.normalize(error).userMessage
        }
    }
}

// MARK: - 列表行

private struct DiscussionGroupRow: View {

    let group: DiscussionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.name)
                .font(.callout)
                .lineLimit(1)

            if !group.topic.isEmpty {
                Text(group.topic)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: -6) {
                ForEach(Array(group.participants.prefix(4).enumerated()), id: \.element.id) { index, p in
                    AgentAvatar(symbol: p.avatarSymbol, hex: p.accentHex, size: 20)
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                        )
                        .zIndex(Double(group.participants.count - index))
                }
                if group.participants.count > 4 {
                    Text("+\(group.participants.count - 4)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

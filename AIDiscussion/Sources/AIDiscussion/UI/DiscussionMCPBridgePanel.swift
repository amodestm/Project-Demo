import SwiftUI
import AIDiscussionCore
import AIDiscussionBridge

/// 侧边栏底部的 MCP 桥接面板。
///
/// 存在的理由：讨论组现在是**可以被外部调用的**。用户在 Codex 里触发一场讨论后，
/// 如果界面上什么都看不见，就无从判断"到底跑没跑、卡在哪一步"。
/// 这个面板把那部分状态摊开，并且复用与桥接返回完全相同的进度文案。
struct DiscussionMCPBridgePanel: View {

    @ObservedObject var services: DiscussionServices

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            body_
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(statusTint)

            Text("MCP 桥接")
                .font(.caption.bold())

            Spacer()

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: String {
        if services.bridgeError != nil { return "exclamationmark.triangle.fill" }
        return services.isBridgeServing ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }

    private var statusTint: Color {
        if services.bridgeError != nil { return .orange }
        return services.isBridgeServing ? .green : .secondary
    }

    private var statusText: String {
        if services.bridgeError != nil { return "未就绪" }
        return services.isBridgeServing ? "已就绪" : "未启动"
    }

    // MARK: - 内容

    @ViewBuilder
    private var body_: some View {
        if let error = services.bridgeError {
            VStack(alignment: .leading, spacing: 3) {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                Text("外部客户端（如 Codex）暂时调不到讨论组；app 本身和界面内讨论不受影响。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let hub = services.bridgeHub {
            if hub.handles.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("等待外部调用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Codex 调用 discussion_run 时，正在跑的讨论会显示在这里。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                BridgeJobsList(hub: hub)
            }

            Text(BridgePaths.socketURL().path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("本地桥接 socket；配置方法见 AIDiscussion/README.md 的「MCP」章节")
        }
    }
}

// MARK: - 任务列表

private struct BridgeJobsList: View {

    @ObservedObject var hub: DiscussionBridgeHub

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(hub.handles) { job in
                BridgeJobRow(job: job) {
                    job.orchestrator.cancel()
                }
            }
        }
    }
}

private struct BridgeJobRow: View {

    let job: DiscussionBridgeHub.JobHandle
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if job.isFinished {
                    Image(systemName: job.orchestrator.run.state == .converged
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(job.orchestrator.run.state == .converged ? .green : .orange)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption2)
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(job.group.name)
                    .font(.caption2.bold())
                    .lineLimit(1)

                Text(job.progressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let issue = job.orchestrator.currentOrInferredLoginIssue {
                    Text("成员「\(issue.participantName)」未登录")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if !job.isFinished {
                Button("停止") { onCancel() }
                    .controlSize(.mini)
                    .help("终止这场外部调用触发的讨论（已完成发言会保留）")
            }
        }
    }
}

import SwiftUI
import AIRunnerCore

/// 任务列表中的一行。
struct TaskRowView: View {

    let task: AITask
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                StatusBadge(status: task.status)
            }

            if task.executionMode == .codexDesktop {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .foregroundStyle(.indigo)
                    Text("Codex 自动监控")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 8) {
                if task.executionMode == .codexDesktop {
                    Text(task.actionHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(task.progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if isActive {
                    HStack(spacing: 3) {
                        ProgressView().controlSize(.mini)
                        Text("执行中").font(.caption2)
                    }
                    .foregroundStyle(.blue)
                }

                Spacer(minLength: 4)

                if task.executionMode != .codexDesktop {
                    Text("\(task.primaryProvider) / \(task.primaryModel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let message = task.errorMessage,
               task.status == .failed || task.status == .paused {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.tintColor.opacity(0.18), in: Capsule())
            .foregroundStyle(status.tintColor)
    }
}

// MARK: - 状态样式

extension TaskStatus {
    var tintColor: Color {
        switch self {
        case .queued:            return .secondary
        case .running:           return .blue
        case .waiting:           return .orange
        case .waitingForAccount: return .purple
        case .waitingForBrowser: return .indigo
        case .waitingForUser:    return .teal
        case .paused:            return .yellow
        case .completed:         return .green
        case .failed:            return .red
        case .cancelled:         return .gray
        }
    }

    var symbolName: String {
        switch self {
        case .queued:            return "clock"
        case .running:           return "play.circle.fill"
        case .waiting:           return "hourglass"
        case .waitingForAccount: return "person.crop.circle.badge.exclamationmark"
        case .waitingForBrowser: return "safari"
        case .waitingForUser:    return "doc.on.clipboard"
        case .paused:            return "pause.circle.fill"
        case .completed:         return "checkmark.circle.fill"
        case .failed:            return "xmark.octagon.fill"
        case .cancelled:         return "slash.circle.fill"
        }
    }
}

extension StepStatus {
    var tintColor: Color {
        switch self {
        case .pending:     return .secondary
        case .prepared:    return .teal
        case .running:     return .blue
        case .completed:   return .green
        case .failed:      return .red
        case .skipped:     return .gray
        case .interrupted: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .pending:     return "circle"
        case .prepared:    return "doc.on.clipboard.fill"
        case .running:     return "arrow.triangle.2.circlepath"
        case .completed:   return "checkmark.circle.fill"
        case .failed:      return "xmark.circle.fill"
        case .skipped:     return "minus.circle"
        case .interrupted: return "bolt.slash.fill"
        }
    }
}

extension LogLevel {
    var tintColor: Color {
        switch self {
        case .debug:    return .secondary
        case .info:     return .blue
        case .warning:  return .orange
        case .error:    return .red
        case .critical: return .purple
        }
    }
}

extension ProviderHealthState {
    var tintColor: Color {
        switch self {
        case .healthy:     return .green
        case .degraded:    return .orange
        case .unavailable: return .red
        }
    }
}

import SwiftUI
import AIRunnerCore

/// 新建任务表单。
struct CreateTaskView: View {

    @ObservedObject var manager: TaskManager
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var goal = ""
    @State private var stepsText = "5"
    @State private var errorMessage: String?

    private var stepCount: Int? {
        Int(stepsText.trimmingCharacters(in: .whitespaces))
    }

    private var stepCountIsValid: Bool {
        guard let stepCount else { return false }
        return (1...1000).contains(stepCount)
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !goal.trimmingCharacters(in: .whitespaces).isEmpty
            && stepCountIsValid
    }

    private var primaryRoute: RouteEntry? {
        manager.services.settings.primaryRoute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新建长任务").font(.title3.bold())
                    Text("任务会被拆成 N 个顺序步骤, 每一步的结果与检查点都会立即落盘。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 6) {
                    Text("任务名称").font(.caption.bold()).foregroundStyle(.secondary)
                    TextField("例如: PDF 研究报告", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("任务目标").font(.caption.bold()).foregroundStyle(.secondary)
                    TextEditor(text: $goal)
                        .font(.body)
                        .frame(height: 90)
                        .padding(6)
                        .background(.quaternary.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("步骤数").font(.caption.bold()).foregroundStyle(.secondary)
                        TextField("5", text: $stepsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .monospacedDigit()
                        if !stepCountIsValid && !stepsText.isEmpty {
                            Text("必须是 1 – 1000 的整数")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("执行通道").font(.caption.bold()).foregroundStyle(.secondary)

                        let mode = manager.services.settings.defaultExecutionMode
                        Text(mode.displayName)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.teal.opacity(0.15), in: Capsule())

                        if mode == .chatGPTWeb {
                            Text("可在「设置 → ChatGPT Web」中调整")
                                .font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Text(primaryRoute.map { "路由: \($0.label)" } ?? "未配置路由")
                                .font(.caption2)
                                .foregroundStyle(primaryRoute == nil ? Color.red : Color.secondary)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("MVP 会把目标拆成 N 个等价步骤, 每步都带上目标与最新检查点摘要。"
                          + "步骤拆分策略后续可由 Task Planner 增强。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("创建任务") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(20)
        }
        .frame(width: 560)
    }

    private func submit() {
        guard let stepCount, stepCountIsValid else { return }
        do {
            let task = try manager.createTask(
                name: name,
                goal: goal,
                numberOfSteps: stepCount
            )
            isPresented = false
            // 创建后自动开跑, 符合"长任务"直觉
            manager.start(task)
        } catch {
            errorMessage = AppError.normalize(error).userMessage
        }
    }
}

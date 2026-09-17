import Foundation
import AIDiscussionBridge

/// 把 MCP 工具调用翻译成桥接请求，并把结果整理成模型好读的文本。
///
/// 这一层是**唯一**知道"工具名 ↔ op ↔ 参数"对应关系的地方，所以参数映射和
/// 结果渲染都集中在这里，方便单测直接驱动。
public struct BridgeToolExecutor: MCPToolExecuting {

    /// app 没跑时是否自动拉起。测试里关掉，避免真的启动 app。
    public let autoLaunch: Bool

    public init(autoLaunch: Bool = true) {
        self.autoLaunch = autoLaunch
    }

    private static let shortTimeout = 40
    private static let defaultRunTimeout = 1_800
    private static let maxRunTimeout = 3_600
    private static let defaultMaxChars = 2_000
    private static let minimumMaxChars = 200
    private static let promptPreviewChars = 600

    public func call(tool name: String, arguments: JSONValue) async -> MCPToolResult {
        switch name {
        case "discussion_roles":
            return callBridge(op: .roles, payload: nil, timeout: Self.shortTimeout, render: Self.renderRoles)

        case "discussion_profiles":
            return callBridge(op: .profiles, payload: nil, timeout: Self.shortTimeout, render: Self.renderProfiles)

        case "discussion_groups":
            return callBridge(op: .groups, payload: nil, timeout: Self.shortTimeout, render: Self.renderGroups)

        case "discussion_status":
            return callBridge(op: .status, payload: statusPayload(from: arguments),
                              timeout: Self.shortTimeout, render: Self.renderStatus)

        case "discussion_cancel":
            guard let jobId = jobId(from: arguments) else {
                return .failure("缺少 jobId。", hint: "discussion_start / discussion_run 返回的 jobId。")
            }
            return callBridge(
                op: .cancel,
                payload: .object(["jobId": .string(jobId)]),
                timeout: Self.shortTimeout,
                render: Self.renderCancel
            )

        case "discussion_result":
            guard let jobId = jobId(from: arguments) else {
                return .failure("缺少 jobId。", hint: "discussion_start 返回的 jobId。")
            }
            let limit = maxChars(from: arguments)
            return callBridge(
                op: .result,
                payload: .object(["jobId": .string(jobId)]),
                timeout: Self.shortTimeout,
                render: { try Self.renderOutcome($0, limit: limit) }
            )

        case "discussion_run":
            let timeout = runTimeout(from: arguments)
            return callBridge(
                op: .run,
                payload: try? specPayload(from: arguments),
                timeout: timeout,
                render: { try Self.renderOutcome($0, limit: maxChars(from: arguments)) }
            )

        case "discussion_start":
            return callBridge(
                op: .start,
                payload: try? specPayload(from: arguments),
                timeout: Self.shortTimeout,
                render: Self.renderStarted
            )

        default:
            return .failure("未实现的工具：\(name)")
        }
    }

    // MARK: - 通用调用

    private func callBridge(
        op: BridgeOp,
        payload: JSONValue?,
        timeout: Int,
        render: (JSONValue) throws -> String
    ) -> MCPToolResult {
        if let payload, case .object(let fields) = payload {
            // 讨论规格必须有内容；roles/profiles/groups 这些空参数工具不会走到这里
            if op == .run || op == .start, fields.isEmpty {
                return .failure(
                    "没有可用的讨论参数。",
                    hint: "至少给出 participants（2 位以上）或 group（复用已保存讨论组），以及 topic。"
                )
            }
        }
        if (op == .run || op == .start), payload == nil {
            return .failure(
                "讨论参数解析失败。",
                hint: "检查 participants / rounds / consensus 的字段名与取值是否与 schema 一致。"
            )
        }

        let client: BridgeClient
        do {
            client = try BridgeClient.make(autoLaunch: autoLaunch)
        } catch {
            return .failure(
                error.localizedDescription,
                hint: "让用户打开 AIDiscussion（菜单栏那个 app），然后重试。"
            )
        }

        let response: BridgeResponse
        do {
            response = try client.call(op: op, payload: payload, timeoutSeconds: timeout)
        } catch {
            return .failure(error.localizedDescription)
        }

        if !response.ok {
            return Self.render(error: response.error)
        }
        guard let result = response.result else {
            return .failure("AIDiscussion 返回了空结果。")
        }
        do {
            return MCPToolResult(text: try render(result), structured: result)
        } catch {
            return .failure("结果渲染失败：\(error)")
        }
    }

    /// 把桥接错误码翻译成模型能行动的提示。
    public static func render(error bridgeError: BridgeError?) -> MCPToolResult {
        guard let bridgeError else {
            return .failure("AIDiscussion 返回了未说明的失败。")
        }

        let hint = bridgeError.hint ?? defaultHint(for: bridgeError.code)
        return .failure("[\(bridgeError.code.rawValue)] \(bridgeError.message)", hint: hint)
    }

    private static func defaultHint(for code: BridgeErrorCode) -> String? {
        switch code {
        case .accessibility:
            return "让用户在「系统设置 → 隐私与安全性 → 辅助功能」里勾选 AIDiscussion，然后重试。"
        case .loginRequired:
            return "让用户在 AIDiscussion 界面点「一键跳转登录」完成登录，然后重试。"
        case .unauthenticated:
            return "桥接凭据失效（app 可能刚重启）。直接重试即可，客户端会重读 token。"
        case .notFound:
            return "用 discussion_status（不带 jobId）看当前有哪些任务与可用资源。"
        case .busy:
            return "任务还在跑，稍后再取；或先做别的事。"
        case .timeout:
            return "改用 discussion_status 轮询进度，再用 discussion_result 取结论。"
        case .cancelled:
            return "任务已被取消。"
        case .invalidRequest:
            return "按返回信息修正参数；discussion_profiles 能看到可用的 Profile 与账号标识。"
        case .internalError:
            return "这是 AIDiscussion 内部错误，可以重试一次；持续失败请查看 app 日志。"
        }
    }

    // MARK: - 参数提取

    private func specPayload(from arguments: JSONValue) throws -> JSONValue {
        // 字段名与 BridgeDiscussionSpec 一一对应，直接透传即可。
        // 未知字段（如 maxCharsPerUtterance）会被解码器忽略。
        _ = try BridgeJSON.decode(BridgeDiscussionSpec.self, from: BridgeJSON.encode(arguments))
        return arguments
    }

    private func statusPayload(from arguments: JSONValue) -> JSONValue? {
        guard let jobId = jobId(from: arguments) else { return nil }
        return .object(["jobId": .string(jobId)])
    }

    private func jobId(from arguments: JSONValue) -> String? {
        let value = arguments["jobId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func maxChars(from arguments: JSONValue) -> Int {
        let requested = arguments["maxCharsPerUtterance"]?.intValue ?? Self.defaultMaxChars
        return max(requested, Self.minimumMaxChars)
    }

    private func runTimeout(from arguments: JSONValue) -> Int {
        let requested = arguments["timeoutSeconds"]?.intValue ?? Self.defaultRunTimeout
        return min(max(requested, 30), Self.maxRunTimeout)
    }

    // MARK: - 渲染

    private static func renderRoles(_ result: JSONValue) throws -> String {
        let roles = try decode([BridgeRoleTemplate].self, from: result)
        guard !roles.isEmpty else { return "没有内置角色模板。" }

        var lines = ["# 内置角色模板（\(roles.count) 个）", ""]
        for role in roles {
            lines.append("## \(role.name)")
            lines.append(role.rolePrompt.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        lines.append("用法：把角色名填进 participants 的 preset，或照着它的写法自定义 role。")
        lines.append("关键不是「客观全面」，而是写死**不许越界谈什么** —— 那才是观点差异的来源。")
        return lines.joined(separator: "\n")
    }

    private static func renderProfiles(_ result: JSONValue) throws -> String {
        let profiles = try decode([BridgeProfile].self, from: result)
        guard !profiles.isEmpty else {
            return "本机没有检测到可用的 Chrome Profile。让用户先在 Chrome 里建立并登录账号。"
        }

        var lines = ["# 可用 Chrome Profile（\(profiles.count) 个）", ""]
        lines.append("| profile（传给 profile） | Chrome 里的名字 | account（传给 account） |")
        lines.append("|---|---|---|")
        for profile in profiles {
            lines.append("| `\(profile.directory)` | \(profile.displayName) | `\(profile.suggestedIdentity)` |")
        }
        lines.append("")
        lines.append("一个 Profile 只能绑定一位成员。不传 profile 时服务端会自动分配未占用的。")
        return lines.joined(separator: "\n")
    }

    private static func renderGroups(_ result: JSONValue) throws -> String {
        let groups = try decode([BridgeGroupSummary].self, from: result)
        guard !groups.isEmpty else {
            return "还没有保存过的讨论组。可以直接用 participants 内联定义成员。"
        }

        var lines = ["# 已保存的讨论组（\(groups.count) 个）", ""]
        for group in groups {
            lines.append("## \(group.name)")
            lines.append("- 议题：\(group.topic.isEmpty ? "（未填写）" : group.topic)")
            lines.append("- 成员：\(group.participants.joined(separator: "、"))")
            lines.append("- 议程：\(group.rounds.joined(separator: " → "))")
            lines.append("- 收敛：\(group.consensus)" + (group.moderator.map { "（主席：\($0)）" } ?? ""))
            lines.append("")
        }
        lines.append("复用方式：把组名传给 discussion_run 的 `group`，再给 `topic` 覆盖议题。")
        return lines.joined(separator: "\n")
    }

    private static func renderStarted(_ result: JSONValue) throws -> String {
        let started = try decode(BridgeStartedJob.self, from: result)
        return """
        讨论已在后台启动。

        - jobId：`\(started.jobId)`
        - 讨论组：\(started.groupName)
        - 议题：\(started.topic)
        - 议程：\(started.totalRounds) 轮 / 预计 \(started.expectedUtterances) 条发言

        接下来：用 `discussion_status` 带这个 jobId 查进度（返回 progressText 可直接转述），
        跑完后用 `discussion_result` 取最终结论。可以先去干别的事。
        """
    }

    private static func renderStatus(_ result: JSONValue) throws -> String {
        // 带 jobId → 单个快照；不带 → 桥接总体状态
        if let snapshot = try? decode(BridgeJobSnapshot.self, from: result) {
            return renderSnapshot(snapshot)
        }

        let status = try decode(BridgeBridgeStatus.self, from: result)
        var lines = ["# 桥接状态", ""]
        lines.append("- app 版本：\(status.capabilities.appVersion)")
        lines.append("- 协议版本：v\(status.capabilities.protocolVersion)")
        lines.append("- 辅助功能权限：\(status.capabilities.accessibilityGranted ? "已授予" : "**未授予**（自动化会失败）")")
        lines.append("- 已保存讨论组：\(status.capabilities.groups) 个")
        lines.append("- 可用 Chrome Profile：\(status.capabilities.profiles) 个")
        lines.append("")

        if status.activeJobs.isEmpty {
            lines.append("当前没有在跑的讨论。")
        } else {
            lines.append("## 正在跑的任务（\(status.activeJobs.count) 个）")
            lines.append("")
            for job in status.activeJobs {
                lines.append("- `\(job.jobId)` \(job.groupName) — \(job.progressText)")
                if let issue = job.loginIssue {
                    lines.append("  - ⚠️ 成员「\(issue.participant)」未登录")
                }
            }
        }
        if !status.capabilities.accessibilityGranted {
            lines.append("")
            lines.append("让用户在「系统设置 → 隐私与安全性 → 辅助功能」里勾选 AIDiscussion。")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderSnapshot(_ snapshot: BridgeJobSnapshot) -> String {
        var lines = ["# 讨论进度", ""]
        lines.append("- jobId：`\(snapshot.jobId)`")
        lines.append("- 讨论组：\(snapshot.groupName)")
        lines.append("- 议题：\(snapshot.topic)")
        lines.append("- 状态：\(snapshot.state)")
        lines.append("- 进度：\(snapshot.progressText)")
        lines.append("- 发言：\(snapshot.completedUtterances)/\(snapshot.expectedUtterances) 条")
        if let error = snapshot.errorMessage {
            lines.append("- 错误：\(error)")
        }
        if let issue = snapshot.loginIssue {
            lines.append("")
            lines.append("## ⚠️ 需要登录")
            lines.append("成员「\(issue.participant)」（\(issue.profile)）未登录。")
            lines.append("让用户在 AIDiscussion 界面点「一键跳转登录」，或访问 \(issue.loginURL) 完成登录后重试。")
        }
        if snapshot.isFinished {
            lines.append("")
            lines.append("已结束 —— 用 `discussion_result` 带 jobId `\(snapshot.jobId)` 取最终结论。")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderCancel(_ result: JSONValue) throws -> String {
        let cancelled = try decode(BridgeCancelResult.self, from: result)
        if cancelled.alreadyFinished {
            return "任务 `\(cancelled.jobId)` 在取消前已经结束 —— 结论可以用 discussion_result 取。"
        }
        return "已请求取消任务 `\(cancelled.jobId)`。已完成的发言保留在库里，后续轮次不再推进。"
    }

    /// 讨论结论：**结论放最前面**，模型通常只需要这一段就能继续干活。
    public static func renderOutcome(_ result: JSONValue, limit: Int) throws -> String {
        let outcome = try decode(BridgeOutcome.self, from: result)

        var lines: [String] = []

        switch outcome.state {
        case "converged":
            lines.append("# 讨论结论")
        case "cancelled":
            lines.append("# 讨论被取消（以下是已完成的发言）")
        default:
            lines.append("# 讨论未成功结束")
        }
        lines.append("")

        if let decision = outcome.finalDecision, !decision.isEmpty {
            lines.append(decision.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let error = outcome.errorMessage {
            lines.append("原因：\(error)")
        } else {
            lines.append("（没有产出最终结论）")
        }

        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("## 议题")
        lines.append(outcome.topic)
        lines.append("")

        let received = outcome.utterances.filter { $0.status == "received" }
        let roundTitles = orderedRoundTitles(outcome.utterances)

        lines.append("## 讨论记录（\(outcome.audit.count) 位成员 / \(roundTitles.count) 轮 / \(received.count) 条发言）")
        lines.append("")

        for title in roundTitles {
            lines.append("### \(title)")
            for utterance in outcome.utterances where utterance.roundTitle == title {
                let body: String
                if utterance.status == "received" {
                    body = truncate(utterance.response ?? "", limit: limit)
                } else {
                    body = "（\(utterance.status)）"
                }
                lines.append("**\(utterance.participant)**：\(body)")
                lines.append("")
            }
        }

        if !outcome.audit.isEmpty {
            lines.append("## 账号审计")
            for entry in outcome.audit {
                lines.append("- \(entry.participant) → \(entry.profile)（\(entry.account)），发言 \(entry.utterances) 条")
            }
            lines.append("")
        }

        if let jobId = outcome.jobId {
            lines.append("完整原文（含每条 prompt）可用 `discussion_result` 带 jobId `\(jobId)` 取，")
            lines.append("或调高 `maxCharsPerUtterance` 取消截断。")
        }

        return lines.joined(separator: "\n")
    }

    private static func orderedRoundTitles(_ utterances: [BridgeUtterance]) -> [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for utterance in utterances.sorted(by: { $0.roundIndex < $1.roundIndex }) {
            if seen.insert(utterance.roundTitle).inserted {
                titles.append(utterance.roundTitle)
            }
        }
        return titles
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…（已截断 \(text.count - limit) 字）"
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try BridgeJSON.decode(type, from: BridgeJSON.encode(value))
    }
}

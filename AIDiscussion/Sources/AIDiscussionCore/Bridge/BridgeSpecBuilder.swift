import Foundation
import AIDiscussionBridge

/// 把桥接层传入的 `BridgeDiscussionSpec` 校验并翻译成内部 `DiscussionGroup`。
///
/// ## 为什么校验要跟界面走同一套规则
///
/// 界面「保存」时的约束（议题必填、至少 2 位启用成员、每位成员绑定**不同**的
/// Chrome Profile 且都有可校验的账号标识）不是形式主义 —— 每一条都对应一个真实
/// 的失败场景。MCP 这条入口如果不校验，就会绕过界面把关，产生"能提交但一跑就炸"
/// 的讨论组。所以这里刻意复刻同一套规则，并把错误写成**可直接行动**的提示。
@MainActor
public enum BridgeSpecBuilder {

    /// 自动分配 Profile 时的兜底：`Default` 通常混着各种临时登录态，不适合做讨论账号。
    static let fallbackAvoidedDirectories: Set<String> = ["Default"]

    public static func build(
        spec: BridgeDiscussionSpec,
        services: DiscussionServices
    ) throws -> DiscussionGroup {
        var group: DiscussionGroup

        if let groupName = spec.group?.trimmingCharacters(in: .whitespacesAndNewlines),
           !groupName.isEmpty {
            guard let existing = try findGroup(named: groupName, services: services) else {
                throw BridgeError(
                    code: .notFound,
                    message: "找不到名为「\(groupName)」的讨论组。",
                    hint: "先调用 discussion_groups 看已保存的讨论组，或直接用 participants 内联定义成员。"
                )
            }
            group = existing
        } else {
            group = DiscussionGroup(name: spec.name ?? "MCP 讨论", participants: [])
        }

        // 议题：内联时必填；复用讨论组时允许用 spec.topic 覆盖
        let topic = spec.topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !topic.isEmpty {
            group.topic = topic
        }
        guard !group.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError(
                code: .invalidRequest,
                message: "缺少讨论议题。",
                hint: "在参数里给出 topic。"
            )
        }

        if let name = spec.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            group.name = name
        }

        // 成员
        if let specs = spec.participants, !specs.isEmpty {
            group.participants = try buildParticipants(specs, services: services)
        }
        guard !group.enabledParticipants.isEmpty else {
            throw BridgeError(
                code: .invalidRequest,
                message: "讨论组里没有启用的成员。",
                hint: "用 participants 给出至少 2 位成员（每位含 name 与 role 或 preset）。"
            )
        }

        // 自动补齐未绑定的 Profile
        try autoAssignMissingProfiles(group: &group, services: services)

        // 议程
        if let rounds = spec.rounds, !rounds.isEmpty {
            group.rounds = try buildRounds(rounds, participants: group.participants)
        }
        guard !group.rounds.isEmpty else {
            throw BridgeError(
                code: .invalidRequest,
                message: "议程为空。",
                hint: "用 rounds 给出至少一轮，例如先「独立论述」再「收敛决策」。"
            )
        }

        // 收敛规则
        if let raw = spec.consensus?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let rule = parseConsensus(raw) else {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "无法识别的收敛方式「\(raw)」。",
                    hint: "可选值：\(ConsensusRule.allCases.map(\.rawValue).joined(separator: " / "))。"
                )
            }
            group.consensus = rule
        }

        // 主席
        if let moderatorName = spec.moderator?.trimmingCharacters(in: .whitespacesAndNewlines),
           !moderatorName.isEmpty {
            guard let hit = group.participants.first(where: {
                $0.displayName.caseInsensitiveCompare(moderatorName) == .orderedSame || $0.id == moderatorName
            }) else {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "主席「\(moderatorName)」不在成员列表里。",
                    hint: "可选成员：\(group.participants.map(\.displayName).joined(separator: " / "))。"
                )
            }
            group.moderatorParticipantID = hit.id
        }

        try validate(group: group, services: services)
        group.updatedAt = Date()
        return group
    }

    // MARK: - 成员

    private static func buildParticipants(
        _ specs: [BridgeParticipantSpec],
        services: DiscussionServices
    ) throws -> [DiscussionParticipant] {
        var usedNames = Set<String>()
        var result: [DiscussionParticipant] = []

        for (index, spec) in specs.enumerated() {
            let name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "第 \(index + 1) 位成员缺少 name。"
                )
            }
            let key = name.lowercased()
            guard usedNames.insert(key).inserted else {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "成员名「\(name)」重复。",
                    hint: "成员名是轮次里引用发言人的键，必须唯一。"
                )
            }

            let role = spec.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let presetName = spec.preset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var rolePrompt = role
            var avatarSymbol = DiscussionPalette.symbol(for: index)
            var accentHex = DiscussionPalette.hex(for: index)

            if rolePrompt.isEmpty, !presetName.isEmpty {
                guard let preset = DiscussionPresets.roles.first(where: {
                    $0.displayName.caseInsensitiveCompare(presetName) == .orderedSame
                }) else {
                    throw BridgeError(
                        code: .invalidRequest,
                        message: "没有名为「\(presetName)」的内置角色。",
                        hint: "可选：\(DiscussionPresets.roles.map(\.displayName).joined(separator: " / "))；"
                            + "或直接用 role 写自定义角色设定。"
                    )
                }
                rolePrompt = preset.rolePrompt
                avatarSymbol = preset.avatarSymbol
                accentHex = preset.accentHex
            }

            guard !rolePrompt.isEmpty else {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "成员「\(name)」缺少角色设定。",
                    hint: "给 role（自定义立场）或 preset（内置角色名）—— 角色互斥是讨论质量的前提。"
                )
            }

            result.append(
                DiscussionParticipant(
                    displayName: name,
                    rolePrompt: rolePrompt,
                    avatarSymbol: avatarSymbol,
                    accentHex: accentHex,
                    profileDirectory: spec.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    emailHint: spec.account?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    enabled: spec.enabled ?? true
                )
            )
        }
        return result
    }

    // MARK: - Profile 绑定

    private static func autoAssignMissingProfiles(
        group: inout DiscussionGroup,
        services: DiscussionServices
    ) throws {
        let allProfiles = (try? services.chromeProfiles.availableProfiles()) ?? []
        let aliases = services.settings.accountRotationProfileAliases

        // 已经有成员的绑定要占位，避免重复分配
        var used = Set(
            group.participants
                .map { $0.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        // 偏好顺序：用户配过别名的 > 其它；`Default` 放最后
        let pool = allProfiles.sorted { lhs, rhs in
            let lhsAliased = aliases[lhs.directoryName] != nil
            let rhsAliased = aliases[rhs.directoryName] != nil
            if lhsAliased != rhsAliased { return lhsAliased }
            let lhsAvoided = fallbackAvoidedDirectories.contains(lhs.directoryName)
            let rhsAvoided = fallbackAvoidedDirectories.contains(rhs.directoryName)
            if lhsAvoided != rhsAvoided { return !lhsAvoided }
            return lhs.directoryName < rhs.directoryName
        }

        for index in group.participants.indices {
            guard group.participants[index].enabled else { continue }
            let current = group.participants[index].profileDirectory
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard current.isEmpty else { continue }

            guard let free = pool.first(where: { !used.contains($0.directoryName) }) else {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "可用 Chrome Profile 不足，无法为「\(group.participants[index].displayName)」自动分配。",
                    hint: "已占用 \(used.count) 个，本机检测到 \(allProfiles.count) 个。"
                        + "先在 Chrome 里建立并登录更多 Profile，或显式指定 profile。"
                )
            }
            group.participants[index].profileDirectory = free.directoryName
            if group.participants[index].emailHint.isEmpty {
                group.participants[index].emailHint = free.preferredAccountIdentity(
                    alias: aliases[free.directoryName]
                )
            }
            used.insert(free.directoryName)
        }
    }

    // MARK: - 轮次

    private static func buildRounds(
        _ specs: [BridgeRoundSpec],
        participants: [DiscussionParticipant]
    ) throws -> [DiscussionRoundConfig] {
        var rounds: [DiscussionRoundConfig] = []

        for (index, spec) in specs.enumerated() {
            let kind = try parseKind(spec.kind, position: index)
            let visibility = try parseVisibility(spec.visibility, position: index)

            var speakerIDs: [String] = []
            if let names = spec.speakers, !names.isEmpty {
                for name in names {
                    guard let hit = participants.first(where: {
                        $0.displayName.caseInsensitiveCompare(name) == .orderedSame || $0.id == name
                    }) else {
                        throw BridgeError(
                            code: .invalidRequest,
                            message: "第 \(index + 1) 轮的发言人「\(name)」不在成员列表里。",
                            hint: "可选成员：\(participants.map(\.displayName).joined(separator: " / "))。"
                        )
                    }
                    speakerIDs.append(hit.id)
                }
            }

            rounds.append(
                DiscussionRoundConfig(
                    kind: kind,
                    title: spec.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? spec.title : nil,
                    instruction: spec.instruction ?? "",
                    speakerIDs: speakerIDs,
                    visibility: visibility
                )
            )
        }
        return rounds
    }

    private static func parseKind(_ raw: String?, position: Int) throws -> DiscussionRoundKind {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .crossExamination }

        let normalized = value
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()

        switch normalized {
        case "independentopinion", "independent", "opinion", "论述", "独立论述", "各自表态":
            return .independentOpinion
        case "crossexamination", "cross", "examination", "质询", "交叉质询":
            return .crossExamination
        case "convergence", "converge", "conclusion", "收敛", "收敛决策", "最终决策":
            return .convergence
        default:
            throw BridgeError(
                code: .invalidRequest,
                message: "第 \(position + 1) 轮的 kind「\(value)」无法识别。",
                hint: "可选：independentOpinion / crossExamination / convergence。"
            )
        }
    }

    private static func parseVisibility(_ raw: String?, position: Int) throws -> RoundVisibility? {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }

        switch value.lowercased() {
        case "none", "不看他人", "独立", "isolated":        return RoundVisibility.none
        case "others", "看他人", "peer":                    return RoundVisibility.others
        case "all", "看全部", "everyone", "full":           return RoundVisibility.all
        default:
            throw BridgeError(
                code: .invalidRequest,
                message: "第 \(position + 1) 轮的 visibility「\(value)」无法识别。",
                hint: "可选：none（不看他人）/ others（看他人）/ all（看全部）。"
            )
        }
    }

    private static func parseConsensus(_ raw: String) -> ConsensusRule? {
        let normalized = raw
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()

        switch normalized {
        case "moderatorsummary", "moderator", "主席汇总", "汇总":        return .moderatorSummary
        case "majorityvote", "majority", "vote", "多数投票", "投票":     return .majorityVote
        case "unanimous", "一致同意", "全体同意":                        return .unanimous
        case "chairmandecides", "chairman", "主席独裁", "独裁":          return .chairmanDecides
        default:                                                        return nil
        }
    }

    // MARK: - 最终校验（与界面「保存」同一套规则）

    private static func validate(group: DiscussionGroup, services: DiscussionServices) throws {
        let enabled = group.enabledParticipants

        guard enabled.count >= 2 else {
            throw BridgeError(
                code: .invalidRequest,
                message: "至少需要 2 位启用成员，当前 \(enabled.count) 位。",
                hint: "讨论的意义在于观点互斥，单人无法形成质询。"
            )
        }

        for participant in enabled {
            if participant.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "成员「\(participant.displayName)」没有绑定 Chrome Profile。",
                    hint: "在 participants 里给 profile，或让 app 自动分配。"
                )
            }
            if participant.emailHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "成员「\(participant.displayName)」缺少账号标识。",
                    hint: "在 participants 里给 account（邮箱或 Profile 显示名）。"
                )
            }
        }

        let directories = enabled.map {
            $0.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard Set(directories).count == directories.count else {
            throw BridgeError(
                code: .invalidRequest,
                message: "有成员共用了同一个 Chrome Profile。",
                hint: "同一个人不能同时扮演两个角色 —— 身份校验会直接拦下。"
                    + "当前绑定：\(directories.joined(separator: " / "))。"
            )
        }

        // Profile 必须真实存在，否则到会话层才炸，报错会难懂得多
        let available = Set(
            ((try? services.chromeProfiles.availableProfiles()) ?? []).map(\.directoryName)
        )
        if !available.isEmpty {
            for directory in directories where !available.contains(directory) {
                throw BridgeError(
                    code: .invalidRequest,
                    message: "Chrome Profile「\(directory)」不存在。",
                    hint: "本机可用：\(available.sorted().joined(separator: " / "))。"
                )
            }
        }
    }

    private static func findGroup(
        named name: String,
        services: DiscussionServices
    ) throws -> DiscussionGroup? {
        let all = try services.discussionRepo.fetchAllGroups()
        return all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

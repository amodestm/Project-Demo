import SwiftUI
import AIRunnerCore

/// 讨论组配置 —— 议题、成员、议程、收敛规则。
///
/// ## 界面上的关键引导
///
/// 成员角色必须**互斥**才能让讨论有价值。因此这里提供预设角色一键添加,
/// 并在成员为空时明确提示"至少需要 2 位立场不同的成员"。
struct DiscussionConfigView: View {

    let services: AppServices
    @Binding var group: DiscussionGroup
    var onSave: (DiscussionGroup) -> Void

    @State private var draft: DiscussionGroup
    @State private var editingParticipant: DiscussionParticipant?
    @State private var showingRolePicker = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    init(
        services: AppServices,
        group: Binding<DiscussionGroup>,
        onSave: @escaping (DiscussionGroup) -> Void
    ) {
        self.services = services
        self._group = group
        self.onSave = onSave
        self._draft = State(initialValue: group.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("讨论组配置").font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)

            Divider()

            Form {
                basicSection
                participantsSection
                roundsSection
                consensusSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 640, height: 560)
        .sheet(item: $editingParticipant) { participant in
            ParticipantEditorView(
                participant: participant,
                profiles: (try? services.chromeProfiles.availableProfiles()) ?? [],
                profileAliases: services.settings.accountRotationProfileAliases
            ) { updated in
                if let index = draft.participants.firstIndex(where: { $0.id == updated.id }) {
                    draft.participants[index] = updated
                }
            }
        }
        .sheet(isPresented: $showingRolePicker) {
            RolePickerView { template in
                draft.participants.append(
                    DiscussionParticipant(
                        displayName: template.displayName,
                        rolePrompt: template.rolePrompt,
                        avatarSymbol: template.avatarSymbol,
                        accentHex: template.accentHex
                    )
                )
            }
        }
        .alert("保存失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        Section("基本信息") {
            TextField("讨论组名称", text: $draft.name)

            VStack(alignment: .leading, spacing: 4) {
                Text("议题 / 要决策的问题").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.topic)
                    .font(.callout)
                    .frame(minHeight: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                Text("写清楚要决策什么。模糊的议题会得到模糊的讨论。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 成员

    private var participantsSection: some View {
        Section {
            ForEach(draft.participants) { participant in
                HStack(spacing: 10) {
                    AgentAvatar(
                        symbol: participant.avatarSymbol,
                        hex: participant.accentHex,
                        size: 30
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(participant.displayName)
                                .font(.callout.bold())

                            profilePicker(for: participant)
                        }

                        Text(participant.rolePrompt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { participant.enabled },
                        set: { newValue in
                            if let i = draft.participants.firstIndex(where: { $0.id == participant.id }) {
                                draft.participants[i].enabled = newValue
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Button("编辑") { editingParticipant = participant }
                        .controlSize(.small)

                    Button {
                        draft.participants.removeAll { $0.id == participant.id }
                        if draft.moderatorParticipantID == participant.id {
                            draft.moderatorParticipantID = nil
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
            }

            HStack {
                Button {
                    showingRolePicker = true
                } label: {
                    Label("添加预设角色", systemImage: "plus.circle.fill")
                }
                .controlSize(.small)

                Button {
                    draft.participants.append(
                        DiscussionParticipant(
                            displayName: "新成员",
                            rolePrompt: "",
                            avatarSymbol: DiscussionPalette.symbol(for: draft.participants.count),
                            accentHex: DiscussionPalette.hex(for: draft.participants.count)
                        )
                    )
                } label: {
                    Label("空白成员", systemImage: "plus")
                }
                .controlSize(.small)

                Button {
                    autoAssignProfiles(shuffle: false)
                } label: {
                    Label("一键分配", systemImage: "person.crop.circle.badge.checkmark")
                }
                .controlSize(.small)
                .help("从本地检测到的 Chrome Profile 中，自动为未绑定账号的成员分配不同的 Profile")

                Button {
                    autoAssignProfiles(shuffle: true)
                } label: {
                    Label("随机换一批", systemImage: "shuffle")
                }
                .controlSize(.small)
                .help("随机打乱可用 Chrome Profile 池并重新分配，避开固定批次或失效账号")

                Spacer()
            }
        } header: {
            Text("成员 (\(draft.participants.count))")
        } footer: {
            if draft.enabledParticipants.count < 2 {
                Text("⚠️ 至少需要 2 位**立场互斥**的成员, 否则讨论会变成自我附和。"
                     + "预设角色的职责刻意互斥 (批判者不提建议、成本专家不谈体验)。")
                    .foregroundStyle(.orange)
            } else {
                Text("每位成员绑定一个已登录 ChatGPT 的 Chrome Profile。"
                     + "默认按 Profile 显示名称校验；只有实际邮箱不同才需要单独填写。")
            }
        }
    }

    // MARK: - 议程

    private var roundsSection: some View {
        Section {
            ForEach(Array(draft.rounds.enumerated()), id: \.element.id) { index, round in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        TextField("轮次标题", text: $draft.rounds[index].title)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $draft.rounds[index].kind) {
                            ForEach(DiscussionRoundKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Button {
                            draft.rounds.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 10) {
                        TextField("本轮指令 (可选)", text: $draft.rounds[index].instruction)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Picker("", selection: $draft.rounds[index].visibility) {
                            ForEach(RoundVisibility.allCases, id: \.self) { v in
                                Text(v.displayName).tag(v)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 96)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
            }

            Button {
                draft.rounds.append(
                    DiscussionRoundConfig(kind: .crossExamination)
                )
            } label: {
                Label("添加轮次", systemImage: "plus")
            }
            .controlSize(.small)
        } header: {
            Text("议程 (\(draft.rounds.count) 轮)")
        } footer: {
            Text("「不看他人」= 独立论述, 避免被带节奏; 「看他人」= 交叉质询。")
        }
    }

    // MARK: - 收敛

    private var consensusSection: some View {
        Section {
            Picker("收敛方式", selection: $draft.consensus) {
                ForEach(ConsensusRule.allCases, id: \.self) { rule in
                    Text(rule.displayName).tag(rule)
                }
            }
            Text(draft.consensus.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Picker("主席", selection: Binding(
                get: { draft.moderatorParticipantID ?? "" },
                set: { draft.moderatorParticipantID = $0.isEmpty ? nil : $0 }
            )) {
                Text("自动 (第一位启用成员)").tag("")
                ForEach(draft.enabledParticipants) { p in
                    Text(p.displayName).tag(p.id)
                }
            }
        } header: {
            Text("收敛")
        }
    }

    // MARK: - 保存

    private func save() {
        guard !draft.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先填写讨论议题。"
            return
        }
        applyDefaultAccountIdentities()
        let enabled = draft.enabledParticipants
        guard enabled.count >= 2 else {
            errorMessage = "至少需要 2 位启用成员。"
            return
        }
        guard enabled.allSatisfy({
            !$0.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.emailHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            errorMessage = "每位启用成员都必须绑定 Chrome Profile，并提供可校验的账号名称。"
            return
        }
        let profiles = enabled.map { $0.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(profiles).count == profiles.count else {
            errorMessage = "每位成员必须使用不同的 Chrome Profile。"
            return
        }
        draft.updatedAt = Date()
        do {
            try services.discussionRepo.save(draft)
        } catch {
            errorMessage = AppError.normalize(error).userMessage
            return
        }
        group = draft
        onSave(draft)
        dismiss()
    }

    private func applyDefaultAccountIdentities() {
        let profiles = (try? services.chromeProfiles.availableProfiles()) ?? []
        for index in draft.participants.indices {
            let current = draft.participants[index].emailHint
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard current.isEmpty else { continue }
            let directory = draft.participants[index].profileDirectory
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let profile = profiles.first(where: { $0.directoryName == directory }) else {
                draft.participants[index].emailHint = directory
                continue
            }
            draft.participants[index].emailHint = profile.preferredAccountIdentity(
                alias: services.settings.accountRotationProfileAliases[directory]
            )
        }
    }

    private var availableProfiles: [ChromeProfile] {
        let all = (try? services.chromeProfiles.availableProfiles()) ?? []
        let valid = all.filter { $0.directoryName != "Default" && $0.directoryName != "Profile 10" }
        return valid.isEmpty ? all : valid
    }

    @ViewBuilder
    private func profilePicker(for participant: DiscussionParticipant) -> some View {
        let currentDir = participant.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnassigned = currentDir.isEmpty || currentDir == "Default"
        Menu {
            ForEach(availableProfiles) { profile in
                Button {
                    if let i = draft.participants.firstIndex(where: { $0.id == participant.id }) {
                        draft.participants[i].profileDirectory = profile.directoryName
                        draft.participants[i].emailHint = profile.preferredAccountIdentity(
                            alias: services.settings.accountRotationProfileAliases[profile.directoryName]
                        )
                    }
                } label: {
                    HStack {
                        Text("\(profile.directoryName) (\(profile.displayName))")
                        if currentDir == profile.directoryName {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isUnassigned ? "exclamationmark.triangle.fill" : "person.crop.circle")
                Text(isUnassigned ? "选择 Profile" : "\(currentDir) · \(participant.emailHint.isEmpty ? currentDir : participant.emailHint)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isUnassigned ? Color.orange.opacity(0.15) : Color.blue.opacity(0.12))
            .foregroundStyle(isUnassigned ? Color.orange : Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func autoAssignProfiles(shuffle: Bool = false) {
        let available = availableProfiles
        guard !available.isEmpty else { return }
        var pool = available
        if shuffle {
            pool.shuffle()
        }

        var used = Set<String>()
        if !shuffle {
            for p in draft.participants where !p.profileDirectory.isEmpty && p.profileDirectory != "Default" && p.profileDirectory != "Profile 10" {
                used.insert(p.profileDirectory)
            }
        }

        for index in draft.participants.indices {
            let currentDir = draft.participants[index].profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if shuffle || currentDir.isEmpty || currentDir == "Default" || currentDir == "Profile 10" {
                if let free = pool.first(where: { !used.contains($0.directoryName) }) {
                    draft.participants[index].profileDirectory = free.directoryName
                    draft.participants[index].emailHint = free.preferredAccountIdentity(
                        alias: services.settings.accountRotationProfileAliases[free.directoryName]
                    )
                    used.insert(free.directoryName)
                }
            }
        }
    }
}

// MARK: - 成员编辑

struct ParticipantEditorView: View {

    @State private var draft: DiscussionParticipant
    @State private var usesCustomAccountIdentity: Bool
    let profiles: [ChromeProfile]
    let profileAliases: [String: String]
    let onSave: (DiscussionParticipant) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        participant: DiscussionParticipant,
        profiles: [ChromeProfile] = [],
        profileAliases: [String: String] = [:],
        onSave: @escaping (DiscussionParticipant) -> Void
    ) {
        var initialParticipant = participant
        let selectedProfile = profiles.first {
            $0.directoryName == participant.profileDirectory
        }
        let defaultIdentity = selectedProfile?.preferredAccountIdentity(
            alias: profileAliases[participant.profileDirectory]
        ) ?? participant.profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIdentity = participant.emailHint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if currentIdentity.isEmpty {
            initialParticipant.emailHint = defaultIdentity
        }
        self._draft = State(initialValue: initialParticipant)
        self._usesCustomAccountIdentity = State(initialValue:
            !currentIdentity.isEmpty
                && currentIdentity.caseInsensitiveCompare(defaultIdentity) != .orderedSame
        )
        self.profiles = profiles
        self.profileAliases = profileAliases
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑成员").font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                Button("完成") {
                    applyAccountIdentity()
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            Form {
                TextField("显示名", text: $draft.displayName)

                VStack(alignment: .leading, spacing: 4) {
                    Text("角色与立场").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.rolePrompt)
                        .font(.callout)
                        .frame(minHeight: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                    Text("写清这个角色专门负责什么, 最好明确禁止他做什么 —— "
                         + "片面才有差异。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Picker("头像", selection: $draft.avatarSymbol) {
                    ForEach(DiscussionPalette.avatarSymbols, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }

                Picker("颜色", selection: $draft.accentHex) {
                    ForEach(DiscussionPalette.options, id: \.hex) { option in
                        HStack {
                            Circle()
                                .fill(Color(hex: option.hex))
                                .frame(width: 12, height: 12)
                            Text(option.name)
                        }
                        .tag(option.hex)
                    }
                }

                if profiles.isEmpty {
                    TextField("Chrome Profile 目录 (如 Profile 3)", text: $draft.profileDirectory)
                    TextField("账号邮箱 / 别名 (用于校验窗口身份)", text: $draft.emailHint)
                } else {
                    Picker("ChatGPT 账号", selection: $draft.profileDirectory) {
                        Text("请选择账号").tag("")
                        ForEach(profiles) { profile in
                            Text(profileLabel(profile)).tag(profile.directoryName)
                        }
                    }
                    .onChange(of: draft.profileDirectory) { _, directory in
                        usesCustomAccountIdentity = false
                        draft.emailHint = defaultAccountIdentity(for: directory)
                    }

                    LabeledContent("默认校验账号") {
                        Text(defaultAccountIdentity(for: draft.profileDirectory).isEmpty
                             ? "请先选择 Profile"
                             : defaultAccountIdentity(for: draft.profileDirectory))
                            .foregroundStyle(.secondary)
                    }

                    Toggle("校验邮箱与 Profile 名称不一致", isOn: $usesCustomAccountIdentity)
                        .onChange(of: usesCustomAccountIdentity) { _, isCustom in
                            if !isCustom {
                                draft.emailHint = defaultAccountIdentity(
                                    for: draft.profileDirectory
                                )
                            }
                        }

                    if usesCustomAccountIdentity {
                        TextField("实际账号邮箱（发送前校验）", text: $draft.emailHint)
                    }

                    Text("默认直接使用 Profile 的显示名称校验；只有实际邮箱不同才需要打开上方选项并输入。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 520)
    }

    private func profileLabel(_ profile: ChromeProfile) -> String {
        let alias = profileAliases[profile.directoryName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !alias.isEmpty {
            return "\(alias) · \(profile.directoryName)"
        }
        return profile.label
    }

    private func defaultAccountIdentity(for directory: String) -> String {
        guard let profile = profiles.first(where: { $0.directoryName == directory }) else {
            return directory.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return profile.preferredAccountIdentity(alias: profileAliases[directory])
    }

    private func applyAccountIdentity() {
        if usesCustomAccountIdentity {
            draft.emailHint = draft.emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            draft.emailHint = defaultAccountIdentity(for: draft.profileDirectory)
        }
    }
}

// MARK: - 预设角色选择

struct RolePickerView: View {

    let onPick: (DiscussionPresets.RoleTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择预设角色").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    Text("这些角色的职责刻意互斥 —— 用强制片面换取观点差异, "
                         + "避免所有账号给出雷同答案。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(DiscussionPresets.roles, id: \.displayName) { role in
                        Button {
                            onPick(role)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                AgentAvatar(
                                    symbol: role.avatarSymbol,
                                    hex: role.accentHex,
                                    size: 32
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(role.displayName)
                                        .font(.callout.bold())
                                        .foregroundStyle(Color(hex: role.accentHex))
                                    Text(role.rolePrompt)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(hex: role.accentHex).opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 520)
    }
}

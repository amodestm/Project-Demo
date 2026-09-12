import SwiftUI
import AIRunnerCore

/// Provider 配置: 端点、默认模型、API Key (写入 macOS Keychain)。
struct ProviderSettingsView: View {

    let services: AppServices

    @State private var selection: String?
    @State private var apiKeyInput = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false

    @State private var draftBaseURL = ""
    @State private var draftModel = ""
    @State private var draftEnabled = true
    @State private var loadedProviderID: String?

    private var providers: [ProviderConfig] {
        services.factory.allProviders
    }

    private var selectedProvider: ProviderConfig? {
        guard let selection else { return nil }
        return providers.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            editor
                .frame(minWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 左: Provider 列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Provider")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)

            List(selection: $selection) {
                ForEach(providers) { provider in
                    HStack(spacing: 8) {
                        Image(systemName: services.factory.isConfigured(providerID: provider.id)
                              ? "checkmark.seal.fill" : "circle.dashed")
                            .foregroundStyle(services.factory.isConfigured(providerID: provider.id)
                                             ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.displayName).font(.callout)
                            Text(provider.requiresAPIKey
                                 ? services.factory.maskedKey(for: provider.id)
                                 : "无需密钥")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !provider.enabled {
                            Text("已禁用")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(provider.id)
                }
            }
            .listStyle(.inset)
        }
        .onAppear {
            if selection == nil { selection = providers.first?.id }
        }
    }

    // MARK: 右: 编辑表单

    @ViewBuilder
    private var editor: some View {
        if let provider = selectedProvider {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    HStack {
                        Text(provider.displayName).font(.title3.bold())
                        Text(provider.kind.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Spacer()
                    }

                    Divider()

                    field("Base URL (不含 /chat/completions)") {
                        TextField("https://api.example.com/v1", text: $draftBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    field("默认模型") {
                        TextField("model-name", text: $draftModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    Toggle("启用此 Provider", isOn: $draftEnabled)

                    Divider()

                    field("API Key") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                SecureField("粘贴 API Key (sk-…)", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                Button("保存到 Keychain") { saveKey(for: provider) }
                                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill").font(.caption2)
                                Text("当前: \(services.factory.maskedKey(for: provider.id))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text("Key 只写入 macOS Keychain (service = com.airunner.apikeys, "
                                 + "account = \(provider.keychainKey))。不会进入数据库、日志或 UserDefaults。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            if services.factory.isConfigured(providerID: provider.id),
                               provider.requiresAPIKey {
                                Button("删除已存密钥", role: .destructive) {
                                    deleteKey(for: provider)
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .green)
                    }

                    Divider()

                    HStack {
                        Button("保存 Provider 设置") { saveProvider(provider) }
                            .buttonStyle(.borderedProminent)
                        Button("还原") { load(provider) }
                        Spacer()
                    }
                }
                .padding(18)
            }
            .id(provider.id)
        } else {
            ContentUnavailableView("选择一个 Provider", systemImage: "server.rack")
        }
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: 动作

    private func load(_ provider: ProviderConfig) {
        draftBaseURL = provider.baseURL
        draftModel = provider.defaultModel
        draftEnabled = provider.enabled
        apiKeyInput = ""
        loadedProviderID = provider.id
        statusMessage = nil
    }

    private func saveProvider(_ provider: ProviderConfig) {
        var updated = provider
        updated.baseURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.defaultModel = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.enabled = draftEnabled

        guard !updated.baseURL.isEmpty, !updated.defaultModel.isEmpty else {
            report("Base URL 与默认模型不能为空", isError: true)
            return
        }

        var settings = services.settings
        if let index = settings.providers.firstIndex(where: { $0.id == provider.id }) {
            settings.providers[index] = updated
        } else {
            settings.providers.append(updated)
        }

        Task {
            await services.saveSettings(settings)
            await MainActor.run {
                report("已保存 \(updated.displayName) 的设置", isError: false)
            }
        }
    }

    private func saveKey(for provider: ProviderConfig) {
        do {
            try services.factory.saveAPIKey(apiKeyInput, for: provider.id)
            apiKeyInput = ""
            report("API Key 已写入 Keychain", isError: false)
            refreshSelection()
        } catch {
            report(AppError.normalize(error).userMessage, isError: true)
        }
    }

    private func deleteKey(for provider: ProviderConfig) {
        do {
            try services.factory.deleteAPIKey(for: provider.id)
            report("已删除 Keychain 中的密钥", isError: false)
            refreshSelection()
        } catch {
            report(AppError.normalize(error).userMessage, isError: true)
        }
    }

    /// 强制刷新左侧列表的"已配置"状态。
    private func refreshSelection() {
        let current = selection
        selection = nil
        DispatchQueue.main.async { selection = current }
    }

    private func report(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}

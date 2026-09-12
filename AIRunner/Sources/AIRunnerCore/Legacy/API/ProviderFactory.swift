import Foundation

/// 根据 (provider, model) 构造可执行的 AIProvider 实例。
///
/// 这里是**唯一**读取 API Key 的地方。读完立刻登记到 `SecretRedactor`,
/// 确保后续任何日志都不会把它打印出来。
///
/// 做成 class (而非 struct) 是为了让 Settings 变更能**就地生效**:
/// `ModelRouter` 持有的 `isProviderConfigured` 闭包引用同一个实例,
/// 因此用户在设置里填完 Key 后不需要重建整个依赖图。
public final class ProviderFactory: @unchecked Sendable {

    private let lock = NSLock()
    private var providerConfigs: [String: ProviderConfig]
    private let keychain: any KeychainManaging
    private let session: URLSession?

    /// 测试专用覆盖表, key = "provider::model"。
    /// 生产路径永不写入 —— `ProviderConfig.defaults` 里没有任何 mock provider,
    /// 且 UI 也不提供注册入口。
    private var overrides: [String: any AIProvider] = [:]

    public init(
        providers: [ProviderConfig],
        keychain: any KeychainManaging,
        session: URLSession? = nil
    ) {
        var map: [String: ProviderConfig] = [:]
        for provider in providers {
            map[provider.id] = provider
        }
        self.providerConfigs = map
        self.keychain = keychain
        self.session = session
    }

    /// 替换 Provider 配置 (Settings 保存时调用)。
    public func update(providers: [ProviderConfig]) {
        var map: [String: ProviderConfig] = [:]
        for provider in providers { map[provider.id] = provider }
        lock.lock(); defer { lock.unlock() }
        providerConfigs = map
    }

    // MARK: - 查询

    public func config(for providerID: String) -> ProviderConfig? {
        lock.lock(); defer { lock.unlock() }
        return providerConfigs[providerID]
    }

    public var allProviders: [ProviderConfig] {
        lock.lock(); defer { lock.unlock() }
        return providerConfigs.values.sorted { $0.id < $1.id }
    }

    public func allProviderIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return providerConfigs.keys.sorted()
    }

    /// 该 Provider 是否已经可以直接使用 (本地模型无需 Key)。
    public func isConfigured(providerID: String) -> Bool {
        guard let config = config(for: providerID), config.enabled else { return false }
        guard config.requiresAPIKey else { return true }
        return hasUsableStoredKey(config.keychainKey)
    }

    public func hasStoredKey(_ keychainKey: String) -> Bool {
        hasUsableStoredKey(keychainKey)
    }

    private func hasUsableStoredKey(_ keychainKey: String) -> Bool {
        guard let value = try? keychain.read(key: keychainKey) else { return false }
        return !value.isEmpty
    }

    public func availableProviderIDs() -> [String] {
        allProviderIDs().filter { isConfigured(providerID: $0) }
    }

    // MARK: - 密钥

    /// 读取 API Key 并登记脱敏。
    public func apiKey(for providerID: String) -> String? {
        guard let config = config(for: providerID), config.requiresAPIKey else { return nil }
        let key = try? keychain.read(key: config.keychainKey)
        SecretRedactor.register(key)
        return key
    }

    public func saveAPIKey(_ value: String, for providerID: String) throws {
        guard let config = config(for: providerID) else {
            throw AppError.invalidRequest("未知 Provider: \(providerID)")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidRequest("API Key 不能为空")
        }
        try keychain.save(key: config.keychainKey, value: trimmed)
        SecretRedactor.register(trimmed)
    }

    public func deleteAPIKey(for providerID: String) throws {
        guard let config = config(for: providerID) else { return }
        try keychain.delete(key: config.keychainKey)
    }

    /// 只返回脱敏后的展示值 —— UI 永远拿不到明文。
    public func maskedKey(for providerID: String) -> String {
        guard let config = config(for: providerID), config.requiresAPIKey else {
            return "无需密钥"
        }
        let value = try? keychain.read(key: config.keychainKey)
        return SecretMasking.mask(value)
    }

    /// 登记所有已配置的密钥到脱敏器 (App 启动时调用一次)。
    public func registerAllSecrets() {
        for provider in allProviders where provider.requiresAPIKey {
            if let value = try? keychain.read(key: provider.keychainKey) {
                SecretRedactor.register(value)
            }
        }
    }

    // MARK: - 测试注入

    /// 测试专用: 覆盖某个 (provider, model) 的 Provider 实例。
    ///
    /// 用于把 `MockAIProvider` 的脚本注入执行链, 从而精确构造
    /// "第 3 步超时一次后成功" 这类场景。
    public func registerOverride(_ provider: any AIProvider, providerID: String, model: String) {
        lock.lock(); defer { lock.unlock() }
        overrides["\(providerID)::\(model)"] = provider
    }

    public func removeOverride(providerID: String, model: String) {
        lock.lock(); defer { lock.unlock() }
        overrides.removeValue(forKey: "\(providerID)::\(model)")
    }

    public func removeAllOverrides() {
        lock.lock(); defer { lock.unlock() }
        overrides.removeAll()
    }

    private func override(providerID: String, model: String) -> (any AIProvider)? {
        lock.lock(); defer { lock.unlock() }
        return overrides["\(providerID)::\(model)"]
    }

    // MARK: - 构造

    public func makeProvider(providerID: String, model: String) throws -> any AIProvider {
        if let registered = override(providerID: providerID, model: model) {
            return registered
        }
        guard let config = config(for: providerID) else {
            throw AppError.invalidRequest("未知 Provider: \(providerID)")
        }
        guard config.enabled else {
            throw AppError.invalidRequest("Provider \(providerID) 已被禁用")
        }

        switch config.kind {
        case .mock:
            // 只可能由测试 / 离线 Demo 显式触发 —— ProviderConfig.defaults 里没有 mock。
            return MockAIProvider(id: providerID, model: model)

        case .openAICompatible:
            let key = apiKey(for: providerID)
            if config.requiresAPIKey, (key ?? "").isEmpty {
                throw AppError.authentication
            }
            return OpenAICompatibleProvider(
                config: config,
                model: model,
                apiKey: key,
                session: session
            )
        }
    }
}

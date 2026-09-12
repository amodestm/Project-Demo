import Foundation

/// 一个 Codex 登录账号, 供「退出当前账号 → 重新账号密码登录」式切换。
///
/// ## ★ 密码只存在 Keychain ★
///
/// `password` 字段仅作为 Keychain JSON blob 的编解码形态存在:
/// - **不进** SQLite / UserDefaults / 日志 / 源码 / 任何配置文件
/// - 只在登录动作发生的那一刻被短暂取出
/// - UI 展示只允许出现 label 与 email (email 是用户名, 不是机密;
///   与 ssh config / aws credentials 存用户名同级)
public struct CodexAccountRecord: Codable, Sendable, Equatable, Identifiable {

    public let id: String
    /// 用户起的名字 (如 "账号A")。
    public var label: String
    /// 登录邮箱。
    public var email: String
    /// ★ 登录密码 —— 只允许在 Keychain blob 里。★
    public var password: String

    public init(id: String = UUID().uuidString, label: String, email: String, password: String) {
        self.id = id
        self.label = label
        self.email = email
        self.password = password
    }

    /// 安全摘要 (日志/展示用, 不含密码)。
    public var summary: String { "\(label) <\(email)>" }
}

/// Codex 账号仓库 (测试可注入替身)。
public protocol CodexAccountVaulting: Sendable {

    /// 新增一个账号, 返回带 id 的记录。
    @discardableResult
    func save(label: String, email: String, password: String) throws -> CodexAccountRecord

    /// 更新已有账号 (密码改了/改邮箱/改名)。
    func update(_ record: CodexAccountRecord) throws

    func fetch(id: String) throws -> CodexAccountRecord?

    /// 删除。返回是否真的删掉了。
    @discardableResult
    func delete(id: String) throws -> Bool
}

/// 基于 macOS Keychain 的账号仓库。
///
/// 存储形态: `KeychainManaging` (kSecClassGenericPassword) 下的
/// `codex.account.<uuid>` 键, 值为整条记录的 JSON (含密码, 由 Keychain 加密)。
///
/// 复用注入的 Keychain 实例 —— 测试注入 InMemoryKeychain 即可全内存隔离,
/// 生产用 KeychainManager (service = com.airunner.apikeys, 键前缀区分)。
public struct CodexKeychainVault: CodexAccountVaulting {

    private let keychain: any KeychainManaging

    public init(keychain: any KeychainManaging) {
        self.keychain = keychain
    }

    static func storageKey(_ id: String) -> String { "codex.account.\(id)" }

    // MARK: - 写

    @discardableResult
    public func save(label: String, email: String, password: String) throws -> CodexAccountRecord {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password

        guard !trimmedLabel.isEmpty else {
            throw AppError.invalidRequest("账号名称不能为空")
        }
        guard trimmedEmail.contains("@"), !trimmedEmail.contains(" ") else {
            throw AppError.invalidRequest("邮箱格式看起来不对: \(trimmedEmail)")
        }
        guard !trimmedPassword.isEmpty else {
            throw AppError.invalidRequest("密码不能为空")
        }

        let record = CodexAccountRecord(
            id: UUID().uuidString,
            label: trimmedLabel,
            email: trimmedEmail,
            password: trimmedPassword
        )
        try keychain.save(key: Self.storageKey(record.id), value: try Self.encode(record))
        return record
    }

    public func update(_ record: CodexAccountRecord) throws {
        guard (try? keychain.read(key: Self.storageKey(record.id))) != nil else {
            throw AppError.invalidRequest("要更新的账号不存在: \(record.label)")
        }
        try keychain.save(key: Self.storageKey(record.id), value: try Self.encode(record))
    }

    // MARK: - 读

    public func fetch(id: String) throws -> CodexAccountRecord? {
        guard let raw = try keychain.read(key: Self.storageKey(id)) else { return nil }
        return try? JSONCoding.decode(CodexAccountRecord.self, from: raw)
    }

    /// Keychain 不支持按键枚举 —— 全量列表由 `AppSettings.codexAccountRotationIDs`
    /// (非敏感的 id 顺序表) 承担, 逐 id fetch。

    // MARK: - 删

    @discardableResult
    public func delete(id: String) throws -> Bool {
        let existed = (try? keychain.read(key: Self.storageKey(id))) != nil
        try keychain.delete(key: Self.storageKey(id))
        return existed
    }

    // MARK: - 内部

    private static func encode(_ record: CodexAccountRecord) throws -> String {
        try JSONCoding.encodeToString(record)
    }
}

/// 全内存账号仓库 —— 单元测试用。绝不用于生产。
public final class InMemoryCodexAccountVault: CodexAccountVaulting, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: CodexAccountRecord] = [:]

    public init() {}

    @discardableResult
    public func save(label: String, email: String, password: String) throws -> CodexAccountRecord {
        let record = CodexAccountRecord(id: UUID().uuidString, label: label, email: email, password: password)
        lock.lock(); defer { lock.unlock() }
        storage[record.id] = record
        return record
    }

    public func update(_ record: CodexAccountRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard storage[record.id] != nil else {
            throw AppError.invalidRequest("要更新的账号不存在: \(record.label)")
        }
        storage[record.id] = record
    }

    public func fetch(id: String) throws -> CodexAccountRecord? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    public func fetchAll() throws -> [CodexAccountRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(storage.values)
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let existed = storage.removeValue(forKey: id) != nil
        return existed
    }
}

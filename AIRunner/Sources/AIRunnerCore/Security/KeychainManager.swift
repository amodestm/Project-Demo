import Foundation
import Security

/// Keychain 抽象。便于测试时替换为内存实现。
public protocol KeychainManaging: Sendable {
    func save(key: String, value: String) throws
    func read(key: String) throws -> String?
    func delete(key: String) throws
    func exists(key: String) throws -> Bool
}

/// 基于 macOS Security.framework 的真实 Keychain 实现。
///
/// 存储形态: `kSecClassGenericPassword`, service = `com.airunner.apikeys`,
/// account = Provider 的 keychainKey (如 `openai.apiKey`)。
///
/// 可访问性: 使用 `kSecAttrAccessibleAfterFirstUnlock` —— 这样 App 在后台/由 launchd
/// 拉起时依然能读到密钥, 但设备完全锁定后不可读。这是安全与可自动化之间的正确取舍。
///
/// ★ 安全红线 ★
/// API Key **只** 允许存在这里。禁止写入 UserDefaults / SQLite / 日志 / plist / 源码。
public struct KeychainManager: KeychainManaging {

    public let service: String

    public init(service: String = "com.airunner.apikeys") {
        self.service = service
    }

    // MARK: - 写

    public func save(key: String, value: String) throws {
        guard !key.isEmpty else { throw AppError.fatal("Keychain key 不能为空") }
        guard !value.isEmpty else { throw AppError.fatal("拒绝写入空密钥 (key=\(key))") }

        let data = Data(value.utf8)
        let query = baseQuery(key: key)

        // 先尝试更新: 避免"已存在则 add 失败"的常见坑。
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw Self.error(status: addStatus, operation: "写入密钥", key: key)
            }
            return
        }

        throw Self.error(status: updateStatus, operation: "更新密钥", key: key)
    }

    // MARK: - 读

    public func read(key: String) throws -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw AppError.fatal("Keychain 返回了非 Data 内容 (key=\(key))")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw AppError.fatal("Keychain 内容不是合法 UTF-8 (key=\(key))")
            }
            return text.isEmpty ? nil : text
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status: status, operation: "读取密钥", key: key)
        }
    }

    // MARK: - 删

    public func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw Self.error(status: status, operation: "删除密钥", key: key)
        }
    }

    public func exists(key: String) throws -> Bool {
        try read(key: key) != nil
    }

    // MARK: - 内部

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func error(status: OSStatus, operation: String, key: String) -> AppError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus=\(status)"
        return .fatal("Keychain \(operation) 失败 (key=\(key)): \(detail)")
    }
}

/// 内存 Keychain —— 仅供单元测试与离线 Demo。
/// 绝不用于生产: 数据不加密且随进程消失。
public final class InMemoryKeychain: KeychainManaging, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func save(key: String, value: String) throws {
        guard !key.isEmpty else { throw AppError.fatal("key 不能为空") }
        guard !value.isEmpty else { throw AppError.fatal("拒绝写入空密钥") }
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func read(key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func delete(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func exists(key: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage[key] != nil
    }
}

// MARK: - 展示辅助

public enum SecretMasking {

    /// 把密钥转成可安全展示/记录的形式。
    ///
    /// 规则: 长度 <= 8 全遮; 否则保留前 3 后 2。
    /// 绝不要在任何 UI / 日志里直接使用明文密钥。
    public static func mask(_ secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return "未配置" }
        if secret.count <= 8 { return String(repeating: "•", count: 8) }
        let prefix = secret.prefix(3)
        let suffix = secret.suffix(2)
        return "\(prefix)\(String(repeating: "•", count: 10))\(suffix)"
    }
}

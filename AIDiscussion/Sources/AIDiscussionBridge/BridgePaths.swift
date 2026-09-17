import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Unix domain socket 地址构造。
///
/// 单独抽出来是因为 `sun_path` 是定长 C 数组：路径长度的判断、结尾 NUL 的处理、
/// 以及 `sockaddr_un` → `sockaddr` 的重绑定，两侧各写一遍就迟早会有一侧写歪，
/// 而写歪的表现是"连接随机失败"，极难排查。
public enum UnixSocketAddress {

    /// `sun_path` 能容纳的字节数（含结尾 NUL）。
    ///
    /// 用 `size(ofValue:)` 而不是 `MemoryLayout.offset(of:)`：`sun_path` 是定长元组，
    /// 元组的 key path 在部分工具链上不可用。
    public static let pathCapacity: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// 构造地址；路径过长（放不下 + NUL）时返回 nil。
    public static func make(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path.utf8)
        guard bytes.count < pathCapacity else { return nil }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    /// 以 `sockaddr` 指针调用系统函数，自动带上正确的长度。
    public static func withSockaddr<R>(
        _ address: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R
    ) rethrows -> R {
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// 桥接的落盘位置与本地鉴权约定。
///
/// app 与 MCP 两端共用，避免路径/文件名两头写死不一致。
public enum BridgePaths {

    /// `~/Library/Application Support/AIDiscussion`
    public static func supportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AIDiscussion", isDirectory: true)
    }

    public static func socketURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager)
            .appendingPathComponent(BridgeProtocol.socketFileName)
    }

    public static func tokenURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager)
            .appendingPathComponent(BridgeProtocol.tokenFileName)
    }

    /// 描述文件：MCP 侧用来判断 app 是否就绪、以及拿到版本信息。
    public static func metaURL(fileManager: FileManager = .default) -> URL {
        supportDirectory(fileManager: fileManager)
            .appendingPathComponent(BridgeProtocol.metaFileName)
    }

    /// app 写入的元信息（`bridge.json`）。
    public struct Meta: Codable, Sendable {
        public var protocolVersion: Int
        public var pid: Int32
        public var appVersion: String
        public var socketPath: String

        public init(protocolVersion: Int, pid: Int32, appVersion: String, socketPath: String) {
            self.protocolVersion = protocolVersion
            self.pid = pid
            self.appVersion = appVersion
            self.socketPath = socketPath
        }
    }

    public static func readToken(fileManager: FileManager = .default) -> String? {
        guard let data = try? Data(contentsOf: tokenURL(fileManager: fileManager)),
              let token = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func readMeta(fileManager: FileManager = .default) -> Meta? {
        guard let data = try? Data(contentsOf: metaURL(fileManager: fileManager)) else { return nil }
        return try? BridgeJSON.decode(Meta.self, from: data)
    }

    /// 生成一个新的随机 token。
    public static func makeToken() -> String {
        // 两段 UUID 拼起来，熵足够做本地一次性凭据
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
}

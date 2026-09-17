import Foundation

/// 桥接层的 JSON 编解码。
///
/// 线协议是**换行分隔的 JSON**（newline-delimited JSON-RPC 风格）：
/// 一条消息 = 一行，因此编码结果**绝不能包含裸换行**。
/// 紧凑编码下的 JSON 会把字符串里的换行转义成 `\n` 两个字符，
/// 所以这里只需保证不做 pretty-print。
public enum BridgeJSON {

    public static let newline: UInt8 = 0x0A

    // MARK: - 编解码器

    public static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - 便捷方法

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        try makeEncoder(pretty: pretty).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        guard let data = line.data(using: .utf8) else {
            throw BridgeError(code: .invalidRequest, message: "消息不是合法的 UTF-8")
        }
        return try decode(type, from: data)
    }

    /// 紧凑单行字符串（可直接写进流）。
    public static func string<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encode(value, pretty: false) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func prettyString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encode(value, pretty: true) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 编码结果是否满足"单行"约束（测试与调试用）。
    public static func isSingleLine<T: Encodable>(_ value: T) -> Bool {
        guard let data = try? encode(value, pretty: false) else { return false }
        return !data.contains(newline)
    }
}

/// 把字节流切成一条条以换行结尾的消息。
///
/// stdio 与 Unix socket 都可能是**半包/粘包**的：一次 `read` 可能只拿到半条
/// 消息，也可能一次拿到三条。所有读取路径都必须过这个缓冲区。
public struct LineBuffer: Sendable {

    private var buffer = Data()

    public init() {}

    /// 追加新读到的字节，返回其中已经完整（以换行结尾）的消息。
    ///
    /// - 空行会被丢弃（客户端心跳/多余换行不应被当成消息）。
    /// - `\r\n` 也能正确处理。
    public mutating func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var messages: [Data] = []
        while let index = buffer.firstIndex(of: BridgeJSON.newline) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            var trimmed = Data(line)
            if trimmed.last == 0x0D { trimmed.removeLast() }   // 容忍 CRLF
            if !trimmed.isEmpty { messages.append(trimmed) }
        }
        return messages
    }

    /// 流结束时若还有残留（对端没补换行），把它当作最后一条消息。
    public mutating func flush() -> Data? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : buffer
    }

    public var pendingByteCount: Int { buffer.count }
}

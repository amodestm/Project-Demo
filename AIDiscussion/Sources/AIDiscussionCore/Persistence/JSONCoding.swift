import Foundation

/// 统一的 JSON 编解码入口。
///
/// 不缓存 JSONEncoder/JSONDecoder 实例 —— 它们不是 Sendable 的,
/// 跨并发域共享会因为内部可变状态产生数据竞争。每次构造的开销对本地任务可忽略。
public enum JSONCoding {

    public static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(DateCoding.string(from: date))
        }
        if pretty {
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = DateCoding.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "无法解析日期: \(s)"
                )
            }
            return date
        }
        return d
    }

    public static func encodeToString<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        let data = try makeEncoder(pretty: pretty).encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw AppError.invalidOutput("JSON 编码结果不是合法 UTF-8")
        }
        return s
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw AppError.invalidOutput("输入不是合法 UTF-8")
        }
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw AppError.invalidOutput("JSON 解码失败: \(error)")
        }
    }

    /// 宽松解码: 失败返回 nil, 不抛错。用于读取可能为空的 DB 列。
    public static func decodeIfPossible<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string, !string.isEmpty else { return nil }
        return try? decode(type, from: string)
    }
}

/// ISO8601 日期与字符串互转。
///
/// 使用 `Date.ISO8601FormatStyle` (值类型 + Sendable), 避免 `ISO8601DateFormatter`
/// 在并发环境下的共享可变状态问题。
public enum DateCoding {

    private static let withFraction = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: true,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    private static let withoutFraction = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: false,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    public static func string(from date: Date) -> String {
        withFraction.format(date)
    }

    public static func date(from string: String) -> Date? {
        if let d = try? withFraction.parse(string) { return d }
        return try? withoutFraction.parse(string)
    }

    /// 从任意 JSON 兼容值解析日期 (兼容旧数据里存数字时间戳的情况)。
    public static func date(from value: JSONValue?) -> Date? {
        guard let value else { return nil }
        switch value {
        case .string(let s): return date(from: s)
        case .double(let d): return Date(timeIntervalSince1970: d)
        case .int(let i):    return Date(timeIntervalSince1970: TimeInterval(i))
        default:             return nil
        }
    }
}

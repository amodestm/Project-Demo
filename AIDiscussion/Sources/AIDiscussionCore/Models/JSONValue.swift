import Foundation

/// Codable-safe 的任意 JSON 值。
///
/// 刻意 **不** 使用 `[AnyHashable: Any]` —— 它不 Codable、不 Sendable,
/// 且会在跨 actor 边界时静默丢失类型信息。
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Decoding

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let v = try? container.decode(Bool.self) {
            self = .bool(v); return
        }
        if let v = try? container.decode(Int.self) {
            self = .int(v); return
        }
        if let v = try? container.decode(Double.self) {
            self = .double(v); return
        }
        if let v = try? container.decode(String.self) {
            self = .string(v); return
        }
        if let v = try? container.decode([JSONValue].self) {
            self = .array(v); return
        }
        if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v); return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "无法识别的 JSON 值"
        )
    }

    // MARK: - Encoding

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case .bool(let v):     try container.encode(v)
        case .int(let v):      try container.encode(v)
        case .double(let v):   try container.encode(v)
        case .string(let v):   try container.encode(v)
        case .array(let v):    try container.encode(v)
        case .object(let v):   try container.encode(v)
        }
    }

    // MARK: - 便捷访问

    public var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .int(let v):    return String(v)
        case .double(let v): return String(v)
        case .bool(let v):   return String(v)
        default:             return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let v):    return v
        case .double(let v): return Int(v)
        case .string(let v): return Int(v)
        default:             return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v):    return Double(v)
        case .string(let v): return Double(v)
        default:             return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let v):   return v
        case .int(let v):    return v != 0
        case .string(let v): return ["true", "1", "yes"].contains(v.lowercased())
        default:             return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let arr) = self, arr.indices.contains(index) else { return nil }
        return arr[index]
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: - 常量

    public static let emptyObject = JSONValue.object([:])
    public static let emptyArray = JSONValue.array([])

    // MARK: - 与 Foundation 互转

    public init(any value: Any) {
        switch value {
        case let v as JSONValue:            self = v
        case is NSNull:                     self = .null
        case let v as Bool:                 self = .bool(v)
        case let v as Int:                  self = .int(v)
        case let v as Double:               self = .double(v)
        case let v as Float:                self = .double(Double(v))
        case let v as String:               self = .string(v)
        case let v as [Any]:                self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]:
            self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as NSNumber:
            // NSNumber 包住了 Bool 时会走到这里
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if v.doubleValue == v.doubleValue.rounded(),
                      abs(v.doubleValue) < Double(Int.max) {
                self = .int(v.intValue)
            } else {
                self = .double(v.doubleValue)
            }
        default:
            self = .string(String(describing: value))
        }
    }

    /// 转回 Foundation 对象 (写入 UserDefaults / 拼接 HTTP body 时用)。
    public var foundationValue: Any {
        switch self {
        case .null:            return NSNull()
        case .bool(let v):     return v
        case .int(let v):      return v
        case .double(let v):   return v
        case .string(let v):   return v
        case .array(let v):    return v.map(\.foundationValue)
        case .object(let v):   return v.mapValues(\.foundationValue)
        }
    }

    public var prettyDescription: String {
        (try? JSONCoding.encodeToString(self, pretty: true)) ?? "<unencodable>"
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

import Foundation

/// 密钥脱敏。
///
/// 两道防线:
/// 1. **精确匹配**: `register(_:)` 登记当前进程已知的密钥明文, 命中即整体替换。
/// 2. **模式匹配**: 识别 `sk-...` / `Bearer ...` / `api_key=...` 等常见形态。
///
/// 宁可多遮一点, 也不能让 Key 落进日志 —— 日志会进 SQLite, 而 SQLite 是不加密的。
public enum SecretRedactor {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var knownSecrets: [String] = []

    private static let patterns: [NSRegularExpression] = {
        let raw: [String] = [
            #"sk-[A-Za-z0-9_\-]{8,}"#,
            #"(?i)\bbearer\s+[A-Za-z0-9._\-]{8,}"#,
            #"(?i)\b(api[_-]?key|apikey|x-api-key|access[_-]?token|auth[_-]?token|secret|password)\b("?\s*[:=]\s*"?)([A-Za-z0-9._\-]{8,})"#,
            #"(?i)\b(anthropic|openai|deepseek|gemini|google)[_\-]?(key|token)\b("?\s*[:=]\s*"?)([A-Za-z0-9._\-]{8,})"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let replacement = "«REDACTED»"

    /// 登记一个已知密钥明文。只登记长度 >= 8 的值, 避免误伤普通文本。
    public static func register(_ secret: String?) {
        guard let secret, secret.count >= 8 else { return }
        lock.lock(); defer { lock.unlock() }
        guard !knownSecrets.contains(secret) else { return }
        // 只保留最近 32 个, 防止长期运行后无界增长
        knownSecrets.append(secret)
        if knownSecrets.count > 32 {
            knownSecrets.removeFirst(knownSecrets.count - 32)
        }
    }

    public static func unregisterAll() {
        lock.lock(); defer { lock.unlock() }
        knownSecrets.removeAll()
    }

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = text

        lock.lock()
        let secrets = knownSecrets
        lock.unlock()

        for secret in secrets where !secret.isEmpty {
            if output.contains(secret) {
                output = output.replacingOccurrences(of: secret, with: replacement)
            }
        }

        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        for regex in patterns {
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: fullRange,
                withTemplate: replacement
            )
        }
        return output
    }

    /// 递归脱敏一个 JSON 结构。
    public static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(redact(s))
        case .array(let arr):
            return .array(arr.map { redact($0) })
        case .object(let dict):
            var out: [String: JSONValue] = [:]
            for (k, v) in dict {
                // 键名本身就敏感时, 直接遮住值
                let lowered = k.lowercased()
                if lowered.contains("key") || lowered.contains("token")
                    || lowered.contains("authorization") || lowered.contains("secret") {
                    out[k] = .string(replacement)
                } else {
                    out[k] = redact(v)
                }
            }
            return .object(out)
        default:
            return value
        }
    }
}

/// 统一日志入口。
///
/// 所有写入 `events` 表的内容都必须经过这里 —— 它在落库前强制脱敏。
/// 同时它承担的职责是"**不**因为日志失败而让 JobRunner 崩掉":
/// 日志是旁路, 不是主路径。
public struct LoggerService: Sendable {

    private let events: EventRepository
    private let echoToConsole: Bool

    public init(events: EventRepository, echoToConsole: Bool = true) {
        self.events = events
        self.echoToConsole = echoToConsole
    }

    // MARK: - 主入口

    public func log(
        _ level: LogLevel,
        _ eventType: EventType,
        _ message: String,
        taskID: String? = nil,
        stepIndex: Int? = nil,
        metadata: JSONValue? = nil
    ) {
        let safeMessage = SecretRedactor.redact(message)
        let safeMetadata = metadata.map { SecretRedactor.redact($0) }

        let event = AppEvent(
            taskID: taskID,
            stepIndex: stepIndex,
            level: level,
            eventType: eventType,
            message: safeMessage,
            metadata: safeMetadata
        )

        if echoToConsole {
            let taskPart = taskID.map { " task=\($0.prefix(8))" } ?? ""
            let stepPart = stepIndex.map { " step=\($0)" } ?? ""
            print("[\(level.displayName)] \(eventType.rawValue)\(taskPart)\(stepPart) \(safeMessage)")
        }

        do {
            try events.append(event)
        } catch {
            // 日志写库失败绝不能冒泡到调用方 (那会把 Runner 一起带走)。
            FileHandle.standardError.write(
                Data("AIRunner: 日志写入失败: \(error)\n".utf8)
            )
        }
    }

    // MARK: - 便捷方法

    public func debug(_ t: EventType, _ m: String, taskID: String? = nil,
                      stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.debug, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    public func info(_ t: EventType, _ m: String, taskID: String? = nil,
                     stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.info, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    public func warning(_ t: EventType, _ m: String, taskID: String? = nil,
                        stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.warning, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    public func error(_ t: EventType, _ m: String, taskID: String? = nil,
                      stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.error, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    public func critical(_ t: EventType, _ m: String, taskID: String? = nil,
                         stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.critical, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    /// 记录任意 Error (自动归一化 + 脱敏)。
    public func record(_ error: Error, eventType: EventType, taskID: String? = nil,
                       stepIndex: Int? = nil, extra: JSONValue? = nil) {
        let appError = AppError.normalize(error)
        var meta: [String: JSONValue] = ["errorClass": .string(appError.eventName)]
        if let extra, case .object(let d) = extra {
            for (k, v) in d { meta[k] = v }
        }
        log(.error, eventType, appError.userMessage,
            taskID: taskID, stepIndex: stepIndex, metadata: .object(meta))
    }
}

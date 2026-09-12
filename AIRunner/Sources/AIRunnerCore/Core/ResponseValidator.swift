import Foundation

/// 输出校验器。
///
/// 存在的意义: 模型经常"看起来成功但其实返回了废话"。
/// 若不做校验, 一场跑 300 步的任务可能在最后才发现结果全是空字符串。
public protocol ResponseValidator: Sendable {
    func validate(_ response: AIResponse, request: AIRequest) throws
}

/// 非空校验: 最基础的一道门。
public struct NonEmptyResponseValidator: ResponseValidator {

    public let minimumLength: Int
    public let rejectPlaceholders: Bool

    public init(minimumLength: Int = 1, rejectPlaceholders: Bool = true) {
        self.minimumLength = minimumLength
        self.rejectPlaceholders = rejectPlaceholders
    }

    public func validate(_ response: AIResponse, request: AIRequest) throws {
        let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= minimumLength else {
            throw AppError.invalidOutput(
                "响应为空或过短 (\(trimmed.count) 字符, 期望 >= \(minimumLength))"
            )
        }

        if rejectPlaceholders {
            let lowered = trimmed.lowercased()
            let placeholders = ["todo", "n/a", "as an ai language model", "i cannot"]
            if trimmed.count < 40, placeholders.contains(where: { lowered == $0 }) {
                throw AppError.invalidOutput("响应是占位文本: \(trimmed.prefix(40))")
            }
        }
    }
}

/// JSON 校验: 当步骤声明 responseFormat == .json 时必须能解析成功。
public struct JSONResponseValidator: ResponseValidator {

    public init() {}

    public func validate(_ response: AIResponse, request: AIRequest) throws {
        guard JSONResponseValidator.extractJSONValue(from: response.text) != nil else {
            let preview = response.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(120)
            throw AppError.invalidOutput("响应不是合法 JSON: \(preview)")
        }
    }

    /// 从模型输出里尽可能稳健地提取 JSON。
    ///
    /// 处理三种常见污染:
    /// 1. 被 ```json ... ``` 包裹
    /// 2. 前后有解释性文字
    /// 3. 直接就是裸 JSON
    public static func extractJSONValue(from text: String) -> JSONValue? {
        let cleaned = stripCodeFence(text)

        if let value = try? JSONCoding.decode(JSONValue.self, from: cleaned) {
            return value
        }

        // 截取最外层的 {...}
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start < end {
            let candidate = String(cleaned[start...end])
            if let value = try? JSONCoding.decode(JSONValue.self, from: candidate) {
                return value
            }
        }

        // 截取最外层的 [...]
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]"),
           start < end {
            let candidate = String(cleaned[start...end])
            if let value = try? JSONCoding.decode(JSONValue.self, from: candidate) {
                return value
            }
        }

        return nil
    }

    static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        if let newline = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: newline)...])
        }
        if let closing = s.range(of: "```", options: .backwards) {
            s = String(s[s.startIndex..<closing.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 组合校验器。
public struct CompositeResponseValidator: ResponseValidator {

    public let validators: [any ResponseValidator]

    public init(_ validators: [any ResponseValidator]) {
        self.validators = validators
    }

    public func validate(_ response: AIResponse, request: AIRequest) throws {
        for validator in validators {
            try validator.validate(response, request: request)
        }
    }

    public static func standard(for format: ResponseFormat) -> CompositeResponseValidator {
        switch format {
        case .json:
            return CompositeResponseValidator([
                NonEmptyResponseValidator(minimumLength: 2),
                JSONResponseValidator(),
            ])
        case .text:
            return CompositeResponseValidator([
                NonEmptyResponseValidator(minimumLength: 1),
            ])
        }
    }
}

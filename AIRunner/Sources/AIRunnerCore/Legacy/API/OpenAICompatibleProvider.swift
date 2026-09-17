import Foundation

/// OpenAI 兼容的 HTTP Provider。
///
/// 覆盖: OpenAI 官方、DeepSeek、Moonshot、Groq, 以及任何兼容
/// `POST {baseURL}/chat/completions` 协议的网关 (含本地 vLLM / Ollama /v1)。
///
/// 职责边界: 只管 HTTP 与协议编解码。不关心重试、路由、检查点 —— 那是 Runner 的事。
public struct OpenAICompatibleProvider: AIProvider {

    public let id: String
    public let model: String

    private let config: ProviderConfig
    private let apiKey: String?
    private let session: URLSession

    public init(
        config: ProviderConfig,
        model: String? = nil,
        apiKey: String?,
        session: URLSession? = nil
    ) {
        self.id = config.id
        self.model = model ?? config.defaultModel
        self.config = config
        self.apiKey = apiKey
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral   // 不落盘缓存
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 1800
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "AIRunner/1.0 (macOS)"]
        return URLSession(configuration: cfg)
    }

    // MARK: - execute

    public func execute(request: AIRequest) async throws -> AIResponse {
        guard let url = config.chatCompletionsURL else {
            throw AppError.invalidRequest("Provider \(id) 的 baseURL 非法: \(config.baseURL)")
        }
        if config.requiresAPIKey, (apiKey ?? "").isEmpty {
            throw AppError.authentication
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = request.timeout
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildBody(request))
        } catch {
            throw AppError.invalidRequest("请求体构造失败: \(error)")
        }

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AppError.normalize(error)
        }
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("响应不是 HTTPURLResponse")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(
                status: http.statusCode, data: data, headers: http, providerID: id
            )
        }

        return try Self.parseSuccess(
            data: data, providerID: id, model: model, latencyMs: latencyMs
        )
    }

    // MARK: - 请求体

    private func buildBody(_ request: AIRequest) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": request.systemPrompt])
        }
        messages.append(["role": "user", "content": request.userPrompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]
        // 用 max_tokens 而非 max_completion_tokens: 兼容面更广 (后者只有较新的 OpenAI 模型接受)。
        if let maxTokens = request.maxOutputTokens {
            body["max_tokens"] = maxTokens
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if request.responseFormat == .json {
            body["response_format"] = ["type": "json_object"]
        }
        return body
    }

    // MARK: - 成功响应解析

    private struct ChatCompletionResponse: Decodable {
        struct Message: Decodable {
            let content: String?
            let reasoning_content: String?
        }
        struct Choice: Decodable {
            let message: Message?
            let text: String?
            let finish_reason: String?
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
        }
        let choices: [Choice]?
        let usage: Usage?
        let model: String?
    }

    static func parseSuccess(
        data: Data,
        providerID: String,
        model: String,
        latencyMs: Int
    ) throws -> AIResponse {
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONCoding.makeDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw AppError.invalidOutput(
                "无法解析 chat/completions 响应: \(error.localizedDescription)"
            )
        }

        guard let choice = decoded.choices?.first else {
            throw AppError.invalidOutput("响应中没有 choices")
        }

        let text = (choice.message?.content ?? choice.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw AppError.invalidOutput(
                "模型返回了空内容 (finish_reason=\(choice.finish_reason ?? "nil"))"
            )
        }

        return AIResponse(
            text: text,
            provider: providerID,
            model: decoded.model ?? model,
            inputTokens: decoded.usage?.prompt_tokens,
            outputTokens: decoded.usage?.completion_tokens,
            latencyMilliseconds: latencyMs,
            finishReason: choice.finish_reason
        )
    }

    // MARK: - ★ HTTP 状态 → AppError 映射 ★

    /// 这是"不同错误不同策略"能成立的前提。
    /// 若把所有非 2xx 都映射成同一个错误, RetryManager 就只能一律重试 —— 那正是要避免的。
    static func mapHTTPError(
        status: Int,
        data: Data,
        headers: HTTPURLResponse,
        providerID: String
    ) -> AppError {
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let haystack = bodyText.lowercased()
        let detail = extractErrorMessage(from: data) ?? String(bodyText.prefix(400))

        switch status {

        case 400:
            if containsAny(haystack, [
                "context length", "context_length_exceeded", "maximum context",
                "too many tokens", "reduce the length", "max_tokens",
            ]) {
                return .contextTooLong
            }
            return .invalidRequest(detail)

        case 401:
            return .authentication

        case 402:
            return .billingRequired

        case 403:
            // 403 既可能是"无权限"也可能是"额度/账单问题", 靠内容区分。
            if containsAny(haystack, ["quota", "billing", "credit", "balance", "payment", "insufficient"]) {
                return .billingRequired
            }
            return .authentication

        case 404:
            // 通常是 model 名写错, 也可能 baseURL 路径错。换 model 有意义, 所以单独分类。
            return .modelUnavailable

        case 408:
            return .timeout

        case 409:
            return .network("请求冲突 (409): \(detail)")

        case 413:
            return .contextTooLong

        case 422:
            return .invalidRequest(detail)

        case 429:
            // ★ 关键区分 ★
            // OpenAI 用 429 同时表达"太快了"和"余额没了"。
            // 前者应当等待重试; 后者重试一万次也没用, 必须熔断并暂停任务。
            if containsAny(haystack, [
                "insufficient_quota", "exceeded your current quota",
                "quota", "billing", "credit", "balance", "payment required",
            ]) {
                return .billingRequired
            }
            return .rateLimit(retryAfter: parseRetryAfter(headers, bodyText: bodyText))

        case 500, 502, 503, 504, 529:
            return .providerUnavailable

        default:
            if (500..<600).contains(status) {
                return .providerUnavailable
            }
            return .invalidRequest("HTTP \(status): \(detail)")
        }
    }

    static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// 从 Retry-After 头或 body 中提取建议等待秒数。
    static func parseRetryAfter(_ headers: HTTPURLResponse, bodyText: String) -> TimeInterval? {
        if let raw = headers.value(forHTTPHeaderField: "Retry-After") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let seconds = Double(trimmed) {
                return max(0, seconds)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: trimmed) {
                return max(0, date.timeIntervalSinceNow)
            }
        }

        // OpenAI 会带 x-ratelimit-reset-requests, 形如 "1s" / "6m0s"
        for header in ["x-ratelimit-reset-requests", "x-ratelimit-reset-tokens"] {
            if let raw = headers.value(forHTTPHeaderField: header), let parsed = parseDuration(raw) {
                return parsed
            }
        }

        // 兜底: 从文案里抓 "try again in 20s"
        if let range = bodyText.range(of: #"in\s+(\d+(\.\d+)?)\s*s"#, options: .regularExpression) {
            let snippet = bodyText[range]
            let digits = snippet.filter { $0.isNumber || $0 == "." }
            if let value = Double(digits) { return value }
        }
        return nil
    }

    /// 解析 "1s" / "6m0s" / "1h2m3s" 这类时长。
    static func parseDuration(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let plain = Double(trimmed) { return plain }

        var total: TimeInterval = 0
        var matched = false
        let pattern = #"(\d+(?:\.\d+)?)(ms|s|m|h)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in regex.matches(in: trimmed, range: range) {
            guard match.numberOfRanges == 3,
                  let valueRange = Range(match.range(at: 1), in: trimmed),
                  let unitRange = Range(match.range(at: 2), in: trimmed),
                  let value = Double(trimmed[valueRange]) else { continue }
            matched = true
            switch trimmed[unitRange] {
            case "ms": total += value / 1000
            case "s":  total += value
            case "m":  total += value * 60
            case "h":  total += value * 3600
            default:   break
            }
        }
        return matched ? total : nil
    }

    /// 兼容 OpenAI / Anthropic / 通用网关的错误体格式。
    static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = object["error"] as? [String: Any] {
            if let message = err["message"] as? String { return message }
            if let type = err["type"] as? String { return type }
        }
        for key in ["message", "detail", "msg", "error_description"] {
            if let value = object[key] as? String { return value }
        }
        if let err = object["error"] as? String { return err }
        return nil
    }

    // MARK: - 健康探测

    public func healthCheck() async -> ProviderHealth {
        guard let url = config.modelsURL else {
            return ProviderHealth(provider: id, model: model, state: .degraded,
                                  reason: "baseURL 非法")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(15, config.timeout)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ProviderHealth(provider: id, model: model, state: .degraded,
                                      reason: "非 HTTP 响应")
            }
            switch http.statusCode {
            case 200..<300:
                return ProviderHealth(provider: id, model: model, state: .healthy,
                                      lastSuccess: Date())
            case 401, 403:
                return ProviderHealth(provider: id, model: model, state: .unavailable,
                                      lastFailure: Date(), reason: "认证失败")
            case 429:
                return ProviderHealth(provider: id, model: model, state: .degraded,
                                      lastFailure: Date(), reason: "限流中")
            default:
                return ProviderHealth(provider: id, model: model, state: .degraded,
                                      lastFailure: Date(), reason: "HTTP \(http.statusCode)")
            }
        } catch {
            let message = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            return ProviderHealth(provider: id, model: model, state: .degraded,
                                  lastFailure: Date(), reason: message)
        }
    }
}

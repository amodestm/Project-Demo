import Foundation

public enum CodexQuotaProbeError: Error, LocalizedError, Sendable, Equatable {
    case authFileMissing(String)
    case authFileUnreadable(String)
    case notLoggedIn
    case requestFailed(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .authFileMissing(let path):
            return "找不到 Codex 凭据文件 \(path)：请先在 Codex 里登录。"
        case .authFileUnreadable(let reason):
            return "无法读取 Codex 凭据文件：\(reason)"
        case .notLoggedIn:
            return "Codex 当前没有可用的 ChatGPT 登录会话，无法查询额度。"
        case .requestFailed(let reason):
            return "额度接口请求失败：\(reason)"
        case .malformedResponse(let reason):
            return "额度接口返回了无法解析的内容：\(reason)"
        }
    }
}

/// 一次额度探测的结果。
///
/// 这是**实时**值，来自 OpenAI 官方用量接口 `backend-api/wham/usage`，
/// 与 Codex 桌面端「剩余额度」面板同源。
public struct CodexQuotaUsage: Sendable, Equatable {

    public var email: String?
    public var accountID: String?
    public var planType: String?
    public var allowed: Bool?
    public var limitReached: Bool?
    public var rateLimitReachedType: String?

    public var primaryUsedPercent: Double?
    public var primaryWindowSeconds: Int?
    public var primaryResetAt: Int?

    public var secondaryUsedPercent: Double?
    public var secondaryWindowSeconds: Int?
    public var secondaryResetAt: Int?

    /// 有模型暂不可用时的最早恢复时间戳；全部可用时为 nil。
    public var modelAvailableAt: Int?

    public var creditsBalance: String?
    public var resetCreditsAvailable: Int?

    public var rawJSON: String?

    public init(
        email: String? = nil,
        accountID: String? = nil,
        planType: String? = nil,
        allowed: Bool? = nil,
        limitReached: Bool? = nil,
        rateLimitReachedType: String? = nil,
        primaryUsedPercent: Double? = nil,
        primaryWindowSeconds: Int? = nil,
        primaryResetAt: Int? = nil,
        secondaryUsedPercent: Double? = nil,
        secondaryWindowSeconds: Int? = nil,
        secondaryResetAt: Int? = nil,
        modelAvailableAt: Int? = nil,
        creditsBalance: String? = nil,
        resetCreditsAvailable: Int? = nil,
        rawJSON: String? = nil
    ) {
        self.email = email
        self.accountID = accountID
        self.planType = planType
        self.allowed = allowed
        self.limitReached = limitReached
        self.rateLimitReachedType = rateLimitReachedType
        self.primaryUsedPercent = primaryUsedPercent
        self.primaryWindowSeconds = primaryWindowSeconds
        self.primaryResetAt = primaryResetAt
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryWindowSeconds = secondaryWindowSeconds
        self.secondaryResetAt = secondaryResetAt
        self.modelAvailableAt = modelAvailableAt
        self.creditsBalance = creditsBalance
        self.resetCreditsAvailable = resetCreditsAvailable
        self.rawJSON = rawJSON
    }

    /// 5 小时窗口剩余比例。
    public var primaryRemainingPercent: Double? {
        primaryUsedPercent.map { max(0, 100 - $0) }
    }

    public func snapshot(
        profileDirectory: String,
        source: String,
        at date: Date = Date()
    ) -> CodexQuotaSnapshot {
        CodexQuotaSnapshot(
            profileDirectory: profileDirectory,
            capturedAt: date,
            source: source,
            email: email,
            accountID: accountID,
            planType: planType,
            allowed: allowed,
            limitReached: limitReached,
            rateLimitReachedType: rateLimitReachedType,
            primaryUsedPercent: primaryUsedPercent,
            primaryWindowSeconds: primaryWindowSeconds,
            primaryResetAt: primaryResetAt,
            secondaryUsedPercent: secondaryUsedPercent,
            secondaryWindowSeconds: secondaryWindowSeconds,
            secondaryResetAt: secondaryResetAt,
            modelAvailableAt: modelAvailableAt,
            creditsBalance: creditsBalance,
            resetCreditsAvailable: resetCreditsAvailable,
            rawJSON: rawJSON
        )
    }
}

public protocol CodexQuotaProbing: Sendable {
    func probe() async throws -> CodexQuotaUsage
}

/// 读取本机 Codex 的 OAuth 凭据并查询官方额度接口。
///
/// ★ 安全边界 ★
/// access token 只在 `probe()` 的调用栈与 HTTP 请求头里出现：不写日志、不落库、
/// 不出现在错误信息中。落库的只有额度计量值（见 `CodexQuotaSnapshot`）。
public struct CodexQuotaProbe: CodexQuotaProbing {

    /// 官方用量接口。与 Codex 桌面端「剩余额度」面板同源。
    public static let usageEndpoint = URL(
        string: "https://chatgpt.com/backend-api/wham/usage"
    )!

    private let authURL: URL
    private let endpoint: URL
    private let timeout: TimeInterval
    private let session: URLSession
    /// 可选的显式代理（本机需要走代理才能访问 chatgpt.com 时使用）。
    private let proxyServer: String?

    public init(
        authURL: URL? = nil,
        endpoint: URL = CodexQuotaProbe.usageEndpoint,
        timeout: TimeInterval = 20,
        proxyServer: String? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.authURL = authURL
            ?? home.appendingPathComponent(".codex/auth.json", isDirectory: false)
        self.endpoint = endpoint
        self.timeout = timeout
        self.proxyServer = proxyServer

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        if let proxyServer, !proxyServer.isEmpty,
           let proxyURL = URL(string: proxyServer), let host = proxyURL.host {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": proxyURL.port ?? 0,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": proxyURL.port ?? 0,
            ]
        }
        self.session = URLSession(configuration: configuration)
    }

    public func probe() async throws -> CodexQuotaUsage {
        let credentials = try Self.readCredentials(at: authURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIRunner/\(Self.userAgentSuffix)", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexQuotaProbeError.requestFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CodexQuotaProbeError.notLoggedIn
            }
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw CodexQuotaProbeError.requestFailed("HTTP \(http.statusCode) \(body)")
        }

        return try Self.decode(data)
    }

    // MARK: - 凭据

    struct Credentials: Sendable {
        let accessToken: String
        let accountID: String?
    }

    static func readCredentials(at url: URL) throws -> Credentials {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexQuotaProbeError.authFileMissing(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexQuotaProbeError.authFileUnreadable(error.localizedDescription)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else {
            throw CodexQuotaProbeError.notLoggedIn
        }
        return Credentials(
            accessToken: token,
            accountID: tokens["account_id"] as? String
        )
    }

    // MARK: - 解析

    private struct UsageResponse: Decodable {

        struct Window: Decodable {
            let usedPercent: Double?
            let windowSeconds: Int?
            let resetAfterSeconds: Int?
            let resetAt: Int?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowSeconds = "limit_window_seconds"
                case resetAfterSeconds = "reset_after_seconds"
                case resetAt = "reset_at"
            }
        }

        struct RateLimit: Decodable {
            let allowed: Bool?
            let limitReached: Bool?
            let primaryWindow: Window?
            let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case allowed
                case limitReached = "limit_reached"
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        struct ModelUsage: Decodable {
            let available: Bool?
            let availableAt: Int?

            enum CodingKeys: String, CodingKey {
                case available
                case availableAt = "available_at"
            }
        }

        struct Credits: Decodable {
            let balance: String?
        }

        struct ResetCredits: Decodable {
            let availableCount: Int?

            enum CodingKeys: String, CodingKey {
                case availableCount = "available_count"
            }
        }

        let email: String?
        let accountID: String?
        let planType: String?
        let rateLimit: RateLimit?
        let modelUsage: [String: ModelUsage]?
        let credits: Credits?
        let resetCredits: ResetCredits?
        let rateLimitReachedType: String?

        enum CodingKeys: String, CodingKey {
            case email
            case accountID = "account_id"
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case modelUsage = "model_usage"
            case credits
            case resetCredits = "rate_limit_reset_credits"
            case rateLimitReachedType = "rate_limit_reached_type"
        }
    }

    static func decode(_ data: Data) throws -> CodexQuotaUsage {
        let response: UsageResponse
        do {
            response = try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw CodexQuotaProbeError.malformedResponse(error.localizedDescription)
        }

        // 「模型恢复时间」取所有暂不可用模型里最早的一个：它决定最早什么时候
        // 能重新用上受限模型。全部可用时不记录（nil）。
        let unavailable = (response.modelUsage ?? [:]).compactMap { _, entry -> Int? in
            guard entry.available == false else { return nil }
            guard let at = entry.availableAt, at > 0 else { return nil }
            return at
        }

        return CodexQuotaUsage(
            email: response.email,
            accountID: response.accountID,
            planType: response.planType,
            allowed: response.rateLimit?.allowed,
            limitReached: response.rateLimit?.limitReached,
            rateLimitReachedType: response.rateLimitReachedType,
            primaryUsedPercent: response.rateLimit?.primaryWindow?.usedPercent,
            primaryWindowSeconds: response.rateLimit?.primaryWindow?.windowSeconds,
            primaryResetAt: response.rateLimit?.primaryWindow?.resetAt,
            secondaryUsedPercent: response.rateLimit?.secondaryWindow?.usedPercent,
            secondaryWindowSeconds: response.rateLimit?.secondaryWindow?.windowSeconds,
            secondaryResetAt: response.rateLimit?.secondaryWindow?.resetAt,
            modelAvailableAt: unavailable.min(),
            creditsBalance: response.credits?.balance,
            resetCreditsAvailable: response.resetCredits?.availableCount,
            rawJSON: String(data: data, encoding: .utf8)
        )
    }

    static var userAgentSuffix: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short).\(build)"
    }
}

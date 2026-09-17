import Foundation

/// 全项目统一错误类型。
///
/// 设计原则: **绝不允许"所有错误一律重试"**。
/// 每个 case 都映射到一个明确的处置策略 (`ErrorStrategy`), 由 JobRunner 分派,
/// 而不是在 Runner 里散落 `if error is X` 判断。
public enum AppError: Error, Sendable {
    case network(String)
    case timeout
    case rateLimit(retryAfter: TimeInterval?)
    case providerUnavailable
    case modelUnavailable
    case authentication
    case billingRequired
    case invalidRequest(String)
    case contextTooLong
    case invalidOutput(String)
    /// 乐观并发冲突: 目标行的状态在本次操作期间被改动了 (CAS 失败)。
    ///
    /// 典型场景是"同一份结果被提交两次"。绝不能重试 —— 必须让调用方重新读取状态。
    case concurrentModification(String)
    case cancelled
    case database(String)
    case fatal(String)
}

/// 处置策略。JobRunner 依据它决定下一步动作。
public enum ErrorStrategy: String, Sendable, Codable {
    /// 原地重试, 指数退避。消耗正常 retry 预算。
    case retrySame
    /// 限流场景的长退避。使用独立预算, 不消耗步骤 retry 次数。
    case retryWithBackoff
    /// 换 backend (同 provider 换 model, 或换 provider)。不消耗 retry 预算。
    case switchBackend
    /// 缩小上下文后重试 (contextTooLong)。
    case shrinkContext
    /// 暂停任务, 等用户介入 (认证失败 / 余额耗尽)。绝不自动重试。
    case pauseTask
    /// 当前步骤失败。
    case failStep
    /// 整个任务失败。
    case failTask
}

extension AppError {

    // MARK: - 分类

    public var strategy: ErrorStrategy {
        switch self {
        case .network, .timeout:
            return .retrySame
        case .rateLimit:
            return .retryWithBackoff
        case .providerUnavailable, .modelUnavailable:
            return .switchBackend
        case .contextTooLong:
            return .shrinkContext
        case .invalidOutput:
            return .retrySame          // 附加"请只返回合法 JSON"提示后重试
        case .authentication, .billingRequired:
            return .pauseTask
        case .invalidRequest, .concurrentModification:
            return .failStep
        case .cancelled, .database, .fatal:
            return .failTask
        }
    }

    /// 是否可以自动重试 (语义层面; 实际是否还有预算由 RetryManager 决定)。
    public var isRetryable: Bool {
        switch self {
        case .network, .timeout, .rateLimit, .invalidOutput:
            return true
        case .providerUnavailable, .modelUnavailable:
            return true   // 可重试, 但方式必须是换 backend
        case .authentication, .billingRequired, .invalidRequest,
             .concurrentModification,
             .contextTooLong, .cancelled, .database, .fatal:
            return false
        }
    }

    /// 是否应该让该 Provider 的熔断计数器 +1。
    ///
    /// 网络抖动不该熔断 Provider; 认证失败/余额耗尽则必须 —— 继续调用只是浪费时间和额度。
    public var tripsProviderCircuit: Bool {
        switch self {
        case .providerUnavailable, .authentication, .billingRequired:
            return true
        case .network, .timeout, .rateLimit, .modelUnavailable, .invalidRequest,
             .concurrentModification,
             .contextTooLong, .invalidOutput, .cancelled, .database, .fatal:
            return false
        }
    }

    /// 是否属于"永久性"故障 —— 换 backend 也没用, 只能靠用户修配置。
    public var isTerminalForProvider: Bool {
        switch self {
        case .authentication, .billingRequired:
            return true
        default:
            return false
        }
    }

    /// 给 UI 显示的中文简述。
    public var userMessage: String {
        switch self {
        case .network(let m):        return "网络错误: \(m)"
        case .timeout:               return "请求超时"
        case .rateLimit(let after):
            if let after { return "触发限流, 建议等待 \(Int(after)) 秒" }
            return "触发限流"
        case .providerUnavailable:   return "Provider 暂时不可用"
        case .modelUnavailable:      return "模型不可用"
        case .authentication:        return "认证失败, 请检查 API Key"
        case .billingRequired:       return "余额/额度不足, 已熔断该 Provider"
        case .invalidRequest(let m): return "请求非法: \(m)"
        case .concurrentModification(let m): return "并发冲突 (状态已被改动): \(m)"
        case .contextTooLong:        return "上下文超长"
        case .invalidOutput(let m):  return "输出校验失败: \(m)"
        case .cancelled:             return "已取消"
        case .database(let m):       return "数据库错误: \(m)"
        case .fatal(let m):          return "致命错误: \(m)"
        }
    }

    /// 写日志用的稳定标识 (不含任何敏感信息)。
    public var eventName: String {
        switch self {
        case .network:              return "NETWORK_ERROR"
        case .timeout:              return "TIMEOUT"
        case .rateLimit:            return "RATE_LIMITED"
        case .providerUnavailable:  return "PROVIDER_UNAVAILABLE"
        case .modelUnavailable:     return "MODEL_UNAVAILABLE"
        case .authentication:       return "AUTHENTICATION_ERROR"
        case .billingRequired:      return "BILLING_REQUIRED"
        case .invalidRequest:       return "INVALID_REQUEST"
        case .concurrentModification: return "CONCURRENT_MODIFICATION"
        case .contextTooLong:       return "CONTEXT_TOO_LONG"
        case .invalidOutput:        return "INVALID_OUTPUT"
        case .cancelled:            return "CANCELLED"
        case .database:             return "DATABASE_ERROR"
        case .fatal:                return "FATAL_ERROR"
        }
    }

    /// 便捷: 取限流等待时间。
    public var retryAfter: TimeInterval? {
        if case .rateLimit(let after) = self { return after }
        return nil
    }

    /// 把任意 Error 归一化成 AppError。
    public static func normalize(_ error: Error) -> AppError {
        switch error {
        case let e as AppError:
            return e
        case is CancellationError:
            return .cancelled
        case let e as URLError:
            switch e.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .internationalRoamingOff,
                 .dataNotAllowed, .resourceUnavailable:
                return .network(e.localizedDescription)
            default:
                return .network("URLError(\(e.code.rawValue)): \(e.localizedDescription)")
            }
        case let e as DecodingError:
            return .invalidOutput("响应解码失败: \(e)")
        default:
            return .fatal(error.localizedDescription)
        }
    }
}

extension AppError: CustomStringConvertible {
    public var description: String { "AppError.\(eventName)" }
}

extension AppError: LocalizedError {
    public var errorDescription: String? { userMessage }
}

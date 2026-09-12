import Foundation

/// 限制并发数量的异步信号量。
///
/// 用途: MVP 全局最多同时跑 N 个 Task Runner (默认 3)。
/// 用 `actor` 而非 DispatchSemaphore —— 后者在 Swift Concurrency 里会造成
/// 线程阻塞 (线程饥饿), 且无法参与结构化取消。
public actor AsyncSemaphore {

    public let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        precondition(limit > 0, "AsyncSemaphore limit 必须 > 0")
        self.limit = limit
        self.available = limit
    }

    /// 获取一个许可。若已达上限则挂起等待。
    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// 释放一个许可。若有等待者, 直接把许可移交给队首 (不增加 available)。
    public func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available = min(available + 1, limit)
        }
    }

    /// 作用域化使用许可。保证异常路径下也会释放。
    public func withPermit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    // MARK: - 观测 (测试与调试用)

    public var availableCount: Int { available }
    public var waitingCount: Int { waiters.count }
}

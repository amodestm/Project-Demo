import Foundation
import XCTest
@testable import AIRunnerCore

/// 测试公共装置。
enum TestSupport {

    static let mockProviderID = "mock"
    static let mockModel = "mock-fast"

    // MARK: - 配置

    static func mockProviderConfig(
        id: String = mockProviderID,
        model: String = mockModel
    ) -> ProviderConfig {
        ProviderConfig(
            id: id,
            displayName: "Mock \(id)",
            kind: .mock,
            baseURL: "",
            defaultModel: model,
            models: [model],
            timeout: 5,
            maxOutputTokens: 256,
            keychainKey: "\(id).apiKey"
        )
    }

    /// 测试用极短退避 —— 否则一个重试用例要等好几分钟。
    static func fastRetryConfig() -> RetryConfiguration {
        var config = RetryConfiguration()
        config.baseDelay = 0.01
        config.factor = 1.5
        config.maxDelay = 0.05
        config.jitterRatio = 0
        config.maxRetries = 4
        config.maxRateLimitWaits = 4
        config.maxRepairs = 2
        config.providerDegradedThreshold = 3
        config.providerUnavailableThreshold = 5
        config.providerCooldown = 0.2
        config.billingCooldown = 0.5
        return config
    }

    static func mockSettings(
        providers: [ProviderConfig]? = nil,
        routes: [RouteEntry]? = nil,
        concurrency: Int = 3,
        retry: RetryConfiguration? = nil
    ) -> AppSettings {
        let resolvedProviders = providers ?? [mockProviderConfig()]
        let resolvedRoutes = routes ?? [RouteEntry(priority: 1, provider: mockProviderID, model: mockModel)]
        return AppSettings(
            providers: resolvedProviders,
            routes: resolvedRoutes,
            concurrency: concurrency,
            retry: retry ?? fastRetryConfig(),
            useCodexBrowserOAuthRotation: false
        )
    }

    // MARK: - 服务装配

    static func makeServices(settings: AppSettings? = nil) throws -> AppServices {
        let resolved = settings ?? mockSettings()
        // 需要排查测试失败时: AILR_TEST_VERBOSE=1 swift test
        let verbose = ProcessInfo.processInfo.environment["AILR_TEST_VERBOSE"] == "1"
        return try AppServices(
            database: try Database.inMemory(),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: resolved,
            echoLogsToConsole: verbose
        )
    }

    // MARK: - 任务构造

    /// 构造测试任务。
    ///
    /// `executionMode` 默认 `.api` —— 因为既有测试验证的是 router / provider / retry
    /// 这条通道的具体行为。Web 通道的行为由 `WebExecutionTests` 单独覆盖。
    @discardableResult
    static func makeTask(
        _ services: AppServices,
        name: String = "Test Task",
        goal: String = "Accomplish the test goal",
        steps: Int,
        executionMode: ExecutionMode = .api,
        primaryProvider: String = mockProviderID,
        primaryModel: String = mockModel
    ) throws -> AITask {
        let task = AITask(
            name: name,
            goal: goal,
            status: .queued,
            executionMode: executionMode,
            primaryProvider: primaryProvider,
            primaryModel: primaryModel,
            totalSteps: steps
        )
        try services.tasks.insert(task)
        let plan = TaskPlanner.defaultPlan(taskID: task.id, numberOfSteps: steps, goal: goal)
        try services.steps.insertBatch(plan)
        try services.checkpoints.insert(Checkpoint.initial(taskID: task.id))
        return task
    }

    // MARK: - 等待

    /// 轮询直到任务进入"不再自动前进"的状态。
    ///
    /// 除了终态与 paused, **「等用户」状态也必须算作已稳定** —— 它们意味着
    /// Runner 已经退出, 不会再有自动进展 (用户在浏览器里操作之前不会有变化)。
    /// 否则 Web 通道的测试会一直空转到超时。
    @discardableResult
    static func waitUntilSettled(
        _ services: AppServices,
        taskID: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AITask {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let task = try services.tasks.fetch(id: taskID) {
                if task.status.isTerminal
                    || task.status == .paused
                    || task.status.requiresUserAction {
                    return task
                }
            }
            try await Task.sleep(nanoseconds: 15_000_000)   // 15ms
        }
        XCTFail("等待任务进入稳定状态超时 (\(timeout)s)", file: file, line: line)
        return try services.tasks.fetch(id: taskID)!
    }

    /// 轮询直到某个断言成立。
    static func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            // 用 try? 忽略 CancellationError —— 测试收尾时取消任务属正常现象,
            // 但不能让 sleep 的取消掩盖 condition 自身抛出的错误。
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return false
    }
}

import XCTest
@testable import AIRunnerCore

/// 真实**文件**数据库的端到端测试。
///
/// 与其它测试不同的是: 这里用磁盘上的 SQLite 而不是 `:memory:`,
/// 因此额外覆盖了 WAL 配置、外键约束、以及最关键的
/// **「关闭 App → 重新打开 → 数据与进度仍在」** 这条路径。
final class PersistenceSmokeTests: XCTestCase {

    private var directory: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbPath = directory.appendingPathComponent("airunner.sqlite").path
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func openServices() throws -> AppServices {
        try AppServices(
            database: try Database(path: dbPath),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: TestSupport.mockSettings(),
            echoLogsToConsole: false
        )
    }

    private func installMock(_ services: AppServices) -> MockAIProvider {
        let mock = MockAIProvider(id: TestSupport.mockProviderID, model: TestSupport.mockModel)
        services.factory.registerOverride(
            mock,
            providerID: TestSupport.mockProviderID,
            model: TestSupport.mockModel
        )
        return mock
    }

    // MARK: - 数据库本身

    func testLocalDatabaseUsesWALAndForeignKeys() throws {
        let database = try Database(path: dbPath)
        defer { database.close() }

        // 直接 new 出来的 Database 还没建表, user_version 自然是 0
        try DatabaseMigrator.migrate(database)

        let diagnostics = try database.diagnostics()
        XCTAssertEqual(diagnostics.journalMode.lowercased(), "wal",
                       "本地磁盘应使用 WAL, 让 UI 读取与 Runner 写入可以并行")
        XCTAssertTrue(diagnostics.foreignKeys, "外键必须开启, 否则 CASCADE 删除失效")
        XCTAssertTrue(diagnostics.integrityOK)
        XCTAssertEqual(diagnostics.userVersion, DatabaseMigrator.currentVersion)
    }

    func testCascadeDeleteRemovesStepsAndCheckpoints() throws {
        let services = try openServices()
        defer { services.shutdown() }

        let task = try TestSupport.makeTask(services, steps: 3)
        XCTAssertEqual(try services.steps.count(taskID: task.id), 3)
        XCTAssertGreaterThan(try services.checkpoints.count(taskID: task.id), 0)

        try services.tasks.delete(id: task.id)

        XCTAssertEqual(try services.steps.count(taskID: task.id), 0)
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), 0)
    }

    // MARK: - 重启后数据仍在

    func testCompletedTaskSurvivesDatabaseReopen() async throws {
        var taskID = ""

        // ---- 第一次运行 ----
        do {
            let services = try openServices()
            _ = installMock(services)
            let task = try TestSupport.makeTask(services, steps: 4)
            taskID = task.id

            await services.runner.start(taskID: task.id)
            let settled = try await TestSupport.waitUntilSettled(
                services, taskID: task.id, timeout: 20
            )
            XCTAssertEqual(settled.status, .completed)
            services.shutdown()
        }

        // ---- 第二次运行 (模拟用户重新打开 App) ----
        do {
            let services = try openServices()
            defer { services.shutdown() }

            let reopened = try XCTUnwrap(services.tasks.fetch(id: taskID))
            XCTAssertEqual(reopened.status, .completed)
            XCTAssertEqual(reopened.currentStep, 4)

            let steps = try services.steps.fetchAll(taskID: taskID)
            XCTAssertEqual(steps.count, 4)
            XCTAssertTrue(steps.allSatisfy { $0.status == .completed })
            XCTAssertTrue(steps.allSatisfy { $0.output != nil }, "每步输出都必须落盘")

            XCTAssertEqual(try services.checkpoints.latest(taskID: taskID)?.nextStep, 4)

            let events = try services.events.list(taskID: taskID, limit: 200)
            XCTAssertFalse(events.isEmpty, "日志也要一并持久化")

            // 重开之后不应有"需要恢复"的任务 —— 它已经完成了
            let report = try services.recovery.recover()
            XCTAssertFalse(report.recoverableTaskIDs.contains(taskID))
        }
    }

    // MARK: - 中断后重开继续

    func testInterruptedRunResumesAfterReopen() async throws {
        var taskID = ""
        var completedBeforeCrash = 0

        // ---- 第一次运行: 跑一部分, 留下一个 running 步骤模拟被强杀 ----
        do {
            let services = try openServices()
            let task = try TestSupport.makeTask(services, steps: 6)
            taskID = task.id

            // 完成前两步
            for index in 0..<2 {
                let step = try XCTUnwrap(services.steps.fetch(taskID: taskID, index: index))
                try services.steps.markRunning(
                    stepID: step.id, provider: TestSupport.mockProviderID, model: TestSupport.mockModel
                )
                try services.steps.commitSuccessfulStep(
                    SuccessfulStepCommit(
                        stepID: step.id, taskID: taskID,
                        output: .object(["text": .string("pre-crash \(index)")]),
                        provider: TestSupport.mockProviderID, model: TestSupport.mockModel,
                        durationMs: 3,
                        checkpoint: Checkpoint(taskID: taskID, completedStep: index, nextStep: index + 1),
                        newCurrentStep: index + 1
                    )
                )
            }
            // 第三步处于 running —— 进程此刻被 kill
            let third = try XCTUnwrap(services.steps.fetch(taskID: taskID, index: 2))
            try services.steps.markRunning(
                stepID: third.id, provider: TestSupport.mockProviderID, model: TestSupport.mockModel
            )
            try services.tasks.updateStatus(id: taskID, to: .running)

            completedBeforeCrash = try services.steps
                .fetchAll(taskID: taskID).filter { $0.status == .completed }.count
            XCTAssertEqual(completedBeforeCrash, 2)

            services.shutdown()   // 相当于进程消失
        }

        // ---- 第二次运行: 恢复并继续 ----
        do {
            let services = try openServices()
            let mock = installMock(services)

            let report = try services.recovery.recover()
            XCTAssertEqual(report.interruptedSteps, 1, "应发现 1 个中断步骤")
            XCTAssertTrue(report.recoverableTaskIDs.contains(taskID))

            await services.runner.start(taskID: taskID)
            let settled = try await TestSupport.waitUntilSettled(
                services, taskID: taskID, timeout: 20
            )
            defer { services.shutdown() }

            XCTAssertEqual(settled.status, .completed)
            XCTAssertEqual(settled.currentStep, 6)

            // ★ 关键: 崩溃前完成的 2 步不得重跑 ★
            XCTAssertEqual(mock.calls, 6 - completedBeforeCrash,
                           "只应补跑剩余步骤")

            let first = try XCTUnwrap(services.steps.fetch(taskID: taskID, index: 0))
            XCTAssertEqual(first.output?["text"]?.stringValue, "pre-crash 0",
                           "崩溃前的结果必须原封不动")

            XCTAssertEqual(try services.checkpoints.latest(taskID: taskID)?.nextStep, 6)
        }
    }

    // MARK: - 幂等

    func testRepeatedRecoveryOnReopenIsSafe() async throws {
        var taskID = ""

        do {
            let services = try openServices()
            let task = try TestSupport.makeTask(services, steps: 3)
            taskID = task.id
            try services.tasks.updateStatus(id: taskID, to: .running)
            services.shutdown()
        }

        for round in 1...3 {
            let services = try openServices()
            let report = try services.recovery.recover()
            XCTAssertTrue(report.recoverableTaskIDs.contains(taskID),
                          "第 \(round) 次重开都应能继续该任务")
            XCTAssertEqual(report.interruptedSteps, 0,
                           "第 \(round) 次不应再有 running 步骤")
            services.shutdown()
        }
    }
}

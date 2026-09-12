import XCTest
@testable import AIRunnerCore

/// ChatGPT Web 通道测试。
///
/// 重点验证四件事:
/// 1. 续跑 prompt **完全自包含** —— 换个会话、换了账号也能接着做
/// 2. 账号交接**不丢任何进度**
/// 3. 崩溃后重新生成的 prompt 与之前**逐字一致**
/// 4. 已完成的步骤**绝不重做**
final class WebExecutionTests: XCTestCase {

    // MARK: - 装置

    private func makeWebServices(
        clipboard: (any ClipboardServicing)? = nil,
        browser: (any BrowserLaunching)? = nil
    ) throws -> AppServices {
        var settings = TestSupport.mockSettings()
        settings.defaultExecutionMode = .chatGPTWeb
        return try AppServices(
            database: try Database.inMemory(),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: settings,
            clipboard: clipboard ?? InMemoryClipboard(),
            browser: browser ?? RecordingBrowserLauncher(),
            echoLogsToConsole: false
        )
    }

    @discardableResult
    private func makeWebTask(
        _ services: AppServices,
        steps: Int,
        goal: String = "分析 300 份 PDF 并生成综合报告"
    ) throws -> AITask {
        try TestSupport.makeTask(
            services,
            goal: goal,
            steps: steps,
            executionMode: .chatGPTWeb
        )
    }

    /// 模拟用户走完一整轮: 拿到 prompt → (去 ChatGPT) → 贴回结果。
    @discardableResult
    private func completeOneWebStep(
        _ services: AppServices,
        taskID: String,
        resultText: String
    ) async throws -> ImportedResult {
        _ = try await services.web.prepareStep(taskID: taskID)
        return try await services.web.acceptResult(
            taskID: taskID,
            stepID: try XCTUnwrap(services.steps.awaitingResultStep(taskID: taskID)).id,
            result: resultText
        )
    }

    // MARK: - 1. Prompt 自包含性

    func testContinuationPromptIsSelfContained() {
        let checkpoint = Checkpoint(
            taskID: "t1",
            completedStep: 62,
            nextStep: 63,
            workingSummary: "已完成 63 个文件的解析, 提取出 12 个关键主题 (A/B/C…)"
        )

        let prompt = ContinuationPromptBuilder().build(
            .init(
                goal: "分析 300 份 PDF 并生成综合报告",
                stepIndex: 63,
                totalSteps: 100,
                stepType: .map,
                checkpoint: checkpoint,
                completedStepIndexes: Array(0...62),
                structuredFacts: ["已识别主题数: 12"],
                outputSchema: "返回 JSON: {\"findings\": [...], \"confidence\": 0-1}"
            )
        )

        // 目标
        XCTAssertTrue(prompt.contains("分析 300 份 PDF 并生成综合报告"))
        // 进度范围 (压缩形式)
        XCTAssertTrue(prompt.contains("1...63"), "300 步任务不能逐个列举已完成步骤")
        XCTAssertTrue(prompt.contains("Current step: 64"))
        XCTAssertTrue(prompt.contains("Total steps: 100"))
        // 检查点摘要
        XCTAssertTrue(prompt.contains("已完成 63 个文件的解析"))
        // 已确立事实
        XCTAssertTrue(prompt.contains("已识别主题数: 12"))
        // 输出格式
        XCTAssertTrue(prompt.contains("findings"))

        // 硬性约束
        XCTAssertTrue(prompt.contains("Do NOT restart"))
        XCTAssertTrue(prompt.contains("Do NOT redo"))
        XCTAssertTrue(prompt.contains("do NOT have access to any previous conversation"))

        // 不得依赖任何会话标识
        let lowered = prompt.lowercased()
        XCTAssertFalse(lowered.contains("conversation id"))
        XCTAssertFalse(lowered.contains("chat_history"))
    }

    func testPromptGenerationIsDeterministic() {
        let builder = ContinuationPromptBuilder()
        let checkpoint = Checkpoint(
            taskID: "t1", completedStep: 4, nextStep: 5, workingSummary: "step 5 done"
        )
        let input = ContinuationPromptBuilder.Input(
            goal: "goal",
            stepIndex: 5,
            totalSteps: 10,
            stepType: .map,
            checkpoint: checkpoint,
            completedStepIndexes: [0, 1, 2, 3, 4]
        )

        XCTAssertEqual(
            builder.build(input), builder.build(input),
            "崩溃恢复依赖确定性: 同样的输入必须产出逐字相同的 prompt"
        )
    }

    func testRangeCompression() {
        XCTAssertEqual(
            ContinuationPromptBuilder.compressRanges([]),
            "(none — this is the first step)"
        )
        XCTAssertEqual(ContinuationPromptBuilder.compressRanges([0, 1, 2]), "1...3")
        XCTAssertEqual(ContinuationPromptBuilder.compressRanges([0, 1, 2, 7]), "1...3, 8")
        XCTAssertEqual(ContinuationPromptBuilder.compressRanges([0, 2, 4]), "1, 3, 5")
        // 乱序 + 重复也必须稳定
        XCTAssertEqual(ContinuationPromptBuilder.compressRanges([2, 0, 1, 1]), "1...3")
    }

    func testFirstStepPromptSaysNoProgressYet() {
        let prompt = ContinuationPromptBuilder().build(
            .init(goal: "goal", stepIndex: 0, totalSteps: 3)
        )
        XCTAssertTrue(prompt.contains("(none — this is the first step)"))
        XCTAssertTrue(prompt.contains("No prior progress has been recorded"))
    }

    func testFinalStepInstructionDiffersFromMiddleSteps() {
        let builder = ContinuationPromptBuilder()
        let middle = builder.build(.init(goal: "g", stepIndex: 3, totalSteps: 10, stepType: .map))
        let final = builder.build(.init(goal: "g", stepIndex: 9, totalSteps: 10, stepType: .final))

        XCTAssertTrue(middle.contains("Complete step 4 of 10"))
        XCTAssertTrue(final.contains("FINAL step"))
        XCTAssertNotEqual(middle, final)
    }

    // MARK: - 2. 准备步骤

    func testPrepareStepMarksPreparedAndGeneratesPrompt() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 5)

        let prepared = try await services.web.prepareStep(taskID: task.id)

        XCTAssertEqual(prepared.stepIndex, 0)
        XCTAssertEqual(prepared.ordinal, 1)
        XCTAssertFalse(prepared.prompt.isEmpty)
        XCTAssertFalse(prepared.wasAlreadyPrepared)

        let step = try XCTUnwrap(services.steps.fetch(id: prepared.stepID))
        XCTAssertEqual(step.status, .prepared)
        XCTAssertNotNil(step.preparedAt)
    }

    func testPrepareStepWhenAllStepsDoneThrows() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 1)

        _ = try await completeOneWebStep(services, taskID: task.id, resultText: "唯一一步的结果")

        do {
            _ = try await services.web.prepareStep(taskID: task.id)
            XCTFail("没有可执行步骤时应当抛错")
        } catch let error as WebExecutionError {
            guard case .noExecutableStep = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }
    }

    func testDeliverPromptCopiesToClipboardAndOpensBrowser() async throws {
        let clipboard = InMemoryClipboard()
        let browser = RecordingBrowserLauncher()
        let services = try makeWebServices(clipboard: clipboard, browser: browser)
        let task = try makeWebTask(services, steps: 3)

        let delivery = try await services.web.deliverPrompt(taskID: task.id)

        XCTAssertTrue(delivery.copiedToClipboard)
        XCTAssertEqual(clipboard.readString(), delivery.prepared.prompt)
        XCTAssertTrue(delivery.browserOpened)
        XCTAssertEqual(browser.lastOpened?.absoluteString, ChatGPTWebTarget.defaultURLString)
    }

    func testBrowserOpensConfiguredURL() async throws {
        let browser = RecordingBrowserLauncher()
        let services = try makeWebServices(browser: browser)
        let task = try makeWebTask(services, steps: 2)

        var settings = services.settings
        settings.chatGPTURL = "https://example.invalid/chat"
        await services.saveSettings(settings)

        _ = try await services.web.deliverPrompt(taskID: task.id)
        XCTAssertEqual(browser.lastOpened?.absoluteString, "https://example.invalid/chat")
    }

    // MARK: - 3. 接收结果

    func testAcceptResultCommitsAndAdvancesCheckpoint() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        let prepared = try await services.web.prepareStep(taskID: task.id)
        let imported = try await services.web.acceptResult(
            taskID: task.id,
            stepID: prepared.stepID,
            result: "第一份文件的结论: 主题 A 出现 12 次"
        )

        XCTAssertEqual(imported.stepIndex, 0)
        XCTAssertEqual(imported.checkpoint.completedStep, 0)
        XCTAssertEqual(imported.checkpoint.nextStep, 1)
        XCTAssertEqual(imported.remainingSteps, 2)
        XCTAssertFalse(imported.isFinalStep)

        let step = try XCTUnwrap(services.steps.fetch(id: prepared.stepID))
        XCTAssertEqual(step.status, .completed)
        XCTAssertEqual(step.output?["text"]?.stringValue, "第一份文件的结论: 主题 A 出现 12 次")

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1)
    }

    func testEmptyResultIsRejectedAndCheckpointUnchanged() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)
        let prepared = try await services.web.prepareStep(taskID: task.id)

        do {
            _ = try await services.web.acceptResult(
                taskID: task.id, stepID: prepared.stepID, result: "   \n\t  "
            )
            XCTFail("空结果必须被拒绝")
        } catch let error as WebExecutionError {
            guard case .emptyClipboard = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 0)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.completedStep, -1)
        XCTAssertEqual(
            try services.steps.fetch(id: prepared.stepID)?.status, .prepared,
            "校验失败后步骤应保持「已就绪」, 允许重新提交"
        )
    }

    func testImportClipboardResult() async throws {
        let clipboard = InMemoryClipboard()
        let services = try makeWebServices(clipboard: clipboard)
        let task = try makeWebTask(services, steps: 2)

        _ = try await services.web.prepareStep(taskID: task.id)
        clipboard.writeString("ChatGPT 的回复内容")

        let imported = try await services.web.importClipboardResult(taskID: task.id)
        XCTAssertEqual(imported.stepIndex, 0)
        XCTAssertEqual(imported.checkpoint.nextStep, 1)
    }

    func testImportFailsOnEmptyClipboard() async throws {
        let services = try makeWebServices(clipboard: InMemoryClipboard())
        let task = try makeWebTask(services, steps: 2)
        _ = try await services.web.prepareStep(taskID: task.id)

        do {
            _ = try await services.web.importClipboardResult(taskID: task.id)
            XCTFail("空剪贴板应当报错")
        } catch let error as WebExecutionError {
            guard case .emptyClipboard = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }
    }

    func testMarkSubmittedRecordsTimestamp() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 2)
        let prepared = try await services.web.prepareStep(taskID: task.id)

        try await services.web.markSubmitted(taskID: task.id, stepID: prepared.stepID)
        XCTAssertNotNil(try services.steps.fetch(id: prepared.stepID)?.submittedAt)
    }

    // MARK: - 4. 账号交接

    func testPauseForAccountSwitchPreservesAllProgress() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 5)

        // 先完成两步
        for index in 1...2 {
            _ = try await completeOneWebStep(
                services, taskID: task.id, resultText: "第 \(index) 步的结果"
            )
        }

        let before = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(before.currentStep, 2)

        try await services.web.pauseForAccountSwitch(
            taskID: task.id, reason: "测试: 当前会话无法继续"
        )

        let paused = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(paused.status, .waitingForAccount)
        XCTAssertTrue(paused.status.requiresUserAction)
        XCTAssertFalse(paused.status.isTerminal)

        // ★ 进度一字未动 ★
        XCTAssertEqual(paused.currentStep, 2)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.completedStep, 1)
        XCTAssertEqual(
            try services.steps.fetchAll(taskID: task.id).filter { $0.status == .completed }.count, 2
        )
        // 剩下三步仍可执行
        XCTAssertEqual(try services.steps.executableCount(taskID: task.id), 3)
    }

    func testPauseForAccountSwitchIsIdempotent() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        try await services.web.pauseForAccountSwitch(taskID: task.id, reason: "第一次")
        try await services.web.pauseForAccountSwitch(taskID: task.id, reason: "第二次")

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .waitingForAccount)
    }

    func testResumeAfterAccountSwitchContinuesFromCheckpoint() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 4)

        for index in 1...2 {
            _ = try await completeOneWebStep(
                services, taskID: task.id, resultText: "第 \(index) 步"
            )
        }
        try await services.web.pauseForAccountSwitch(taskID: task.id, reason: "切换账号")
        try await services.web.resumeAfterManualAccountSwitch(taskID: task.id)

        let resumed = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(resumed.status, .running)
        XCTAssertEqual(resumed.currentStep, 2, "必须从检查点继续, 不得回到 0")

        // 下一步是第 3 步, 且 prompt 反映已完成的 2 步
        let next = try await services.web.prepareStep(taskID: task.id)
        XCTAssertEqual(next.stepIndex, 2)
        XCTAssertTrue(next.prompt.contains("1...2"), "prompt 必须反映已完成的 2 步")

        // 日志留痕
        let events = try services.events.list(taskID: task.id, limit: 200)
        XCTAssertTrue(events.contains { $0.eventType == .accountHandoffRequested })
        XCTAssertTrue(events.contains { $0.eventType == .accountHandoffCompleted })
    }

    func testResumeIsRejectedWhenTaskIsNotAwaiting() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        // 任务还在 queued, 恢复调用应当无害地忽略
        try await services.web.resumeAfterManualAccountSwitch(taskID: task.id)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .queued)
    }

    // MARK: - 5. 崩溃恢复

    func testPreparedStepIsRecoveredWithIdenticalPrompt() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        let first = try await services.web.prepareStep(taskID: task.id)

        // 模拟: prompt 已生成, 但用户在回填之前 App 被杀
        try services.tasks.updateStatus(id: task.id, to: .running)

        let report = try services.recovery.recover()
        XCTAssertEqual(report.interruptedSteps, 0, "prepared 不是 running, 不该被标为中断")
        XCTAssertTrue(report.recoverableTaskIDs.contains(task.id))

        // 重启后重新生成 —— ★ 必须逐字一致 ★
        let second = try await services.web.prepareStep(taskID: task.id)
        XCTAssertTrue(second.wasAlreadyPrepared, "应识别出这是对已就绪步骤的重新生成")
        XCTAssertEqual(second.stepID, first.stepID, "不得换到别的步骤")
        XCTAssertEqual(second.prompt, first.prompt, "崩溃后重新生成的 prompt 必须完全相同")
    }

    func testCompletedStepsAreNotRedoneAfterAccountSwitch() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        let first = try await services.web.prepareStep(taskID: task.id)
        _ = try await services.web.acceptResult(
            taskID: task.id, stepID: first.stepID, result: "第 1 步的结果"
        )

        try await services.web.pauseForAccountSwitch(taskID: task.id, reason: "换账号")
        try await services.web.resumeAfterManualAccountSwitch(taskID: task.id)

        let next = try await services.web.prepareStep(taskID: task.id)

        XCTAssertEqual(next.stepIndex, 1, "应准备第 2 步, 而不是重做第 1 步")
        XCTAssertNotEqual(next.stepID, first.stepID)
        XCTAssertEqual(try services.steps.fetch(id: first.stepID)?.status, .completed)
    }

    func testPreparedStepSurvivesDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbPath = directory.appendingPathComponent("airunner.sqlite").path
        let settings = TestSupport.mockSettings()
        var taskID = ""
        var promptBefore = ""

        // 第一次运行: 生成 prompt, 然后"进程消失"
        do {
            let services = try AppServices(
                database: try Database(path: dbPath),
                keychain: InMemoryKeychain(),
                settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
                settingsOverride: settings,
                clipboard: InMemoryClipboard(),
                browser: RecordingBrowserLauncher(),
                echoLogsToConsole: false
            )
            let task = try TestSupport.makeTask(
                services, goal: "长任务", steps: 4, executionMode: .chatGPTWeb
            )
            taskID = task.id
            let prepared = try await services.web.prepareStep(taskID: task.id)
            promptBefore = prepared.prompt
            services.shutdown()
        }

        // 第二次运行: 重新生成必须一致
        do {
            let services = try AppServices(
                database: try Database(path: dbPath),
                keychain: InMemoryKeychain(),
                settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
                settingsOverride: settings,
                clipboard: InMemoryClipboard(),
                browser: RecordingBrowserLauncher(),
                echoLogsToConsole: false
            )
            defer { services.shutdown() }

            let step = try XCTUnwrap(services.steps.awaitingResultStep(taskID: taskID))
            XCTAssertEqual(step.status, .prepared, "prepared 状态必须持久化")
            XCTAssertNotNil(step.preparedAt)

            let regenerated = try await services.web.prepareStep(taskID: taskID)
            XCTAssertEqual(regenerated.prompt, promptBefore, "重开 App 后 prompt 必须一致")
        }
    }

    // MARK: - 6. JobRunner 走 Web 通道

    func testRunnerEntersWaitingForUserInsteadOfBlocking() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(
            settled.status, .waitingForUser,
            "Web 通道下 Runner 生成 prompt 后必须立刻退出, 绝不阻塞等用户"
        )
        XCTAssertEqual(settled.currentStep, 0, "尚未回填结果, 进度不应前进")

        let awaiting = try XCTUnwrap(services.steps.awaitingResultStep(taskID: task.id))
        XCTAssertEqual(awaiting.index, 0)
        XCTAssertEqual(awaiting.status, .prepared)
    }

    func testWebChannelNeverCallsAPIProvider() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 2)

        let mock = MockAIProvider(
            id: TestSupport.mockProviderID, model: TestSupport.mockModel
        )
        services.factory.registerOverride(
            mock, providerID: TestSupport.mockProviderID, model: TestSupport.mockModel
        )

        await services.runner.start(taskID: task.id)
        _ = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(mock.calls, 0, "Web 通道绝不触碰 API Provider")
    }

    // MARK: - 7. 端到端

    func testEndToEndWebTaskCompletesWithoutRedoingWork() async throws {
        let clipboard = InMemoryClipboard()
        let browser = RecordingBrowserLauncher()
        let services = try makeWebServices(clipboard: clipboard, browser: browser)
        let task = try makeWebTask(
            services, steps: 4, goal: "把 4 份文档逐个总结后给出总览"
        )

        // 模拟用户操作 4 轮: 复制 prompt → 提交给 ChatGPT → 粘贴结果
        for round in 1...4 {
            let delivery = try await services.web.deliverPrompt(taskID: task.id)
            XCTAssertEqual(delivery.prepared.ordinal, round)
            XCTAssertEqual(clipboard.readString(), delivery.prepared.prompt)

            clipboard.writeString("第 \(round) 步的结论: 略")

            let imported = try await services.web.importClipboardResult(taskID: task.id)
            XCTAssertEqual(imported.stepIndex, round - 1)
            XCTAssertEqual(imported.checkpoint.nextStep, round)
        }

        let finished = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(finished.currentStep, 4)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 4)

        let steps = try services.steps.fetchAll(taskID: task.id)
        XCTAssertEqual(steps.filter { $0.status == .completed }.count, 4)
        XCTAssertTrue(steps.allSatisfy { $0.output != nil })

        // 每轮都在日志里留痕
        let events = try services.events.list(taskID: task.id, limit: 200)
        XCTAssertTrue(events.contains { $0.eventType == .webStepPrepared })
        XCTAssertTrue(events.contains { $0.eventType == .resultImported })
        XCTAssertTrue(events.contains { $0.eventType == .webPromptCopied })
    }

    func testEndToEndWithMidTaskAccountHandoff() async throws {
        let clipboard = InMemoryClipboard()
        let services = try makeWebServices(clipboard: clipboard)
        let task = try makeWebTask(services, steps: 5, goal: "跨账号完成 5 步")

        // 账号 A: 做完 2 步
        for round in 1...2 {
            _ = try await services.web.deliverPrompt(taskID: task.id)
            clipboard.writeString("A 账号下的第 \(round) 步结果")
            _ = try await services.web.importClipboardResult(taskID: task.id)
        }

        // 账号 A 额度用尽 —— 用户主动交接
        try await services.web.pauseForAccountSwitch(
            taskID: task.id, reason: "账号 A 无法继续"
        )
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .waitingForAccount)

        // 用户手动在浏览器里切到账号 B, 回来点"我已切换"
        try await services.web.resumeAfterManualAccountSwitch(taskID: task.id)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .running)

        // 账号 B: 做完剩下 3 步
        for round in 3...5 {
            _ = try await services.web.deliverPrompt(taskID: task.id)
            let prompt = try XCTUnwrap(clipboard.readString())
            XCTAssertTrue(prompt.contains("1...\(round - 1)"),
                          "第 \(round) 步的 prompt 必须带上之前所有已完成步骤")
            clipboard.writeString("B 账号下的第 \(round) 步结果")
            _ = try await services.web.importClipboardResult(taskID: task.id)
        }

        let finished = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(finished.currentStep, 5)

        let steps = try services.steps.fetchAll(taskID: task.id)
        XCTAssertEqual(steps.filter { $0.status == .completed }.count, 5)
        XCTAssertEqual(steps[0].output?["text"]?.stringValue, "A 账号下的第 1 步结果",
                       "换账号后, 换账号前的结果必须原封不动")
        XCTAssertEqual(steps[4].output?["text"]?.stringValue, "B 账号下的第 5 步结果")
    }

    // MARK: - 8. 状态与迁移

    func testWaitingForAccountTransitionLegality() {
        XCTAssertTrue(TaskStatus.running.canTransition(to: .waitingForAccount))
        XCTAssertTrue(TaskStatus.waitingForAccount.canTransition(to: .running))
        XCTAssertTrue(TaskStatus.waitingForAccount.canTransition(to: .paused))
        XCTAssertTrue(TaskStatus.waitingForAccount.canTransition(to: .waitingForUser))
        XCTAssertFalse(TaskStatus.completed.canTransition(to: .waitingForAccount))

        XCTAssertTrue(TaskStatus.waitingForAccount.requiresUserAction)
        XCTAssertTrue(TaskStatus.waitingForBrowser.requiresUserAction)
        XCTAssertTrue(TaskStatus.waitingForUser.requiresUserAction)
        XCTAssertFalse(TaskStatus.running.requiresUserAction)

        XCTAssertFalse(TaskStatus.waitingForAccount.isTerminal)
    }

    func testMigrationIsIdempotentAndAddsWebColumns() throws {
        let db = try Database.inMemory()
        try DatabaseMigrator.migrate(db)
        try DatabaseMigrator.migrate(db)   // 第二次不得报错

        XCTAssertEqual(try db.scalarInt("PRAGMA user_version;"), DatabaseMigrator.currentVersion)
        XCTAssertTrue(
            try DatabaseMigrator.columnExists(db, table: "tasks", column: "execution_mode")
        )
        XCTAssertTrue(
            try DatabaseMigrator.columnExists(db, table: "task_steps", column: "prepared_at")
        )
        XCTAssertTrue(
            try DatabaseMigrator.columnExists(db, table: "task_steps", column: "submitted_at")
        )
    }

    func testLegacyRowsDefaultToChatGPTWebMode() throws {
        let db = try Database.inMemory()
        try DatabaseMigrator.migrate(db)

        // 模拟 v1 时代写入的行 (不带 execution_mode), 依赖列默认值
        try db.execute(
            """
            INSERT INTO tasks (
                id, name, goal, status, primary_provider, primary_model,
                current_step, total_steps, retry_count, max_retries,
                created_at, updated_at, plan_type, meta_json
            ) VALUES ('legacy','旧任务','旧目标','queued','openai','gpt-4o-mini',
                      0, 3, 0, 8,
                      '2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','uniform','{}')
            """
        )

        let task = try XCTUnwrap(TaskRepository(db: db).fetch(id: "legacy"))
        XCTAssertEqual(task.executionMode, .chatGPTWeb, "v1 老数据应默认归入 Web 主通道")
    }

    func testDefaultExecutionModeIsChatGPTWeb() {
        XCTAssertEqual(ExecutionMode.chatGPTWeb.rawValue, "chatgpt_web")
        XCTAssertTrue(ExecutionMode.chatGPTWeb.isPrimary)
        XCTAssertFalse(ExecutionMode.api.isPrimary)

        // 出厂设置默认走 Web
        XCTAssertEqual(AppSettings.default.defaultExecutionMode, .chatGPTWeb)

        // 设置升级: 老 JSON 里没有新字段也不该整份失效
        let legacyJSON = """
        {"providers":[],"routes":[],"concurrency":5,"retry":{"baseDelay":7,"factor":2,"maxDelay":300,"jitterRatio":0.3,"maxRetries":8,"maxRateLimitWaits":12,"maxRepairs":2,"providerDegradedThreshold":3,"providerUnavailableThreshold":5,"providerCooldown":600,"billingCooldown":21600,"contextShrinkFactor":0.5}}
        """
        let decoded = try? JSONCoding.decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded?.concurrency, 5, "老配置里的已有字段必须保留")
        XCTAssertEqual(decoded?.defaultExecutionMode, .chatGPTWeb, "缺失的新字段走默认值")
    }
}

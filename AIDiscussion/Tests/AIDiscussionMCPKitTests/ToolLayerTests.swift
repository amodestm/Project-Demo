import XCTest
import AIDiscussionBridge
@testable import AIDiscussionMCPKit

/// 工具层：参数校验、错误翻译、结果渲染。
///
/// 这一层是模型看到的一切。渲染错位的代价是模型拿到一段读不懂的文本然后乱猜，
/// 所以"结论在最前面""截断要留痕""错误要带 hint"这些都被钉成断言。
final class ToolLayerTests: XCTestCase {

    // MARK: - 不依赖桥接的参数校验

    /// jobId 缺失必须在**连桥接之前**就拦下，并给出可操作提示。
    func testResultWithoutJobIdFailsBeforeTouchingBridge() async {
        let executor = BridgeToolExecutor(autoLaunch: false)

        let result = await executor.call(tool: "discussion_result", arguments: .emptyObject)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("jobId"))
        XCTAssertTrue(result.text.contains("提示"))
    }

    func testCancelWithoutJobIdFailsBeforeTouchingBridge() async {
        let executor = BridgeToolExecutor(autoLaunch: false)

        let result = await executor.call(tool: "discussion_cancel", arguments: .emptyObject)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("jobId"))
    }

    func testBlankJobIdIsTreatedAsMissing() async {
        let executor = BridgeToolExecutor(autoLaunch: false)

        let result = await executor.call(
            tool: "discussion_result",
            arguments: .object(["jobId": .string("   ")])
        )

        XCTAssertTrue(result.isError)
    }

    func testUnknownToolIsReportedAsFailure() async {
        let executor = BridgeToolExecutor(autoLaunch: false)

        let result = await executor.call(tool: "made_up_tool", arguments: .emptyObject)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("made_up_tool"))
    }

    /// 这条**不能**断言"一定失败" —— 本机 app 可能正在运行，桥接是通的。
    /// 不稳定测试比没有测试更糟，所以这里只断言**契约**：
    /// 失败必须是可行动的，成功必须是结构完整的。
    func testCatalogToolEitherSucceedsOrFailsActionably() async {
        let executor = BridgeToolExecutor(autoLaunch: false)

        let result = await executor.call(tool: "discussion_profiles", arguments: .emptyObject)

        if result.isError {
            XCTAssertTrue(
                result.text.contains("提示："),
                "失败文本必须告诉用户下一步做什么，实际是：\(result.text)"
            )
            XCTAssertTrue(
                result.text.contains("AIDiscussion"),
                "失败文本应指向 AIDiscussion，实际是：\(result.text)"
            )
        } else {
            XCTAssertFalse(result.text.isEmpty)
            // 成功时应当能解析出 Profile 列表（即使是空数组也不能是一段乱码）
            XCTAssertNotNil(result.structured?.arrayValue)
        }
    }

    /// 走不到桥接的失败路径是确定性的，这里钉死它。
    func testMissingJobIdFailsWithoutTouchingBridgeEvenWhenAppRuns() async {
        let executor = BridgeToolExecutor(autoLaunch: false)

        let result = await executor.call(tool: "discussion_result", arguments: .emptyObject)

        XCTAssertTrue(result.isError, "缺 jobId 必须在连桥接之前就拦下")
        XCTAssertTrue(result.text.contains("jobId"))
    }

    // MARK: - 错误翻译

    func testKnownErrorCodesCarryActionableHints() {
        let cases: [BridgeErrorCode] = [
            .accessibility, .loginRequired, .unauthenticated,
            .notFound, .busy, .timeout, .invalidRequest, .internalError
        ]

        for code in cases {
            let rendered = BridgeToolExecutor.render(
                error: BridgeError(code: code, message: "原始错误")
            )
            XCTAssertTrue(rendered.isError)
            XCTAssertTrue(
                rendered.text.contains(code.rawValue),
                "错误码要出现在文本里，便于模型与日志对照"
            )
            XCTAssertTrue(
                rendered.text.contains("提示："),
                "\(code.rawValue) 缺少行动提示"
            )
        }
    }

    func testLoginRequiredHintPointsAtTheApp() {
        let rendered = BridgeToolExecutor.render(
            error: BridgeError(
                code: .loginRequired,
                message: "成员「批判者」未登录：窗口账号不匹配"
            )
        )

        XCTAssertTrue(rendered.text.contains("一键跳转登录"))
    }

    func testNilErrorStillProducesFailure() {
        let rendered = BridgeToolExecutor.render(error: nil)
        XCTAssertTrue(rendered.isError)
    }

    // MARK: - 结论渲染

    private func makeOutcome(
        state: String = "converged",
        decision: String? = "选 A。理由是成本最低且能在两周内落地。",
        utterances: [BridgeUtterance]
    ) throws -> JSONValue {
        let outcome = BridgeOutcome(
            runId: "run-1",
            jobId: "job-1",
            groupName: "仲裁器选型",
            topic: "要不要把仲裁器换成 v4",
            state: state,
            finalDecision: decision,
            errorMessage: nil,
            utterances: utterances,
            audit: [
                BridgeAuditEntry(participant: "批判者", profile: "Profile 3", account: "critic@example.com", utterances: 2),
                BridgeAuditEntry(participant: "成本专家", profile: "Profile 4", account: "cost@example.com", utterances: 2)
            ],
            startedAt: "2026-01-01T00:00:00Z",
            finishedAt: "2026-01-01T00:10:00Z"
        )
        return try BridgeJSON.decode(JSONValue.self, from: BridgeJSON.encode(outcome))
    }

    private func utterance(
        round: Int,
        title: String,
        participant: String,
        status: String = "received",
        response: String
    ) -> BridgeUtterance {
        BridgeUtterance(
            roundIndex: round,
            roundTitle: title,
            participant: participant,
            status: status,
            prompt: "很长的提示词",
            response: response,
            accountUsed: "\(participant)@example.com"
        )
    }

    func testOutcomeRendersDecisionBeforeTranscript() throws {
        let json = try makeOutcome(utterances: [
            utterance(round: 0, title: "第 1 轮 · 各自表态", participant: "批判者", response: "我反对"),
            utterance(round: 1, title: "收敛 · 最终决策", participant: "主席", response: "选 A")
        ])

        let text = try BridgeToolExecutor.renderOutcome(json, limit: 2_000)

        // 结论必须在最前面 —— 模型通常只读这一段
        XCTAssertTrue(text.hasPrefix("# 讨论结论"))
        let decisionIndex = try XCTUnwrap(text.range(of: "选 A。理由是成本最低"))
        let transcriptIndex = try XCTUnwrap(text.range(of: "## 讨论记录"))
        XCTAssertLessThan(decisionIndex.lowerBound, transcriptIndex.lowerBound)

        XCTAssertTrue(text.contains("批判者"))
        XCTAssertTrue(text.contains("第 1 轮 · 各自表态"))
        XCTAssertTrue(text.contains("## 账号审计"))
        XCTAssertTrue(text.contains("Profile 3"))
        XCTAssertTrue(text.contains("`job-1`"), "要告诉模型怎么取全文")
    }

    func testOutcomeTruncatesLongUtterancesAndSaysSo() throws {
        let long = String(repeating: "长", count: 500)
        let json = try makeOutcome(utterances: [
            utterance(round: 0, title: "第 1 轮", participant: "批判者", response: long)
        ])

        let text = try BridgeToolExecutor.renderOutcome(json, limit: 200)

        XCTAssertTrue(text.contains("…（已截断 300 字）"), "截断必须留痕，否则模型会以为原文就这么多")
        XCTAssertFalse(text.contains(long))
    }

    func testUnconvergedOutcomeSurfacesErrorInsteadOfFakeDecision() throws {
        let json = try makeOutcome(state: "failed", decision: nil, utterances: [
            utterance(round: 0, title: "第 1 轮", participant: "批判者", status: "failed", response: "")
        ])

        let text = try BridgeToolExecutor.renderOutcome(json, limit: 2_000)

        XCTAssertTrue(text.contains("讨论未成功结束"))
        XCTAssertFalse(text.contains("# 讨论结论"))
    }

    func testFailedUtteranceShowsStatusPlaceholder() throws {
        let json = try makeOutcome(utterances: [
            utterance(round: 0, title: "第 1 轮", participant: "批判者", status: "failed", response: "")
        ])

        let text = try BridgeToolExecutor.renderOutcome(json, limit: 2_000)

        XCTAssertTrue(text.contains("（failed）"))
    }

    // MARK: - schema

    /// run 的 topic 刻意**不**放进 required：复用已保存讨论组时议题来自组本身。
    func testDiscussionRunSchemaAllowsTopicToComeFromGroup() throws {
        let tool = try XCTUnwrap(ToolCatalog.tools.first { $0.name == "discussion_run" })

        let required = tool.inputSchema["required"]?.arrayValue
        XCTAssertEqual(required?.isEmpty, true)

        let properties = try XCTUnwrap(tool.inputSchema["properties"]?.objectValue)
        for key in ["topic", "participants", "rounds", "consensus", "group", "moderator", "timeoutSeconds"] {
            XCTAssertNotNil(properties[key], "discussion_run 缺少参数 \(key)")
        }
    }

    func testParticipantSchemaRequiresName() throws {
        let tool = try XCTUnwrap(ToolCatalog.tools.first { $0.name == "discussion_run" })
        let participants = try XCTUnwrap(tool.inputSchema["properties"]?["participants"])

        XCTAssertEqual(participants["type"]?.stringValue, "array")
        let items = try XCTUnwrap(participants["items"])
        XCTAssertEqual(items["required"]?.arrayValue?.first?.stringValue, "name")

        let properties = try XCTUnwrap(items["properties"]?.objectValue)
        XCTAssertNotNil(properties["role"])
        XCTAssertNotNil(properties["preset"])
        XCTAssertNotNil(properties["profile"])
        XCTAssertNotNil(properties["account"])
    }

    func testResultToolRequiresJobId() throws {
        let tool = try XCTUnwrap(ToolCatalog.tools.first { $0.name == "discussion_result" })

        XCTAssertEqual(
            tool.inputSchema["required"]?.arrayValue?.first?.stringValue,
            "jobId"
        )
    }

    func testNoArgToolsDeclareEmptyObjectSchema() throws {
        for name in ["discussion_roles", "discussion_profiles", "discussion_groups"] {
            let tool = try XCTUnwrap(ToolCatalog.tools.first { $0.name == name })
            XCTAssertEqual(tool.inputSchema["type"]?.stringValue, "object")
            XCTAssertNotNil(tool.inputSchema["properties"])
            XCTAssertEqual(tool.inputSchema["required"]?.arrayValue?.isEmpty, true)
        }
    }

    /// instructions 是模型唯一的说明书，"角色互斥"这条不写进去，讨论必然退化成附和。
    func testInstructionsExplainMutuallyExclusiveRoles() {
        let text = ToolCatalog.instructions

        XCTAssertTrue(text.contains("互斥"))
        XCTAssertTrue(text.contains("discussion_profiles"))
        XCTAssertTrue(text.contains("discussion_run"))
        XCTAssertTrue(text.contains("login_required"))
    }
}

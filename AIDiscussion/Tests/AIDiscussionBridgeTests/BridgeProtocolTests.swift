import XCTest
@testable import AIDiscussionBridge

/// 桥接线协议的编解码与分帧测试。
///
/// 这些是 app 与 MCP 两端**唯一共用的契约**，任何一侧改错都会让桥接静默失效，
/// 所以必须钉死。
final class BridgeProtocolTests: XCTestCase {

    // MARK: - 分帧

    func testLineBufferSplitsMultipleMessagesInOneChunk() {
        var buffer = LineBuffer()
        let chunk = Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n".utf8)

        let messages = buffer.append(chunk)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(String(decoding: messages[0], as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(String(decoding: messages[2], as: UTF8.self), "{\"c\":3}")
        XCTAssertEqual(buffer.pendingByteCount, 0)
    }

    func testLineBufferReassemblesMessageSplitAcrossChunks() {
        var buffer = LineBuffer()

        XCTAssertTrue(buffer.append(Data("{\"topic\":\"半".utf8)).isEmpty)
        XCTAssertTrue(buffer.append(Data("条消息\"}".utf8)).isEmpty)
        XCTAssertEqual(buffer.pendingByteCount, "{\"topic\":\"半条消息\"}".utf8.count)

        let messages = buffer.append(Data("\n".utf8))

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(
            String(decoding: messages[0], as: UTF8.self),
            "{\"topic\":\"半条消息\"}"
        )
    }

    func testLineBufferToleratesCRLFAndDropsBlankLines() {
        var buffer = LineBuffer()

        let messages = buffer.append(Data("\r\n{\"a\":1}\r\n\n\n".utf8))

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(String(decoding: messages[0], as: UTF8.self), "{\"a\":1}")
    }

    func testLineBufferFlushReturnsTrailingMessageWithoutNewline() {
        var buffer = LineBuffer()
        _ = buffer.append(Data("{\"a\":1}".utf8))

        let trailing = buffer.flush()

        XCTAssertEqual(trailing.map { String(decoding: $0, as: UTF8.self) }, "{\"a\":1}")
        XCTAssertTrue(buffer.isEmptyAfterFlushForTesting)
    }

    // MARK: - 单行约束

    /// 线协议是"一条消息一行"，编码结果里出现裸换行会直接把流切坏。
    func testEncodedMessagesNeverContainRawNewline() throws {
        let spec = BridgeDiscussionSpec(
            topic: "第一行\n第二行\r\n第三行",
            participants: [
                BridgeParticipantSpec(name: "批判者", role: "只挑毛病\n不许肯定任何人"),
                BridgeParticipantSpec(name: "成本专家", preset: "成本专家")
            ]
        )
        let request = BridgeRequest(token: "t", op: .run, payload: nil)

        XCTAssertTrue(BridgeJSON.isSingleLine(spec), "讨论规格编码后出现了裸换行")
        XCTAssertTrue(BridgeJSON.isSingleLine(request), "请求封套编码后出现了裸换行")

        // 换行必须以转义形式保留，而不是被丢掉
        let json = try XCTUnwrap(BridgeJSON.string(spec))
        XCTAssertTrue(json.contains("\\n"))
    }

    // MARK: - 封套往返

    func testRequestDecodesBackToSameSpec() throws {
        let spec = BridgeDiscussionSpec(
            topic: "要不要把 S4.5 的仲裁器换成 v4",
            name: "仲裁器选型",
            participants: [
                BridgeParticipantSpec(
                    name: "风险官",
                    role: "只关注最坏情况",
                    profile: "Profile 3",
                    account: "user@example.com"
                )
            ],
            rounds: [
                BridgeRoundSpec(kind: "independentOpinion", visibility: "none"),
                BridgeRoundSpec(kind: "convergence", visibility: "all", speakers: ["风险官"])
            ],
            consensus: "majorityVote"
        )

        let request = BridgeRequest(
            token: "abc",
            op: .run,
            payload: try BridgeJSON.decode(JSONValue.self, from: BridgeJSON.encode(spec))
        )
        let line = try XCTUnwrap(BridgeJSON.string(request))

        let decoded = try BridgeJSON.decode(BridgeRequest.self, from: line)
        XCTAssertEqual(decoded.token, "abc")
        XCTAssertEqual(decoded.op, BridgeOp.run)

        let payload = try XCTUnwrap(decoded.payload)
        let roundTripped = try BridgeJSON.decode(
            BridgeDiscussionSpec.self, from: BridgeJSON.encode(payload)
        )
        XCTAssertEqual(roundTripped, spec)
    }

    func testResponseEncodingCarriesTypedResult() throws {
        let snapshot = BridgeJobSnapshot(
            jobId: "job-1",
            runId: "run-1",
            groupName: "仲裁器选型",
            topic: "议题",
            state: "running",
            isFinished: false,
            currentRound: 1,
            totalRounds: 3,
            currentParticipant: "成本专家",
            completedUtterances: 2,
            expectedUtterances: 9,
            progressText: "第 2/3 轮，成本专家正在作答",
            errorMessage: nil,
            loginIssue: nil,
            startedAt: nil
        )

        let response = BridgeResponse.encoding(snapshot)
        XCTAssertTrue(response.ok)

        let decoded = try response.decodedResult(BridgeJobSnapshot.self)
        XCTAssertEqual(decoded, snapshot)
    }

    func testFailureResponseCarriesErrorCodeAndHint() throws {
        let response = BridgeResponse.failure(
            BridgeError(
                code: .loginRequired,
                message: "成员「批判者」的窗口账号不匹配",
                hint: "在 AIDiscussion 里点一键跳转登录后重试"
            )
        )

        let line = try XCTUnwrap(BridgeJSON.string(response))
        let decoded = try BridgeJSON.decode(BridgeResponse.self, from: line)

        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, .loginRequired)
        XCTAssertEqual(decoded.error?.hint, "在 AIDiscussion 里点一键跳转登录后重试")
        XCTAssertThrowsError(try decoded.decodedResult(BridgeJobSnapshot.self))
    }

    // MARK: - op 取值稳定性

    /// op 是跨端字符串契约，改名等于破坏兼容。
    func testOperationRawValuesAreStable() {
        XCTAssertEqual(BridgeOp.ping.rawValue, "ping")
        XCTAssertEqual(BridgeOp.roles.rawValue, "roles")
        XCTAssertEqual(BridgeOp.profiles.rawValue, "profiles")
        XCTAssertEqual(BridgeOp.groups.rawValue, "groups")
        XCTAssertEqual(BridgeOp.run.rawValue, "run")
        XCTAssertEqual(BridgeOp.start.rawValue, "start")
        XCTAssertEqual(BridgeOp.status.rawValue, "status")
        XCTAssertEqual(BridgeOp.result.rawValue, "result")
        XCTAssertEqual(BridgeOp.cancel.rawValue, "cancel")

        XCTAssertEqual(BridgeErrorCode.invalidRequest.rawValue, "invalid_request")
        XCTAssertEqual(BridgeErrorCode.loginRequired.rawValue, "login_required")
        XCTAssertEqual(BridgeErrorCode.accessibility.rawValue, "accessibility")
    }

    // MARK: - 路径约定

    func testPathsLiveInApplicationSupportDirectory() {
        let dir = BridgePaths.supportDirectory()

        XCTAssertTrue(dir.path.hasSuffix("/Library/Application Support/AIDiscussion"))
        XCTAssertEqual(
            BridgePaths.socketURL().lastPathComponent,
            BridgeProtocol.socketFileName
        )
        XCTAssertEqual(
            BridgePaths.tokenURL().lastPathComponent,
            BridgeProtocol.tokenFileName
        )
        XCTAssertEqual(
            BridgePaths.metaURL().lastPathComponent,
            BridgeProtocol.metaFileName
        )
    }

    func testGeneratedTokensAreLongAndUnique() {
        let a = BridgePaths.makeToken()
        let b = BridgePaths.makeToken()

        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
    }
}

private extension LineBuffer {
    var isEmptyAfterFlushForTesting: Bool { pendingByteCount == 0 }
}

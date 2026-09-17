import XCTest
import AIDiscussionBridge
@testable import AIDiscussionMCPKit

/// MCP 会话状态机与工具面的测试。
///
/// 这些测试**不碰真实 app、不碰 socket** —— 需要跑讨论的路径由 app 侧测试覆盖，
/// 这里只钉住"协议层面绝不允许出错"的部分：握手、能力声明、错误码、参数校验。
final class MCPSessionTests: XCTestCase {

    // MARK: - 测试替身

    /// 把调用记录下来的执行器，用于断言"参数有没有原样传下去"。
    private actor RecordingExecutor: MCPToolExecuting {
        private(set) var calls: [(tool: String, arguments: JSONValue)] = []
        private let result: MCPToolResult

        init(result: MCPToolResult = MCPToolResult(text: "ok")) {
            self.result = result
        }

        func call(tool name: String, arguments: JSONValue) async -> MCPToolResult {
            calls.append((name, arguments))
            return result
        }

        var lastCall: (tool: String, arguments: JSONValue)? { calls.last }
    }

    // MARK: - 构造辅助

    private func makeSession(executor: any MCPToolExecuting) -> MCPSession {
        MCPSession(
            tools: ToolCatalog.tools,
            executor: executor,
            serverName: ToolCatalog.serverName,
            serverVersion: ToolCatalog.serverVersion,
            instructions: ToolCatalog.instructions
        )
    }

    /// 建一个已握手的会话。
    private func makeReadySession(executor: any MCPToolExecuting) async -> MCPSession {
        let session = makeSession(executor: executor)
        _ = await session.handle(request(1, "initialize", initializeParams("2025-06-18")))
        _ = await session.handle(notification("notifications/initialized"))
        return session
    }

    /// `XCTUnwrap` 的参数是 autoclosure，装不下 `await`，所以先 await 再解包。
    private func respond(
        _ session: MCPSession,
        _ message: JSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> JSONValue {
        let raw = await session.handle(message)
        return try XCTUnwrap(raw, "本应返回响应（非通知）", file: file, line: line)
    }

    private func request(_ id: Int, _ method: String, _ params: JSONValue? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method)
        ]
        if let params { fields["params"] = params }
        return .object(fields)
    }

    private func notification(_ method: String, _ params: JSONValue? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ]
        if let params { fields["params"] = params }
        return .object(fields)
    }

    private func initializeParams(_ version: String) -> JSONValue {
        .object([
            "protocolVersion": .string(version),
            "capabilities": .emptyObject,
            "clientInfo": .object(["name": .string("test"), "version": .string("0")])
        ])
    }

    // MARK: - 握手

    func testInitializeAdvertisesToolsCapabilityAndInstructions() async throws {
        let session = makeSession(executor: RecordingExecutor())

        let response = try await respond(
            session, request(1, "initialize", initializeParams("2025-06-18"))
        )

        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(result["serverInfo"]?["name"]?.stringValue, "aidiscussion")
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertFalse(
            (result["instructions"]?.stringValue ?? "").isEmpty,
            "instructions 是模型唯一的说明书，不能为空"
        )
    }

    /// 规范要求：客户端给的版本认识就照抄，不认识就回自己的最新版。
    func testInitializeEchoesKnownVersionAndFallsBackForUnknown() async throws {
        let session = makeSession(executor: RecordingExecutor())

        let known = try await respond(
            session, request(1, "initialize", initializeParams("2024-11-05"))
        )
        XCTAssertEqual(known["result"]?["protocolVersion"]?.stringValue, "2024-11-05")

        let unknown = try await respond(
            session, request(2, "initialize", initializeParams("1999-01-01"))
        )
        XCTAssertEqual(unknown["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
    }

    /// ★ 这条如果写歪，表现是"请求被拒却静默无响应"，客户端会一直等下去。
    func testRequestBeforeInitializeGetsNotInitializedError() async throws {
        let session = makeSession(executor: RecordingExecutor())

        let response = try await respond(session, request(7, "tools/list"))

        XCTAssertEqual(response["id"]?.intValue, 7)
        XCTAssertEqual(response["error"]?["code"]?.intValue, JSONRPC.serverNotInitialized)
        XCTAssertNil(response["result"])
    }

    func testNotificationBeforeInitializeGetsNoResponse() async {
        let session = makeSession(executor: RecordingExecutor())

        let response = await session.handle(notification("notifications/initialized"))

        XCTAssertNil(response, "通知按规范不应有响应")
    }

    func testPingWorksWithoutHandshake() async throws {
        let session = makeSession(executor: RecordingExecutor())

        let response = try await respond(session, request(3, "ping"))

        XCTAssertNil(response["error"])
        XCTAssertNotNil(response["result"])
    }

    // MARK: - 方法分发

    func testToolsListReturnsEveryCatalogToolWithObjectSchema() async throws {
        let session = await makeReadySession(executor: RecordingExecutor())

        let response = try await respond(session, request(2, "tools/list"))
        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)

        XCTAssertEqual(tools.count, ToolCatalog.tools.count)

        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names).count, names.count, "工具名不能重复")
        for expected in [
            "discussion_run", "discussion_start", "discussion_status",
            "discussion_result", "discussion_cancel",
            "discussion_roles", "discussion_profiles", "discussion_groups"
        ] {
            XCTAssertTrue(names.contains(expected), "缺少工具 \(expected)")
        }

        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object")
            XCTAssertFalse((tool["description"]?.stringValue ?? "").isEmpty)
        }
    }

    func testUnknownMethodReturnsMethodNotFoundWithSupportedList() async throws {
        let session = await makeReadySession(executor: RecordingExecutor())

        let response = try await respond(session, request(4, "does/not/exist"))

        XCTAssertEqual(response["error"]?["code"]?.intValue, JSONRPC.methodNotFound)
        XCTAssertNotNil(response["error"]?["data"]?["supported"])
    }

    func testNonObjectMessageIsRejected() async throws {
        let session = makeSession(executor: RecordingExecutor())

        let response = try await respond(session, .string("not a message"))

        XCTAssertEqual(response["error"]?["code"]?.intValue, JSONRPC.invalidRequest)
    }

    // MARK: - 工具调用

    func testUnknownToolIsProtocolErrorWithAvailableList() async throws {
        let session = await makeReadySession(executor: RecordingExecutor())

        let response = try await respond(
            session,
            request(5, "tools/call", .object([
                "name": .string("nonexistent_tool"),
                "arguments": .emptyObject
            ]))
        )

        XCTAssertEqual(response["error"]?["code"]?.intValue, JSONRPC.invalidParams)
        let available = try XCTUnwrap(response["error"]?["data"]?["available"]?.arrayValue)
        XCTAssertEqual(available.count, ToolCatalog.tools.count)
    }

    func testSuccessfulToolCallReturnsTextContent() async throws {
        let executor = RecordingExecutor(result: MCPToolResult(text: "讨论结论：选 A"))
        let session = await makeReadySession(executor: executor)

        let arguments = JSONValue.object(["jobId": .string("job-1")])
        let response = try await respond(
            session,
            request(6, "tools/call", .object([
                "name": .string("discussion_result"),
                "arguments": arguments
            ]))
        )

        let content = try XCTUnwrap(response["result"]?["content"]?.arrayValue)
        XCTAssertEqual(content.first?["type"]?.stringValue, "text")
        XCTAssertEqual(content.first?["text"]?.stringValue, "讨论结论：选 A")
        XCTAssertNil(response["result"]?["isError"])

        let recorded = await executor.lastCall
        XCTAssertEqual(recorded?.tool, "discussion_result")
        XCTAssertEqual(recorded?.arguments, arguments)
    }

    /// 业务失败必须走 `isError`，把可行动的说明交给模型，
    /// 而不是甩一个协议错误让客户端渲染成裸失败。
    func testToolFailureIsReportedAsIsErrorResult() async throws {
        let executor = RecordingExecutor(
            result: .failure("成员「批判者」未登录", hint: "点一键跳转登录")
        )
        let session = await makeReadySession(executor: executor)

        let response = try await respond(
            session,
            request(8, "tools/call", .object([
                "name": .string("discussion_run"),
                "arguments": .emptyObject
            ]))
        )

        XCTAssertNil(response["error"], "业务失败不应变成协议错误")
        XCTAssertEqual(response["result"]?["isError"]?.boolValue, true)
        let text = try XCTUnwrap(
            response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        )
        XCTAssertTrue(text.contains("未登录"))
        XCTAssertTrue(text.contains("一键跳转登录"))
    }

    func testToolCallWithoutNameIsInvalidParams() async throws {
        let session = await makeReadySession(executor: RecordingExecutor())

        let response = try await respond(
            session, request(9, "tools/call", .object(["arguments": .emptyObject]))
        )

        XCTAssertEqual(response["error"]?["code"]?.intValue, JSONRPC.invalidParams)
    }

    /// 通知形式的 tools/call 不该回响应（客户端不会等，回了就是脏消息）。
    func testToolCallAsNotificationProducesNoResponse() async {
        let session = await makeReadySession(executor: RecordingExecutor())

        let response = await session.handle(notification("tools/call", .object([
            "name": .string("discussion_roles"),
            "arguments": .emptyObject
        ])))

        XCTAssertNil(response)
    }
}

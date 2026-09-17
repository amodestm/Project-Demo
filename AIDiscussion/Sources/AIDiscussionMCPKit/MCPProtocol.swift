import Foundation
import AIDiscussionBridge

/// JSON-RPC 2.0 / MCP 的固定取值。
public enum JSONRPC {
    public static let version = "2.0"

    // 协议错误码（规范定义）
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// 服务器尚未完成 initialize 握手
    public static let serverNotInitialized = -32002

    /// 本服务端认识并愿意回退兼容的 MCP 协议版本（新 → 旧）。
    public static let supportedProtocolVersions = [
        "2025-06-18",
        "2025-03-26",
        "2024-11-05"
    ]
    public static let defaultProtocolVersion = "2025-06-18"
}

/// 一条 MCP 工具调用的结果。
///
/// ## 错误分成两层是刻意的
///
/// - **协议错误**（`JSONRPC.invalidParams` 之类）留给"工具名不存在"这种框架级问题。
/// - **业务失败**走这里：`isError = true` + 一段可行动的说明文本。模型能读到这段文本
///   并自行纠正（比如换个 Profile、补上账号标识），而协议错误在多数客户端里
///   只会被渲染成一句冷冰冰的失败，模型拿不到修正所需的信息。
public struct MCPToolResult {
    var text: String
    var structured: JSONValue?
    var isError: Bool

    init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    static func failure(_ message: String, hint: String? = nil) -> MCPToolResult {
        var text = message
        if let hint, !hint.isEmpty { text += "\n提示：\(hint)" }
        return MCPToolResult(text: text, isError: true)
    }

    var json: JSONValue {
        var payload: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]
        if let structured { payload["structuredContent"] = structured }
        if isError { payload["isError"] = .bool(true) }
        return .object(payload)
    }
}

/// 一个 MCP 工具的定义。
public struct MCPTool: Sendable {
    var name: String
    var title: String
    var description: String
    var inputSchema: JSONValue

    var json: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }
}

/// 工具的实际执行者。抽出来是为了让会话状态机可以脱离真实 socket 做单元测试。
public protocol MCPToolExecuting: Sendable {
    func call(tool name: String, arguments: JSONValue) async -> MCPToolResult
}

/// MCP 会话状态机：把一条入站消息变成一条（或零条）出站消息。
///
/// 不碰 stdin/stdout，因此可以在测试里逐条喂消息断言行为。
///
/// 用 `actor` 而不是 `class`：主循环会为每条入站消息起一个 Task（否则一条
/// `discussion_run` 阻塞几十分钟，客户端的取消通知就永远读不到），
/// 而握手状态是共享可变的。actor 正好把这件事管住。
public actor MCPSession {

    public nonisolated let tools: [MCPTool]
    private let executor: any MCPToolExecuting
    private let serverName: String
    private let serverVersion: String
    private let instructions: String

    /// 握手完成前，除 `initialize`/`ping` 之外的请求都应被拒。
    public private(set) var isInitialized = false
    public private(set) var negotiatedProtocolVersion = JSONRPC.defaultProtocolVersion

    public init(
        tools: [MCPTool],
        executor: any MCPToolExecuting,
        serverName: String,
        serverVersion: String,
        instructions: String
    ) {
        self.tools = tools
        self.executor = executor
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
    }

    /// 处理一条消息。返回 `nil` 表示这条是通知，按规范不回响应。
    public func handle(_ message: JSONValue) async -> JSONValue? {
        guard case let .object(fields) = message else {
            return errorResponse(id: .null, code: JSONRPC.invalidRequest, message: "消息必须是 JSON 对象")
        }

        let id = fields["id"]
        let isNotification = (id == nil || id?.isNull == true)

        guard let method = fields["method"]?.stringValue else {
            return isNotification
                ? nil
                : errorResponse(id: id, code: JSONRPC.invalidRequest, message: "缺少 method 字段")
        }

        let params = fields["params"]

        // 握手前置检查：initialize 与 ping 之外，握手完成前一律拒绝。
        // 放在 switch 之前，避免每个分支各写一遍（写歪一次就会变成"请求被拒却静默无响应"）。
        let isHandshakeExempt = method == "initialize"
            || method == "ping"
            || method.hasPrefix("notifications/")
        if !isHandshakeExempt && !isInitialized {
            return isNotification
                ? nil   // 通知按规范不回错误
                : errorResponse(
                    id: id,
                    code: JSONRPC.serverNotInitialized,
                    message: "服务器尚未完成 initialize 握手",
                    data: .object(["hint": .string("先发送 initialize，收到结果后再发 notifications/initialized。")])
                )
        }

        switch method {
        case "initialize":
            return handleInitialize(id: id, params: params, isNotification: isNotification)

        case "notifications/initialized", "notifications/cancelled":
            // 通知：确认状态即可，不回响应
            if method == "notifications/initialized" { isInitialized = true }
            return nil

        case "ping":
            return isNotification ? nil : resultResponse(id: id, result: .emptyObject)

        case "tools/list":
            return isNotification
                ? nil
                : resultResponse(id: id, result: .object(["tools": .array(tools.map(\.json))]))

        case "tools/call":
            guard !isNotification else { return nil }
            return await handleToolCall(id: id, params: params)

        case "prompts/list":
            return isNotification ? nil : resultResponse(id: id, result: .object(["prompts": .emptyArray]))

        case "resources/list":
            return isNotification ? nil : resultResponse(id: id, result: .object(["resources": .emptyArray]))

        default:
            return isNotification
                ? nil
                : errorResponse(
                    id: id,
                    code: JSONRPC.methodNotFound,
                    message: "不支持的方法：\(method)",
                    data: .object(["supported": .array([
                        .string("initialize"),
                        .string("tools/list"),
                        .string("tools/call"),
                        .string("ping")
                    ])])
                )
        }
    }

    // MARK: - 各方法

    private func handleInitialize(id: JSONValue?, params: JSONValue?, isNotification: Bool) -> JSONValue? {
        isInitialized = true

        // 版本协商：客户端给的版本认识就照抄，否则回自己的最新版（规范要求）
        if let requested = params?["protocolVersion"]?.stringValue,
           JSONRPC.supportedProtocolVersions.contains(requested) {
            negotiatedProtocolVersion = requested
        } else {
            negotiatedProtocolVersion = JSONRPC.defaultProtocolVersion
        }

        let result = JSONValue.object([
            "protocolVersion": .string(negotiatedProtocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)])
            ]),
            "serverInfo": .object([
                "name": .string(serverName),
                "title": .string("AI 议事会"),
                "version": .string(serverVersion)
            ]),
            "instructions": .string(instructions)
        ])

        return isNotification ? nil : resultResponse(id: id, result: result)
    }

    private func handleToolCall(id: JSONValue?, params: JSONValue?) async -> JSONValue? {
        guard let name = params?["name"]?.stringValue, !name.isEmpty else {
            return errorResponse(
                id: id,
                code: JSONRPC.invalidParams,
                message: "tools/call 缺少 name 参数"
            )
        }

        guard tools.contains(where: { $0.name == name }) else {
            return errorResponse(
                id: id,
                code: JSONRPC.invalidParams,
                message: "未知工具：\(name)",
                data: .object(["available": .array(tools.map { .string($0.name) })])
            )
        }

        let arguments = params?["arguments"] ?? .emptyObject
        let result = await executor.call(tool: name, arguments: arguments)
        return resultResponse(id: id, result: result.json)
    }

    // MARK: - 封套

    private func resultResponse(id: JSONValue?, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string(JSONRPC.version),
            "id": id ?? .null,
            "result": result
        ])
    }

    private func errorResponse(
        id: JSONValue?,
        code: Int,
        message: String,
        data: JSONValue? = nil
    ) -> JSONValue {
        var error: [String: JSONValue] = [
            "code": .int(code),
            "message": .string(message)
        ]
        if let data { error["data"] = data }
        return .object([
            "jsonrpc": .string(JSONRPC.version),
            "id": id ?? .null,
            "error": .object(error)
        ])
    }
}

import Foundation
import Darwin
import AIDiscussionBridge
import AIDiscussionMCPKit

/// MCP stdio 服务端。
///
/// ## 两条不能破的纪律
///
/// 1. **stdout 只能是协议消息**。任何调试输出都必须走 stderr —— 一行混进去，
///    整条流对客户端就废了。所以这里连日志都做了前缀，方便在客户端日志里认出来。
/// 2. **一条消息一个 Task**。`discussion_run` 可能阻塞几十分钟；如果顺序处理，
///    客户端随后发来的 `notifications/cancelled` 就永远读不到。并发处理 + 各带 `id`
///    是 JSON-RPC 允许的，也是这里唯一可行的做法。
final class AIDiscussionMCPServer {

    private let session: MCPSession
    private let writer = LineWriter()

    init() {
        self.session = MCPSession(
            tools: ToolCatalog.tools,
            executor: BridgeToolExecutor(),
            serverName: ToolCatalog.serverName,
            serverVersion: ToolCatalog.serverVersion,
            instructions: ToolCatalog.instructions
        )
    }

    func run() {
        // stdout 被客户端关掉时，不要因为写失败就让进程吃 SIGPIPE 死掉
        signal(SIGPIPE, SIG_IGN)

        log("启动 pid=\(ProcessInfo.processInfo.processIdentifier)")
        log("桥接 socket=\(BridgePaths.socketURL().path)")

        var buffer = LineBuffer()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        let inFlight = DispatchGroup()

        while true {
            let count = scratch.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(STDIN_FILENO, raw.baseAddress, raw.count)
            }

            if count > 0 {
                for line in buffer.append(Data(scratch[0..<count])) {
                    dispatch(line: line, inFlight: inFlight)
                }
                continue
            }

            if count == 0 { break }                    // 客户端关闭了 stdin
            if errno == EINTR { continue }
            log("读取 stdin 失败，errno=\(errno)")
            break
        }

        // 客户端已断开；给在途响应一点时间，但绝不无限等待。
        // 讨论本身跑在 app 里，本进程退出不会中断它。
        _ = inFlight.wait(timeout: .now() + 2)
        log("stdin 已关闭，退出")
        exit(0)
    }

    // MARK: - 消息分发

    private func dispatch(line: Data, inFlight: DispatchGroup) {
        inFlight.enter()
        // 刻意不捕获 self：Task 的闭包是 @Sendable，而这个类不是 Sendable。
        // 需要的两个依赖都是值语义/Sendable，直接传进去。
        let session = self.session
        let writer = self.writer
        Task {
            defer { inFlight.leave() }

            let message: JSONValue
            do {
                message = try BridgeJSON.decode(JSONValue.self, from: line)
            } catch {
                writer.write(Self.parseErrorResponse(detail: String(describing: error)))
                return
            }

            // MCP 2025-06-18 已移除批处理；收到数组要明确拒绝而不是静默忽略
            if case .array = message {
                writer.write(
                    Self.errorResponse(
                        id: .null,
                        code: JSONRPC.invalidRequest,
                        message: "不支持 JSON-RPC 批处理，请逐条发送消息。"
                    )
                )
                return
            }

            if let response = await session.handle(message) {
                writer.write(response)
            }
        }
    }

    // MARK: - 工具

    private static func parseErrorResponse(detail: String) -> JSONValue {
        errorResponse(
            id: .null,
            code: JSONRPC.parseError,
            message: "无法解析 JSON-RPC 消息：\(detail)"
        )
    }

    private static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string(JSONRPC.version),
            "id": id,
            "error": .object([
                "code": .int(code),
                "message": .string(message)
            ])
        ])
    }

    private func log(_ text: String) {
        Self.log(text)
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("[aidiscussion-mcp] \(text)\n".utf8))
    }
}

/// 串行化 stdout 写入：并发 Task 各写一行，必须保证不会交错。
private final class LineWriter: @unchecked Sendable {

    private let lock = NSLock()

    func write(_ message: JSONValue) {
        guard var data = try? BridgeJSON.encode(message) else { return }
        data.append(BridgeJSON.newline)

        lock.lock()
        defer { lock.unlock() }

        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(STDOUT_FILENO, base.advanced(by: offset), data.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0, errno == EINTR { continue }
            return
        }
    }
}

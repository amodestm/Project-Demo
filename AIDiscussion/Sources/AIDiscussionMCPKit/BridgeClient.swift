import Foundation
import Darwin
import AIDiscussionBridge

/// 桥接客户端：连 app 的 Unix socket，发一条请求，收一条响应。
///
/// ## 为什么每次请求都新建连接
///
/// 长连接会引入"连接还活着但 app 已经被重启"这类幽灵状态，而 MCP 的调用间隔
/// 可能长达几小时。一次一连接 + 每次重读 token 的代价是几十微秒，
/// 换来的是**永远不会有陈旧连接**。
struct BridgeClient {

    enum ClientError: LocalizedError {
        case appNotRunning(String)
        case notConnected(String)
        case timedOut(Int)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case let .appNotRunning(detail):
                return "AIDiscussion 未在运行，且无法自动启动：\(detail)"
            case let .notConnected(detail):
                return "无法连接 AIDiscussion 桥接：\(detail)"
            case let .timedOut(seconds):
                return "等待 AIDiscussion 响应超过 \(seconds) 秒。"
            case let .malformedResponse(detail):
                return "AIDiscussion 返回了无法解析的响应：\(detail)"
            }
        }
    }

    let socketPath: String
    let token: String

    /// 读取当前 token 并组装客户端。app 未运行时会尝试拉起并等待。
    static func make(
        autoLaunch: Bool = true,
        launchWaitSeconds: Int = 25
    ) throws -> BridgeClient {
        if let client = try? current() {
            return client
        }

        guard autoLaunch else {
            throw ClientError.appNotRunning("未找到 \(BridgePaths.socketURL().path)")
        }

        let launchDetail = AppLauncher.launch()
        let deadline = Date().addingTimeInterval(TimeInterval(launchWaitSeconds))
        while Date() < deadline {
            if let client = try? current() { return client }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw ClientError.appNotRunning(
            "已尝试启动（\(launchDetail)），但 \(launchWaitSeconds) 秒内没有等到桥接就绪。"
            + "请手动打开 AIDiscussion 后重试。"
        )
    }

    /// 只在 app 确实已在服务时才返回客户端（不做拉起）。
    static func current() throws -> BridgeClient {
        let socketPath = BridgePaths.socketURL().path
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ClientError.appNotRunning("socket 不存在")
        }
        guard let token = BridgePaths.readToken() else {
            throw ClientError.appNotRunning("读不到 bridge.token")
        }
        return BridgeClient(socketPath: socketPath, token: token)
    }

    /// 发一条请求并等待响应。
    /// - Parameter timeoutSeconds: 服务端最多处理多久；socket 接收超时会自动放宽 60 秒。
    func call(
        op: BridgeOp,
        payload: JSONValue? = nil,
        timeoutSeconds: Int
    ) throws -> BridgeResponse {
        let request = BridgeRequest(token: token, op: op, payload: payload)
        let line = try BridgeJSON.encode(request)
        return try roundTrip(line: line, timeoutSeconds: timeoutSeconds)
    }

    // MARK: - socket 往返

    private func roundTrip(line: Data, timeoutSeconds: Int) throws -> BridgeResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.notConnected("socket() 失败，errno=\(errno)")
        }
        defer { close(fd) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        // 服务端可能要为一场讨论阻塞几十分钟，接收超时必须比它更宽
        var timeout = timeval(tv_sec: timeoutSeconds + 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard var address = UnixSocketAddress.make(path: socketPath) else {
            throw ClientError.notConnected("socket 路径过长")
        }
        let connected = UnixSocketAddress.withSockaddr(&address) { connect(fd, $0, $1) }
        guard connected == 0 else {
            let detail = String(cString: strerror(errno))
            throw ClientError.notConnected("connect() 失败：\(detail)")
        }

        try writeLine(fd: fd, line: line)
        let raw = try readLine(fd: fd, timeoutSeconds: timeoutSeconds)

        do {
            return try BridgeJSON.decode(BridgeResponse.self, from: raw)
        } catch {
            throw ClientError.malformedResponse(String(decoding: raw, as: UTF8.self))
        }
    }

    private func writeLine(fd: Int32, line: Data) throws {
        var payload = line
        payload.append(BridgeJSON.newline)

        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), payload.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0, errno == EINTR { continue }
            throw ClientError.notConnected("写入请求失败，errno=\(errno)")
        }
    }

    private func readLine(fd: Int32, timeoutSeconds: Int) throws -> Data {
        var buffer = LineBuffer()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let read = scratch.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }

            if read > 0 {
                let chunk = Data(scratch[0..<read])
                if let first = buffer.append(chunk).first { return first }
                continue
            }

            if read == 0 {
                // 对端先关：把残留当成最后一条
                if let trailing = buffer.flush() { return trailing }
                throw ClientError.notConnected("AIDiscussion 提前关闭了连接（可能已退出）")
            }

            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw ClientError.timedOut(timeoutSeconds)
            }
            throw ClientError.notConnected("读取响应失败，errno=\(errno)")
        }
    }
}

/// 负责在 app 没跑的时候把它拉起来。
///
/// 刻意**不继承 stdout**：MCP 的 stdout 只能写协议消息，
/// 一旦子进程的日志漏进 stdout，整条流就废了。
enum AppLauncher {

    static let bundleIdentifier = "com.aidiscussion.app"
    static let displayName = "AIDiscussion"

    @discardableResult
    static func launch() -> String {
        if openWithLaunchServices() { return "open -b \(bundleIdentifier)" }

        for candidate in candidateAppPaths() where FileManager.default.fileExists(atPath: candidate) {
            if openPath(candidate) { return "open \(candidate)" }
        }
        return "未找到可启动的 app（试过 bundle id \(bundleIdentifier) 与 \(candidateAppPaths().joined(separator: "、"))）"
    }

    /// 优先用 bundle id —— 不依赖 app 装在哪里，也不依赖 MCP 的工作目录。
    private static func openWithLaunchServices() -> Bool {
        run("/usr/bin/open", ["-g", "-b", bundleIdentifier, "--args", "--background"])
    }

    private static func openPath(_ path: String) -> Bool {
        run("/usr/bin/open", ["-g", path, "--args", "--background"])
    }

    /// 兜底位置：装到 /Applications，或从仓库里直接跑打包产物。
    private static func candidateAppPaths() -> [String] {
        var paths = ["/Applications/\(displayName).app"]

        // 可执行文件通常在 .build/<config>/ 下；仓库根目录是它的上两级
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let repoRoot = executable
            .deletingLastPathComponent()   // <config>
            .deletingLastPathComponent()   // .build
            .deletingLastPathComponent()   // 仓库根
        paths.append(repoRoot.appendingPathComponent("dist/\(displayName).app").path)
        return paths
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // ★ 绝不能让子进程的 stdout 混进 MCP 协议流 ★
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

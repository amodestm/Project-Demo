import Foundation
import Darwin
import AIDiscussionBridge

/// 本地 Unix domain socket 桥接服务端。
///
/// ## 为什么是 Unix socket 而不是 TCP
///
/// - **不占端口、不暴露网络**：只在本机文件系统里可见，天然不经过任何网卡。
/// - **权限就是访问控制**：socket 与 token 都设成 `0600`，只有当前用户能连/能读。
///   再叠一层随机 token，防止同机其它程序"顺手"驱动你的讨论。
/// - **不依赖 app 的沙箱/网络权限**：MCP 作为子进程直接连文件即可。
///
/// ## 线程模型
///
/// accept 在一个串行队列上；每条连接起一个**独立 `Thread`** 做阻塞 I/O。
/// 刻意不用 GCD 并发队列 —— 一场讨论可能阻塞连接线程几十分钟，
/// 把 GCD 的线程池占住会影响 app 其它后台工作。连接数最多是个位数，线程足够廉价。
public final class DiscussionBridgeServer: @unchecked Sendable {

    public enum StartError: LocalizedError {
        case alreadyRunning
        case anotherInstanceRunning
        case bindFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "桥接服务已在运行。"
            case .anotherInstanceRunning:
                return "已有另一个 AIDiscussion 实例占用了桥接 socket。"
            case let .bindFailed(detail):
                return "无法建立桥接 socket：\(detail)"
            }
        }
    }

    /// 连接空闲多久后自动断开（秒）。MCP 侧是"每次请求新建连接"，所以这个值
    /// 只用来回收异常挂住的连接。
    static let idleReadTimeoutSeconds = 300

    private let hub: DiscussionBridgeHub
    private let supportDirectory: URL
    private let socketPath: String
    private let token: String
    private let appVersion: String

    private let acceptQueue = DispatchQueue(label: "com.aidiscussion.bridge.accept")
    private var listenFD: Int32 = -1
    private var isRunning = false
    private var activeThreads = 0

    public init(
        hub: DiscussionBridgeHub,
        appVersion: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.hub = hub
        self.supportDirectory = BridgePaths.supportDirectory(fileManager: fileManager)
        self.socketPath = BridgePaths.socketURL(fileManager: fileManager).path
        self.token = BridgePaths.makeToken()
        // 与 hub 用同一套取值逻辑，避免 bridge.json 里写 "dev" 而桥接返回真实版本
        self.appVersion = appVersion ?? DiscussionBridgeHub.appVersionString()
    }

    public var isServing: Bool { isRunning }

    // MARK: - 生命周期

    public func start() throws {
        guard !isRunning else { throw StartError.alreadyRunning }

        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true
        )

        try reclaimStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw StartError.bindFailed("socket() 失败，errno=\(errno)")
        }

        guard var address = UnixSocketAddress.make(path: socketPath) else {
            close(fd)
            throw StartError.bindFailed("socket 路径过长：\(socketPath)")
        }

        let bound = UnixSocketAddress.withSockaddr(&address) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw StartError.bindFailed("bind() 失败：\(detail)")
        }

        // 只有本用户可访问
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw StartError.bindFailed("listen() 失败：\(detail)")
        }

        try writeCredentials()

        listenFD = fd
        isRunning = true

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }

        log("桥接已就绪：\(socketPath)")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        if listenFD >= 0 {
            // 关闭监听会让阻塞中的 accept 立即返回错误，accept 循环随之退出
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }

        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: BridgePaths.tokenURL().path)
        try? FileManager.default.removeItem(atPath: BridgePaths.metaURL().path)

        log("桥接已停止")
    }

    // MARK: - 凭据与元信息

    private func writeCredentials() throws {
        let tokenURL = BridgePaths.tokenURL()
        try Data(token.utf8).write(to: tokenURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenURL.path
        )

        let meta = BridgePaths.Meta(
            protocolVersion: BridgeProtocol.version,
            pid: ProcessInfo.processInfo.processIdentifier,
            appVersion: appVersion,
            socketPath: socketPath
        )
        let metaURL = BridgePaths.metaURL()
        try BridgeJSON.encode(meta, pretty: true).write(to: metaURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: metaURL.path
        )
    }

    /// 上一次异常退出可能留下死 socket。用它自己的连通性判断真假：
    /// 连得上说明有活着的实例在服务，必须让位；连不上就是残骸，直接删掉。
    private func reclaimStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            defer { close(probe) }
            if var address = UnixSocketAddress.make(path: socketPath) {
                let connected = UnixSocketAddress.withSockaddr(&address) { connect(probe, $0, $1) }
                if connected == 0 {
                    throw StartError.anotherInstanceRunning
                }
            }
        }

        log("清理遗留 socket：\(socketPath)")
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Accept

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if isRunning {
                    // EINTR 之类的瞬时错误：让出一下再继续，别空转烧 CPU
                    usleep(50_000)
                    continue
                }
                return
            }
            setUpClientSocket(clientFD)

            activeThreads += 1
            let thread = Thread { [weak self] in
                guard let self else { close(clientFD); return }
                self.serve(clientFD: clientFD)
                close(clientFD)
                self.activeThreads -= 1
            }
            thread.name = "com.aidiscussion.bridge.connection"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private func setUpClientSocket(_ fd: Int32) {
        var one: Int32 = 1
        // 对端先关掉时，write 返回 EPIPE 而不是给进程发 SIGPIPE（那会直接干掉 app）
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: Self.idleReadTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - 单连接服务

    private func serve(clientFD: Int32) {
        var buffer = LineBuffer()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)

        while isRunning {
            let read = scratch.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(clientFD, raw.baseAddress, raw.count)
            }

            if read > 0 {
                let chunk = Data(scratch[0..<read])
                for message in buffer.append(chunk) {
                    let response = respond(to: message)
                    guard write(response, to: clientFD) else { return }
                }
                continue
            }

            if read == 0 { return }                    // 对端关闭

            if errno == EINTR { continue }             // 被信号打断
            if errno == EAGAIN || errno == EWOULDBLOCK { return }  // 空闲超时，回收
            return
        }
    }

    /// 同步等待 hub（@MainActor）的处理结果。
    ///
    /// 这里故意用信号量而不是把整个 serve 改成 async：连接线程本来就是独占的阻塞
    /// 线程，转换收益为零，而混合阻塞 read 与 await 反而更容易写错。
    private func respond(to message: Data) -> Data {
        let request: BridgeRequest
        do {
            request = try BridgeJSON.decode(BridgeRequest.self, from: message)
        } catch {
            return failure(
                BridgeError(
                    code: .invalidRequest,
                    message: "无法解析桥接请求：\(error)",
                    hint: "请求必须是单行 JSON，形如 {\"token\":\"…\",\"op\":\"ping\"}。"
                )
            )
        }

        guard constantTimeEquals(request.token, token) else {
            return failure(
                BridgeError(
                    code: .unauthenticated,
                    message: "桥接 token 不匹配。",
                    hint: "从 \(BridgePaths.tokenURL().path) 读取当前 token。"
                )
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var encoded: Data = failure(
            BridgeError(code: .internalError, message: "桥接未返回结果。")
        )

        Task { @MainActor [hub] in
            let response = await hub.handle(op: request.op, payload: request.payload)
            encoded = (try? BridgeJSON.encode(response)) ?? Data()
            semaphore.signal()
        }

        semaphore.wait()
        return encoded.isEmpty
            ? failure(BridgeError(code: .internalError, message: "结果编码失败。"))
            : encoded
    }

    private func failure(_ error: BridgeError) -> Data {
        (try? BridgeJSON.encode(BridgeResponse.failure(error))) ?? Data()
    }

    /// 写一行响应，自动补换行。返回 false 表示连接已断，调用方应结束该连接。
    private func write(_ payload: Data, to fd: Int32) -> Bool {
        var line = payload
        line.append(BridgeJSON.newline)

        var offset = 0
        while offset < line.count {
            let written = line.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), line.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    // MARK: - 工具

    /// 定长比较，避免按字符短路泄漏 token 前缀。
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[bridge] \(message)\n".utf8))
    }
}

import Foundation
import SQLite3
import AIDiscussionBridge

// MARK: - SQL 值

/// 可绑定到 SQL 语句的值。
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// 一行查询结果。列名 -> 值。
public struct SQLRow: Sendable {

    public let columns: [String: SQLValue]

    public init(columns: [String: SQLValue]) {
        self.columns = columns
    }

    public subscript(name: String) -> SQLValue? { columns[name] }

    public func string(_ name: String) -> String? {
        guard let v = columns[name] else { return nil }
        switch v {
        case .text(let s):   return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .blob(let b):   return String(data: b, encoding: .utf8)
        case .null:          return nil
        }
    }

    public func int(_ name: String) -> Int? {
        guard let v = columns[name] else { return nil }
        switch v {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        case .text(let s):   return Int(s)
        default:             return nil
        }
    }

    public func double(_ name: String) -> Double? {
        guard let v = columns[name] else { return nil }
        switch v {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        case .text(let s):   return Double(s)
        default:             return nil
        }
    }

    public func bool(_ name: String) -> Bool? {
        guard let v = columns[name] else { return nil }
        switch v {
        case .int(let i):    return i != 0
        case .double(let d): return d != 0
        case .text(let s):   return ["1", "true", "yes"].contains(s.lowercased())
        default:             return nil
        }
    }

    public func date(_ name: String) -> Date? {
        guard let s = string(name) else { return nil }
        return DateCoding.date(from: s)
    }

    public func json(_ name: String) -> JSONValue? {
        guard let s = string(name), !s.isEmpty else { return nil }
        return try? JSONCoding.decode(JSONValue.self, from: s)
    }

    // MARK: 必填读取 (列缺失/类型不符时抛出可诊断的错误)

    public func requireString(_ name: String) throws -> String {
        guard let v = string(name) else {
            throw AppError.database("列 '\(name)' 缺失或不是文本 (行: \(columns.keys.sorted()))")
        }
        return v
    }

    public func requireInt(_ name: String) throws -> Int {
        guard let v = int(name) else {
            throw AppError.database("列 '\(name)' 缺失或不是整数")
        }
        return v
    }
}

// MARK: - Database

/// SQLite 封装。
///
/// 设计取舍
/// --------
/// * **不用 actor**: SQLite 是同步 C API, actor 的 hop 只会引入额外开销,
///   且 actor 重入会让"事务内不能 await"这条约束变得难以强制执行。
///   这里用 `NSRecursiveLock` (递归锁, 支持嵌套事务) 保证线程安全, 并显式标注
///   `@unchecked Sendable`。
/// * **所有事务走 `BEGIN IMMEDIATE`**: 一次性拿到写锁, 避免锁升级死锁;
///   配合 `busy_timeout` 让 Web/UI 线程与 Runner 线程安全并行。
/// * **业务不写 SQL 到这个文件之外**: Repository 层只调用 execute/query/transaction。
public final class Database: @unchecked Sendable {

    // SQLite 要求 TRANSIENT: 让 SQLite 自己拷贝字符串, 不依赖 Swift 侧生命周期。
    nonisolated(unsafe) private static let TRANSIENT =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let path: String

    public private(set) var isClosed = false

    // MARK: 打开 / 关闭

    /// 打开 (或创建) 数据库。
    /// - Parameter inMemory: 传 true 使用临时内存库 (测试用)。
    public init(path: String, inMemory: Bool = false) throws {
        self.path = inMemory ? ":memory:" : path

        if !inMemory {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true
                )
            }
        }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(self.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 失败 (\(rc))"
            if let db { sqlite3_close_v2(db) }
            throw AppError.database("无法打开数据库 \(self.path): \(msg)")
        }
        self.handle = db

        do {
            try configure()
        } catch {
            sqlite3_close_v2(db)
            self.handle = nil
            throw error
        }
    }

    public static func inMemory() throws -> Database {
        try Database(path: ":memory:", inMemory: true)
    }

    /// 默认数据库位置: `~/Library/Application Support/AIDiscussion/aidiscussion.sqlite`
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("AIDiscussion", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("aidiscussion.sqlite")
    }

    public static func openDefault() throws -> Database {
        try Database(path: try defaultURL().path)
    }

    public var databasePath: String { path }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !isClosed else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
        isClosed = true
    }

    deinit {
        if let handle, !isClosed {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: 配置

    private func configure() throws {
        // 外键约束必须显式开启, 否则 ON DELETE CASCADE 不会生效。
        try execRaw("PRAGMA foreign_keys = ON;")
        try execRaw("PRAGMA busy_timeout = 15000;")

        if path != ":memory:" {
            // WAL: 让读 (UI 刷新) 与写 (Runner) 并行。仅对本地文件库有意义。
            try execRaw("PRAGMA journal_mode = WAL;")
            try execRaw("PRAGMA synchronous = NORMAL;")
        } else {
            try execRaw("PRAGMA synchronous = OFF;")
        }
    }

    private func execRaw(_ sql: String) throws {
        guard let handle else { throw AppError.database("数据库已关闭") }
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errmsg)
            throw AppError.database("执行失败 [\(sql.prefix(80))]: \(msg)")
        }
    }

    // MARK: 基础执行

    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try run(sql, params: params, collectRows: false)
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        lock.lock()
        defer { lock.unlock() }
        return try run(sql, params: params, collectRows: true)
    }

    public func queryOne(_ sql: String, _ params: [SQLValue] = []) throws -> SQLRow? {
        try query(sql, params).first
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int? {
        guard let row = try queryOne(sql, params) else { return nil }
        guard let first = row.columns.values.first else { return nil }
        switch first {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        case .text(let s):   return Int(s)
        default:             return nil
        }
    }

    public func lastInsertRowID() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    // MARK: 核心执行 + 绑定

    private func run(_ sql: String, params: [SQLValue], collectRows: Bool) throws -> [SQLRow] {
        guard let handle, !isClosed else { throw AppError.database("数据库已关闭") }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw AppError.database("SQL 准备失败 [\(sql.prefix(120))]: \(lastError())")
        }
        defer { sqlite3_finalize(stmt) }

        try bind(stmt, params)

        var rows: [SQLRow] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                if collectRows {
                    rows.append(readRow(stmt))
                }
                continue
            }
            if stepRC == SQLITE_DONE { break }
            throw AppError.database(
                "SQL 执行失败 (rc=\(stepRC)) [\(sql.prefix(120))]: \(lastError())"
            )
        }
        return rows
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLValue]) throws {
        for (offset, value) in params.enumerated() {
            let idx = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case .int(let i):
                rc = sqlite3_bind_int64(stmt, idx, Int64(i))
            case .double(let d):
                rc = sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, idx, s, -1, Database.TRANSIENT)
            case .blob(let data):
                rc = data.withUnsafeBytes { buf in
                    sqlite3_bind_blob(
                        stmt, idx, buf.baseAddress, Int32(buf.count), Database.TRANSIENT
                    )
                }
            }
            if rc != SQLITE_OK {
                throw AppError.database("参数绑定失败 (index=\(idx)): \(lastError())")
            }
        }
    }

    private func readRow(_ stmt: OpaquePointer) -> SQLRow {
        var cols: [String: SQLValue] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            guard let namePtr = sqlite3_column_name(stmt, i) else { continue }
            let name = String(cString: namePtr)
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL:
                cols[name] = .null
            case SQLITE_INTEGER:
                cols[name] = .int(Int(sqlite3_column_int64(stmt, i)))
            case SQLITE_FLOAT:
                cols[name] = .double(sqlite3_column_double(stmt, i))
            case SQLITE_BLOB:
                if let ptr = sqlite3_column_blob(stmt, i) {
                    let len = Int(sqlite3_column_bytes(stmt, i))
                    cols[name] = .blob(Data(bytes: ptr, count: len))
                } else {
                    cols[name] = .null
                }
            default: // SQLITE_TEXT
                if let cstr = sqlite3_column_text(stmt, i) {
                    cols[name] = .text(String(cString: cstr))
                } else {
                    cols[name] = .null
                }
            }
        }
        return SQLRow(columns: cols)
    }

    private func lastError() -> String {
        guard let handle else { return "数据库已关闭" }
        return String(cString: sqlite3_errmsg(handle))
    }

    // MARK: 事务

    /// 写事务。`BEGIN IMMEDIATE` 立即获取写锁。
    ///
    /// 闭包为**同步**的 —— 这是刻意的: 事务内部一旦 `await`, 就可能让出执行权,
    /// 别的任务插入自己的写操作, 破坏原子性。SQLite 也是同步 API,
    /// 业务代码没必要在事务里做异步 I/O。
    ///
    /// 支持嵌套: 内层使用 `SAVEPOINT`, 因此 Repository 可以互相组合。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let nesting = transactionDepth
        let savepointName = "sp_\(nesting)"
        transactionDepth += 1
        defer { transactionDepth -= 1 }

        if nesting == 0 {
            try execRaw("BEGIN IMMEDIATE;")
        } else {
            try execRaw("SAVEPOINT \(savepointName);")
        }

        do {
            let result = try body()
            if nesting == 0 {
                try execRaw("COMMIT;")
            } else {
                try execRaw("RELEASE \(savepointName);")
            }
            return result
        } catch {
            if nesting == 0 {
                try? execRaw("ROLLBACK;")
            } else {
                try? execRaw("ROLLBACK TO \(savepointName);")
                try? execRaw("RELEASE \(savepointName);")
            }
            throw error
        }
    }

    private var transactionDepth = 0

    /// 只读操作。不加显式事务 (SQLite 会自动开启读事务)。
    public func read<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: 诊断

    public struct Diagnostics: Sendable {
        public var journalMode: String
        public var foreignKeys: Bool
        public var pageCount: Int
        public var integrityOK: Bool
        public var userVersion: Int
    }

    public func diagnostics() throws -> Diagnostics {
        let journal = try queryOne("PRAGMA journal_mode;")?.columns.values.first
        let fk = try scalarInt("PRAGMA foreign_keys;") ?? 0
        let pages = try scalarInt("PRAGMA page_count;") ?? 0
        let version = try scalarInt("PRAGMA user_version;") ?? 0
        let integrity = try queryOne("PRAGMA quick_check;")
        let okText = integrity?.columns.values.first?.stringValueOrEmpty ?? ""
        return Diagnostics(
            journalMode: journal?.stringValueOrEmpty ?? "?",
            foreignKeys: fk != 0,
            pageCount: pages,
            integrityOK: okText.lowercased() == "ok",
            userVersion: version
        )
    }
}

private extension SQLValue {
    var stringValueOrEmpty: String {
        switch self {
        case .text(let s):   return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        default:             return ""
        }
    }
}

import XCTest
@testable import AIRunnerCore

/// Resume 租约测试 —— 跨进程防重复发送的基础设施。
///
/// 这些用例刻意用**两个独立的 `Database` 对象指向同一个文件**,
/// 而不是共用同一个连接 —— 只有这样才真正验证了"两个 AIRunner 实例
/// 抢同一个 binding"的场景。
final class CodexResumeLeaseTests: XCTestCase {

    private var directory: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbPath = directory.appendingPathComponent("airunner.sqlite").path
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// 打开一个"独立进程"的连接。
    private func openDatabase() throws -> Database {
        let db = try Database(path: dbPath)
        try DatabaseMigrator.migrate(db)
        return db
    }

    // MARK: - 基本认领

    func testClaimSucceedsWhenNoExistingLease() throws {
        let db = try openDatabase()
        defer { db.close() }
        let leases = CodexResumeLeaseRepository(db: db)

        let result = try leases.claim(bindingID: "b1", ownerID: "owner-A", ttl: 120)

        guard case .acquired(let lease) = result else {
            return XCTFail("应当成功认领, 实际: \(result)")
        }
        XCTAssertEqual(lease.bindingID, "b1")
        XCTAssertEqual(lease.ownerID, "owner-A")
        XCTAssertFalse(lease.isExpired())
    }

    func testSecondOwnerIsBlockedWhileLeaseIsActive() throws {
        let db = try openDatabase()
        defer { db.close() }
        let leases = CodexResumeLeaseRepository(db: db)

        _ = try leases.claim(bindingID: "b1", ownerID: "owner-A", ttl: 120)
        let second = try leases.claim(bindingID: "b1", ownerID: "owner-B", ttl: 120)

        guard case .busy(let existing) = second else {
            return XCTFail("第二个 owner 应当被挡住, 实际: \(second)")
        }
        XCTAssertEqual(existing.ownerID, "owner-A")
    }

    func testSameOwnerCanRenewLease() throws {
        let db = try openDatabase()
        defer { db.close() }
        let leases = CodexResumeLeaseRepository(db: db)

        let first = try leases.claim(bindingID: "b1", ownerID: "owner-A", ttl: 10)
        let renewed = try leases.claim(bindingID: "b1", ownerID: "owner-A", ttl: 600)

        guard case .acquired = first else {
            return XCTFail("第一次认领应当成功")
        }
        guard case .acquired(let lease) = renewed else {
            return XCTFail("同一个 owner 应当可以续租")
        }
        XCTAssertGreaterThan(lease.remaining(), 500, "续租后有效期应当被延长")
    }

    // MARK: - ★ 过期租约绝不静默覆盖 ★

    func testExpiredLeaseRequiresExplicitRecovery() throws {
        let db = try openDatabase()
        defer { db.close() }
        let leases = CodexResumeLeaseRepository(db: db)

        let base = Date()
        _ = try leases.claim(bindingID: "b1", ownerID: "owner-A", ttl: 10, now: base)

        // 时间推进到租约过期之后 (另一个 owner 来抢)
        let later = base.addingTimeInterval(60)
        let attempt = try leases.claim(bindingID: "b1", ownerID: "owner-B", ttl: 120, now: later)

        guard case .staleRequiresExplicitRecovery(let existing) = attempt else {
            return XCTFail("过期租约必须要求用户显式恢复, 而不是静默覆盖。实际: \(attempt)")
        }
        XCTAssertEqual(existing.ownerID, "owner-A", "原租约必须原样保留, 等用户确认")
    }

    func testForceReleaseClearsStaleLease() throws {
        let db = try openDatabase()
        defer { db.close() }
        let leases = CodexResumeLeaseRepository(db: db)

        let base = Date()
        _ = try leases.claim(bindingID: "b1", ownerID: "owner-A", ttl: 10, now: base)

        let later = base.addingTimeInterval(60)
        let released = try leases.forceRelease(bindingID: "b1")
        XCTAssertTrue(released)

        let retry = try leases.claim(bindingID: "b1", ownerID: "owner-B", ttl: 120, now: later)
        guard case .acquired = retry else {
            return XCTFail("强制释放后应当可以重新认领, 实际: \(retry)")
        }
    }

    // MARK: - 释放

    func testOnlyOwnerCanRelease() throws {
        let db = try openDatabase()
        defer { db.close() }
        let leases = CodexResumeLeaseRepository(db: db)

        _ = try leases.claim(bindingID: "b1", ownerID: "owner-A", ttl: 120)

        let foreignRelease = try leases.release(bindingID: "b1", ownerID: "owner-B")
        XCTAssertFalse(foreignRelease, "非持有者不能释放")

        let ownRelease = try leases.release(bindingID: "b1", ownerID: "owner-A")
        XCTAssertTrue(ownRelease)

        let afterRelease = try leases.current(bindingID: "b1")
        XCTAssertNil(afterRelease)
    }

    // MARK: - ★ 跨"进程" ★

    func testTwoIndependentConnectionsOnlyOneAcquires() throws {
        // 两个 Database 对象 = 两个独立的 SQLite 连接 = 最接近"两个 AIRunner 实例"
        let dbA = try openDatabase()
        let dbB = try openDatabase()
        defer { dbA.close(); dbB.close() }

        let leasesA = CodexResumeLeaseRepository(db: dbA)
        let leasesB = CodexResumeLeaseRepository(db: dbB)

        let a = try leasesA.claim(bindingID: "shared", ownerID: "app-1", ttl: 120)
        let b = try leasesB.claim(bindingID: "shared", ownerID: "app-2", ttl: 120)

        guard case .acquired = a else { return XCTFail("第一个实例应当拿到租约") }
        guard case .busy = b else {
            return XCTFail("第二个实例必须被挡住, 否则会出现两次发送。实际: \(b)")
        }
    }

    func testReleaseFromOneConnectionIsVisibleToTheOther() throws {
        let dbA = try openDatabase()
        let dbB = try openDatabase()
        defer { dbA.close(); dbB.close() }

        let leasesA = CodexResumeLeaseRepository(db: dbA)
        let leasesB = CodexResumeLeaseRepository(db: dbB)

        _ = try leasesA.claim(bindingID: "shared", ownerID: "app-1", ttl: 120)
        let released = try leasesA.release(bindingID: "shared", ownerID: "app-1")
        XCTAssertTrue(released)

        let retry = try leasesB.claim(bindingID: "shared", ownerID: "app-2", ttl: 120)
        guard case .acquired = retry else {
            return XCTFail("释放后另一个实例应当能拿到, 实际: \(retry)")
        }
    }

    // MARK: - 清理

    func testPurgeExpiredRemovesOnlyExpiredLeases() throws {
        let db = try openDatabase()
        defer { db.close() }
        let leases = CodexResumeLeaseRepository(db: db)

        let base = Date()
        _ = try leases.claim(bindingID: "old", ownerID: "A", ttl: 10, now: base)
        _ = try leases.claim(bindingID: "fresh", ownerID: "A", ttl: 600, now: base)

        let purged = try leases.purgeExpired(now: base.addingTimeInterval(60))

        XCTAssertEqual(purged, 1)

        let purgedLease = try leases.current(bindingID: "old")
        XCTAssertNil(purgedLease)

        let keptLease = try leases.current(bindingID: "fresh")
        XCTAssertNotNil(keptLease)

        let remaining = try leases.all()
        XCTAssertEqual(remaining.count, 1)
    }
}

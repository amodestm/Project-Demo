import XCTest
@testable import AIRunnerCore

/// 额度快照与「按额度选号」的纯逻辑测试。
///
/// 真实额度接口与 GUI 切号不在单测范围内；这里只验证排序规则与落库往返，
/// 确保「有余额优先、恢复早优先」这条策略不会被后来的改动悄悄破坏。
final class CodexQuotaRotationTests: XCTestCase {

    private func profile(_ name: String) -> ChromeProfile {
        ChromeProfile(directoryName: name, displayName: "")
    }

    private func standing(
        _ directory: String,
        limitReached: Bool,
        usedPercent: Double? = nil,
        resetAt: Int? = nil
    ) -> CodexQuotaStanding {
        CodexQuotaStanding(
            profileDirectory: directory,
            capturedAt: Date(),
            limitReached: limitReached,
            primaryUsedPercent: usedPercent,
            primaryResetAt: resetAt
        )
    }

    /// 相对当前时间偏移的恢复时间戳 —— 「已耗尽」只有在恢复时间尚未到来时才成立。
    private func resetIn(_ seconds: TimeInterval) -> Int {
        Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)
    }

    // MARK: - 排序

    func testCandidatesWithoutSnapshotsKeepRingOrder() {
        let pool = [profile("Profile 1"), profile("Profile 2"), profile("Profile 3")]
        let result = AccountRotationManager.quotaAwareCandidates(
            startingWith: nil, in: pool, standings: [:]
        )
        XCTAssertEqual(result.map(\.directoryName), ["Profile 1", "Profile 2", "Profile 3"])
    }

    func testCandidatesStartFromGivenProfileWhenNoSnapshots() {
        let pool = [profile("Profile 1"), profile("Profile 2"), profile("Profile 3")]
        let result = AccountRotationManager.quotaAwareCandidates(
            startingWith: profile("Profile 2"), in: pool, standings: [:]
        )
        XCTAssertEqual(result.map(\.directoryName), ["Profile 2", "Profile 3", "Profile 1"])
    }

    func testAccountWithHeadroomBeatsExhaustedAccount() {
        let pool = [profile("Profile 1"), profile("Profile 2"), profile("Profile 3")]
        let standings = [
            "Profile 1": standing(
                "Profile 1", limitReached: true, usedPercent: 100, resetAt: resetIn(3_600)
            ),
            "Profile 2": standing("Profile 2", limitReached: false, usedPercent: 40),
        ]
        let result = AccountRotationManager.quotaAwareCandidates(
            startingWith: nil, in: pool, standings: standings
        )
        // 未耗尽 → 已耗尽 → 无快照
        XCTAssertEqual(result.map(\.directoryName), ["Profile 2", "Profile 1", "Profile 3"])
    }

    func testLessUsedAccountComesFirst() {
        let pool = [profile("Profile 1"), profile("Profile 2")]
        let standings = [
            "Profile 1": standing("Profile 1", limitReached: false, usedPercent: 80),
            "Profile 2": standing("Profile 2", limitReached: false, usedPercent: 15),
        ]
        let result = AccountRotationManager.quotaAwareCandidates(
            startingWith: nil, in: pool, standings: standings
        )
        XCTAssertEqual(result.map(\.directoryName), ["Profile 2", "Profile 1"])
    }

    func testEarlierRecoveryWinsAmongExhaustedAccounts() {
        let pool = [profile("Profile 1"), profile("Profile 2")]
        let standings = [
            "Profile 1": standing(
                "Profile 1", limitReached: true, usedPercent: 100, resetAt: resetIn(7_200)
            ),
            "Profile 2": standing(
                "Profile 2", limitReached: true, usedPercent: 100, resetAt: resetIn(1_800)
            ),
        ]
        let result = AccountRotationManager.quotaAwareCandidates(
            startingWith: nil, in: pool, standings: standings
        )
        XCTAssertEqual(result.map(\.directoryName), ["Profile 2", "Profile 1"])
    }

    func testCoolingDownAccountMovesToTheBack() {
        let pool = [profile("Profile 1"), profile("Profile 2"), profile("Profile 3")]
        let standings = [
            "Profile 1": standing("Profile 1", limitReached: false, usedPercent: 50),
            "Profile 2": standing("Profile 2", limitReached: false, usedPercent: 5),
        ]
        let result = AccountRotationManager.quotaAwareCandidates(
            startingWith: nil,
            in: pool,
            standings: standings,
            activeAccountKeys: ["profile:Profile 2"]
        )
        // 冷却优先于额度好坏：Profile 2 即使额度几乎没动也排最后。
        XCTAssertEqual(result.map(\.directoryName), ["Profile 1", "Profile 3", "Profile 2"])
    }

    func testSameTierKeepsOriginalRingOrder() {
        let pool = [profile("Profile 1"), profile("Profile 2"), profile("Profile 3")]
        let standings = [
            "Profile 1": standing("Profile 1", limitReached: false, usedPercent: 30),
            "Profile 2": standing("Profile 2", limitReached: false, usedPercent: 30),
            "Profile 3": standing("Profile 3", limitReached: false, usedPercent: 30),
        ]
        let result = AccountRotationManager.quotaAwareCandidates(
            startingWith: nil, in: pool, standings: standings
        )
        XCTAssertEqual(result.map(\.directoryName), ["Profile 1", "Profile 2", "Profile 3"])
    }

    // MARK: - isBlocked

    func testStandingBlockedOnlyWhileResetIsInTheFuture() {
        let now = Date()
        let past = standing(
            "Profile 1", limitReached: true, usedPercent: 100,
            resetAt: Int(now.addingTimeInterval(-60).timeIntervalSince1970)
        )
        let future = standing(
            "Profile 1", limitReached: true, usedPercent: 100,
            resetAt: Int(now.addingTimeInterval(600).timeIntervalSince1970)
        )
        let healthy = standing("Profile 1", limitReached: false, usedPercent: 10)

        XCTAssertFalse(past.isBlocked(at: now))
        XCTAssertTrue(future.isBlocked(at: now))
        XCTAssertFalse(healthy.isBlocked(at: now))
    }

    func testStandingWithoutResetTimestampStaysBlocked() {
        let blocked = standing("Profile 1", limitReached: true, usedPercent: 100)
        XCTAssertTrue(blocked.isBlocked(at: Date()))
    }

    // MARK: - 落库往返

    func testSnapshotRepositoryRoundTrip() throws {
        let db = try Database.inMemory()
        try DatabaseMigrator.migrate(db)
        let repo = CodexQuotaSnapshotRepository(db: db)

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        try repo.record(CodexQuotaSnapshot(
            profileDirectory: "Profile 1", capturedAt: older, source: "rotation-after",
            email: "first@example.com", planType: "plus",
            limitReached: false, primaryUsedPercent: 25, primaryResetAt: 1_800,
            secondaryUsedPercent: 84, secondaryResetAt: 604_800
        ))
        try repo.record(CodexQuotaSnapshot(
            profileDirectory: "Profile 1", capturedAt: newer, source: "rotation-after",
            email: "first@example.com", planType: "plus",
            limitReached: true, primaryUsedPercent: 100, primaryResetAt: 9_000
        ))

        let latest = try XCTUnwrap(repo.latest(profileDirectory: "Profile 1"))
        XCTAssertEqual(latest.primaryUsedPercent, 100)
        XCTAssertTrue(latest.limitReached ?? false)
        XCTAssertEqual(latest.primaryResetAt, 9_000)

        let standings = try repo.quotaStanding()
        XCTAssertEqual(standings.count, 1)
        XCTAssertTrue(standings["Profile 1"]?.limitReached ?? false)
        XCTAssertEqual(standings["Profile 1"]?.primaryResetAt, 9_000)

        XCTAssertEqual(try repo.history(profileDirectory: "Profile 1").count, 2)
    }

    func testDuplicateSnapshotOnSameTimestampIsIgnored() throws {
        let db = try Database.inMemory()
        try DatabaseMigrator.migrate(db)
        let repo = CodexQuotaSnapshotRepository(db: db)
        let stamp = Date(timeIntervalSince1970: 5_000)

        for used in [10.0, 90.0] {
            try repo.record(CodexQuotaSnapshot(
                profileDirectory: "Profile 2", capturedAt: stamp, source: "mcp",
                limitReached: false, primaryUsedPercent: used
            ))
        }
        let history = try repo.history(profileDirectory: "Profile 2")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.primaryUsedPercent, 10)
    }

    func testPruneKeepsOnlyTheNewestPerProfile() throws {
        let db = try Database.inMemory()
        try DatabaseMigrator.migrate(db)
        let repo = CodexQuotaSnapshotRepository(db: db)

        for offset in 0..<10 {
            try repo.record(CodexQuotaSnapshot(
                profileDirectory: "Profile 1",
                capturedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + offset)),
                source: "mcp", limitReached: false,
                primaryUsedPercent: Double(offset)
            ))
            try repo.record(CodexQuotaSnapshot(
                profileDirectory: "Profile 2",
                capturedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + offset)),
                source: "mcp", limitReached: false,
                primaryUsedPercent: Double(offset)
            ))
        }

        let removed = try repo.prune(keepingPerProfile: 3)
        XCTAssertEqual(removed, 14)
        XCTAssertEqual(try repo.history(profileDirectory: "Profile 1").count, 3)
        XCTAssertEqual(try repo.history(profileDirectory: "Profile 2").count, 3)
        // 保留的必须是最新的三条。
        XCTAssertEqual(try repo.latest(profileDirectory: "Profile 1")?.primaryUsedPercent, 9)
    }

    // MARK: - 用量响应解析

    func testDecodeUsageResponseFlattensWindowsAndModels() throws {
        let json = """
        {
          "email": "person@example.com",
          "account_id": "acct-1",
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 25,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 613,
              "reset_at": 1789672914
            },
            "secondary_window": {
              "used_percent": 84,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 456418,
              "reset_at": 1790128720
            }
          },
          "model_usage": {
            "gpt-6-astra": {"available": true, "available_at": null},
            "gpt-next": {"available": false, "available_at": 1790200000}
          },
          "credits": {"balance": "0"},
          "rate_limit_reset_credits": {"available_count": 0}
        }
        """.data(using: .utf8)!

        let usage = try CodexQuotaProbe.decode(json)
        XCTAssertEqual(usage.email, "person@example.com")
        XCTAssertEqual(usage.planType, "plus")
        XCTAssertEqual(usage.primaryUsedPercent, 25)
        XCTAssertEqual(usage.primaryRemainingPercent, 75)
        XCTAssertEqual(usage.primaryWindowSeconds, 18_000)
        XCTAssertEqual(usage.primaryResetAt, 1_789_672_914)
        XCTAssertEqual(usage.secondaryUsedPercent, 84)
        XCTAssertEqual(usage.secondaryWindowSeconds, 604_800)
        // 只记录「不可用模型」的恢复时间；可用模型不产生噪音。
        XCTAssertEqual(usage.modelAvailableAt, 1_790_200_000)
        XCTAssertEqual(usage.creditsBalance, "0")
    }

    func testDecodeUsageWithoutUnavailableModelsLeavesModelTimeEmpty() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {"allowed": true, "limit_reached": false},
          "model_usage": {"gpt-6-astra": {"available": true, "available_at": null}}
        }
        """.data(using: .utf8)!

        let usage = try CodexQuotaProbe.decode(json)
        XCTAssertNil(usage.modelAvailableAt)
        XCTAssertNil(usage.primaryUsedPercent)
    }

    func testUsageSnapshotCarriesProfileAndSource() throws {
        let usage = CodexQuotaUsage(
            email: "person@example.com", planType: "plus",
            limitReached: false, primaryUsedPercent: 12, primaryResetAt: 1_800
        )
        let snapshot = usage.snapshot(
            profileDirectory: "Profile 7", source: "rotation-after"
        )
        XCTAssertEqual(snapshot.profileDirectory, "Profile 7")
        XCTAssertEqual(snapshot.source, "rotation-after")
        XCTAssertEqual(snapshot.primaryUsedPercent, 12)
        XCTAssertEqual(snapshot.primaryRemainingPercent, 88)
    }
}

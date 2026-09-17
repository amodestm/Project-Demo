import XCTest
import AIDiscussionBridge
@testable import AIDiscussionCore

/// `BridgeSpecBuilder` 的校验与翻译测试。
///
/// 这一层是 MCP 入口的**唯一防线**：界面「保存」时的那几条约束（议题必填、
/// 至少 2 位成员、每人绑定不同 Profile、账号标识必填）如果在这里不生效，
/// 就会出现"能提交但一跑就炸"的讨论组。
///
/// 所有测试都在**临时 home** 里跑：`ChromeProfileScanner` 读的是
/// `<home>/Library/Application Support/Google/Chrome/Local State`，
/// 不隔离就会变成"在别人机器上必挂"的测试。
/// 整个类钉在 MainActor 上：`DiscussionServices` 与 `BridgeSpecBuilder` 都是
/// `@MainActor`，逐个方法标注只会让噪音盖过意图。`setUp`/`tearDown` 用 async 版本，
/// 因为非 async 的 `setUpWithError` 是 nonisolated，无法在 @MainActor 类里覆盖。
@MainActor
final class BridgeSpecBuilderTests: XCTestCase {

    private var temporaryHome: String!
    private var services: DiscussionServices!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        temporaryHome = NSTemporaryDirectory()
            .appending("aidiscussion-bridge-\(UUID().uuidString)")
        try writeLocalState(profiles: [
            "Default": "默认",
            "Profile 3": "work",
            "Profile 4": "personal",
            "Profile 7": "backup"
        ])
        services = try DiscussionServices(
            db: try Database.inMemory(),
            chromeProfiles: ChromeProfileScanner(homeDirectory: temporaryHome)
        )
    }

    @MainActor
    override func tearDown() async throws {
        if let temporaryHome {
            try? FileManager.default.removeItem(atPath: temporaryHome)
        }
        services = nil
        try await super.tearDown()
    }

    /// 造一份最小的 Chrome `Local State`，只保留 scanner 真正读的字段。
    private func writeLocalState(profiles: [String: String]) throws {
        let directory = URL(fileURLWithPath: temporaryHome)
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let infoCache = profiles.mapValues { ["name": $0] }
        let root: [String: Any] = ["profile": ["info_cache": infoCache]]
        let data = try JSONSerialization.data(withJSONObject: root)
        try data.write(to: directory.appendingPathComponent("Local State"))
    }

    private func participant(
        _ name: String,
        role: String = "只负责挑毛病",
        profile: String? = nil,
        account: String? = nil
    ) -> BridgeParticipantSpec {
        BridgeParticipantSpec(name: name, role: role, profile: profile, account: account)
    }

    @MainActor
    private func build(_ spec: BridgeDiscussionSpec) throws -> DiscussionGroup {
        try BridgeSpecBuilder.build(spec: spec, services: services)
    }

    // MARK: - 议题

    func testMissingTopicIsRejectedWithHint() {
        let spec = BridgeDiscussionSpec(
            participants: [participant("A", profile: "Profile 3", account: "a@x.com"),
                           participant("B", profile: "Profile 4", account: "b@x.com")]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "议题")
    }

    // MARK: - 成员

    func testFewerThanTwoParticipantsIsRejected() {
        let spec = BridgeDiscussionSpec(
            topic: "选 A 还是 B",
            participants: [participant("独苗", profile: "Profile 3", account: "a@x.com")]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "2 位")
    }

    func testDuplicateParticipantNamesAreRejected() {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [
                participant("批判者", profile: "Profile 3", account: "a@x.com"),
                participant("批判者", profile: "Profile 4", account: "b@x.com")
            ]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "重复")
    }

    func testParticipantWithoutRoleOrPresetIsRejected() {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [
                BridgeParticipantSpec(name: "空角色", profile: "Profile 3", account: "a@x.com"),
                participant("成本专家", profile: "Profile 4", account: "b@x.com")
            ]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "角色设定")
    }

    func testUnknownPresetListsAvailableRoles() {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [
                BridgeParticipantSpec(name: "A", preset: "不存在的角色", profile: "Profile 3", account: "a@x.com"),
                participant("B", profile: "Profile 4", account: "b@x.com")
            ]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "批判者")
    }

    func testPresetResolvesToBuiltInRolePrompt() throws {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [
                BridgeParticipantSpec(name: "挑刺的", preset: "批判者", profile: "Profile 3", account: "a@x.com"),
                BridgeParticipantSpec(name: "算账的", preset: "成本专家", profile: "Profile 4", account: "b@x.com")
            ]
        )

        let group = try build(spec)

        XCTAssertEqual(group.participants.count, 2)
        let critic = try XCTUnwrap(group.participants.first { $0.displayName == "挑刺的" })
        XCTAssertTrue(critic.rolePrompt.contains("挑毛病"))
        // 内置模板的配色/图标要跟着走，而不是用默认色
        XCTAssertEqual(critic.accentHex, "#FF7B72")
    }

    /// 显式 role 优先于 preset —— 否则用户自定义的立场会被模板悄悄覆盖。
    func testExplicitRoleWinsOverPreset() throws {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [
                BridgeParticipantSpec(name: "A", role: "我的自定义立场", preset: "批判者",
                                      profile: "Profile 3", account: "a@x.com"),
                participant("B", profile: "Profile 4", account: "b@x.com")
            ]
        )

        let group = try build(spec)
        let first = try XCTUnwrap(group.participants.first { $0.displayName == "A" })
        XCTAssertEqual(first.rolePrompt, "我的自定义立场")
    }

    // MARK: - Profile 绑定

    func testMissingProfilesAreAutoAssignedDistinctly() throws {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [participant("A"), participant("B"), participant("C")]
        )

        let group = try build(spec)

        let directories = group.enabledParticipants.map(\.profileDirectory)
        XCTAssertEqual(directories.count, 3)
        XCTAssertEqual(Set(directories).count, 3, "自动分配必须一个 Profile 一位成员")
        for directory in directories {
            XCTAssertFalse(directory.isEmpty)
        }
    }

    func testExplicitProfileIsPreservedAndOthersAvoidIt() throws {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [
                participant("A", profile: "Profile 7", account: "a@x.com"),
                participant("B")
            ]
        )

        let group = try build(spec)

        XCTAssertEqual(group.participants[0].profileDirectory, "Profile 7")
        XCTAssertNotEqual(group.participants[1].profileDirectory, "Profile 7")
    }

    func testAccountHintFallsBackToProfileDisplayName() throws {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [participant("A"), participant("B")]
        )

        let group = try build(spec)

        for participant in group.enabledParticipants {
            XCTAssertFalse(
                participant.emailHint.isEmpty,
                "账号标识必须被补齐，否则身份校验会永远 fail closed"
            )
        }
    }

    func testTwoParticipantsSharingOneProfileIsRejected() {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [
                participant("A", profile: "Profile 3", account: "a@x.com"),
                participant("B", profile: "Profile 3", account: "b@x.com")
            ]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "同一个")
    }

    /// Profile 不存在时要在这里就报错，而不是等会话层去炸 —— 那边的报错难懂得多。
    func testNonexistentProfileIsRejectedWithAvailableList() {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [
                participant("A", profile: "Profile 99", account: "a@x.com"),
                participant("B", profile: "Profile 4", account: "b@x.com")
            ]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "Profile 3")
    }

    // MARK: - 议程

    func testDefaultAgendaIsUsedWhenRoundsOmitted() throws {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [participant("A", profile: "Profile 3", account: "a@x.com"),
                           participant("B", profile: "Profile 4", account: "b@x.com")]
        )

        let group = try build(spec)

        XCTAssertEqual(group.rounds.count, 3)
        XCTAssertEqual(group.rounds.first?.kind, .independentOpinion)
        XCTAssertEqual(group.rounds.last?.kind, .convergence)
    }

    func testRoundKindAndVisibilityAcceptRawValues() throws {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [participant("A", profile: "Profile 3", account: "a@x.com"),
                           participant("B", profile: "Profile 4", account: "b@x.com")],
            rounds: [
                BridgeRoundSpec(kind: "independentOpinion", visibility: "none"),
                BridgeRoundSpec(kind: "convergence", visibility: "all", speakers: ["A"])
            ]
        )

        let group = try build(spec)

        XCTAssertEqual(group.rounds.count, 2)
        XCTAssertEqual(group.rounds[0].visibility, .none)
        XCTAssertEqual(group.rounds[1].visibility, .all)
        XCTAssertEqual(group.rounds[1].speakerIDs.count, 1)
        XCTAssertEqual(group.rounds[1].speakerIDs.first, group.participants[0].id)
    }

    func testUnknownRoundKindIsRejectedWithOptions() {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [participant("A", profile: "Profile 3", account: "a@x.com"),
                           participant("B", profile: "Profile 4", account: "b@x.com")],
            rounds: [BridgeRoundSpec(kind: "brainstorm")]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "independentOpinion")
    }

    func testRoundSpeakerMustBeAKnownParticipant() {
        let spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [participant("A", profile: "Profile 3", account: "a@x.com"),
                           participant("B", profile: "Profile 4", account: "b@x.com")],
            rounds: [BridgeRoundSpec(kind: "convergence", speakers: ["查无此人"])]
        )

        assertBridgeError(try build(spec), code: .invalidRequest, contains: "查无此人")
    }

    // MARK: - 收敛与主席

    func testConsensusAcceptsRawValueAndRejectsUnknown() throws {
        let base = BridgeDiscussionSpec(
            topic: "议题",
            participants: [participant("A", profile: "Profile 3", account: "a@x.com"),
                           participant("B", profile: "Profile 4", account: "b@x.com")]
        )

        var ok = base
        ok.consensus = "majorityVote"
        XCTAssertEqual(try build(ok).consensus, .majorityVote)

        var bad = base
        bad.consensus = "掷骰子"
        assertBridgeError(try build(bad), code: .invalidRequest, contains: "收敛方式")
    }

    func testModeratorMustBeAParticipant() throws {
        var spec = BridgeDiscussionSpec(
            topic: "议题",
            participants: [participant("A", profile: "Profile 3", account: "a@x.com"),
                           participant("B", profile: "Profile 4", account: "b@x.com")]
        )
        spec.moderator = "B"

        let group = try build(spec)
        XCTAssertEqual(group.moderator()?.displayName, "B")

        spec.moderator = "C"
        assertBridgeError(try build(spec), code: .invalidRequest, contains: "主席")
    }

    // MARK: - 复用已保存讨论组

    func testUnknownGroupNameIsNotFound() {
        let spec = BridgeDiscussionSpec(topic: "议题", group: "并不存在的组")

        assertBridgeError(try build(spec), code: .notFound, contains: "discussion_groups")
    }

    func testTopicOverridesSavedGroupTopic() throws {
        var saved = DiscussionPresets.starterGroup(name: "复用组")
        saved.topic = "旧议题"
        saved.participants[0].profileDirectory = "Profile 3"
        saved.participants[0].emailHint = "a@x.com"
        saved.participants[1].profileDirectory = "Profile 4"
        saved.participants[1].emailHint = "b@x.com"
        saved.participants[2].profileDirectory = "Profile 7"
        saved.participants[2].emailHint = "c@x.com"
        try services.discussionRepo.save(saved)

        let group = try build(BridgeDiscussionSpec(topic: "新议题", group: "复用组"))

        XCTAssertEqual(group.topic, "新议题")
        XCTAssertEqual(group.participants.count, 3, "成员应沿用保存的配置")
    }

    func testSavedGroupTopicIsKeptWhenSpecOmitsTopic() throws {
        var saved = DiscussionPresets.starterGroup(name: "有议题的组")
        saved.topic = "沿用这个议题"
        saved.participants[0].profileDirectory = "Profile 3"
        saved.participants[0].emailHint = "a@x.com"
        saved.participants[1].profileDirectory = "Profile 4"
        saved.participants[1].emailHint = "b@x.com"
        saved.participants[2].profileDirectory = "Profile 7"
        saved.participants[2].emailHint = "c@x.com"
        try services.discussionRepo.save(saved)

        let group = try build(BridgeDiscussionSpec(group: "有议题的组"))

        XCTAssertEqual(group.topic, "沿用这个议题")
    }

    // MARK: - 断言辅助

    /// 同时校验错误码与提示文案。
    ///
    /// 刻意用 `@autoclosure () throws`：调用点写 `assertBridgeError(try build(spec), …)`，
    /// 抛出被这里接住。若写成 `try? build(spec)` 传进来，`try?` 会先把错误吞成 nil，
    /// code 与文案断言就静默失效了 —— 那种"永远通过的测试"比没有测试更糟。
    private func assertBridgeError(
        _ expression: @autoclosure () throws -> DiscussionGroup,
        code: BridgeErrorCode,
        contains fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("预期抛出 BridgeError(\(code))，实际成功", file: file, line: line)
        } catch let error as BridgeError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            let combined = error.message + " " + (error.hint ?? "")
            XCTAssertTrue(
                combined.contains(fragment),
                "错误信息应包含「\(fragment)」，实际是：\(combined)",
                file: file, line: line
            )
        } catch {
            XCTFail("预期 BridgeError，实际抛出 \(error)", file: file, line: line)
        }
    }
}

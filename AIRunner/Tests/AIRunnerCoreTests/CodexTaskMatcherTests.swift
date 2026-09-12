import XCTest
@testable import AIRunnerCore

/// 线程匹配测试 —— "确认是那一个线程"的核心判定。
final class CodexTaskMatcherTests: XCTestCase {

    private let matcher = CodexTaskMatcher()

    private func fingerprint(
        title: String? = "长对话任务",
        project: String? = "airunner",
        repo: String? = "/Users/dev/airunner"
    ) -> CodexTaskFingerprint {
        CodexTaskFingerprint(
            threadTitle: title,
            projectName: project,
            repositoryPath: repo
        )
    }

    private func candidate(
        title: String,
        project: String? = nil,
        repo: String? = nil
    ) -> CodexThreadCandidate {
        CodexThreadCandidate(
            title: title, projectName: project, repositoryPath: repo
        )
    }

    // MARK: - 强度评定

    func testExactWhenTitleAndSecondaryBothMatch() {
        let scored = matcher.strength(
            of: candidate(title: "长对话任务", project: "airunner"),
            against: fingerprint()
        )
        XCTAssertEqual(scored, .exact)
    }

    func testStrongWhenTitleMatchesButNoSecondaryAvailable() {
        // UI 上读不到项目名 —— 无从佐证, 但标题对上了
        let scored = matcher.strength(
            of: candidate(title: "长对话任务"),
            against: fingerprint()
        )
        XCTAssertEqual(scored, .strong)
    }

    func testWeakWhenSecondaryContradicts() {
        // 标题一样, 但项目名对不上 → 极可能是同名线程
        let scored = matcher.strength(
            of: candidate(title: "长对话任务", project: "另一个项目"),
            against: fingerprint()
        )
        XCTAssertEqual(scored, .weak, "有明确矛盾时必须降级, 不能靠标题硬匹配")
    }

    func testWeakWhenTitleDiffers() {
        let scored = matcher.strength(
            of: candidate(title: "完全不同的线程", project: "airunner"),
            against: fingerprint()
        )
        XCTAssertEqual(scored, .weak)
    }

    // MARK: - 唯一性判定

    func testUniqueWhenExactlyOneMatches() {
        let outcome = matcher.match(
            fingerprint: fingerprint(),
            candidates: [
                candidate(title: "无关线程"),
                candidate(title: "长对话任务", project: "airunner"),
                candidate(title: "另一个无关线程"),
            ]
        )

        guard case .unique(let scored) = outcome else {
            return XCTFail("应当唯一匹配, 实际: \(outcome)")
        }
        XCTAssertEqual(scored.candidate.title, "长对话任务")
        XCTAssertEqual(scored.strength, .exact)
    }

    func testAmbiguousWhenTwoCandidatesMatch() {
        let outcome = matcher.match(
            fingerprint: fingerprint(),
            candidates: [
                candidate(title: "长对话任务", project: "airunner"),
                candidate(title: "长对话任务", project: "airunner"),
            ]
        )

        guard case .ambiguous(let list) = outcome else {
            return XCTFail("两个可用候选必须判定为歧义, 实际: \(outcome)")
        }
        XCTAssertEqual(list.count, 2)
        XCTAssertFalse(outcome.isUnique)
    }

    func testNotFoundWhenNoCandidates() {
        XCTAssertEqual(matcher.match(fingerprint: fingerprint(), candidates: []), .notFound)
    }

    func testOnlyWeakMatchesWhenAllCandidatesMismatch() {
        let outcome = matcher.match(
            fingerprint: fingerprint(),
            candidates: [candidate(title: "别的线程"), candidate(title: "又是别的")]
        )

        guard case .onlyWeakMatches(let list) = outcome else {
            return XCTFail("全部不匹配应当单独归类, 实际: \(outcome)")
        }
        XCTAssertEqual(list.count, 2)
        XCTAssertFalse(outcome.isUnique)
    }

    func testOnlyWeakMatchIsNeverUnique() {
        // 即使只有一个候选, 只要它是 weak 就不能放行
        let outcome = matcher.match(
            fingerprint: fingerprint(),
            candidates: [candidate(title: "长对话任务", project: "另一个项目")]
        )
        XCTAssertFalse(outcome.isUnique, "唯一的 weak 候选也不允许自动发送")
    }

    func testCandidateCountIsReported() {
        XCTAssertEqual(matcher.match(fingerprint: fingerprint(), candidates: []).candidateCount, 0)
        XCTAssertEqual(
            matcher.match(
                fingerprint: fingerprint(),
                candidates: [candidate(title: "长对话任务", project: "airunner")]
            ).candidateCount,
            1
        )
    }

    // MARK: - 二次验证（打开之后的 Gate）

    func testVerifyPassesWithTitleAndSecondaryContext() {
        let result = matcher.verifyOpenedThread(
            context: CodexOpenThreadContext(
                threadTitle: "长对话任务",
                projectName: "airunner",
                repositoryPath: "/Users/dev/airunner"
            ),
            against: fingerprint()
        )

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.secondaryMatched)
        XCTAssertNil(result.reason)
    }

    func testVerifyFailsWhenTitleDiffers() {
        let result = matcher.verifyOpenedThread(
            context: CodexOpenThreadContext(threadTitle: "别的线程", projectName: "airunner"),
            against: fingerprint()
        )

        XCTAssertFalse(result.passed, "打开后的标题对不上必须失败")
        XCTAssertNotNil(result.reason)
    }

    func testVerifyFailsWhenSecondaryContradicts() {
        let result = matcher.verifyOpenedThread(
            context: CodexOpenThreadContext(
                threadTitle: "长对话任务",
                projectName: "完全不同的项目"
            ),
            against: fingerprint()
        )

        XCTAssertFalse(result.passed, "同名但不同项目 → 可能打开错了, 必须失败")
        XCTAssertFalse(result.secondaryMatched)
    }

    func testVerifyPassesButFlagsMissingSecondSignal() {
        // 绑定里只有标题 → 定位可以放行, 但没有第二个独立信号
        let titleOnly = CodexTaskFingerprint(threadTitle: "长对话任务")
        let result = matcher.verifyOpenedThread(
            context: CodexOpenThreadContext(threadTitle: "长对话任务"),
            against: titleOnly
        )

        XCTAssertTrue(result.passed, "定位门槛可以放行")
        XCTAssertFalse(result.secondaryMatched, "必须如实报告缺少第二个信号")
        XCTAssertNotNil(result.reason)
    }

    // MARK: - 指纹自检

    func testFingerprintSufficiencyRequiresSecondarySignal() {
        XCTAssertFalse(
            CodexTaskFingerprint(threadTitle: "只有标题").isSufficientForAutoResume,
            "只有标题不足以自动发送"
        )
        XCTAssertTrue(
            CodexTaskFingerprint(threadTitle: "标题", projectName: "proj")
                .isSufficientForAutoResume
        )
        XCTAssertFalse(CodexTaskFingerprint().isSufficientForAutoResume)
    }
}

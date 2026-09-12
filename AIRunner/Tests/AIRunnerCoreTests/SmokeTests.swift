import XCTest
@testable import AIRunnerCore

/// 占位 —— 真实测试见后续的 RetryManagerTests / ModelRouterTests / JobRunnerTests 等。
final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(TaskStatus.running.rawValue, "running")
    }
}

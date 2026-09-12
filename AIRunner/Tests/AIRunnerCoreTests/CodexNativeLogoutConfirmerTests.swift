import XCTest
@testable import AIRunnerCore

final class CodexNativeLogoutConfirmerTests: XCTestCase {
    func testRecognizesOnlyExactNativeLogoutMenuCommands() {
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutCommand(
            role: "AXMenuItem", text: "注销"
        ))
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutCommand(
            role: "AXMenuItem", text: "Log Out"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutCommand(
            role: "AXMenuItem", text: "退出登录“alex”…"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutCommand(
            role: "AXButton", text: "注销"
        ))
    }

    func testRecognizesOfficialLocalizedConfirmationTitles() {
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutConfirmationTitle("退出登录？"))
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutConfirmationTitle("登出？"))
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutConfirmationTitle("Log out?"))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutConfirmationTitle("设置里可以退出登录"))
    }

    func testRecognizesOnlyExactConfirmationButtons() {
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutConfirmationButton(
            role: "AXButton", text: "退出登录"
        ))
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutConfirmationButton(
            role: "AXButton", text: "Log out"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutConfirmationButton(
            role: "AXButton", text: "取消"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutConfirmationButton(
            role: "AXStaticText", text: "退出登录"
        ))
    }

    func testRejectsConversationSentenceContainingConfirmationWords() {
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutConfirmationTitle(
            "还有一个退出登录？确认界面"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutConfirmationButton(
            role: "AXButton", text: "点击退出登录就好了"
        ))
    }
}

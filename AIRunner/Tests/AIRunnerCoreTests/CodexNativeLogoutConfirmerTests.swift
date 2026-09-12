import XCTest
@testable import AIRunnerCore

final class CodexNativeLogoutConfirmerTests: XCTestCase {
    func testRecognizesObservedCodexProfileMenuControl() {
        XCTAssertTrue(CodexNativeLogoutConfirmer.isProfileMenuControl(
            role: "AXPopUpButton", text: "打开个人资料菜单"
        ))
        XCTAssertTrue(CodexNativeLogoutConfirmer.isProfileMenuControl(
            role: "AXButton", text: "Open account menu"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isProfileMenuControl(
            role: "AXStaticText", text: "打开个人资料菜单"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isProfileMenuControl(
            role: "AXButton", text: "请打开个人资料菜单"
        ))
    }

    func testRecognizesOnlyExactSidebarLogoutControl() {
        XCTAssertTrue(CodexNativeLogoutConfirmer.isSidebarLogoutControl(
            role: "AXButton", text: "退出登录"
        ))
        XCTAssertTrue(CodexNativeLogoutConfirmer.isSidebarLogoutControl(
            role: "AXStaticText", text: "Log out"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isSidebarLogoutControl(
            role: "AXButton", text: "这个是退出登录，修正一下"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isSidebarLogoutControl(
            role: "AXGroup", text: "退出登录"
        ))
    }

    func testRecognizesOnlyExactNativeLogoutMenuCommands() {
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutCommand(
            role: "AXMenuItem", text: "注销"
        ))
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutCommand(
            role: "AXMenuItem", text: "Log Out"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutCommand(
            role: "AXMenuItem", text: "退出登录“swen”…"
        ))
        XCTAssertFalse(CodexNativeLogoutConfirmer.isLogoutCommand(
            role: "AXButton", text: "注销"
        ))
    }

    func testRecognizesOfficialLocalizedConfirmationTitles() {
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutConfirmationTitle("退出登录？"))
        XCTAssertTrue(CodexNativeLogoutConfirmer.isLogoutConfirmationTitle("要退出登录？"))
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

    func testLogoutFailureMessagesDistinguishConfirmationFromLoginPage() {
        XCTAssertTrue(
            CodexBrowserOAuthError.codexLogoutConfirmationDidNotDismiss
                .localizedDescription.contains("确认框仍然可见")
        )
        XCTAssertTrue(
            CodexBrowserOAuthError.codexLogoutDidNotComplete
                .localizedDescription.contains("确认框已经消失")
        )
    }
}

import XCTest
@testable import AIRunnerCore

final class DiscussionAttachmentTests: XCTestCase {

    func testChatGPTAttachmentEntryMatchesCurrentTwoLevelMenu() throws {
        XCTAssertTrue(AX.attachmentButtonTextMatches("添加文件等"))
        XCTAssertTrue(AX.attachmentButtonTextMatches("Add photos & files"))
        XCTAssertTrue(AX.attachmentMenuItemTextMatches("添加文件。登录后使用。"))
        XCTAssertTrue(AX.attachmentMenuItemTextMatches("Attach files"))
        XCTAssertFalse(AX.attachmentMenuItemTextMatches("添加照片"))
        XCTAssertFalse(AX.attachmentMenuItemTextMatches("Create image"))
    }

    func testChatGPTPolicyAcceptsDocumentSpreadsheetTextAndImage() throws {
        let supported = [
            ("brief.pdf", DiscussionAttachmentKind.document),
            ("data.xlsx", .spreadsheet),
            ("notes.txt", .text),
            ("diagram.png", .image),
        ]
        for (name, expectedKind) in supported {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(ChatGPTAttachmentPolicy.kind(for: url), expectedKind)
        }
        XCTAssertNil(ChatGPTAttachmentPolicy.kind(for: URL(fileURLWithPath: "/tmp/file.gdoc")))
        XCTAssertNil(ChatGPTAttachmentPolicy.kind(for: URL(fileURLWithPath: "/tmp/archive.zip")))
    }

    func testPolicyErrorsNameTheOffendingFile() throws {
        let unsupported = URL(fileURLWithPath: "/tmp/archive.zip")
        let unsupportedError = ChatGPTAttachmentPolicy.validationError(
            for: unsupported,
            byteSize: 1
        )
        XCTAssertEqual(unsupportedError, "ChatGPT 网页不支持此文件格式：archive.zip")

        let oversized = URL(fileURLWithPath: "/tmp/large.pdf")
        let oversizedError = ChatGPTAttachmentPolicy.validationError(
            for: oversized,
            byteSize: ChatGPTAttachmentPolicy.maxFileBytes + 1,
            kind: .document
        )
        XCTAssertEqual(oversizedError, "文件超过 512 MB：large.pdf")
    }

    func testFolderScannerFiltersUnsupportedFilesAndHonorsMessageLimit() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-discussion-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("not supported".utf8).write(to: folder.appendingPathComponent("archive.zip"))
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a,b\n1,2\n".utf8).write(to: nested.appendingPathComponent("data.csv"))

        let result = DiscussionAttachmentScanner.scan(folder: folder)
        XCTAssertEqual(result.attachments.map(\.fileName), ["data.csv", "notes.txt"])
        XCTAssertEqual(result.skippedFileNames, ["archive.zip"])
        XCTAssertFalse(result.truncated)
    }

    @MainActor
    func testDiscussionPromptListsPersistedAttachments() throws {
        let services = try TestSupport.makeServices()
        let attachment = DiscussionAttachment(
            path: "/tmp/reference.pdf",
            byteSize: 1024,
            kind: .document
        )
        let participant = DiscussionParticipant(
            displayName: "分析员",
            rolePrompt: "只分析证据。",
            emailHint: "analyst@example.com"
        )
        let group = DiscussionGroup(
            name: "附件讨论",
            topic: "分析参考材料",
            attachments: [attachment],
            participants: [participant]
        )
        let orchestrator = DiscussionOrchestrator(
            group: group,
            sessions: ScriptedSessionProvider(group: group),
            logger: services.logger
        )

        let prompt = orchestrator.buildPrompt(
            round: group.rounds[0],
            speaker: participant
        )
        XCTAssertTrue(prompt.contains("reference.pdf"))
        XCTAssertTrue(prompt.contains("文档"))
        XCTAssertTrue(prompt.contains("已随本条消息上传"))
    }

    func testDiscussionRepositoryRoundTripsAttachments() throws {
        let services = try TestSupport.makeServices()
        let attachment = DiscussionAttachment(
            path: "/tmp/reference.xlsx",
            byteSize: 2048,
            kind: .spreadsheet
        )
        let group = DiscussionGroup(
            name: "附件持久化",
            topic: "检查表格",
            attachments: [attachment],
            participants: [
                DiscussionParticipant(displayName: "甲", rolePrompt: "分析", emailHint: "a@example.com"),
                DiscussionParticipant(displayName: "乙", rolePrompt: "质询", emailHint: "b@example.com"),
            ]
        )

        try services.discussionRepo.save(group)
        let loaded = try XCTUnwrap(services.discussionRepo.fetchGroup(id: group.id))
        XCTAssertEqual(loaded.attachments, [attachment])
        XCTAssertEqual(loaded.topic, group.topic)
    }
}

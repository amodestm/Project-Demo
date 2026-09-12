import XCTest
import ApplicationServices
@testable import AIRunnerCore

/// 真机 AX tree 探测。
///
/// 目的: 在写任何"如何点击"的代码之前, 先看清楚真实的 AX 结构长什么样。
/// 这是"不猜坐标"的落地方式 —— 先有事实, 再有适配。
///
/// 没有辅助功能权限时这个测试会 skip, 而不是失败。
final class AXTreeProbeTests: XCTestCase {

    func testProbeChatGPTAccessibilityTree() async throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip(
                "没有辅助功能权限。请在「系统设置 → 隐私与安全性 → 辅助功能」中授权后重跑。"
            )
        }

        let bundleID = "com.openai.codex"
        let inspector = AXElementInspector()

        // AXTreeSnapshotOptions 有自定义 init, 没有成员构造器 —— 逐字段设置。
        var options = AXTreeSnapshotOptions()
        options.maxDepth = 10
        options.maxNodes = 3000
        options.valuePreviewLength = 0     // ★ 默认不写消息正文 ★
        options.labelMaxLength = 80

        let snapshot = try await inspector.inspect(
            bundleIdentifier: bundleID,
            options: options
        )

        let text = snapshot.render()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatgpt-ax-tree.txt")
        try text.write(to: outputURL, atomically: true, encoding: String.Encoding.utf8)

        let lineCount = text.split(separator: "\n").count

        // 汇总: 这棵树里出现了哪些 role
        var roleCounts: [String: Int] = [:]
        collectRoles(snapshot, into: &roleCounts)
        let topRoles = roleCounts
            .sorted { $0.value > $1.value }
            .prefix(15)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")

        print("\n===== AX TREE PROBE (\(bundleID)) =====")
        print("输出文件: \(outputURL.path)")
        print("总行数: \(lineCount)")
        print("顶层 role: \(snapshot.role)")
        print("role 分布: \(topRoles)")
        print("=====================================\n")

        XCTAssertGreaterThan(lineCount, 1, "应当导出到非空的一棵树")
    }

    func testReportCandidateCodexApplications() async throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("没有辅助功能权限")
        }
        let candidates = AXElementInspector.candidateCodexApplications()
        print("\n===== 候选 Codex App =====")
        for candidate in candidates {
            print("  \(candidate.bundleIdentifier)  —  \(candidate.name)")
        }
        print("==========================\n")

        XCTAssertFalse(candidates.isEmpty, "ChatGPT 桌面版应当在运行")
    }

    // MARK: - 内部

    private func collectRoles(_ node: AXNodeSnapshot, into counts: inout [String: Int]) {
        counts[node.role, default: 0] += 1
        for child in node.children {
            collectRoles(child, into: &counts)
        }
    }
}

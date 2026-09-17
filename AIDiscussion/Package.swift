// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIDiscussion",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AIDiscussionCore", targets: ["AIDiscussionCore"]),
        .library(name: "AIDiscussionBridge", targets: ["AIDiscussionBridge"]),
        .executable(name: "AIDiscussion", targets: ["AIDiscussion"]),
        .executable(name: "AIDiscussionMCP", targets: ["AIDiscussionMCP"])
    ],
    dependencies: [],
    targets: [
        // app 与 MCP 共用的本地桥接协议（只依赖 Foundation）
        .target(
            name: "AIDiscussionBridge",
            dependencies: [],
            path: "Sources/AIDiscussionBridge"
        ),
        .target(
            name: "AIDiscussionCore",
            dependencies: ["AIDiscussionBridge"],
            path: "Sources/AIDiscussionCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AIDiscussion",
            dependencies: ["AIDiscussionCore"],
            path: "Sources/AIDiscussion"
        ),
        // MCP 的协议/工具层，独立成库以便单元测试直接驱动（可执行目标不便被测试导入）
        .target(
            name: "AIDiscussionMCPKit",
            dependencies: ["AIDiscussionBridge"],
            path: "Sources/AIDiscussionMCPKit"
        ),
        // 供 Codex 等 MCP 客户端调用的 stdio 服务端
        .executableTarget(
            name: "AIDiscussionMCP",
            dependencies: ["AIDiscussionMCPKit", "AIDiscussionBridge"],
            path: "Sources/AIDiscussionMCP"
        ),
        .testTarget(
            name: "AIDiscussionCoreTests",
            dependencies: ["AIDiscussionCore"],
            path: "Tests/AIDiscussionCoreTests"
        ),
        .testTarget(
            name: "AIDiscussionBridgeTests",
            dependencies: ["AIDiscussionBridge"],
            path: "Tests/AIDiscussionBridgeTests"
        ),
        .testTarget(
            name: "AIDiscussionMCPKitTests",
            dependencies: ["AIDiscussionMCPKit"],
            path: "Tests/AIDiscussionMCPKitTests"
        )
    ]
)

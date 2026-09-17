// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIDiscussion",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AIDiscussionCore", targets: ["AIDiscussionCore"]),
        .executable(name: "AIDiscussion", targets: ["AIDiscussion"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AIDiscussionCore",
            dependencies: [],
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
        .testTarget(
            name: "AIDiscussionCoreTests",
            dependencies: ["AIDiscussionCore"],
            path: "Tests/AIDiscussionCoreTests"
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIRunner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIRunnerCore", targets: ["AIRunnerCore"]),
        .executable(name: "AIRunner", targets: ["AIRunner"]),
    ],
    dependencies: [
        // 刻意保持零外部依赖。
        // 数据库使用 macOS SDK 自带的 SQLite3 (见 AIRunnerCore/Persistence/Database.swift)。
    ],
    targets: [
        .target(
            name: "AIRunnerCore",
            path: "Sources/AIRunnerCore",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "AIRunner",
            dependencies: ["AIRunnerCore"],
            path: "Sources/AIRunner",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AIRunnerCoreTests",
            dependencies: ["AIRunnerCore"],
            path: "Tests/AIRunnerCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

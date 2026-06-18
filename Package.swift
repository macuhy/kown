// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kown",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
        // Sparkle 自动更新框架 — 仅 macOS 用到(见 UpdaterService.swift)。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Kown",
            dependencies: [
                .product(name: "Textual", package: "textual"),
                // Sparkle 是 macOS-only:iOS 端不链接,避免在 iOS 平台编译失败。
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
            ],
            path: "Sources/Kown",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "KownTests",
            dependencies: ["Kown"],
            path: "Tests/KownTests"
        )
    ]
)

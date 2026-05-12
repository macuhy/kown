// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kown",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kown",
            path: "Sources/Kown",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)

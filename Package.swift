// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MDirStat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MDirStat",
            path: "Sources/MDirStat",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

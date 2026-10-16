// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reaper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Reaper",
            path: "Sources/Reaper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

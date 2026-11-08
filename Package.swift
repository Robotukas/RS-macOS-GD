// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GDHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GDHub",
            path: "Sources/GDHub",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GDHubTests",
            dependencies: ["GDHub"],
            path: "Tests/GDHubTests"
        ),
    ]
)

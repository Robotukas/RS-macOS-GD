// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GDHub",
    platforms: [.macOS(.v14)],
    targets: [
        // The one C translator (report 0x06 -> pad reports). Shared with the Xcode app target and, from T5, the dext.
        // -ffp-contract=off keeps every multiply and add separate, exactly as Swift evaluates them.
        .target(
            name: "GDHubXlate",
            path: "Shared",
            publicHeadersPath: ".",
            cSettings: [.unsafeFlags(["-ffp-contract=off"])]
        ),
        .executableTarget(
            name: "GDHub",
            dependencies: ["GDHubXlate"],
            path: "Sources/GDHub",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GDHubTests",
            dependencies: ["GDHub", "GDHubXlate"],
            path: "Tests/GDHubTests"
        ),
    ]
)

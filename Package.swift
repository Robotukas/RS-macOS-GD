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
        // The DriverKit-free core of the dext (registry state machine, meter, status2 packer, CRC-32): the same files the
        // Xcode dext target compiles, built here so the tests can drive them.
        .target(
            name: "GDHubDextCore",
            path: "Dext/GDHubVirtualHID/Core",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "GDHub",
            dependencies: ["GDHubXlate"],
            path: "Sources/GDHub",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "GDHubTests",
            dependencies: ["GDHub", "GDHubXlate", "GDHubDextCore"],
            path: "Tests/GDHubTests"
        ),
    ]
)

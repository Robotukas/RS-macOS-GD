import XCTest
@testable import GDHub

/// The engine must never create an application object or join RunningBoard (engine-agent-plan §3.4): a source scan of
/// the engine files and the shared files they use.
final class EngineIsolationTests: XCTestCase {
    private static let forbidden = ["import SwiftUI", "import AppKit", "import GameController", "@MainActor",
                                    "NSApplication", "NSApp", "NSWorkspace", "beginActivity", "PadActivity"]

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/GDHub")
    }

    private func swiftFiles(in dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    private func files() -> [URL] {
        var urls = swiftFiles(in: root.appendingPathComponent("Engine"))
        urls += swiftFiles(in: root.appendingPathComponent("Output/VirtualPad"))
        for rel in ["Output/VirtualHID/DextClient.swift", "Output/VirtualHID/DextControlling.swift",
                    "Output/VirtualHID/DextProtocol.swift", "Output/VirtualHID/DextStatusPoller.swift",
                    "Output/VirtualHID/HIDReportSizer.swift", "Mapping/ControlMapping.swift", "Mapping/MappingStore.swift",
                    "Devices/EnvisionPro/EnvisionProReport.swift", "Shared/ControllerStatus.swift"] {
            urls.append(root.appendingPathComponent(rel))
        }
        return urls
    }

    func testEngineFilesExistAndAreScanned() {
        let names = Set(files().map(\.lastPathComponent))
        for n in ["EngineMain.swift", "EngineService.swift", "EngineCore.swift", "GamepadHIDReader.swift",
                  "ControllerPresence.swift", "PowerObserver.swift", "ThrottleCheck.swift", "MappingWatcher.swift",
                  "DextClient.swift", "VirtualPadSink.swift", "ControlMapping.swift"] {
            XCTAssertTrue(names.contains(n), "\(n) is not in the scanned set")
        }
    }

    func testNoForbiddenTokens() throws {
        for url in files() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = raw.components(separatedBy: "//").first ?? ""          // comments may name the rules
                for token in Self.forbidden where code.contains(token) {
                    XCTFail("\(url.lastPathComponent):\(i + 1) contains \"\(token)\"")
                }
            }
        }
    }
}

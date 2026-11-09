import XCTest
@testable import GDHub

final class ProbeExtensionRequesterTests: XCTestCase {
    func testOnlyTheProbeFlagSelectsTheProbeMode() {
        XCTAssertEqual(ProbeExtensionRequester.parse(arguments: ["GDHub"]), .notRequested)
        XCTAssertEqual(ProbeExtensionRequester.parse(arguments: ["GDHub", "--engine", "--engine-foreground"]), .notRequested)
        XCTAssertEqual(ProbeExtensionRequester.parse(arguments: ["GDHub", "--install-driver", "--dev-terminate-driver"]), .notRequested)
    }

    func testActivateAndDeactivate() {
        XCTAssertEqual(ProbeExtensionRequester.parse(arguments: ["GDHub", "--dev-probe-dext", "activate"]), .run(.activate))
        XCTAssertEqual(ProbeExtensionRequester.parse(arguments: ["GDHub", "--dev-probe-dext", "deactivate"]), .run(.deactivate))
    }

    func testMissingOrUnknownModeIsAUsageErrorNotAGUILaunch() {
        for args in [["GDHub", "--dev-probe-dext"], ["GDHub", "--dev-probe-dext", "install"], ["GDHub", "--dev-probe-dext", "--engine"]] {
            guard case .usage = ProbeExtensionRequester.parse(arguments: args) else { return XCTFail("\(args)") }
        }
    }
}

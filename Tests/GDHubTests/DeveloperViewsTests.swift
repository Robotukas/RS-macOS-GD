import XCTest
@testable import GDHub

final class DeveloperViewsTests: XCTestCase {
    func testRingDrainsFromElapsed() {
        XCTAssertEqual(DevRingMath.remaining(totalNs: 5_000_000_000, elapsedNs: 0, sinceStamp: 0), 1)
        XCTAssertEqual(DevRingMath.remaining(totalNs: 5_000_000_000, elapsedNs: 1_000_000_000, sinceStamp: 1.5)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(DevRingMath.remaining(totalNs: 5_000_000_000, elapsedNs: nil, sinceStamp: 9), 0)
        XCTAssertNil(DevRingMath.remaining(totalNs: nil, elapsedNs: nil, sinceStamp: 1))
    }

    func testSecondsLeftRoundsUp() {
        XCTAssertEqual(DevRingMath.secondsLeft(totalNs: 5_000_000_000, elapsedNs: 0, sinceStamp: 0.2), 5)
        XCTAssertEqual(DevRingMath.secondsLeft(totalNs: 5_000_000_000, elapsedNs: 4_100_000_000, sinceStamp: 0), 1)
        XCTAssertEqual(DevRingMath.secondsLeft(totalNs: 5_000_000_000, elapsedNs: 6_000_000_000, sinceStamp: 0), 0)
    }

    func testPadOverlayMapsStickYDownAndButtons() throws {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        var state = PadDecodedState()
        state.ly = 0.5          // pad: up is positive
        state.rt = 0.75
        state.buttons = [.a, .ls]
        state.hat = 1           // N
        state.guide = true
        func overlay(_ id: String) throws -> DevPadOverlay {
            DevPadOverlay(control: try XCTUnwrap(layout.controls.first { $0.id == id }), state: state)
        }
        XCTAssertEqual(try overlay("left_stick").stick, CGPoint(x: 0, y: -0.5))
        XCTAssertEqual(try overlay("rt").trigger, 0.75)
        XCTAssertTrue(try overlay("a").pressed)
        XCTAssertFalse(try overlay("b").pressed)
        XCTAssertTrue(try overlay("l3").pressed)
        XCTAssertTrue(try overlay("dpad_up").pressed)
        XCTAssertFalse(try overlay("dpad_down").pressed)
        XCTAssertTrue(try overlay("start").pressed)
    }

    func testTemplateGroupsOrderAndLabels() {
        func entry(_ id: String, _ s: DevTemplateSource) -> DevTemplateEntry {
            DevTemplateEntry(id: id, template: nil, source: s, url: URL(fileURLWithPath: "/tmp/\(id).json"))
        }
        let groups = DeveloperBar.groups([entry("l", .local), entry("b", .builtIn), entry("o", .localOverride)])
        XCTAssertEqual(groups.map(\.source.tag), ["built-in", "local override", "local"])
    }

    func testVerdictLabelsAndChipRerun() {
        XCTAssertEqual(DevVerdict.fail("x").label, "Fail")
        XCTAssertTrue(DevChip.Status.failed.canRerun)
        XCTAssertFalse(DevChip.Status.passed.canRerun)
    }
}

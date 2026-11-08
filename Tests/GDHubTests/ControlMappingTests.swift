import XCTest
@testable import GDHub

final class ControlMappingTests: XCTestCase {
    func testFactoryDefaultsMatchLearnedTable() {
        let m = ControlMapping.default
        XCTAssertEqual(m.buttons["a"], .button(1))
        XCTAssertEqual(m.buttons["menu"], .button(8))
        XCTAssertEqual(m.buttons["start"], .button(11))
        XCTAssertEqual(m.buttons["g5"], .button(16))
        XCTAssertEqual(m.buttons["profile"], .button(17))
        XCTAssertEqual(m.buttons["dpad_left"], .hat(6))
        XCTAssertEqual(m.physicalBits["sax_right"], 32)
    }

    func testPhysicalBitsTakePrecedenceOverMappedButton() {
        let m = ControlMapping.default
        var f = GamepadFrame.idle
        f.buttons = 1 << 0          // A pressed on the face
        XCTAssertTrue(m.isActive("a", f))
        XCTAssertFalse(m.isActive("sax_left", f), "SAX left is mapped to A but was not physically pressed")
        f.extra = 1 << 4            // SAX left physically pressed (also reports A)
        XCTAssertTrue(m.isActive("sax_left", f))
    }

    func testStickPositionUsesLearnedRanges() {
        var m = ControlMapping.default
        m.sticks["left_stick"]?.ranges = ["x": AxisRange(min: -20000, max: 20000), "y": AxisRange(min: -32768, max: 32767)]
        var f = GamepadFrame.idle
        f.x = 20000
        let p = m.stickPosition("left_stick", f)
        XCTAssertEqual(p?.x ?? 0, 1, accuracy: 0.001, "full learned travel maps to the ring edge")
    }

    func testApplyReplacesPhysicalBitsWhenRelearned() {
        var m = ControlMapping.default
        m.apply(LearnAssignment(controlId: "paddle_outer_left", target: .whole, binding: .hat(6), physicalBits: 2))
        XCTAssertEqual(m.physicalBits["paddle_outer_left"], 2)
        m.apply(LearnAssignment(controlId: "paddle_outer_left", target: .whole, binding: .hat(6), physicalBits: 8))
        XCTAssertEqual(m.physicalBits["paddle_outer_left"], 8, "re-learning must replace, not merge, stale bits")
    }
}

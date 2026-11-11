import XCTest
@testable import GDHub

final class RemapLabelTests: XCTestCase {
    private func label(_ text: String, _ id: String, _ m: ControlMapping, _ mode: RemapLabel.Mode = .live) -> RemapLabel {
        RemapLabel(label: text, id: id, mapping: m, mode: mode)
    }

    func testAnUnmappedControlShowsItsPlainLabel() {
        let l = label("G1", "g1", .default)
        XCTAssertEqual(l.text, "G1")
        XCTAssertNil(l.suffix)
        XCTAssertEqual(l.fullText, "G1")
        XCTAssertFalse(l.isRemapped)
    }

    func testVolumeKeysAtBuiltInHaveNoSuffix() {
        for (id, text) in [("g2", "G2"), ("g3", "G3"), ("g4", "G4")] {
            XCTAssertNil(label(text, id, .default).suffix)
            XCTAssertNil(label(text, id, .default, .mapping).suffix)
        }
    }

    func testARemapShowsAnOrangeArrowAndTheShortTargetName() {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        m.setOutput(.pad(.guide), for: "g5")
        m.setOutput(.pad(.dpad_up), for: "g3")
        m.setOutput(.pad(.lt), for: "a")
        let g1 = label("G1", "g1", m)
        XCTAssertEqual(g1.suffix, RemapLabel.Suffix(text: "→ Y", style: .remapped))
        XCTAssertEqual(g1.fullText, "G1 → Y")
        XCTAssertEqual(label("G5", "g5", m).suffix?.text, "→ Guide")
        XCTAssertEqual(label("G3", "g3", m).suffix?.text, "→ D-pad up")
        XCTAssertEqual(label("A", "a", m).suffix?.text, "→ LT")
        XCTAssertEqual(label("G1", "g1", m, .mapping).suffix?.text, "→ Y", "Mapping mode shows it too")
    }

    func testNothingIsAGreyArrow() {
        var m = ControlMapping.default
        m.setOutput(.nothing, for: "view")
        m.setOutput(.nothing, for: "g2")
        XCTAssertEqual(label("View", "view", m).suffix, RemapLabel.Suffix(text: "→ Nothing", style: .nothing))
        XCTAssertEqual(label("G2", "g2", m).fullText, "G2 → Nothing", "Nothing on a volume key is a real pick")
    }

    func testStartMappedAwayFromGuideAndBackToIt() {
        var m = ControlMapping.default
        m.setOutput(.pad(.x), for: "start")
        XCTAssertEqual(label("Start", "start", m).suffix?.text, "→ X")
        m.setOutput(.pad(.guide), for: "start")                 // the default again clears the remap
        XCTAssertNil(label("Start", "start", m).suffix)
    }

    func testEditLayoutAlwaysShowsThePlainLabel() {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        m.setOutput(.nothing, for: "view")
        for (text, id) in [("G1", "g1"), ("View", "view"), ("A", "a")] {
            let l = label(text, id, m, .editLayout)
            XCTAssertEqual(l.text, text)
            XCTAssertNil(l.suffix)
            XCTAssertEqual(l.fullText, text)
        }
    }

    func testControlsThatAreNotRemappableHaveNoSuffix() {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        XCTAssertNil(label("Left stick", "left_stick", m).suffix)
        XCTAssertNil(label("SAX left", "sax_left", m).suffix, "a SAX key follows A's remap but is not remapped itself")
    }

    func testLongLabelsStayIntact() {
        var m = ControlMapping.default
        m.setOutput(.pad(.dpad_right), for: "g4")
        XCTAssertEqual(label("G4", "g4", m).fullText, "G4 → D-pad right")
    }

    func testPaddleAndSaxLabelsShowTheirPickInWords() {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        m.setOutput(.nothing, for: "sax_left")
        m.setOutput(.pad(.dpad_up), for: "paddle_inner_right")
        let paddle = label("Paddle outer right", "paddle_outer_right", m, .mapping)
        XCTAssertEqual(paddle.fullText, "Paddle outer right → Y")
        XCTAssertEqual(paddle.suffix?.style, .remapped)
        let sax = label("SAX left", "sax_left", m, .mapping)
        XCTAssertEqual(sax.fullText, "SAX left → Nothing")
        XCTAssertEqual(sax.suffix?.style, .nothing, "grey")
        XCTAssertEqual(label("Paddle inner right", "paddle_inner_right", m).fullText, "Paddle inner right → D-pad up")
        // Keys left on Controller's profile keep the plain label; Edit layout shows the plain label for all.
        XCTAssertEqual(label("Paddle outer left", "paddle_outer_left", m, .mapping).fullText, "Paddle outer left")
        XCTAssertEqual(label("SAX right", "sax_right", m).fullText, "SAX right")
        XCTAssertEqual(label("Paddle outer right", "paddle_outer_right", m, .editLayout).fullText, "Paddle outer right")
    }
}

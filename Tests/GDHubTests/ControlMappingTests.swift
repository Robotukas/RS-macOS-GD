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

    // MARK: Remap model

    private func decode(_ json: String) throws -> ControlMapping {
        try JSONDecoder().decode(ControlMapping.self, from: Data(json.utf8))
    }

    private func encoded(_ m: ControlMapping) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(m), as: UTF8.self)
    }

    func testPadOutputStaysInStepWithPadItem() {
        XCTAssertEqual(PadOutput.allCases.count, 17)
        for item in PadItem.allCases {
            XCTAssertEqual(PadOutput(item).padItem, item)
        }
        for o in PadOutput.allCases {
            if o.isTrigger {
                XCTAssertNil(o.padItem)
            } else if let item = o.padItem {
                XCTAssertEqual(PadOutput(item), o)
                if o != .guide { XCTAssertEqual(item.layoutControlID, o.rawValue, "\(o) draws on its own control") }
            } else {
                XCTFail("\(o) has no PadItem")
            }
        }
        XCTAssertEqual(Set(PadOutput.allCases.filter(\.isTrigger)), [.lt, .rt])
    }

    func testControlOutputStringForm() {
        XCTAssertEqual(ControlOutput.pad(.y).string, "y")
        XCTAssertEqual(ControlOutput.pad(.guide).string, "guide")
        XCTAssertEqual(ControlOutput.nothing.string, "nothing")
        XCTAssertEqual(ControlOutput.builtIn.string, "built_in")
        for o in PadOutput.allCases { XCTAssertEqual(ControlOutput(string: o.rawValue), .pad(o)) }
        XCTAssertEqual(ControlOutput(string: "nothing"), .nothing)
        XCTAssertEqual(ControlOutput(string: "built_in"), .builtIn)
        XCTAssertNil(ControlOutput(string: "turbo"))
        XCTAssertNil(ControlOutput(string: ""))
    }

    func testOldFileWithoutOutputsOrPhysicalBitsLoads() throws {
        let m = try decode(#"{"buttons":{"a":{"button":{"_0":1}}},"sticks":{}}"#)
        XCTAssertEqual(m.buttons["a"], .button(1))
        XCTAssertTrue(m.physicalBits.isEmpty)
        XCTAssertTrue(m.outputs.isEmpty)
        XCTAssertEqual(try decode(#"{"buttons":{}}"#), ControlMapping())
        XCTAssertThrowsError(try decode("{}"), "no buttons key: unreadable, not an empty mapping that leaves the pad dead")
    }

    func testRoundTripWithOutputsAndEmptyOmitted() throws {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        m.setOutput(.nothing, for: "a")
        m.setOutput(.pad(.rt), for: "lt")
        m.setOutput(.pad(.guide), for: "g5")
        m.setOutput(.nothing, for: "g3")
        let json = try encoded(m)
        XCTAssertTrue(json.contains(#""outputs":{"#))
        XCTAssertTrue(json.contains(#""g1":"y""#))
        XCTAssertTrue(json.contains(#""g3":"nothing""#))
        XCTAssertEqual(try decode(json), m)

        let plain = try encoded(.default)
        XCTAssertFalse(plain.contains("outputs"))
        XCTAssertFalse(try encoded(ControlMapping()).contains("outputs"))
    }

    func testBadOutputEntriesAreDroppedAndTheRestLoads() throws {
        var clean = ControlMapping.default
        clean.setOutput(.pad(.y), for: "g1")
        let dirty = try decode(#"""
        {"buttons":{},"sticks":{},"physicalBits":{},
         "outputs":{"g1":"y","bogus":"a","g5":"turbo","g2":7,"g4":null,"a":"built_in","lt":["x"],
                    "b":"b","g3":"built_in","start":"guide"}}
        """#)
        var expected = ControlMapping()
        expected.setOutput(.pad(.y), for: "g1")
        XCTAssertEqual(dirty, expected)
        XCTAssertEqual(dirty.outputs, ["g1": .pad(.y)], "entries equal to the default are normalised away")
        // The same file with the dirt removed gives the same mapping and the same bytes.
        var cleanOnlyOutputs = ControlMapping()
        cleanOnlyOutputs.outputs = clean.outputs
        XCTAssertEqual(try encoded(dirty), try encoded(cleanOnlyOutputs))
        // outputs of the wrong shape does not fail the file either.
        XCTAssertEqual(try decode(#"{"buttons":{},"outputs":["a"]}"#), ControlMapping())
        XCTAssertEqual(try decode(#"{"buttons":{},"outputs":null}"#), ControlMapping())
    }

    func testBuiltInOnlyOnG2ToG4() {
        var m = ControlMapping()
        for id in ControlMapping.remappableIDs where !["g2", "g3", "g4"].contains(id) {
            m.setOutput(.builtIn, for: id)
            XCTAssertTrue(m.outputs.isEmpty, "built_in refused on \(id)")
        }
        m.setOutput(.nothing, for: "g2")
        XCTAssertEqual(m.effectiveOutput("g2"), .nothing)
        m.setOutput(.builtIn, for: "g2")
        XCTAssertFalse(m.isRemapped("g2"), "built_in is g2's default")
        m.setOutput(.pad(.a), for: "g4")
        m.setOutput(.builtIn, for: "g4")
        XCTAssertNil(m.outputs["g4"])
    }

    func testSetOutputNormalisesAndIgnoresUnknownIDs() {
        var m = ControlMapping()
        m.setOutput(.pad(.x), for: "y")
        XCTAssertTrue(m.isRemapped("y"))
        m.setOutput(.pad(.y), for: "y")
        XCTAssertFalse(m.isRemapped("y"), "setting the default removes the key")
        XCTAssertTrue(m.outputs.isEmpty)
        m.setOutput(.nothing, for: "g1")
        XCTAssertTrue(m.outputs.isEmpty)
        m.setOutput(.pad(.guide), for: "start")
        XCTAssertTrue(m.outputs.isEmpty)
        for id in ["left_stick", "paddle_outer_left", "sax_left", "nope", "guide"] {
            m.setOutput(.pad(.a), for: id)
        }
        XCTAssertTrue(m.outputs.isEmpty)
        m.setOutput(.pad(.a), for: "g1")
        m.setOutput(.nothing, for: "b")
        XCTAssertEqual(m.outputs.count, 2)
        m.resetAllOutputs()
        XCTAssertTrue(m.outputs.isEmpty)
    }

    func testEffectiveOutputTable() {
        let m = ControlMapping()
        XCTAssertEqual(ControlMapping.remappableIDs.count, 23)
        XCTAssertEqual(Set(ControlMapping.remappableIDs).count, 23)
        let padNamed = ["a", "b", "x", "y", "lb", "rb", "lt", "rt", "view", "menu", "l3", "r3",
                        "dpad_up", "dpad_right", "dpad_down", "dpad_left"]
        for id in padNamed { XCTAssertEqual(m.effectiveOutput(id), .pad(PadOutput(rawValue: id)!), id) }
        XCTAssertEqual(m.effectiveOutput("start"), .pad(.guide))
        for id in ["g1", "g5", "profile"] { XCTAssertEqual(m.effectiveOutput(id), .nothing, id) }
        for id in ["g2", "g3", "g4"] { XCTAssertEqual(m.effectiveOutput(id), .builtIn, id) }
        XCTAssertEqual(padNamed.count + 1 + 3 + 3, 23)
        for id in ["paddle_outer_left", "sax_right", "left_stick", "right_stick", "stray", "guide"] {
            XCTAssertEqual(m.effectiveOutput(id), .nothing, id)
        }
        // A stray key in `outputs` cannot change an id outside the list.
        var stray = ControlMapping()
        stray.outputs["paddle_outer_left"] = .pad(.a)
        XCTAssertEqual(stray.effectiveOutput("paddle_outer_left"), .nothing)
    }

    func testSourcesOrdering() {
        var m = ControlMapping()
        XCTAssertEqual(m.sources(of: .y), ["y"])
        XCTAssertEqual(m.sources(of: .guide), ["start"])
        XCTAssertEqual(m.sources(of: .lt), ["lt"])
        m.setOutput(.pad(.y), for: "g1")
        m.setOutput(.pad(.y), for: "a")
        XCTAssertEqual(m.sources(of: .y), ["y", "a", "g1"], "owner first, then list order")
        XCTAssertEqual(m.sources(of: .a), [])
        m.setOutput(.pad(.guide), for: "g5")
        m.setOutput(.pad(.guide), for: "b")
        XCTAssertEqual(m.sources(of: .guide), ["start", "b", "g5"])
        m.setOutput(.nothing, for: "start")
        XCTAssertEqual(m.sources(of: .guide), ["b", "g5"], "a remapped-away owner is not a source")
        m.setOutput(.pad(.rt), for: "lt")
        XCTAssertEqual(m.sources(of: .rt), ["rt", "lt"])
        XCTAssertEqual(m.sources(of: .lt), [])
    }

    func testApplyLeavesOutputsAlone() {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        let before = m.outputs
        m.apply(LearnAssignment(controlId: "g1", target: .whole, binding: .button(20), physicalBits: 0))
        m.apply(LearnAssignment(controlId: "paddle_outer_left", target: .whole, binding: .hat(6), physicalBits: 2))
        m.apply(LearnAssignment(controlId: "left_stick", target: .stickHorizontal, binding: .axis("x", sign: 1), physicalBits: 0))
        XCTAssertEqual(m.outputs, before)
        XCTAssertEqual(m.buttons["g1"], .button(20))
    }

    func testLearnConflict() {
        let m = ControlMapping.default
        // Re-learning A and D-pad up as today: the SAX / paddle echoes carry physical bits, so they are not owners.
        XCTAssertNil(m.learnConflict(LearnAssignment(controlId: "a", target: .whole, binding: .button(1), physicalBits: 0)))
        XCTAssertNil(m.learnConflict(LearnAssignment(controlId: "dpad_up", target: .whole, binding: .hat(0), physicalBits: 0)))
        // G1 learned as Y's button is refused and names Y.
        XCTAssertEqual(m.learnConflict(LearnAssignment(controlId: "g1", target: .whole, binding: .button(4), physicalBits: 0)), "y")
        // A paddle learned without its bits is refused (the D-pad owns the hat).
        XCTAssertEqual(m.learnConflict(LearnAssignment(controlId: "paddle_outer_left", target: .whole, binding: .hat(6), physicalBits: 0)), "dpad_left")
        // With its bits it is a real paddle learn.
        XCTAssertNil(m.learnConflict(LearnAssignment(controlId: "paddle_outer_left", target: .whole, binding: .hat(6), physicalBits: 8)))
        // A fresh binding, no binding, other targets: nothing to refuse.
        XCTAssertNil(m.learnConflict(LearnAssignment(controlId: "g1", target: .whole, binding: .button(30), physicalBits: 0)))
        XCTAssertNil(m.learnConflict(LearnAssignment(controlId: "g1", target: .whole, binding: nil, physicalBits: 0)))
        XCTAssertNil(m.learnConflict(LearnAssignment(controlId: "left_stick", target: .stickHorizontal, binding: .button(4), physicalBits: 0)))
        // Lowest id wins when two controls share the binding.
        var two = ControlMapping()
        two.buttons["m"] = .button(9)
        two.buttons["c"] = .button(9)
        XCTAssertEqual(two.learnConflict(LearnAssignment(controlId: "z", target: .whole, binding: .button(9), physicalBits: 0)), "c")
    }

    func testLearnGuardLeavesCrosswiseOrdinaryButtonsRepairable() {
        var m = ControlMapping.default
        m.buttons["a"] = .button(2); m.buttons["b"] = .button(1)        // learned crosswise by a slip
        XCTAssertNil(m.learnConflict(LearnAssignment(controlId: "a", target: .whole, binding: .button(1), physicalBits: 0)))
        XCTAssertNil(m.learnConflict(LearnAssignment(controlId: "b", target: .whole, binding: .button(2), physicalBits: 0)))
        XCTAssertEqual(m.learnConflict(LearnAssignment(controlId: "g1", target: .whole, binding: .button(4), physicalBits: 0)), "y")
    }
}

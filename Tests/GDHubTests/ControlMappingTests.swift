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

    func testBuiltInOnlyOnG2ToG4AndThePaddlesAndSaxKeys() {
        var m = ControlMapping()
        let valid = Set(["g2", "g3", "g4"] + ControlMapping.echoKeyIDs)
        XCTAssertEqual(ControlMapping.builtInIDs, valid)
        for id in ControlMapping.remappableIDs where !valid.contains(id) {
            m.setOutput(.builtIn, for: id)
            XCTAssertTrue(m.outputs.isEmpty, "built_in refused on \(id)")
        }
        for id in ControlMapping.echoKeyIDs {
            m.setOutput(.nothing, for: id)
            XCTAssertEqual(m.effectiveOutput(id), .nothing, id)
            m.setOutput(.builtIn, for: id)
            XCTAssertFalse(m.isRemapped(id), "built_in is \(id)'s default (what the controller's profile sends)")
        }
        XCTAssertTrue(m.outputs.isEmpty)
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
        for id in ["left_stick", "nope", "guide"] {
            m.setOutput(.pad(.a), for: id)
        }
        XCTAssertTrue(m.outputs.isEmpty)
        // A paddle or SAX key takes any pick; Nothing is a pick of its own (its default is "the controller's profile").
        m.setOutput(.pad(.a), for: "paddle_outer_left")
        m.setOutput(.nothing, for: "sax_left")
        XCTAssertEqual(m.outputs, ["paddle_outer_left": .pad(.a), "sax_left": .nothing])
        m.resetAllOutputs()
        m.setOutput(.pad(.a), for: "g1")
        m.setOutput(.nothing, for: "b")
        XCTAssertEqual(m.outputs.count, 2)
        m.resetAllOutputs()
        XCTAssertTrue(m.outputs.isEmpty)
    }

    func testEffectiveOutputTable() {
        let m = ControlMapping()
        XCTAssertEqual(ControlMapping.remappableIDs.count, 29)
        XCTAssertEqual(Set(ControlMapping.remappableIDs).count, 29)
        XCTAssertEqual(Array(ControlMapping.remappableIDs.suffix(6)), ["paddle_outer_right", "paddle_inner_right", "paddle_inner_left",
                                                                      "paddle_outer_left", "sax_left", "sax_right"],
                       "the six are appended, so the order of every older remap does not move")
        let padNamed = ["a", "b", "x", "y", "lb", "rb", "lt", "rt", "view", "menu", "l3", "r3",
                        "dpad_up", "dpad_right", "dpad_down", "dpad_left"]
        for id in padNamed { XCTAssertEqual(m.effectiveOutput(id), .pad(PadOutput(rawValue: id)!), id) }
        XCTAssertEqual(m.effectiveOutput("start"), .pad(.guide))
        for id in ["g1", "g5", "profile"] { XCTAssertEqual(m.effectiveOutput(id), .nothing, id) }
        for id in ["g2", "g3", "g4"] { XCTAssertEqual(m.effectiveOutput(id), .builtIn, id) }
        for id in ["paddle_outer_right", "paddle_inner_right", "paddle_inner_left", "paddle_outer_left", "sax_left", "sax_right"] {
            XCTAssertEqual(m.effectiveOutput(id), .builtIn, "\(id): what the controller's profile sends")
            XCTAssertEqual(m.defaultOutput(id), .builtIn, id)
        }
        XCTAssertEqual(padNamed.count + 1 + 3 + 3 + 6, 29)
        for id in ["left_stick", "right_stick", "stray", "guide"] {
            XCTAssertEqual(m.effectiveOutput(id), .nothing, id)
        }
        // A stray key in `outputs` cannot change an id outside the list.
        var stray = ControlMapping()
        stray.outputs["left_stick"] = .pad(.a)
        XCTAssertEqual(stray.effectiveOutput("left_stick"), .nothing)
    }

    func testThePaddlesAndSaxKeysAreStoredAndDecode() throws {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        m.setOutput(.nothing, for: "sax_left")
        let json = try encoded(m)
        XCTAssertTrue(json.contains(#""paddle_outer_right":"y""#))
        XCTAssertTrue(json.contains(#""sax_left":"nothing""#))
        XCTAssertEqual(try decode(json), m)
        // built_in on a paddle is its default and normalises away; unknown words are still dropped one by one.
        let dirty = try decode(#"{"buttons":{},"outputs":{"paddle_inner_left":"built_in","sax_right":"turbo","paddle_outer_left":"x"}}"#)
        XCTAssertEqual(dirty.outputs, ["paddle_outer_left": .pad(.x)])
        // The factory mapping stays free of remaps: no `outputs` key.
        XCTAssertFalse(try encoded(.default).contains("outputs"))
    }

    func testPaddlesAreSourcesOnlyWhenRemappedAndComeAfterTheOlderControls() {
        var m = ControlMapping.default
        XCTAssertEqual(m.sources(of: .dpad_right), ["dpad_right"], "a paddle on Controller's profile feeds nothing of its own")
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        m.setOutput(.pad(.y), for: "g1")
        m.setOutput(.pad(.y), for: "sax_left")
        XCTAssertEqual(m.sources(of: .y), ["y", "g1", "paddle_outer_right", "sax_left"], "owner first, then list order, the six last")
        m.setOutput(.nothing, for: "paddle_outer_right")
        XCTAssertEqual(m.sources(of: .y), ["y", "g1", "sax_left"])
        XCTAssertEqual(m.sources(of: .dpad_right), ["dpad_right"], "Nothing feeds nothing and does not take the D-pad's place")
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

    // MARK: Paddles and SAX keys by their own signal (remap step 2)

    private let sixIDs = ["paddle_outer_right", "paddle_inner_right", "paddle_inner_left", "paddle_outer_left", "sax_left", "sax_right"]

    func testIdentityBitsAreTheFixedTableAndZeroElsewhere() {
        let table: [String: UInt16] = ["paddle_outer_right": 1, "paddle_inner_right": 2, "paddle_inner_left": 4,
                                       "paddle_outer_left": 8, "sax_left": 16, "sax_right": 32]
        for (id, bits) in table { XCTAssertEqual(ControlMapping.default.identityBits(id), bits, id) }
        XCTAssertEqual(ControlMapping.echoKeyIDs, sixIDs)
        for id in ControlMapping.remappableIDs + ["left_stick", "guide", "stray"] where table[id] == nil {
            XCTAssertEqual(ControlMapping().identityBits(id), 0, id)
        }
    }

    func testAStoredPaddleBitThatDiffersFromTheTableIsNeverUsed() {
        var m = ControlMapping.default
        m.physicalBits["paddle_outer_right"] = 8         // a mis-learn: outer left's bit
        var f = GamepadFrame.idle
        f.extra = 8
        XCTAssertFalse(m.isActive("paddle_outer_right", f), "identity is the table's bit 1, not the stored 8")
        XCTAssertTrue(m.isActive("paddle_outer_left", f))
        f.extra = 1
        XCTAssertTrue(m.isActive("paddle_outer_right", f))
        // A mapping with no stored bits at all still knows the six by the table.
        var bare = ControlMapping()
        bare.buttons["sax_left"] = .button(1)
        XCTAssertTrue(bare.isActive("sax_left", { var g = GamepadFrame.idle; g.extra = 16; return g }()))
        XCTAssertFalse(bare.isActive("sax_left", { var g = GamepadFrame.idle; g.buttons = 1; return g }()))
        // Other controls still use their stored bits.
        var other = ControlMapping()
        other.physicalBits["g1"] = 64
        XCTAssertTrue(other.isActive("g1", { var g = GamepadFrame.idle; g.extra = 64; return g }()))
    }

    func testEchoHideMaskIsEveryKeyNotOnControllersProfileNothingIncluded() {
        var m = ControlMapping.default
        XCTAssertEqual(m.echoHideMask, 0)
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        XCTAssertEqual(m.echoHideMask, 0b000001)
        m.setOutput(.nothing, for: "sax_left")
        XCTAssertEqual(m.echoHideMask, 0b010001)
        m.setOutput(.pad(.a), for: "g1")
        m.setOutput(.pad(.b), for: "sax_right")
        XCTAssertEqual(m.echoHideMask, 0b110001, "other remaps do not count")
        for id in sixIDs { m.setOutput(.pad(.x), for: id) }
        XCTAssertEqual(m.echoHideMask, 0x3F)
        m.resetAllOutputs()
        XCTAssertEqual(m.echoHideMask, 0)
    }

    func testEchoItemReadsTheBindingAndFallsBackToTheFactoryItem() {
        let factory: [String: UInt8] = ["paddle_outer_right": 12, "paddle_inner_right": 13, "paddle_inner_left": 11,
                                        "paddle_outer_left": 14, "sax_left": 1, "sax_right": 2]
        var m = ControlMapping.default
        for (id, item) in factory { XCTAssertEqual(m.echoItem(id), item, id) }
        let table: [(Binding?, UInt8)] = [
            (.button(1), 1), (.button(4), 4), (.button(10), 10),       // receiver buttons 1...10
            (.hat(0), 11), (.hat(2), 12), (.hat(4), 13), (.hat(6), 14),
            (.hat(1), 0), (.hat(3), 0), (.hat(5), 0), (.hat(7), 0),    // a diagonal: the factory item
            (.trigger("lt"), 0), (.axis("x", sign: 1), 0), (.button(11), 0), (.button(19), 0), (.button(0), 0), (nil, 0),
        ]
        for (k, id) in sixIDs.enumerated() {
            for (binding, want) in table {
                m.buttons[id] = binding
                XCTAssertEqual(m.echoItem(id), want == 0 ? EchoParams.factoryItems[k] : want, "\(id) \(String(describing: binding))")
                XCTAssertNotEqual(m.echoItem(id), 0, "never none")
            }
        }
        for id in ["a", "g1", "left_stick", "dpad_up", "stray"] { XCTAssertEqual(m.echoItem(id), 0, id) }
    }

    func testEchoParamsOfTheDefaultMappingAndOfARemap() {
        XCTAssertEqual(ControlMapping.default.echoParams, EchoParams(hideMask: 0))
        XCTAssertEqual(ControlMapping.default.echoParams.items, [0, 0, 0, 0, 0, 0], "a key outside the mask has no item")
        var m = ControlMapping.default
        m.setOutput(.pad(.r3), for: "paddle_outer_right")
        m.setOutput(.nothing, for: "paddle_inner_left")
        m.buttons["paddle_inner_left"] = .button(3)
        let p = m.echoParams
        XCTAssertEqual(p.hideMask, 0b000101)
        XCTAssertEqual(p.items, [12, 0, 3, 0, 0, 0])
        for id in sixIDs { m.setOutput(.pad(.x), for: id) }
        XCTAssertEqual(m.echoParams, EchoParams(hideMask: 0x3F, items: [12, 13, 3, 14, 1, 2]))
    }

    func testTriggerFeedOfAPaddleIsFullScaleByItsBitsWhateverIsStored() {
        var m = ControlMapping.default
        m.setOutput(.pad(.rt), for: "paddle_inner_left")
        m.buttons["paddle_inner_left"] = .trigger("lt")             // a stray stored binding
        XCTAssertEqual(m.triggerFeed(from: "paddle_inner_left", into: .rt), .fullScale)
        m.setOutput(.pad(.lt), for: "sax_right")
        XCTAssertEqual(m.triggerFeed(from: "sax_right", into: .lt), .fullScale)
        // Every other source keeps today's order.
        m.setOutput(.pad(.lt), for: "g1")
        XCTAssertEqual(m.triggerFeed(from: "g1", into: .lt), .fullScale)
        XCTAssertEqual(m.triggerFeed(from: "lt", into: .lt), .analog("lt"))
        XCTAssertEqual(ControlMapping().triggerFeed(from: "lt", into: .lt), .nothing)
        // A stray learned bit on lt or rt never turns the analog trigger digital.
        var stray = ControlMapping.default
        stray.physicalBits["lt"] = 1; stray.physicalBits["rt"] = 0x20
        XCTAssertEqual(stray.triggerFeed(from: "lt", into: .lt), .analog("lt"))
        XCTAssertEqual(stray.triggerFeed(from: "rt", into: .rt), .analog("rt"))
    }

    func testLearnConflictNeverNamesAPaddleOrSaxKeyAsOwner() {
        var m = ControlMapping.default
        m.buttons["sax_left"] = .button(3)
        m.physicalBits["sax_left"] = nil                              // stored as button 3 with no bits
        m.buttons["x"] = .button(30)                                  // so X is not the owner of button 3
        XCTAssertEqual(m.learnConflict(LearnAssignment(controlId: "g1", target: .whole, binding: .button(3), physicalBits: 0)), nil,
                       "SAX left is never an owner")
        m.buttons["x"] = .button(3)
        XCTAssertEqual(m.learnConflict(LearnAssignment(controlId: "g1", target: .whole, binding: .button(3), physicalBits: 0)), "x")
    }

    func testLearnSignalOwnerNamesTheOtherKey() {
        let m = ControlMapping.default
        func a(_ id: String, bits: UInt16) -> LearnAssignment { LearnAssignment(controlId: id, target: .whole, binding: .hat(2), physicalBits: bits) }
        XCTAssertNil(m.learnSignalOwner(a("paddle_outer_right", bits: 1)), "its own bit")
        XCTAssertEqual(m.learnSignalOwner(a("paddle_outer_right", bits: 8)), "paddle_outer_left")
        XCTAssertEqual(m.learnSignalOwner(a("sax_right", bits: 16)), "sax_left")
        XCTAssertNil(m.learnSignalOwner(a("sax_right", bits: 0)), "no extra bit at all: not this refusal")
        XCTAssertNil(m.learnSignalOwner(a("sax_right", bits: 64)), "a bit no key owns cannot be named")
        XCTAssertNil(m.learnSignalOwner(a("g1", bits: 8)), "only the six")
    }

    func testSignalConflictNamesTheOldLearnOfAnotherControl() {
        func label(_ id: String) -> String {
            ["g1": "G1", "a": "A", "paddle_outer_right": "Paddle outer right", "sax_left": "SAX left"][id] ?? id
        }
        var m = ControlMapping.default
        m.physicalBits["a"] = 1                                       // A was learned with paddle outer right's signal
        XCTAssertNil(m.signalConflict(label: label), "the paddle is not remapped: nothing to hide, no conflict")
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        XCTAssertEqual(m.signalConflict(label: label), "A was learned with Paddle outer right's signal: re-learn A.")
        m.setOutput(.builtIn, for: "paddle_outer_right")
        XCTAssertNil(m.signalConflict(label: label))
        m.setOutput(.nothing, for: "sax_left")
        XCTAssertNil(m.signalConflict(label: label), "A's bit is not SAX left's")
        m.physicalBits["g1"] = 16
        XCTAssertEqual(m.signalConflict(label: label), "G1 was learned with SAX left's signal: re-learn G1.")
        // The same on every driver build: no limit text from it.
        XCTAssertNil(MapBlobEncoder.remapLimit(m)?.range(of: "re-learn"))
    }
}

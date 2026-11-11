import XCTest
@testable import GDHub

/// The echo rule on scripted sequences (docs/plans/remap-step2-plan.md, "Tests", V1-V27, their Swift halves). Every
/// sequence starts with a report at rest; the controller model is `EchoSim`; factory stored items and factory echoes unless
/// a case says otherwise. The Python oracle `scripts/tools/echo_rule.py` runs the same rule (its tests pin the same cases);
/// V25 (the exhaustive search) lives there only. The C halves come with S5.
final class EchoFilterTests: XCTestCase {
    private typealias S = EchoSim
    private let factory = EchoParams.factoryItems
    private let all = S.keyNames

    private func flags(_ rows: [S.Row], _ mask: UInt32) -> [Bool] { rows.dropFirst().map { $0.word & mask != 0 } }

    private func assertNoGhost(_ rows: [S.Row], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        for (i, r) in rows.enumerated() where r.ghost {
            XCTFail("\(name): ghost at report \(i): pad \(S.text(r.pad)), allowed \(S.text(r.hold))", file: file, line: line)
        }
    }

    // MARK: parameters and state

    func testParamsKeepAKeyInTheMaskCoveringSomething() {
        XCTAssertEqual(EchoParams.factoryItems, [12, 13, 11, 14, 1, 2])
        let p = EchoParams(hideMask: 0x41, items: [0, 5, 6])                     // bit 6 is not a key; a short list
        XCTAssertEqual(p.hideMask, 0x01)
        XCTAssertEqual(p.items, [12, 0, 0, 0, 0, 0], "a key in the mask with code 0 gets its factory item, keys outside get 0")
        XCTAssertEqual(EchoParams(hideMask: 0x3F, items: [15, 99, 0, 3, 14, 1]).items, [12, 13, 11, 3, 14, 1])
        XCTAssertEqual(EchoParams(hideMask: 0x02, items: [1, 7, 1, 1, 1, 1]), EchoParams(hideMask: 0x02, items: [9, 7]))
        XCTAssertEqual(EchoParams.none.hideMask, 0)
        XCTAssertEqual(EchoParams.factory(hideMask: 0x3D).items, [12, 0, 11, 14, 1, 2], "row 11's set: paddle inner right is outside the mask")
    }

    func testAFreshStateIs16ZeroBytesAndBytesFollowThePlansLayout() {
        var s = EchoState()
        XCTAssertEqual(s.bytes, [UInt8](repeating: 0, count: 16))
        let p = EchoParams.factory(hideMask: 0x01)
        XCTAssertEqual(s.step(p, buttons: 0, hat: 8, extra: 0), 0)
        let w = s.step(p, buttons: 0, hat: 2, extra: 1)
        XCTAssertEqual(w, EchoFilter.wordApplied | EchoFilter.wordArmed | 1 << 16 | 8 << 10, "held key 0, the hat cleaned to none")
        XCTAssertEqual(s.bytes, [0, 0, 0x00, 0x08, 1, 1, 1, 3, 12, 0, 0, 0, 0, 0, 0, 0])
        s.reset()
        XCTAssertEqual(s, EchoState())
    }

    func testAReportThatIsNotASixteenByteReport6PassesUnchangedAndLeavesTheState() {
        var s = EchoState()
        let p = EchoParams.factory(hideMask: 0x3F)
        _ = s.step(p, report: S.report(buttons: 0, hat: 8, extra: 0))
        let before = s
        XCTAssertEqual(s.step(p, report: [6, 0, 0]), 0)
        XCTAssertEqual(s.step(p, report: [UInt8](repeating: 0, count: 16)), 0, "report id 0")
        XCTAssertEqual(s, before)
        XCTAssertEqual(EchoFilter.apply(EchoFilter.wordApplied | 5, to: [6, 0, 0]), [6, 0, 0])
    }

    func testApplyChangesOnlyButtons1To10AndTheHatNibble() {
        let raw: [UInt8] = [6, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0x2F, 0xFF, 0xFF, 0xFF, 0xFF]
        let word = EchoFilter.wordApplied | 0b10_1010_1010 | 3 << 10
        let out = EchoFilter.apply(word, to: raw)
        XCTAssertEqual(Array(out[0..<11]), Array(raw[0..<11]))
        XCTAssertEqual(out[11], 0x3F, "hat nibble 3, the low nibble stays")
        XCTAssertEqual(out[12], 0xAA)
        XCTAssertEqual(out[13], 0xFE, "bits 0-1 of byte 13 are buttons 9 and 10; the other bits stay")
        XCTAssertEqual(Array(out[14...]), Array(raw[14...]))
        XCTAssertEqual(EchoFilter.apply(0, to: raw), raw, "a word of 0 gives the bytes unchanged")
        XCTAssertEqual(EchoFilter.apply(5 | 3 << 10, to: raw), raw, "without bit 31 nothing is applied")
    }

    func testChangedReadsAPressPerAxis() {
        let (u, r, d, l) = (S.up, S.right, S.down, S.left)
        XCTAssertEqual(EchoFilter.changed(0, r), r)
        XCTAssertEqual(EchoFilter.changed(l, 0), r, "a cancel counts as the opposite direction")
        XCTAssertEqual(EchoFilter.changed(l, r), r, "a straight move from n to p counts as p")
        XCTAssertEqual(EchoFilter.changed(r, l), l)
        XCTAssertEqual(EchoFilter.changed(u, 0), d)
        XCTAssertEqual(EchoFilter.changed(0b1, 0b11), 0b10)
        XCTAssertEqual(EchoFilter.changed(r, r), 0)
        XCTAssertEqual(EchoFilter.changed(0, u | r), u | r)
        XCTAssertEqual((0..<16).map { EchoFilter.itemsHat[$0] }, [8, 0, 2, 1, 4, 8, 3, 2, 6, 7, 8, 0, 5, 6, 4, 8])
    }

    // MARK: V1 - V7

    func testV1EachOfTheSixAloneOnlyThePickReachesThePad() {
        for key in all {
            for script in [["+\(key)", ".", "-\(key)"], ["+\(key)", "-\(key)"]] {
                let rows = S.run(script, hidden: [key])
                XCTAssertEqual(S.pads(rows), [String](repeating: "hat:.", count: script.count), key)
                XCTAssertEqual(flags(rows, EchoFilter.pressFlags), [Bool](repeating: false, count: script.count), "\(key): OTHER and UNCONFIRMED never set")
                assertNoGhost(rows, key)
            }
        }
        // the key's bit is still in the extra bits, so its own rule fires: the raw report keeps it
        let rows = S.run(["+OR"], hidden: ["OR"])
        XCTAssertEqual(rows[1].keys, 1)
    }

    func testV2ARealButtonPressedInsideAHiddenKeysHold() {
        var rows = S.run(["+SL", "+A", "-A", "-SL"], hidden: ["SL"])
        XCTAssertEqual(S.pads(rows), ["hat:.", "hat:.", "hat:.", "hat:."], "pressed and let go inside: never shown")
        rows = S.run(["+SL", "+A", "-SL", "-A"], hidden: ["SL"])
        XCTAssertEqual(S.pads(rows), ["hat:.", "hat:.", "A+hat:.", "hat:."], "still held at the release: shown from the release report")
    }

    func testV3AHeldThenSaxLeftTappedKeepsAWithoutABreak() {
        var rows = S.run(["+A", "+SL", ".", "-SL", "-A"], hidden: ["SL"])
        XCTAssertEqual(S.pads(rows), ["A+hat:.", "A+hat:.", "A+hat:.", "A+hat:.", "hat:."])
        rows = S.run(["+A", "+SL", "-A", "-SL"], hidden: ["SL"])
        XCTAssertEqual(S.pads(rows), ["A+hat:.", "A+hat:.", "A+hat:.", "hat:."], "A let go during the hold stays until the release (the limit)")
    }

    func testV4UpHeldThroughPaddleInnerRightAndThePaddleFirstOrder() {
        var rows = S.run(["+up", "+IR", ".", "-IR", "-up"], hidden: ["IR"])
        XCTAssertEqual(S.hats(rows), ["U", "U", "U", "U", "."], "the S2 gate case: up on every report")
        XCTAssertEqual(flags(rows, EchoFilter.wordRecovered), [false, true, true, false, false])
        rows = S.run(["+IR", "+up", "-up", "+up", "-up", "-IR"], hidden: ["IR"])
        XCTAssertEqual(S.hats(rows), [".", "U", ".", "U", ".", "."], "paddle held first, up pressed twice: up twice")
        XCTAssertEqual(flags(rows, EchoFilter.wordRecovered), [false, true, false, true, false, false])
        assertNoGhost(rows, "V4")
    }

    func testV5TheOppositeCancelForAllFourPaddlesInBothOrders() {
        for (key, dir, letter) in [("OR", "left", "L"), ("IR", "up", "U"), ("IL", "down", "D"), ("OL", "right", "R")] {
            var rows = S.run(["+\(key)", "+\(dir)", "-\(dir)", "+\(dir)", "-\(dir)", "-\(key)"], hidden: [key])
            XCTAssertEqual(S.hats(rows), [".", letter, ".", letter, ".", "."], "\(key) first, \(dir) twice")
            assertNoGhost(rows, key)
            rows = S.run(["+\(dir)", "+\(key)", "-\(key)", "+\(key)", "-\(key)", "-\(dir)"], hidden: [key])
            XCTAssertEqual(S.hats(rows), [letter, letter, letter, letter, letter, "."], "\(dir) first, \(key) twice")
            XCTAssertTrue(rows[2].word & EchoFilter.wordRecovered != 0 && rows[4].word & EchoFilter.wordRecovered != 0, key)
            assertNoGhost(rows, key)
        }
    }

    func testV6Neighbours() {
        var rows = S.run(["+up", "+OR", ".", "-OR", "-up"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["U", "U", "U", "U", "."], "real up + paddle outer right: up")
        rows = S.run(["+OR +IR", "+up", "-up", "+left", "-left", "-OR -IR"], hidden: ["OR", "IR"])
        XCTAssertEqual(S.hats(rows), [".", "U", ".", "L", ".", "."], "outer right and inner right hidden: real up, then real left")
        rows = S.run(["+up +left", "+OR", ".", "-OR", "-up -left"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["UL", "UL", "UL", "UL", "."], "a real up+left with outer right: up+left")
    }

    func testV7TheKeysOwnDirectionDuringTheHold() {
        var rows = S.run(["+OR", "+right", "-right", "-OR"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), [".", ".", ".", "."], "pressed during the hold and let go inside: hidden")
        rows = S.run(["+OR", "+right", "-OR", "-right"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), [".", ".", "R", "."], "still held at the release: shown at the release")
        rows = S.run(["+right", "+OR", ".", "-OR", "-right"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["R", "R", "R", "R", "."], "held from before: kept")
        rows = S.run(["+right", "+OR -right", ".", "-OR"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["R", "R", "R", "."], "let go in the very report of the press: kept until the release")
        rows = S.run(["+right", "+OR", "-right +left", "-left", "-OR"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["R", "R", ".", "R", "."], "rocked to the opposite: none, then the old direction until the release")
    }

    // MARK: V8 - V10

    func testV8BothOuterPaddlesFreezeTheLeftRightAxis() {
        var rows = S.run(["+left", "+OR +OL", "+up", "-up", "-OR -OL", "-left"], hidden: ["OR", "OL"])
        XCTAssertEqual(S.hats(rows), ["L", "L", "UL", "L", "L", "."], "left held from before stays, up passes")
        rows = S.run(["+OR +OL", ".", "-OR -OL"], hidden: ["OR", "OL"])
        XCTAssertEqual(S.hats(rows), [".", ".", "."], "the pair in one report: none (pins Q10)")
        rows = S.run(["+OR", "+OL", "+up", "-up", "-OL", "-OR"], hidden: ["OR", "OL"])
        XCTAssertEqual(S.hats(rows), [".", ".", "U", ".", ".", "."], "one after the other: the same")
        assertNoGhost(rows, "V8")
    }

    func testV9OneOfAPairHiddenTheOtherUntouched() {
        var rows = S.run(["+OR", "+OL", ".", "-OL", "-OR"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), [".", "L", "L", ".", "."], "pressed one after the other and held: outer left's left shows")
        rows = S.run(["+OL", "+OR", ".", "-OR", "-OL"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["L", "L", "L", "L", "."])
        rows = S.run(["+right", "+OL", ".", "-OL", "-right"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["R", ".", ".", "R", "."], "real right held from before: none (the controller's own cancel)")
        rows = S.run(["+OR +OL", ".", "-OR", "-OL"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), [".", ".", "L", "."], "the two in one report: outer left's left shows only at outer right's release (the limit)")
        XCTAssertTrue(rows[1].word & EchoFilter.wordUnconfirmed != 0)
    }

    func testV10AnUntouchedPaddleOnTheOtherAxisPasses() {
        var rows = S.run(["+OR", "+IR", ".", "-IR", "-OR"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), [".", "D", "D", ".", "."], "outer right hidden, inner right untouched: down passes")
        rows = S.run(["+IR", "+OR", ".", "-OR", "-IR"], hidden: ["IR"])
        XCTAssertEqual(S.hats(rows), [".", "R", "R", ".", "."], "and the reverse: right passes")
    }

    // MARK: V11 - V13

    func testV11AnotherItemAtThePressIsHiddenTogetherWithTheStoredOne() {
        let alternatives: [(String, UInt16)] = [("Y", 8), ("A", 1), ("X", 4), ("B", 2), ("LB", 16), ("RB", 32), ("up", S.up), ("down", S.down), ("left", S.left)]
        for (name, echo) in alternatives {
            var echoes = S.factoryEchoes
            echoes[0] = echo
            var rows = S.run(["+OR", "+right", "-OR", "-right"], hidden: ["OR"], echoes: echoes)
            XCTAssertEqual(S.hats(rows), [".", ".", "R", "."], "the controller now adds \(name): a real right pressed during the hold shows at the release")
            XCTAssertEqual(flags(rows, EchoFilter.wordOther), [true, false, false, false], name)
            XCTAssertEqual(S.pads(rows).filter { $0 != "hat:." && $0 != "hat:R" }, [], "\(name) never shows")
            rows = S.run(["+OR", "-OR", "E=OR:right", "+OR", "-OR"], hidden: ["OR"], echoes: echoes)
            XCTAssertEqual(flags(rows, EchoFilter.wordOther), [true, false, false, false, false], "the next hold with the stored item: no OTHER (\(name))")
        }
    }

    func testV12TheItemAlreadyOnAtThePressStaysConfirmed() {
        var rows = S.run(["+up", "+IL", ".", "-IL", "-up"], hidden: ["IL"])
        XCTAssertEqual(S.hats(rows), ["U", "U", "U", "U", "."])
        rows = S.run(["+A", "+SL", ".", "-SL", "-A"], hidden: ["SL"])
        XCTAssertEqual(S.pads(rows), ["A+hat:.", "A+hat:.", "A+hat:.", "A+hat:.", "hat:."])
        // plus one other change in the press report
        let cases: [(String, [String], String, [String])] = [
            ("real right held, outer right + Y: Y passes at once", ["+right", "+OR +Y", "-Y", "-right", "-OR"], "OR",
             ["hat:R", "Y+hat:R", "hat:R", "hat:R", "hat:."]),
            ("real A held, SAX left + X: X passes", ["+A", "+SL +X", "-X", "-SL", "-A"], "SL",
             ["A+hat:.", "A+X+hat:.", "A+hat:.", "A+hat:.", "hat:."]),
            ("A and up held, SAX left as up is let go: up gone, no D-pad up, no recovery", ["+A +up", "+SL -up", ".", "-SL", "-A"], "SL",
             ["A+hat:U", "A+hat:.", "A+hat:.", "A+hat:.", "hat:."]),
            ("real right held, outer right + up, then up let go: right only, no D-pad down", ["+right", "+OR +up", "-up", "-OR", "-right"], "OR",
             ["hat:R", "hat:UR", "hat:R", "hat:R", "hat:."]),
            ("up held, inner left + right: right passes, no D-pad left after it", ["+up", "+IL +right", "-right", "-IL", "-up"], "IL",
             ["hat:U", "hat:UR", "hat:U", "hat:U", "hat:."]),
            ("down held, inner right + left: left passes", ["+down", "+IR +left", "-left", "-IR", "-down"], "IR",
             ["hat:D", "hat:DL", "hat:D", "hat:D", "hat:."]),
            ("A held, SAX left + up: up passes, no D-pad down after it", ["+A", "+SL +up", "-up", "-SL", "-A"], "SL",
             ["A+hat:.", "A+hat:U", "A+hat:.", "A+hat:.", "hat:."]),
            ("up+right held, outer right as up is let go: right", ["+up +right", "+OR -up", ".", "-OR", "-right"], "OR",
             ["hat:UR", "hat:R", "hat:R", "hat:R", "hat:."]),
        ]
        for (name, script, key, expect) in cases {
            let rows = S.run(script, hidden: [key])
            XCTAssertEqual(S.pads(rows), expect, name)
            assertNoGhost(rows, name)
            XCTAssertEqual(flags(rows, EchoFilter.pressFlags), [Bool](repeating: false, count: script.count), "\(name): neither OTHER nor UNCONFIRMED")
        }
    }

    func testV12bAProfileChangeWithTheKeysNewOrOldButtonAlreadyOnAtThePress() {
        var echoes = S.factoryEchoes
        echoes[0] = 1                                                            // outer right now adds A; stored D-pad right
        var rows = S.run(["+A", "+OR", "+right", "-right", "-OR", "-A"], hidden: ["OR"], echoes: echoes)
        XCTAssertEqual(S.pads(rows), ["A+hat:.", "A+hat:.", "A+hat:.", "A+hat:.", "A+hat:.", "hat:."], "A stays until the release; a real right during the hold never shown")
        XCTAssertTrue(rows[2].word & EchoFilter.wordUnconfirmed != 0)
        assertNoGhost(rows, "stored right, now A")
        echoes = S.factoryEchoes
        echoes[4] = 4                                                            // SAX left now adds X; stored A
        rows = S.run(["+A +X", "+SL", ".", "-A", "-SL", "-X"], hidden: ["SL"], stored: factory, echoes: echoes)
        XCTAssertEqual(S.pads(rows), ["A+X+hat:.", "A+X+hat:.", "A+X+hat:.", "A+X+hat:.", "X+hat:.", "hat:."], "A and X stay until the release")
        echoes = S.factoryEchoes
        echoes[0] = S.up                                                         // outer right now adds up; stored right; right held first
        rows = S.run(["+right", "+OR", ".", "+left", "-left", "-OR", "-right"], hidden: ["OR"], echoes: echoes)
        XCTAssertEqual(S.hats(rows), ["R", "UR", "UR", "U", "UR", "R", "."], "up shows for the hold, right while it is held, no other direction")
        echoes = S.factoryEchoes
        echoes[4] = 4
        rows = S.run(["+A", "+SL", ".", "-SL", "-A"], hidden: ["SL"], echoes: echoes)
        XCTAssertEqual(S.pads(rows), ["A+hat:.", "A+X+hat:.", "A+X+hat:.", "A+hat:.", "hat:."], "X shows for the hold, A stays")
    }

    func testV13UnconfirmedPresses() {
        var rows = S.run(["+OR +OL", "+up", "-up", "-OR -OL"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), [".", "U", ".", "."], "two of the six in one report: covered only, no direction worked out")
        XCTAssertEqual(flags(rows, EchoFilter.wordUnconfirmed), [true, false, false, false])
        XCTAssertEqual(flags(rows, EchoFilter.wordRecovered), [false, false, false, false])
        var echoes = S.factoryEchoes
        echoes[4] = 4                                                            // stored A, now X; SAX left + Y in the press report
        rows = S.run(["+SL +Y", "-Y", "-SL"], hidden: ["SL"], echoes: echoes)
        XCTAssertEqual(S.pads(rows), ["X+Y+hat:.", "X+hat:.", "hat:."], "X shows for the hold (Q11 c)")
        XCTAssertEqual(flags(rows, EchoFilter.wordUnconfirmed), [true, false, false])
        // no ghost on any later report of the hold when the stored items are right
        rows = S.run(["+up", "+OR +IR", ".", "-OR -IR"], hidden: ["OR", "IR"])
        assertNoGhost(rows, "two keys, up held")
        XCTAssertEqual(S.hats(rows), ["U", "U", "U", "U"])
    }

    // MARK: V14, V15

    func testV14AResetAtEveryReportOfAHold() {
        for n in 1...4 {
            var script = ["+OR", ".", ".", ".", ".", "-OR"]
            script[n] += " reset"
            let rows = S.run(script, hidden: ["OR"])
            XCTAssertEqual(S.hats(rows), [String](repeating: ".", count: 6), "reset at report \(n): the stored item is covered from the first report on")
            XCTAssertEqual(rows[n + 1].word & EchoFilter.wordArmed, 0, "ARMED is clear until a report with no hidden key held")
            XCTAssertEqual(rows[6].word, 0)
        }
        var rows = S.run(["+A +right", "+OR", "reset", ".", "-OR", "-A -right"], hidden: ["OR"])
        XCTAssertEqual(S.pads(rows), ["A+hat:R", "A+hat:R", "A+hat:.", "A+hat:.", "A+hat:R", "hat:."], "a covered real item held from before drops until the release")
        rows = S.run(["+left", "+OR", "reset", ".", "-OR", "-left"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["L", "L", ".", ".", "L", "."], "a real opposite direction held shows at the release")
        XCTAssertTrue(rows[3].word & EchoFilter.wordUnconfirmed != 0)
        XCTAssertEqual(rows[3].word & EchoFilter.wordArmed, 0)
        // with the actual echo other than the stored one (pins Q11 d)
        var echoes = S.factoryEchoes
        echoes[0] = S.itemTokens["Y"]!
        rows = S.run(["+OR", "reset", ".", "-OR"], hidden: ["OR"], echoes: echoes)
        XCTAssertEqual(S.pads(rows), ["hat:.", "Y+hat:.", "Y+hat:.", "hat:."], "the new button shows until the release and UNCONFIRMED is set")
        XCTAssertTrue(rows[2].word & EchoFilter.wordUnconfirmed != 0)
        echoes[0] = S.left
        rows = S.run(["+OR", "reset", "+right", "-right", "-OR"], hidden: ["OR"], echoes: echoes)
        XCTAssertEqual(S.hats(rows), [".", "L", ".", "L", "."], "outer right now adds left, a real right during the hold shows nothing")
        // the same holds with the state kept (the :564 site, no reset): the new button stays hidden for the whole hold
        echoes[0] = S.itemTokens["Y"]!
        rows = S.run(["+OR", "reset", ".", "-OR"], hidden: ["OR"], echoes: echoes, keepResets: true)
        XCTAssertEqual(S.pads(rows), ["hat:.", "hat:.", "hat:.", "hat:."])
    }

    func testV15ARealOppositeDirectionPressedInTheVerySameReportAsThePaddle() {
        var rows = S.run(["+OR +left", ".", "-OR", "-left"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), [".", ".", "L", "."], "shown at the release (the limit)")
        rows = S.run(["+OR +A", "-A", "-OR"], hidden: ["OR"])
        XCTAssertEqual(S.pads(rows), ["A+hat:.", "hat:.", "hat:."], "another button in that report passes at once")
        rows = S.run(["+left", "+OR -left", "+left", "-left", "-OR"], hidden: ["OR"])
        XCTAssertEqual(S.hats(rows), ["L", ".", "L", ".", "."], "the opposite let go in the press report and pressed again: seen, shown at once")
        XCTAssertTrue(rows[3].word & EchoFilter.wordRecovered != 0)
        XCTAssertEqual(flags(rows, EchoFilter.wordUnconfirmed), [false, false, false, false, false])
        rows = S.run(["+up", "+IR -up", "+up", "-up", "-IR"], hidden: ["IR"])
        XCTAssertEqual(S.hats(rows), ["U", ".", "U", ".", "."])
        XCTAssertTrue(rows[3].word & EchoFilter.wordRecovered != 0)
        XCTAssertEqual(flags(rows, EchoFilter.wordUnconfirmed), [false, false, false, false, false])
    }

    // MARK: V16 - V19

    func testV16FieldsTheRuleNeverTouchesAreByteForByteTheSame() {
        // Start (button 11), G1-G5 (12-16), Profile (17), buttons 18-19, both triggers and four stick fields set in every report
        let others: UInt32 = (1 << 10) | (0x1F << 11) | (1 << 16) | (3 << 17)
        let triggers: UInt32 = 0x3FF | 0x2AA << 10
        let sticks: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
        let p = EchoParams.factory(hideMask: 0x3F)
        var s = EchoState()
        let seq: [(UInt32, UInt8, UInt16)] = [(0, 8, 0), (0, 2, 1), (0, 2, 1), (4, 2, 1), (0, 8, 0), (0, 4, 2), (0, 4, 2), (0, 8, 0)]
        for (i, (b, hat, extra)) in seq.enumerated() {
            let raw = S.report(buttons: b | others, hat: hat, extra: extra, sticks: sticks, triggers: triggers)
            let w = s.step(p, report: raw)
            let out = EchoFilter.apply(w, to: raw)
            XCTAssertEqual(Array(out[0..<11]), Array(raw[0..<11]), "report type, sticks and triggers: report \(i)")
            XCTAssertEqual(out[11] & 0x0F, raw[11] & 0x0F, "report \(i)")
            XCTAssertEqual(out[13] & 0xFC, raw[13] & 0xFC, "buttons 11-16 (Start, G keys): report \(i)")
            XCTAssertEqual(out[14], raw[14], "Profile and buttons 18-19, the first extra bits: report \(i)")
            XCTAssertEqual(out[15], raw[15], "extra bits: report \(i)")
        }
    }

    func testV17ProfilePressedAndLetGoDuringAHoldChangesNothingElse() {
        let p = EchoParams.factory(hideMask: 0x01)
        func cleaned(withProfile: Bool) -> [UInt32] {
            var s = EchoState()
            let profile: UInt32 = withProfile ? 1 << 16 : 0
            return [(0, 8, 0), (0, 2, 1), (profile, 2, 1), (profile, 2, 1), (0, 2, 1), (0, 8, 0)].map { (b, h, e) in
                s.step(p, buttons: UInt32(b), hat: UInt8(h), extra: UInt16(e)) & 0x3FFF
            }
        }
        XCTAssertEqual(cleaned(withProfile: true), cleaned(withProfile: false))
    }

    func testV18NoHiddenKeyMeansEveryReportPassesUnchanged() {
        var s = EchoState()
        var x: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x }
        for _ in 0..<2000 {
            var raw = (0..<16).map { _ in UInt8(truncatingIfNeeded: next()) }
            raw[0] = 6
            let w = s.step(.none, report: raw)
            XCTAssertEqual(w, 0)
            XCTAssertEqual(EchoFilter.apply(w, to: raw), raw)
        }
        // also with a mask that names keys never held
        var t = EchoState()
        let rows = (0..<500).map { _ in (UInt32(next() & 0x3FF), UInt8(next() & 15), UInt16(next() & 0x1FC0)) }
        for (b, h, e) in rows { XCTAssertEqual(t.step(EchoParams.factory(hideMask: 0x3F), buttons: b, hat: h, extra: e), 0) }
    }

    func testV19OnlyUntouchedKeysHeldLeavesTheReportAlone() {
        let p = EchoParams.factory(hideMask: 0x3D)                               // row 11's set: paddle inner right untouched
        var s = EchoState()
        let seq: [(UInt8, UInt16)] = [(8, 0), (4, 2), (4, 2), (8, 0)]
        for (hat, extra) in seq {
            let raw = S.report(buttons: 0, hat: hat, extra: extra)
            let w = s.step(p, report: raw)
            XCTAssertEqual(w, 0)
            XCTAssertEqual(EchoFilter.apply(w, to: raw), raw)
        }
        let rows = S.run(["+IR", ".", "-IR"], hidden: ["OR", "OL", "IL", "SL", "SR"])
        XCTAssertEqual(S.hats(rows), ["D", "D", "."])
    }

    // MARK: V20

    /// A repeated report gives the same state and the same word except bits 25-26, which mark only the press report.
    private func assertRepeat(_ s0: EchoState, _ p: EchoParams, _ b: UInt32, _ h: UInt8, _ e: UInt16, _ ctx: String,
                              file: StaticString = #filePath, line: UInt = #line) -> EchoState {
        var s = s0
        let w1 = s.step(p, buttons: b, hat: h, extra: e)
        let after = s
        let w2 = s.step(p, buttons: b, hat: h, extra: e)
        XCTAssertEqual(s, after, "the state of a repeated report: \(ctx)", file: file, line: line)
        XCTAssertEqual(w1 & ~EchoFilter.pressFlags, w2 & ~EchoFilter.pressFlags, "the word of a repeated report: \(ctx)", file: file, line: line)
        XCTAssertEqual(w2 & EchoFilter.pressFlags, 0, "bits 25-26 mark the press report only: \(ctx)", file: file, line: line)
        return after
    }

    func testV20ARepeatedReportOnScriptedSequences() {
        var turned = S.factoryEchoes
        turned = Array(turned.dropFirst()) + [turned[0]]                         // every key adds the next key's item: every press is "other"
        let none = [UInt16](repeating: 0, count: 6)
        let scripts: [(String, [String], [String], [UInt16])] = [
            ("v13 two keys", ["+OR +OL", "+up", "-up", "-OR -OL"], ["OR"], S.factoryEchoes),
            ("v26 cleared", ["+left", "+OR -left", ".", "-OR", "+OR +Y", ".", "-Y", "-OR"], ["OR"], none),
            ("turned by one key", ["+OR", "+left", "-left", "-OR", "+SL", ".", "-SL", "+IR +IL", "-IR -IL"], all, turned),
            ("factory all six", ["+up", "+OR +IR", ".", "+left", "-left", "-OR", "-IR", "-up", "+A", "+SL", "-A", "-SL"], all, S.factoryEchoes),
        ]
        for (name, script, hidden, echoes) in scripts {
            var mask: UInt8 = 0
            for h in hidden { mask |= 1 << UInt8(S.keyNames.firstIndex(of: h)!) }
            let params = EchoParams.factory(hideMask: mask)
            var s = EchoState()
            for (i, row) in S.run(script, hidden: hidden, echoes: echoes).enumerated() {
                s = assertRepeat(s, params, row.buttons, row.hat, row.extra, "\(name): report \(i)")
            }
        }
    }

    // MARK: V21, V22

    func testV21ThreeInputsOnOneAxisAndAnUntouchedKeyAddingTheSameItem() {
        var rows = S.run(["+up", "+IR", "+IL", ".", "-IL", "-IR", "-up"], hidden: ["IL"])
        XCTAssertEqual(S.hats(rows), ["U", ".", ".", ".", ".", "U", "."], "real up, untouched inner right, hidden inner left: nothing until the hidden paddle is let go")
        rows = S.run(["+IR", "+up", "+IL", ".", "-IL", "-up", "-IR"], hidden: ["IL"])
        XCTAssertEqual(S.hats(rows), ["D", ".", ".", ".", ".", "D", "."])
        rows = S.run(["+IL", "+IR", "+up", ".", "-up", "-IR", "-IL"], hidden: ["IL"])
        XCTAssertEqual(S.hats(rows), [".", "D", "D", "D", "D", ".", "."], "the untouched paddle's direction shows, the real up does not")
        rows = S.run(["+up", "+IR", "+IL +X", "-X", "-IL", "-IR", "-up"], hidden: ["IL"])
        XCTAssertEqual(S.pads(rows), ["hat:U", "hat:.", "hat:.", "hat:.", "hat:.", "hat:U", "hat:."], "a button pressed in the press report there: hidden for that hold")
        // an untouched key that adds the same item as a held hidden key (only after a profile change)
        var echoes = S.factoryEchoes
        echoes[1] = echoes[0]
        rows = S.run(["+OR", "+IR", "-OR", "-IR"], hidden: ["OR"], echoes: echoes)
        XCTAssertEqual(S.hats(rows), [".", ".", "R", "."], "hidden while both are held")
    }

    private func slips(_ params: EchoParams, _ frames: [(UInt32, UInt8, UInt16)]) -> (hats: [String], words: [UInt32]) {
        var s = EchoState()
        var hats: [String] = [], words: [UInt32] = []
        for (b, h, e) in frames {
            let w = s.step(params, buttons: b, hat: h, extra: e)
            hats.append(S.hatText(S.padItems(EchoFilter.items(word: w, buttons: b, hat: h))))
            words.append(w)
        }
        return (hats, words)
    }

    func testV22TimingSlipsWhichWereNeverMeasured() {
        let p = EchoParams.factory(hideMask: 0x01)
        var r = slips(p, [(0, 8, 0), (0, 2, 1), (0, 2, 1), (0, 8, 1), (0, 8, 0)])
        XCTAssertEqual(r.hats, [".", ".", ".", "L", "."], "a release lead of one report: one report of the opposite direction")
        XCTAssertTrue(r.words[3] & EchoFilter.wordRecovered != 0)
        r = slips(p, [(0, 8, 0), (0, 2, 1), (0, 2, 0), (0, 8, 0)])
        XCTAssertEqual(r.hats, [".", ".", "R", "."], "a release lag of one report: one report of the echo")
        r = slips(p, [(0, 8, 0), (0, 8, 1), (0, 2, 1), (0, 2, 1), (0, 8, 0)])
        XCTAssertEqual(r.hats, [".", ".", ".", ".", "."], "a press lag: UNCONFIRMED, no ghost")
        XCTAssertTrue(r.words[1] & EchoFilter.wordUnconfirmed != 0)
        r = slips(p, [(0, 8, 0), (0, 2, 0), (0, 2, 1), (0, 2, 1), (0, 8, 0)])
        XCTAssertEqual(r.hats, [".", "R", "R", "R", "."], "a press lead: the echo shows for the hold (pins the limit text)")
    }

    // MARK: V23

    private struct V23Tables {
        let axis: [String: String]
        let already: [String: String]
    }

    private func v23Tables() throws -> V23Tables {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/echo-v23-table.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: String]]
        return V23Tables(axis: try XCTUnwrap(obj?["axis"]), already: try XCTUnwrap(obj?["already"]))
    }

    private static let v23Axes: [String: (kp: String, kn: String, p: String, n: String)] = [
        "v": ("IL", "IR", "up", "down"), "h": ("OR", "OL", "right", "left")]

    private func change(_ axis: String, _ old: Character, _ new: Character) -> String {
        let a = Self.v23Axes[axis]!
        func tok(_ c: Character) -> String { c == "+" ? a.p : a.n }
        if old == new { return "" }
        var t: [String] = []
        if old != "0" { t.append("-" + tok(old)) }
        if new != "0" { t.append("+" + tok(new)) }
        return t.joined(separator: " ")
    }

    func testV23TheExhaustivePerAxisTableEqualsTheWrittenTable() throws {
        let table = try v23Tables()
        XCTAssertEqual(table.axis.count, 270)
        var cases = 0
        for axis in ["v", "h"] {
            let a = Self.v23Axes[axis]!
            let combos: [([String], String?)] = [([a.kp], nil), ([a.kp], a.kn), ([a.kn], nil), ([a.kn], a.kp), ([a.kp, a.kn], nil)]
            for (hidden, untouched) in combos {
                for before in "+0-" { for pr in "+0-" { for during in "+0-" {
                    let label = "\(axis):\(hidden.joined(separator: "+")):\(untouched ?? "-"):\(before)\(pr)\(during)"
                    let on = hidden.map { "+" + $0 }.joined(separator: " "), off = hidden.map { "-" + $0 }.joined(separator: " ")
                    let script = [
                        change(axis, "0", before).isEmpty ? "." : change(axis, "0", before),
                        untouched.map { "+" + $0 } ?? ".",
                        (on + " " + change(axis, before, pr)).trimmingCharacters(in: .whitespaces),
                        change(axis, pr, during).isEmpty ? "." : change(axis, pr, during),
                        off,
                        ((untouched.map { "-" + $0 } ?? "") + " " + change(axis, during, "0")).trimmingCharacters(in: .whitespaces),
                    ]
                    let rows = S.run(script, hidden: hidden)
                    let (pBit, nBit) = axis == "v" ? (S.up, S.down) : (S.right, S.left)
                    let got = rows.dropFirst().map { r -> String in
                        let v = (r.pad & pBit != 0 ? 1 : 0) - (r.pad & nBit != 0 ? 1 : 0)
                        return v > 0 ? "+" : (v < 0 ? "-" : "0")
                    }.joined()
                    XCTAssertEqual(got, table.axis[label], label)
                    assertNoGhost(rows, label)
                    cases += 1
                } } }
            }
        }
        XCTAssertEqual(cases, 270)
    }

    func testV23TheKeysItemAlreadyOnWithOneOtherChangeInThePressReport() throws {
        let table = try v23Tables()
        let items: [(String, String)] = [("OR", "right"), ("IR", "down"), ("IL", "up"), ("OL", "left"), ("SL", "A"), ("SR", "B")]
        var cases = 0
        for (key, item) in items {
            let perpendicular = ["up", "down"].contains(item) ? ["left", "right"] : (["left", "right"].contains(item) ? ["up", "down"] : ["up", "right", "down", "left"])
            for other in ["X", "Y"] + perpendicular {
                var variants = [("+" + other)]
                if ["up", "right", "down", "left"].contains(other) { variants.append("-" + other) }
                for ch in variants {
                    let o = String(ch.dropFirst())
                    let first = "+" + item + (ch.hasPrefix("-") ? " +" + o : "")
                    let last = "-" + item + (ch.hasPrefix("+") ? " -" + o : "")
                    let rows = S.run([first, "+\(key) \(ch)", ".", "-\(key)", last], hidden: [key])
                    let label = "\(key):\(item):\(ch)"
                    XCTAssertEqual(S.pads(rows).joined(separator: " | "), table.already[label], label)
                    assertNoGhost(rows, label)
                    cases += 1
                }
            }
        }
        XCTAssertEqual(cases, 44)
        XCTAssertEqual(table.already.count, 44)
    }

    // MARK: V24

    func testV24TheButtonWalkCaptureLeaksNoEchoAndPassesFramesWithoutAKeyUnchanged() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scuf-envision/captures/02-button-walk.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var s = EchoState()
        let p = EchoParams.factory(hideMask: 0x3F)
        var reports = 0, withKey = 0
        for line in text.split(separator: "\n") {
            guard line.contains("id=0x06 len=16"), let colon = line.lastIndex(of: ":") else { continue }
            let raw = S.bytes(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            guard raw.count == 16, let f = EchoFilter.fields(raw) else { continue }
            reports += 1
            let w = s.step(p, report: raw)
            if f.extra & 0x3F == 0 {
                XCTAssertEqual(w, 0, "a frame without a paddle or SAX bit is unchanged")
            } else {
                withKey += 1
                let out = EchoFilter.apply(w, to: raw)
                let cleaned = EchoFilter.fields(out)!
                XCTAssertEqual(cleaned.buttons & 0x3FF, 0, "no echo leaks: the walk presses only the keys")
                XCTAssertEqual(cleaned.hat, 8)
            }
        }
        XCTAssertEqual(reports, 2409)
        XCTAssertEqual(withKey, 9)
    }

    // MARK: V26, V27

    func testV26BindingsClearedTheControllerAddsNothing() {
        let none = [UInt16](repeating: 0, count: 6)
        var rows = S.run(["+left", "+OR -left", ".", "-OR"], hidden: ["OR"], echoes: none)
        XCTAssertEqual(S.hats(rows), ["L", "L", "L", "."], "left stays shown until the release")
        rows = S.run(["+OR +Y", ".", "-Y", "-OR"], hidden: ["OR"], echoes: none)
        XCTAssertEqual(S.hats(rows), [".", ".", ".", "."])
        XCTAssertEqual(S.pads(rows), [String](repeating: "hat:.", count: 4), "Y hidden for the hold, no ghost")
        rows = S.run(["+OR +up", ".", "-up", ".", "-OR"], hidden: ["OR"], echoes: none)
        XCTAssertEqual(S.pads(rows), [String](repeating: "hat:.", count: 5), "outer right + up in one report, then up let go: nothing shown")
        rows = S.run(["+OR +right", ".", "-right", ".", "-OR"], hidden: ["OR"], echoes: none)
        XCTAssertEqual(S.hats(rows), [".", ".", "L", "L", "."], "D-pad right pressed in the report of the press, then let go: left shows until the release")
    }

    func testV27AKeyInTheMaskWhoseBindingNamesNoSingleItemCoversTheFactoryItem() {
        let p = EchoParams(hideMask: 0x01, items: [0, 0, 0, 0, 0, 0])            // `.hat(1)`, a diagonal, has no single item
        XCTAssertEqual(p.items[0], 12, "D-pad right")
        for script in [["+OR", "reset", ".", "-OR"], ["+OR +OL", ".", "-OR -OL"], ["+OR", ".", "-OR"]] {
            let rows = S.run(script, params: p)
            XCTAssertEqual(S.hats(rows).dropLast().first, ".")
            XCTAssertFalse(S.hats(rows).dropLast(1).contains("R"), "D-pad right stays hidden for the whole hold: \(script)")
        }
    }

    // MARK: the walk (V20's state guarantees and no ghost under the factory set)

    private struct Walk {
        var x: UInt64
        mutating func next() -> UInt64 {
            x &+= 0x9E3779B97F4A7C15
            var z = x
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
    }

    func testTheRandomWalkKeepsTheGuaranteesAndShowsNoGhostUnderTheFactorySet() {
        let sets: [[UInt16]] = [S.factoryEchoes,
                                [1, 4, 8, 2, 32, 32],                                    // A X Y B with RB
                                [S.up, S.left, S.down, S.right, 16, 4],                  // the directions turned round with LB and X
                                [UInt16](repeating: 0, count: 6)]                        // nothing
        let dirs: [UInt16] = [0, S.up, S.right, S.down, S.left, S.up | S.right, S.right | S.down, S.down | S.left, S.left | S.up]
        for hide: UInt8 in [0x3F, 0x3D, 0x01, 0x09, 0x10] {
            let params = EchoParams.factory(hideMask: hide)
            var rng = Walk(x: UInt64(hide) &* 7919)
            var state = EchoState(), other = EchoState()
            var dpad: UInt16 = 0, btn: UInt16 = 0, keys: UInt8 = 0
            var set = 0, holdSet = 0
            var hold: UInt16 = 0
            var ghostsFactory = 0, factoryReports = 0
            for _ in 0..<40_000 {
                var changes = 0
                if rng.chance(0.12) { changes = rng.chance(0.3) ? 2 : 1 }
                let prevHeld = keys & hide
                var prevIdeal = dpad | btn
                for k in 0..<6 where keys >> UInt8(k) & 1 == 1 && hide >> UInt8(k) & 1 == 0 { prevIdeal |= sets[set][k] }
                for _ in 0..<changes {
                    let c = rng.below(10)
                    if c < 4 { dpad = dirs[rng.below(dirs.count)] }
                    else if c < 6 { btn ^= [1, 2, 4][rng.below(3)] }
                    else { keys ^= 1 << UInt8(rng.below(6)) }
                }
                if changes == 0 && keys == 0 && rng.chance(0.002) { set = rng.below(sets.count) }
                if rng.chance(0.0005) { state.reset() }
                if rng.chance(0.001) { other.reset() }
                let real = dpad | btn
                let c = S.controller(real: real, keys: keys, echoes: sets[set])
                let w = state.step(params, buttons: c.buttons, hat: c.hat, extra: c.extra)
                if keys & hide != 0 { _ = other.step(params, buttons: c.buttons, hat: c.hat, extra: c.extra) }
                // a repeated report
                var twin = state
                let w2 = twin.step(params, buttons: c.buttons, hat: c.hat, extra: c.extra)
                XCTAssertEqual(twin, state)
                XCTAssertEqual(w & ~EchoFilter.pressFlags, w2 & ~EchoFilter.pressFlags)
                if keys & hide == 0 {
                    // after a report with no remapped key held the state is that report's alone
                    var fresh = EchoState()
                    _ = fresh.step(params, buttons: c.buttons, hat: c.hat, extra: c.extra)
                    XCTAssertEqual(state, fresh)
                    XCTAssertEqual(w, 0)
                    _ = other.step(params, buttons: c.buttons, hat: c.hat, extra: c.extra)   // a different history, same report
                    XCTAssertEqual(other, state)
                }
                let pad = S.padItems(EchoFilter.items(word: w, buttons: c.buttons, hat: c.hat))
                var ideal = real
                for k in 0..<6 where keys >> UInt8(k) & 1 == 1 && hide >> UInt8(k) & 1 == 0 { ideal |= sets[set][k] }
                if keys & hide == 0 { hold = ideal; holdSet = set }
                else if prevHeld == 0 { hold = prevIdeal | ideal; holdSet = set }
                else { hold |= ideal }
                if holdSet == 0 {
                    factoryReports += 1
                    if keys & hide != 0 && pad & ~hold != 0 { ghostsFactory += 1 }
                }
            }
            XCTAssertEqual(ghostsFactory, 0, "no ghost under the factory set, hide mask \(hide)")
            XCTAssertGreaterThan(factoryReports, 3_000)
        }
    }
}

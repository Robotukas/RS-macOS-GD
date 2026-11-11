import XCTest
@testable import GDHub

final class DevExpectationTests: XCTestCase {
    private let layout = ControlLayout.loadFromBundle()!
    private let mapping = ControlMapping.default

    private func expected(_ id: String, _ m: ControlMapping? = nil) -> DevExpectedItems {
        DevExpectation.expected(for: id, mapping: m ?? mapping, layout: layout)
    }

    func testFactoryMappingTable() {
        let table: [(String, DevExpectedItems)] = [
            ("a", .init(buttons: ["A"])), ("b", .init(buttons: ["B"])), ("x", .init(buttons: ["X"])), ("y", .init(buttons: ["Y"])),
            ("lb", .init(buttons: ["LB"])), ("rb", .init(buttons: ["RB"])),
            ("l3", .init(buttons: ["LS"])), ("r3", .init(buttons: ["RS"])),
            ("view", .init(buttons: ["View"])), ("menu", .init(buttons: ["Menu"])),
            ("start", .init(guide: true)),
            ("dpad_up", .init(hat: "N")), ("dpad_right", .init(hat: "E")), ("dpad_down", .init(hat: "S")), ("dpad_left", .init(hat: "W")),
            ("g1", .init()), ("g2", .init()), ("g3", .init()), ("g4", .init()), ("g5", .init()), ("profile", .init()),
        ]
        for (id, want) in table { XCTAssertEqual(expected(id), want, id) }
    }

    /// The six keys on Controller's profile expect whatever the profile gives, which the Mac cannot know: no fixed
    /// expectation, the `builtInEcho` rule in every template (rows 1 and 4 press Profile).
    func testAnUntouchedPaddleOrSAXKeyTakesTheBuiltInEchoRule() {
        for id in ControlMapping.echoKeyIDs {
            XCTAssertTrue(expected(id).isEmpty, id)
            XCTAssertTrue(DevExpectation.isBuiltInEcho(id, mapping: mapping), id)
            XCTAssertNil(DevExpectation.linkedOutputControl(for: id, mapping: mapping, layout: layout), id)
            // rows 1 and 4 write no expectation for the step: it takes the rule by itself
            let step = DevStep(id: id, kind: .digital, controls: [id], title: "t")
            XCTAssertTrue(DevExpectation.usesBuiltInEcho(step: step, mapping: mapping), id)
        }
        XCTAssertFalse(DevExpectation.isBuiltInEcho("g2", mapping: mapping), "G2 keeps its own built-in function")
        var explicit = DevStep(id: "s", kind: .digital, controls: ["a"], title: "t")
        XCTAssertFalse(DevExpectation.usesBuiltInEcho(step: explicit, mapping: mapping))
        var e = DevExpect(); e.builtInEcho = true
        explicit.expect = e
        XCTAssertTrue(DevExpectation.usesBuiltInEcho(step: explicit, mapping: mapping), "the template can ask for it")
        // a template that writes its own expectation for a paddle keeps it
        var written = DevStep(id: "w", kind: .digital, controls: ["paddle_outer_left"], title: "t")
        var we = DevExpect(); we.items = DevExpectedItems(hat: "W")
        written.expect = we
        XCTAssertFalse(DevExpectation.usesBuiltInEcho(step: written, mapping: mapping))
    }

    /// A remapped key expects its pick whatever echo is stored: its press is its identity bits alone.
    func testARemappedPaddleExpectsItsPickWhateverEchoIsStored() {
        var m = mapping
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        XCTAssertEqual(expected("paddle_outer_right", m), DevExpectedItems(buttons: ["Y"]))
        XCTAssertEqual(DevExpectation.pressedFrame(for: "paddle_outer_right", mapping: m)?.extra, 1, "only the identity bit")
        XCTAssertEqual(DevExpectation.pressedFrame(for: "paddle_outer_right", mapping: m)?.hat, GamepadFrame.idle.hat, "not the stored D-pad right")
        // stored as a button, as nothing, or with no stored bits at all: the same pick
        var odd = m
        odd.buttons["paddle_outer_right"] = .button(1)
        odd.physicalBits["paddle_outer_right"] = nil
        XCTAssertEqual(expected("paddle_outer_right", odd), DevExpectedItems(buttons: ["Y"]))
        odd.buttons["paddle_outer_right"] = nil
        XCTAssertEqual(expected("paddle_outer_right", odd), DevExpectedItems(buttons: ["Y"]))
        // a paddle stored as hat 2 and remapped to Y expects {Y}, a SAX key sent to Nothing expects nothing
        var nothing = mapping
        nothing.setOutput(.nothing, for: "sax_left")
        XCTAssertTrue(expected("sax_left", nothing).isEmpty)
        XCTAssertFalse(DevExpectation.isBuiltInEcho("sax_left", mapping: nothing))
        XCTAssertTrue(DevExpectation.isHiddenKey("sax_left", mapping: nothing))
        XCTAssertEqual(DevExpectation.linkedOutputControl(for: "paddle_outer_right", mapping: m, layout: layout), "y")
    }

    func testTriggersAreWorkedOutFromTheMapping() {
        func triggers(_ id: String, _ m: ControlMapping) -> [Bool] {
            let t = DevExpectation.expectedTriggers(for: id, mapping: m, layout: layout)
            return [t.lt, t.rt]
        }
        XCTAssertEqual(triggers("lt", mapping), [true, false])
        XCTAssertEqual(triggers("rt", mapping), [false, true])
        XCTAssertEqual(triggers("a", mapping), [false, false])
        var m = mapping
        m.setOutput(.pad(.rt), for: "lt")
        XCTAssertEqual(triggers("lt", m), [false, true], "LT sent to RT pulls RT")
        XCTAssertEqual(triggers("rt", m), [false, true], "RT still sends RT")
        m.setOutput(.pad(.lt), for: "g1")
        XCTAssertEqual(triggers("g1", m), [true, false])
        m.setOutput(.pad(.lt), for: "paddle_outer_right")
        XCTAssertEqual(triggers("paddle_outer_right", m), [true, false], "a paddle sent to a trigger pulls it by its identity bit")
        // the step's expectation: one full pull per press, the other trigger still
        let step = DevStep(id: "lt", kind: .trigger, controls: ["lt"], title: "t")
        let want = DevExpectation.resolve(step: step, mapping: m, layout: layout)
        XCTAssertEqual(want, DevExpectedItems(rt: true))
        XCTAssertEqual(want.summary, "RT, LT still")
        XCTAssertEqual(DevExpectation.linkedOutputControls(for: want), ["rt"])
        XCTAssertEqual(DevExpectation.heldTargets(step: DevStep(id: "h", kind: .held, controls: ["lt"], title: "t"), expected: want), [.trigger(.right)])
        // LT sent to a button: the trigger step expects the button
        var toA = mapping
        toA.setOutput(.pad(.a), for: "lt")
        XCTAssertEqual(DevExpectation.resolve(step: step, mapping: toA, layout: layout), DevExpectedItems(buttons: ["A"]))
        // the old expectation did not know about triggers: an items-only expectation is the same for the digital rule
        XCTAssertEqual(DevExpectedItems(buttons: ["A"]).summary, "A")
    }

    func testBackgroundControlsAreHeldNotExpected() {
        var m = mapping
        m.setOutput(.pad(.r3), for: "paddle_outer_right")
        var step = DevStep(id: "s", kind: .digital, controls: ["paddle_outer_right", "dpad_up"], title: "t")
        var e = DevExpect(); e.background = ["paddle_outer_right"]
        step.expect = e
        XCTAssertEqual(DevExpectation.resolve(step: step, mapping: m, layout: layout), DevExpectedItems(hat: "N"))
        XCTAssertEqual(DevExpectation.backgroundItems(step: step, mapping: m, layout: layout), [.rs])
    }

    func testSticksAndTriggersAreNotDigital() {
        for id in ["left_stick", "right_stick", "lt", "rt", "no_such_control"] { XCTAssertTrue(expected(id).isEmpty, id) }
    }

    func testEveryLayoutControlResolvesWithoutTrapping() {
        for c in layout.controls { _ = expected(c.id) }
    }

    func testARemappedGKeyFollowsItsTarget() {
        var m = mapping
        m.buttons["g1"] = .button(4)          // the Y button's index
        XCTAssertEqual(expected("g1", m), DevExpectedItems(buttons: ["Y"]))
        m.buttons["g1"] = .hat(2)
        XCTAssertEqual(expected("g1", m), DevExpectedItems(hat: "E"))
    }

    // MARK: Remaps (outputs): buttons and the D-pad follow the mapper

    func testExpectationsFollowRemaps() {
        var m = mapping
        m.setOutput(.pad(.y), for: "g1")
        XCTAssertEqual(expected("g1", m), DevExpectedItems(buttons: ["Y"]))
        XCTAssertEqual(expected("y", m), DevExpectedItems(buttons: ["Y"]), "Y still sends Y (OR of two sources)")
        let step = DevStep(id: "s", kind: .digital, controls: ["g1"], title: "t")
        XCTAssertEqual(DevExpectation.resolve(step: step, mapping: m, layout: layout), DevExpectedItems(buttons: ["Y"]))
        XCTAssertEqual(DevExpectation.linkedOutputControls(for: expected("g1", m)), ["y"])
        XCTAssertEqual(DevExpectation.linkedOutputControl(for: "g1", mapping: m, layout: layout), "y")

        var swap = mapping
        swap.setOutput(.pad(.b), for: "a"); swap.setOutput(.pad(.a), for: "b")
        XCTAssertEqual(expected("a", swap), DevExpectedItems(buttons: ["B"]))
        XCTAssertEqual(expected("b", swap), DevExpectedItems(buttons: ["A"]))
        XCTAssertEqual(DevExpectation.linkedOutputControl(for: "a", mapping: swap, layout: layout), "b")

        var none = mapping
        none.setOutput(.nothing, for: "x")
        XCTAssertTrue(expected("x", none).isEmpty)
        XCTAssertTrue(DevExpectation.linkedOutputControls(for: expected("x", none)).isEmpty)

        var guide = mapping
        guide.setOutput(.pad(.guide), for: "g5")
        XCTAssertEqual(expected("g5", guide), DevExpectedItems(guide: true))
        XCTAssertEqual(expected("start", guide), DevExpectedItems(guide: true))

        var dpad = mapping
        dpad.setOutput(.pad(.dpad_left), for: "g2")
        XCTAssertEqual(expected("g2", dpad), DevExpectedItems(hat: "W"))
        XCTAssertEqual(DevExpectation.linkedOutputControl(for: "g2", mapping: dpad, layout: layout), "dpad_left")
        dpad.setOutput(.pad(.a), for: "dpad_up")
        XCTAssertEqual(expected("dpad_up", dpad), DevExpectedItems(buttons: ["A"]))
    }

    func testAHeldStepFollowsARemappedButton() {
        var m = mapping
        m.setOutput(.pad(.x), for: "g3")
        let step = DevStep(id: "s", kind: .held, controls: ["g3"], title: "t")
        let items = DevExpectation.resolve(step: step, mapping: m, layout: layout)
        XCTAssertEqual(items, DevExpectedItems(buttons: ["X"]))
        XCTAssertEqual(DevExpectation.heldTargets(step: step, expected: items), [.item(.x)])
    }

    func testStepOverrideAndUnion() {
        var step = DevStep(id: "s", kind: .digital, controls: ["a", "dpad_up"], title: "t")
        XCTAssertEqual(DevExpectation.resolve(step: step, mapping: mapping, layout: layout), DevExpectedItems(buttons: ["A"], hat: "N"))
        var e = DevExpect(); e.items = DevExpectedItems(buttons: ["X"])
        step.expect = e
        XCTAssertEqual(DevExpectation.resolve(step: step, mapping: mapping, layout: layout), DevExpectedItems(buttons: ["X"]))
    }

    func testLinkedOutputControl() {
        func linked(_ id: String) -> String? { DevExpectation.linkedOutputControl(for: id, mapping: mapping, layout: layout) }
        XCTAssertNil(linked("paddle_outer_left"), "the profile decides what a paddle on Controller's profile shows")
        XCTAssertNil(linked("sax_left"))
        XCTAssertEqual(linked("a"), "a")
        XCTAssertEqual(linked("l3"), "l3")
        XCTAssertEqual(linked("dpad_up"), "dpad_up")
        XCTAssertNil(linked("start"), "Guide has no control of its own")
        XCTAssertNil(linked("g1"))
        XCTAssertNil(linked("lt"))
        XCTAssertEqual(DevExpectation.linkedOutputControls(for: DevExpectedItems(hat: "NE")), ["dpad_up", "dpad_right"])
    }

    // MARK: LT or RT sent to Nothing (review of S4, findings 1 and 9)

    /// A trigger sent to Nothing is not "nothing worked out": the step expects a still pad, and a held step has nothing to
    /// hold. Only a control that is still its own trigger falls back to the trigger itself.
    func testATriggerSentToNothingIsNotTheSameAsNothingWorkedOut() {
        var m = mapping
        m.setOutput(.nothing, for: "lt")
        let trig = DevStep(id: "lt", kind: .trigger, controls: ["lt"], title: "t")
        let held = DevStep(id: "h", kind: .held, controls: ["lt"], title: "t")
        let want = DevExpectation.resolve(step: trig, mapping: m, layout: layout)
        XCTAssertTrue(want.mappedToNothing)
        XCTAssertEqual(want.summary, "nothing on the pad")
        XCTAssertEqual(DevExpectation.heldTargets(step: held, expected: DevExpectation.resolve(step: held, mapping: m, layout: layout)), [],
                       "no own-trigger fallback")
        // the factory mapping and an LT sent elsewhere are not the case
        XCTAssertFalse(DevExpectation.resolve(step: trig, mapping: mapping, layout: layout).mappedToNothing)
        var toRT = mapping
        toRT.setOutput(.pad(.rt), for: "lt")
        XCTAssertFalse(DevExpectation.resolve(step: trig, mapping: toRT, layout: layout).mappedToNothing)
        // RT sent to Nothing is the same for the RT step; LT's own step is untouched by it
        var rtNothing = mapping
        rtNothing.setOutput(.nothing, for: "rt")
        XCTAssertTrue(DevExpectation.resolve(step: DevStep(id: "rt", kind: .trigger, controls: ["rt"], title: "t"), mapping: rtNothing, layout: layout).mappedToNothing)
        XCTAssertFalse(DevExpectation.resolve(step: trig, mapping: rtNothing, layout: layout).mappedToNothing)
        // a G key sent to Nothing has no trigger to judge: still the plain empty expectation
        var g = mapping
        g.setOutput(.nothing, for: "g2")
        XCTAssertFalse(DevExpectation.resolve(step: DevStep(id: "g2", kind: .trigger, controls: ["g2"], title: "t"), mapping: g, layout: layout).mappedToNothing)
    }

    /// Row 1's `lt` step and row 8 under the picks that used to be skipped by `triggerRemapSkip`.
    func testRowsOneAndEightUnderATriggerRemap() throws {
        let all = DevBuiltins.generate(layout: layout)
        let full = try XCTUnwrap(all.first { $0.id == "full" })
        var nothing = mapping
        nothing.setOutput(.nothing, for: "lt")
        let steps = DevResolvedStep.resolve(template: full, mapping: nothing, layout: layout)
        let lt = try XCTUnwrap(steps.first { $0.step.id == "lt" })
        XCTAssertNil(lt.skipReason)
        XCTAssertTrue(lt.expected.mappedToNothing, "judged as a still pad, not as a failing LT pull")

        let t7 = try XCTUnwrap(all.first { $0.id == "t7-rt-hold-toggle" })
        XCTAssertNil(DevResolvedStep.resolve(template: t7, mapping: mapping, layout: layout)[0].skipReason, "RT left alone: it runs")
        for out in [ControlOutput.pad(.lt), .nothing, .pad(.a)] {
            var m = mapping
            m.setOutput(out, for: "rt")
            let step = DevResolvedStep.resolve(template: t7, mapping: m, layout: layout)[0]
            XCTAssertNotNil(step.skipReason, "RT sent to \(out): the step has no RT to hold, so it is skipped and not failed")
            XCTAssertEqual(DevRequirementCheck.startBlock(template: t7, mapping: m, layout: layout) != nil, true)
        }
    }
}

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
            ("paddle_outer_left", .init(hat: "W")), ("paddle_inner_left", .init(hat: "N")),
            ("paddle_inner_right", .init(hat: "S")), ("paddle_outer_right", .init(hat: "E")),
            ("sax_left", .init(buttons: ["A"])), ("sax_right", .init(buttons: ["B"])),
            ("g1", .init()), ("g2", .init()), ("g3", .init()), ("g4", .init()), ("g5", .init()), ("profile", .init()),
        ]
        for (id, want) in table { XCTAssertEqual(expected(id), want, id) }
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
        XCTAssertEqual(linked("paddle_outer_left"), "dpad_left")
        XCTAssertEqual(linked("paddle_inner_right"), "dpad_down")
        XCTAssertEqual(linked("sax_left"), "a")
        XCTAssertEqual(linked("sax_right"), "b")
        XCTAssertEqual(linked("a"), "a")
        XCTAssertEqual(linked("l3"), "l3")
        XCTAssertEqual(linked("dpad_up"), "dpad_up")
        XCTAssertNil(linked("start"), "Guide has no control of its own")
        XCTAssertNil(linked("g1"))
        XCTAssertNil(linked("lt"))
        XCTAssertEqual(DevExpectation.linkedOutputControls(for: DevExpectedItems(hat: "NE")), ["dpad_up", "dpad_right"])
    }
}

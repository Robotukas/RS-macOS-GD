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

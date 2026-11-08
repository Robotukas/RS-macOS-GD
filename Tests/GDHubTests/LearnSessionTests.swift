import XCTest
@testable import GDHub

@MainActor
final class LearnSessionTests: XCTestCase {
    private func control(_ id: String, kind: ControlLayout.Kind) -> ControlLayout.Control {
        ControlLayout.Control(id: id, label: id, kind: kind, order: 1, view: .front, x: 0.5, y: 0.5)
    }

    func testButtonStepAssignsFirstRisingButtonAndExtraBit() {
        var assignments: [LearnAssignment] = []
        let session = LearnSession(controls: [control("sax_left", kind: .button)], mode: .single, baseline: .idle,
                                   onAssign: { assignments.append($0) }, onFinish: {})
        var pressed = GamepadFrame.idle
        pressed.buttons = 1 << 0            // A (mapped function)
        pressed.extra = (1 << 4) | (1 << 5) // physical bit 4, with a brushed neighbour bit 5 in the same frame
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        session.feed(pressed, now: t0)
        session.feed(.idle, now: t0.addingTimeInterval(0.2))
        session.feed(.idle, now: t0.addingTimeInterval(0.8))   // settled for > 0.5 s
        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments.first?.binding, .button(1))
        XCTAssertEqual(assignments.first?.physicalBits, 1 << 4, "only the lowest first-rising extra bit is kept")
        XCTAssertTrue(session.isFinished)
    }

    func testDpadPrefersHatOverButtons() {
        var assignments: [LearnAssignment] = []
        let session = LearnSession(controls: [control("dpad_left", kind: .button)], mode: .single, baseline: .idle,
                                   onAssign: { assignments.append($0) }, onFinish: {})
        var f = GamepadFrame.idle
        f.hat = 6
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        session.feed(f, now: t0)
        session.feed(.idle, now: t0.addingTimeInterval(0.1))
        session.feed(.idle, now: t0.addingTimeInterval(0.7))
        XCTAssertEqual(assignments.first?.binding, .hat(6))
    }

    func testStickCircleLearnsBothAxesAndRanges() {
        var assignments: [LearnAssignment] = []
        let session = LearnSession(controls: [control("left_stick", kind: .stick)], mode: .single, baseline: .idle,
                                   onAssign: { assignments.append($0) }, onFinish: {})
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        // Rotate once around the edge: 36 samples on a circle of radius 30000 in x/y.
        for i in 0..<36 {
            let a = Double(i) / 36 * 2 * .pi
            var f = GamepadFrame.idle
            f.x = Int16(30000 * cos(a)); f.y = Int16(30000 * sin(a))
            session.feed(f, now: t0.addingTimeInterval(Double(i) * 0.05))
        }
        XCTAssertEqual(session.circlePercent, 100)
        session.feed(.idle, now: t0.addingTimeInterval(2.0))
        session.feed(.idle, now: t0.addingTimeInterval(2.6))
        let stick = assignments.first?.stick
        XCTAssertNotNil(stick)
        XCTAssertEqual(stick?.horizontal, .axis("x", sign: 1))
        XCTAssertEqual(stick?.vertical, .axis("y", sign: 1))
        XCTAssertEqual(stick?.ranges?["x"]?.max ?? 0, 30000, accuracy: 300)
        XCTAssertEqual(stick?.ranges?["y"]?.min ?? 0, -30000, accuracy: 300)
    }

    func testBackReturnsToPreviousStep() {
        let session = LearnSession(controls: [control("a", kind: .button), control("b", kind: .button)], mode: .guided,
                                   baseline: .idle, onAssign: { _ in }, onFinish: {})
        XCTAssertEqual(session.currentControl?.id, "a")
        session.skip()
        XCTAssertEqual(session.currentControl?.id, "b")
        XCTAssertTrue(session.canGoBack)
        session.back()
        XCTAssertEqual(session.currentControl?.id, "a")
        XCTAssertFalse(session.canGoBack)
    }
}

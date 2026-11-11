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

    // MARK: Learn guard wiring

    private func learn(_ id: String, mode: LearnSession.Mode, button: Int, mapping: inout ControlMapping) -> LearnSession {
        let holder = mapping
        var applied = mapping
        let session = LearnSession(controls: [control(id, kind: .button)], mode: mode, baseline: .idle,
                                   refusal: { LearnGuard.refusal(mapping: holder, assignment: $0) { $0.uppercased() } },
                                   onAssign: { applied.apply($0) }, onFinish: {})
        var pressed = GamepadFrame.idle
        pressed.buttons = 1 << UInt32(button - 1)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        session.feed(pressed, now: t0)
        session.feed(.idle, now: t0.addingTimeInterval(0.2))
        session.feed(.idle, now: t0.addingTimeInterval(0.8))
        mapping = applied
        return session
    }

    func testSingleRelearnOfG1OntoYIsRefusedWithTheExactMessage() {
        var m = ControlMapping.default
        let before = m
        let s = learn("g1", mode: .single, button: 4, mapping: &m)
        XCTAssertEqual(s.lastResult, "That is Y's button. To make G1 send Y use Mapping \u{2192} Y.")
        XCTAssertEqual(m, before)
        XCTAssertTrue(s.isFinished)
    }

    func testSingleRelearnOfAIsApplied() {
        var m = ControlMapping.default
        m.buttons["a"] = .button(7)
        let s = learn("a", mode: .single, button: 1, mapping: &m)
        XCTAssertEqual(m.buttons["a"], .button(1))
        XCTAssertTrue(s.lastResult.hasPrefix("a:"), s.lastResult)
    }

    func testGuidedLearnIsNeverRefused() {
        var m = ControlMapping.default
        let s = learn("g1", mode: .guided, button: 4, mapping: &m)
        XCTAssertEqual(m.buttons["g1"], .button(4))
        XCTAssertFalse(s.lastResult.hasPrefix("That is"))
    }

    // MARK: Paddles and SAX keys (remap step 2)

    /// Runs a single learn of `id` over `frames` (each held one report), then rest; returns the assignments and the session.
    private func learn(_ id: String, baseline: GamepadFrame = .idle, frames: [GamepadFrame], mapping: ControlMapping = .default,
                       label: @escaping (String) -> String = { $0 }) -> (assignments: [LearnAssignment], session: LearnSession) {
        var assignments: [LearnAssignment] = []
        let session = LearnSession(controls: [control(id, kind: .button)], mode: .single, baseline: baseline,
                                   refusal: { LearnGuard.refusal(mapping: mapping, assignment: $0, label: label) },
                                   onAssign: { assignments.append($0) }, onFinish: {})
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        for (i, f) in frames.enumerated() { session.feed(f, now: t0.addingTimeInterval(Double(i) * 0.01)) }
        session.feed(baseline, now: t0.addingTimeInterval(0.3))
        session.feed(baseline, now: t0.addingTimeInterval(1.0))
        return (assignments, session)
    }

    func testExtraBitsAreAttachedOnlyToThePaddlesAndSaxKeys() {
        var f = GamepadFrame.idle
        f.buttons = 1 << 11; f.extra = 1 << 0           // G1's button, with a paddle brushed
        let g1 = learn("g1", frames: [f])
        XCTAssertEqual(g1.assignments.first?.binding, .button(12))
        XCTAssertEqual(g1.assignments.first?.physicalBits, 0, "a neighbouring paddle must not tie G1 to its signal")
        XCTAssertFalse(g1.session.lastResult.contains("extra bits"))
        var p = GamepadFrame.idle
        p.hat = 2; p.extra = 1 << 0
        let paddle = learn("paddle_outer_right", frames: [p])
        XCTAssertEqual(paddle.assignments.first?.physicalBits, 1)
        XCTAssertEqual(paddle.assignments.first?.binding, .hat(2))
        XCTAssertTrue(paddle.session.lastResult.contains("(+ extra bits)"), paddle.session.lastResult)
    }

    func testLearningAPaddleWithAnotherKeysSignalIsRefused() {
        var f = GamepadFrame.idle
        f.hat = 6; f.extra = 1 << 3                     // paddle outer left pressed, but "Paddle outer right" is being learned
        let r = learn("paddle_outer_right", frames: [f], label: { $0 == "paddle_outer_left" ? "Paddle outer left" : "Paddle outer right" })
        XCTAssertTrue(r.assignments.isEmpty, "nothing is stored")
        XCTAssertEqual(r.session.lastResult, "That was Paddle outer left's signal: press Paddle outer right itself.")
        // Its own key is accepted.
        var own = GamepadFrame.idle
        own.hat = 2; own.extra = 1
        XCTAssertEqual(learn("paddle_outer_right", frames: [own]).assignments.count, 1)
    }

    func testAPaddleLearnedWhileDpadUpIsHeldIsStoredAsTheOneDirectionThatChanged() {
        var base = GamepadFrame.idle; base.hat = 0       // D-pad up held through the whole learn
        var both = base; both.hat = 1; both.extra = 1    // the controller sends up+right for paddle outer right
        let r = learn("paddle_outer_right", baseline: base, frames: [both, both, both])
        XCTAssertEqual(r.assignments.first?.binding, .hat(2), "right, not the diagonal 1")
        // Held D-pad left cancelled by the key's right: the direction that went away counts as the opposite.
        var left = GamepadFrame.idle; left.hat = 6
        var cancelled = left; cancelled.hat = 8; cancelled.extra = 1
        XCTAssertEqual(learn("paddle_outer_right", baseline: left, frames: [cancelled, cancelled]).assignments.first?.binding, .hat(2))
        // Each of the four, from rest.
        for (hat, want) in [(UInt8(0), UInt8(0)), (2, 2), (4, 4), (6, 6)] {
            var f = GamepadFrame.idle; f.hat = hat; f.extra = 1
            XCTAssertEqual(learn("paddle_outer_right", frames: [f]).assignments.first?.binding, .hat(want), "hat \(hat)")
        }
        // A button wins over the hat, as before.
        var b = GamepadFrame.idle; b.buttons = 1; b.extra = 16
        XCTAssertEqual(learn("sax_left", frames: [b]).assignments.first?.binding, .button(1))
    }
}

import XCTest
@testable import GDHub

/// Synthetic pad report streams on a fake timeline: the window starts at `w`, and every time below is in milliseconds
/// from it. Like the sink, the rig emits only the reports whose bytes changed, so the stream has the same gaps.
private extension Int { var asDouble: Double { Double(self) } }

private struct Rig {
    static let w: UInt64 = 10_000_000_000
    var reports: [DevJudge.TimedReport] = []
    private var last: [UInt8: [UInt8]] = [:]

    init(entry: PadState = PadState()) {
        for r in PadReportBuilders.xboxBT16(entry) { last[r.id] = r.bytes }
    }

    static func ns(_ ms: Double) -> UInt64 { UInt64(Double(w) + ms * 1e6) }

    mutating func set(_ s: PadState, at ms: Double) {
        for r in PadReportBuilders.xboxBT16(s) where last[r.id] != r.bytes {
            reports.append(.init(tNs: Rig.ns(ms), id: r.id, bytes: r.bytes))
            last[r.id] = r.bytes
        }
    }

    /// A report even when nothing changed (a real pad repeats reports during motion).
    mutating func repeatLast(_ s: PadState, at ms: Double) {
        for r in PadReportBuilders.xboxBT16(s) where r.id == 1 { reports.append(.init(tNs: Rig.ns(ms), id: r.id, bytes: r.bytes)) }
    }
}

final class DevJudgeTests: XCTestCase {
    private func state(_ f: (inout PadState) -> Void = { _ in }) -> PadState { var s = PadState(); f(&s); return s }
    private func decoded(_ s: PadState) -> PadDecodedState {
        var d = PadDecodedState.neutral
        for r in PadReportBuilders.xboxBT16(s) { PadReportDecoder.xboxBT16.apply(reportID: r.id, bytes: r.bytes, to: &d) }
        return d
    }

    private func run(_ step: DevStep, expected: DevExpectedItems = DevExpectedItems(), entry: PadState? = PadState(),
                     rig: Rig, windowMs: Double = 5000, releaseMs: Double = 500, matched: Int = 1,
                     reference: DevJudge.Reference? = nil, rules: DevJudge.Rules = .init(), handOvers: Int = 0) -> DevJudge.Outcome {
        let input = DevJudge.Input(step: step, expected: expected, entryState: entry.map(decoded), reports: rig.reports,
                                   windowStartNs: Rig.ns(0), windowEndNs: Rig.ns(windowMs), endNs: Rig.ns(windowMs + releaseMs),
                                   matchedCount: matched, reference: reference, handOvers: handOvers)
        return DevJudge.judge(input, rules: rules)
    }

    private func assertPass(_ o: DevJudge.Outcome, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(o.verdict, .pass, o.metrics.detail, file: file, line: line)
    }
    private func assertFail(_ o: DevJudge.Outcome, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .fail(let reason) = o.verdict else { return XCTFail("expected fail, got \(o.verdict): \(o.metrics.detail)", file: file, line: line) }
        XCTAssertTrue(reason.contains(text), "reason \"\(reason)\" lacks \"\(text)\"", file: file, line: line)
    }

    // MARK: stick

    private let leftStick = DevStep(id: "left_stick", kind: .stick, controls: ["left_stick"], title: "t", seconds: 5, releaseSeconds: 0.5)

    /// `turns` slow circles of radius `r` over `ms`, 5 ms per sample, ending with the stick let go at `ms`.
    private func circle(_ rig: inout Rig, stick: PadStick = .left, radius r: Double = 0.9, turns: Double = 1.5, from t0: Double = 100, ms: Double = 2000) {
        let n = Int(ms / 5)
        for i in 0..<n {
            let a = turns * 2 * .pi * Double(i) / Double(n)
            rig.set(state { if stick == .left { $0.lx = r * cos(a); $0.ly = r * sin(a) } else { $0.rx = r * cos(a); $0.ry = r * sin(a) } },
                    at: t0 + Double(i) * 5)
        }
        rig.set(PadState(), at: t0 + ms)
    }

    func testStickPassesAndHoldsAtRestWithNoReportInTheLast300ms() {
        var rig = Rig()
        circle(&rig)
        // The last report is at 2100 ms; the window runs to 5000 and the tail to 5500. Nothing is sent after the
        // stick settles: the pass rests on the held state.
        let o = run(leftStick, rig: rig)
        assertPass(o)
        XCTAssertGreaterThan(o.metrics.values["ls.reportsOutside"] ?? 0, 100)
        XCTAssertEqual(o.metrics.values["ls.xMax"] ?? 0, 0.9, accuracy: 0.01)
        XCTAssertEqual(o.metrics.values["ls.yMin"] ?? 0, -0.9, accuracy: 0.01)
        XCTAssertEqual(o.metrics.values["ls.settledMs"] ?? 0, 3400, accuracy: 1)
        XCTAssertEqual(o.metrics.padReports, o.metrics.padChanged)
    }

    func testStickFailsWhenTooFewReportsOrTooSmallACircle() {
        var few = Rig()
        for (i, p) in [(0.9, 0.0), (0.0, 0.9), (-0.9, 0.0), (0.0, -0.9)].enumerated() { few.set(state { $0.lx = p.0; $0.ly = p.1 }, at: 100 + Double(i) * 100) }
        few.set(PadState(), at: 600)
        assertFail(run(leftStick, rig: few), containing: "only 4 reports")

        var small = Rig()
        circle(&small, radius: 0.3)
        assertFail(run(leftStick, rig: small), containing: "never reached")
    }

    func testStickFailsWhenItIsNotBackAtRestForLongEnough() {
        var late = Rig()
        circle(&late, ms: 5200)            // lets go at 5300 ms; the tail ends at 5500
        assertFail(run(leftStick, rig: late), containing: "had only been at rest for 200 ms")

        var never = Rig()
        for i in 0..<400 { let a = 2 * .pi * Double(i) / 200; never.set(state { $0.lx = 0.9 * cos(a); $0.ly = 0.9 * sin(a) }, at: 100 + Double(i) * 5) }
        assertFail(run(leftStick, rig: never), containing: "still outside the dead zone at the end")
    }

    func testStickCrossTalkFails() {
        var rig = Rig()
        circle(&rig)
        rig.set(state { $0.rx = 0.5 }, at: 1000)
        rig.set(PadState(), at: 1200)
        assertFail(run(leftStick, rig: rig), containing: "right stick moved too")
        // ...unless the template says the other stick may move
        var rules = DevJudge.Rules(); rules.otherStickStill = false
        assertPass(run(leftStick, rig: rig, rules: rules))
    }

    func testStickJitterInsideTheDeadZoneIsNotCounted() {
        var rig = Rig()
        circle(&rig)
        rig.set(state { $0.rx = 0.05; $0.ry = -0.04 }, at: 3000)      // the other stick's resting jitter
        assertPass(run(leftStick, rig: rig))
    }

    func testRightStickUsesItsOwnKeys() {
        var rig = Rig()
        circle(&rig, stick: .right)
        let o = run(DevStep(id: "right_stick", kind: .stick, controls: ["right_stick"], title: "t"), rig: rig)
        assertPass(o)
        XCTAssertNotNil(o.metrics.values["rs.reportsOutside"])
        XCTAssertNil(o.metrics.values["ls.reportsOutside"])
    }

    // MARK: trigger

    private let lt = DevStep(id: "lt", kind: .trigger, controls: ["lt"], title: "t", seconds: 3, releaseSeconds: 0.5)

    private func pull(_ rig: inout Rig, peak: Double, releaseAt: Double?) {
        for i in 0...40 { rig.set(state { $0.lt = peak * Double(i) / 40 }, at: 100 + Double(i) * 25) }
        if let r = releaseAt { rig.set(PadState(), at: r) }
    }

    func testTriggerPassFailAndHold() {
        var ok = Rig(); pull(&ok, peak: 1, releaseAt: 1500)
        let o = run(lt, rig: ok, windowMs: 3000)
        assertPass(o)
        XCTAssertEqual(o.metrics.values["lt.peak"] ?? 0, 1, accuracy: 0.001)

        var weak = Rig(); pull(&weak, peak: 0.6, releaseAt: 1500)
        assertFail(run(lt, rig: weak, windowMs: 3000), containing: "only reached 0.60")

        var stuck = Rig(); pull(&stuck, peak: 1, releaseAt: nil)
        assertFail(run(lt, rig: stuck, windowMs: 3000), containing: "still above")

        var late = Rig(); pull(&late, peak: 1, releaseAt: 3300)
        assertFail(run(lt, rig: late, windowMs: 3000), containing: "had only been released for 200 ms")
    }

    // MARK: digital

    private let aStep = DevStep(id: "a", kind: .digital, controls: ["a"], title: "t")
    private let aExpected = DevExpectedItems(buttons: ["A"])

    private func press(_ rig: inout Rig, _ make: (inout PadState) -> Void, times: Int, from t0: Double = 200) {
        for i in 0..<times {
            rig.set(state(make), at: t0 + Double(i) * 400)
            rig.set(PadState(), at: t0 + Double(i) * 400 + 150)
        }
    }

    func testDigitalPassFailAndUnexpected() {
        var twice = Rig(); press(&twice, { $0.buttons = [.a] }, times: 2)
        let o = run(aStep, expected: aExpected, rig: twice, releaseMs: 0)
        assertPass(o)
        XCTAssertEqual(o.metrics.values["bit.rises"], 2)
        XCTAssertEqual(o.metrics.values["bit.falls"], 2)

        var once = Rig(); press(&once, { $0.buttons = [.a] }, times: 1)
        assertFail(run(aStep, expected: aExpected, rig: once, releaseMs: 0), containing: "A went down 1 and up 1 times (needs 2)")

        var withB = twice
        withB.set(state { $0.buttons = [.b] }, at: 1500)
        withB.set(PadState(), at: 1600)
        assertFail(run(aStep, expected: aExpected, rig: withB, releaseMs: 0), containing: "unexpected change on B")

        var stillDown = Rig(); press(&stillDown, { $0.buttons = [.a] }, times: 2)
        stillDown.set(state { $0.buttons = [.a] }, at: 1500)
        assertFail(run(aStep, expected: aExpected, rig: stillDown, releaseMs: 0), containing: "still down at the end")
    }

    func testDigitalWithNoReportsAtAllFailsAndSaysWhatTheReceiverDid() {
        let ref = DevJudge.Reference(expectedChanges: 4, firstFrameChangeNs: Rig.ns(300))
        let o = run(aStep, expected: aExpected, rig: Rig(), releaseMs: 0, reference: ref)
        assertFail(o, containing: "A went down 0")
        XCTAssertTrue(o.metrics.detail.contains("receiver changed 4 times and the pad never did"))
        XCTAssertEqual(o.metrics.lossRatio, 0)
    }

    func testDigitalBitAlreadySetAtStepStart() {
        let o = run(aStep, expected: aExpected, entry: state { $0.buttons = [.a] }, rig: Rig(), releaseMs: 0)
        assertFail(o, containing: "bit already set at step start")
        XCTAssertEqual(o.metrics.values["entrySet"], 1)
    }

    func testHatExpectationAndItsRoundTrip() {
        let step = DevStep(id: "paddle_outer_left", kind: .digital, controls: ["paddle_outer_left"], title: "t")
        let want = DevExpectedItems(hat: "W")
        var rig = Rig(); press(&rig, { $0.buttons = [.dpadLeft] }, times: 2)
        let o = run(step, expected: want, rig: rig, releaseMs: 0)
        assertPass(o)
        XCTAssertGreaterThan(o.metrics.values["hat.visited"] ?? 0, 0)
        XCTAssertEqual(Int(o.metrics.values["hat.visited"] ?? 0) & (1 << 7), 1 << 7, "hat value 7 (W) was visited")

        var diagonal = Rig(); press(&diagonal, { $0.buttons = [.dpadLeft] }, times: 2)
        diagonal.set(state { $0.buttons = [.dpadLeft, .dpadUp] }, at: 1500)
        diagonal.set(PadState(), at: 1600)
        assertFail(run(step, expected: want, rig: diagonal, releaseMs: 0), containing: "unexpected change on D-pad up")
    }

    func testSaxEchoIsPartOfTheExpectationNotUnexpected() {
        let step = DevStep(id: "sax_left", kind: .digital, controls: ["sax_left"], title: "t")
        var rig = Rig(); press(&rig, { $0.buttons = [.a] }, times: 2)
        assertPass(run(step, expected: DevExpectedItems(buttons: ["A"]), rig: rig, releaseMs: 0))
    }

    func testGuideArrivesOnReport2Only() {
        let step = DevStep(id: "start", kind: .digital, controls: ["start"], title: "t")
        var rig = Rig(); press(&rig, { $0.buttons = [.guide] }, times: 2)
        XCTAssertTrue(rig.reports.allSatisfy { $0.id == 2 }, "the rig only sends the report that changed")
        assertPass(run(step, expected: DevExpectedItems(guide: true), rig: rig, releaseMs: 0))
    }

    func testEmptyExpectationPassesQuietAndFailsOnNoise() {
        let g1 = DevStep(id: "g1", kind: .digital, controls: ["g1"], title: "t")
        assertPass(run(g1, rig: Rig(), releaseMs: 0))

        var jitter = Rig()
        jitter.set(state { $0.lx = 0.03; $0.lt = 0.02 }, at: 500)
        jitter.set(state { $0.lx = -0.04 }, at: 900)
        assertPass(run(g1, rig: jitter, releaseMs: 0))

        var button = Rig(); press(&button, { $0.buttons = [.a] }, times: 1)
        assertFail(run(g1, rig: button, releaseMs: 0), containing: "unexpected change on A")

        var axis = Rig(); axis.set(state { $0.rx = 0.4 }, at: 800); axis.set(PadState(), at: 900)
        assertFail(run(g1, rig: axis, releaseMs: 0), containing: "an axis moved")
    }

    // MARK: rest

    private let rest = DevStep(id: "rest", kind: .rest, title: "t", seconds: 3)

    func testRest() {
        var jitter = Rig()
        jitter.set(state { $0.lx = 0.05; $0.ry = -0.06; $0.rt = 0.02 }, at: 400)
        jitter.set(state { $0.lx = -0.07 }, at: 1200)
        let o = run(rest, rig: jitter, windowMs: 3000, releaseMs: 0)
        assertPass(o)
        XCTAssertEqual(o.metrics.padChanged, 2, "the exact change count is kept even though the judge tolerates it")

        var bump = Rig(); bump.set(state { $0.lx = 0.4 }, at: 1000); bump.set(PadState(), at: 1100)
        assertFail(run(rest, rig: bump, windowMs: 3000, releaseMs: 0), containing: "left rest")

        assertFail(run(rest, entry: state { $0.buttons = [.x] }, rig: Rig(), windowMs: 3000, releaseMs: 0), containing: "not at rest at step start")
    }

    // MARK: inconclusive

    func testInconclusiveCases() {
        var rig = Rig(); press(&rig, { $0.buttons = [.a] }, times: 2)
        XCTAssertEqual(run(aStep, expected: aExpected, entry: nil, rig: rig).verdict, .inconclusive("pad state unknown"))
        XCTAssertEqual(run(aStep, expected: aExpected, rig: rig, matched: 0).verdict, .inconclusive("reader matched 0 pads"))
        XCTAssertEqual(run(aStep, expected: aExpected, rig: rig, matched: 2).verdict, .inconclusive("reader matched 2 pads"))
        var bogus = aStep; bogus.kind = "wiggle"
        guard case .inconclusive = run(bogus, rig: rig).verdict else { return XCTFail() }
    }

    // MARK: ready-phase reports, ordering, metrics

    func testReportsBeforeTheWindowSeedTheHeldStateButAreNotCounted() {
        var rig = Rig()
        rig.set(state { $0.buttons = [.a] }, at: -900)           // pressed during the ready phase, held into the window
        rig.set(PadState(), at: 100)
        rig.set(state { $0.buttons = [.a] }, at: 300)
        rig.set(PadState(), at: 400)
        rig.set(state { $0.buttons = [.a] }, at: 700)
        rig.set(PadState(), at: 800)
        let o = run(aStep, expected: aExpected, rig: rig, releaseMs: 0)
        XCTAssertEqual(o.metrics.padReports, 5, "only the window's reports are counted")
        // Held at window start: the falls are 3, the rises 2.
        assertPass(o)
        XCTAssertEqual(o.verdict, .pass)
    }

    func testReportsAreJudgedInTimeOrderWhateverOrderTheyArriveIn() {
        var rig = Rig(); press(&rig, { $0.buttons = [.a] }, times: 2)
        let shuffled = DevJudge.Input(step: aStep, expected: aExpected, entryState: .neutral, reports: rig.reports.reversed(),
                                      windowStartNs: Rig.ns(0), windowEndNs: Rig.ns(5000), matchedCount: 1)
        XCTAssertEqual(DevJudge.judge(shuffled).verdict, .pass)
    }

    func testLossRatioAndOnsetAgainstTheReference() {
        var rig = Rig(); press(&rig, { $0.buttons = [.a] }, times: 2, from: 250)
        let ref = DevJudge.Reference(expectedChanges: 8, firstFrameChangeNs: Rig.ns(200), framesSeen: 900, framesPerSecond: 960, movingMs: 1100)
        let o = run(aStep, expected: aExpected, rig: rig, releaseMs: 0, reference: ref)
        assertPass(o)
        XCTAssertEqual(o.metrics.padChanged, 4)
        XCTAssertEqual(o.metrics.expectedChanges, 8)
        XCTAssertEqual(o.metrics.lossRatio ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(o.metrics.onsetMs ?? 0, 50, accuracy: 1e-6)
        XCTAssertEqual(o.metrics.framesSeen, 900)
        XCTAssertEqual(o.metrics.movingMs, 1100, accuracy: 1e-9)
    }

    func testRawReportsCarryPhaseAndRelativeTime() {
        var rig = Rig()
        rig.set(state { $0.buttons = [.a] }, at: -500)
        rig.set(PadState(), at: 100)
        rig.set(state { $0.buttons = [.b] }, at: 5200)
        let input = DevJudge.Input(step: aStep, entryState: .neutral, reports: rig.reports, windowStartNs: Rig.ns(0),
                                   windowEndNs: Rig.ns(5000), endNs: Rig.ns(5500))
        let raw = input.rawReports()
        XCTAssertEqual(raw.map(\.phase), [.ready, .window, .release])
        XCTAssertEqual(raw.map(\.tMs), [-500, 100, 5200])
        XCTAssertEqual(raw[0].bytes.split(separator: " ").count, 16)
    }

    func testStepOverridesChangeTheRules() {
        var step = aStep
        var e = DevExpect(); e.times = 1
        step.expect = e
        var once = Rig(); press(&once, { $0.buttons = [.a] }, times: 1)
        assertPass(run(step, expected: aExpected, rig: once, releaseMs: 0))
        var stick = leftStick
        var s = DevExpect(); s.minReports = 3; s.extent = 0.2
        stick.expect = s
        var few = Rig()
        for (i, p) in [(0.5, 0.0), (0.0, 0.5), (-0.5, 0.0), (0.0, -0.5)].enumerated() { few.set(state { $0.lx = p.0; $0.ly = p.1 }, at: 100 + Double(i) * 100) }
        few.set(PadState(), at: 600)
        assertPass(run(stick, rig: few))
    }

    // MARK: held

    private var rtHold: DevStep {
        var s = DevStep(id: "rt-hold", kind: .held, controls: ["rt"], title: "t", seconds: 45)
        var e = DevExpect(); e.item = "RT"; e.minLevel = 0.5
        s.expect = e
        return s
    }
    private let holdMs = 38_000.0

    /// RT ramps up over 150 ms, jitters between 0.98 and 1.0 for the whole window and is let go in the tail.
    private func holdRT(_ rig: inout Rig, until end: Double? = nil, letGoAt: Double? = 38_200) {
        rig.set(state { $0.rt = 0.30 }, at: 50)
        rig.set(state { $0.rt = 0.80 }, at: 100)
        rig.set(state { $0.rt = 1.0 }, at: 150)
        var t = 1000.0
        while t < (end ?? holdMs) {
            rig.set(state { $0.rt = 0.98 }, at: t)
            rig.set(state { $0.rt = 1.0 }, at: t + 500)
            t += 1000
        }
        if let letGoAt { rig.set(PadState(), at: letGoAt) }
    }

    func testHeldPassesWhenTheItemNeverDropsAndLettingGoInTheTailIsNotADrop() {
        var rig = Rig()
        holdRT(&rig)
        let o = run(rtHold, rig: rig, windowMs: holdMs, releaseMs: 500, handOvers: 12)
        assertPass(o)
        XCTAssertEqual(o.metrics.values["held.drops"], 0)
        XCTAssertEqual(o.metrics.values["held.minLevel"] ?? 0, 0.98, accuracy: 0.01)
        XCTAssertEqual(o.metrics.values["held.ms"] ?? 0, 37_900, accuracy: 1, "held from the first report at or above 0.5 (the 100 ms ramp step) to the window end")
        XCTAssertEqual(o.metrics.values["held.padReports"], o.metrics.padReports.asDouble)
        XCTAssertTrue(o.metrics.detail.hasPrefix("RT stayed held for 37.9 s through 12 hand-overs; lowest 0.98;"), o.metrics.detail)
    }

    func testHeldFailsOnADropEvenOneReportLong() {
        for low in [0.0, 0.3] {
            var rig = Rig()
            holdRT(&rig, until: 20_000, letGoAt: nil)
            rig.set(state { $0.rt = low }, at: 20_100)       // the pad lets go for 50 ms ...
            rig.set(state { $0.rt = 1.0 }, at: 20_150)       // ... and comes back
            rig.set(PadState(), at: 38_200)
            let o = run(rtHold, rig: rig, windowMs: holdMs, releaseMs: 500, handOvers: 12)
            assertFail(o, containing: "drops 1")
            XCTAssertEqual(o.metrics.values["held.drops"], 1)
            XCTAssertEqual(o.metrics.values["held.minLevel"] ?? 9, low, accuracy: 0.01)
            XCTAssertTrue(o.metrics.detail.contains("first at 20.10 s"), o.metrics.detail)
        }
    }

    func testHeldCountsEveryDropAndANeutralPost() {
        var rig = Rig()
        holdRT(&rig, until: 10_000, letGoAt: nil)
        rig.set(PadState(), at: 10_000)                      // everything neutral
        rig.set(state { $0.rt = 1.0 }, at: 10_040)
        rig.set(PadState(), at: 11_000)
        rig.set(state { $0.rt = 1.0 }, at: 11_040)
        let o = run(rtHold, rig: rig, windowMs: 20_000, releaseMs: 500)
        assertFail(o, containing: "drops 2")
    }

    func testHeldFailsWhenNotHeldAtTheEnd() {
        var rig = Rig()
        holdRT(&rig, until: 3000, letGoAt: 4000)             // let go inside a 5 s window
        let o = run(rtHold, rig: rig, windowMs: 5000, releaseMs: 500)
        assertFail(o, containing: "drops 1")
    }

    func testHeldFailsWhenNeverHeldOrOnlyMuchTooLate() {
        var weak = Rig()
        weak.set(state { $0.rt = 0.30 }, at: 100)
        let never = run(rtHold, rig: weak, windowMs: 3000)
        assertFail(never, containing: "never became held")
        XCTAssertTrue(never.metrics.detail.contains("highest 0.30"), never.metrics.detail)

        var late = Rig()
        late.set(state { $0.rt = 1.0 }, at: 2500)
        assertFail(run(rtHold, rig: late, windowMs: 5000), containing: "only became held 2.5 s into the window")
    }

    func testHeldAlreadyHeldAtTheStartCountsFromTheStart() {
        let o = run(rtHold, entry: state { $0.rt = 1.0 }, rig: Rig(), windowMs: 3000)
        assertPass(o)
        XCTAssertEqual(o.metrics.values["held.ms"] ?? 0, 3000, accuracy: 1)
    }

    func testHeldButtonAndHatItems() {
        let aHold = DevStep(id: "a-hold", kind: .held, controls: ["a"], title: "t", seconds: 5)
        var rig = Rig()
        rig.set(state { $0.buttons = [.a] }, at: 100)
        rig.set(state { $0.buttons = [.a]; $0.lx = 0.9 }, at: 2000)     // other items moving does not matter
        rig.set(PadState(), at: 5100)                                    // let go in the tail
        let o = run(aHold, expected: DevExpectedItems(buttons: ["A"]), rig: rig, windowMs: 5000)
        assertPass(o)
        XCTAssertTrue(o.metrics.detail.hasPrefix("A stayed held for 4.9 s;"), o.metrics.detail)
        XCTAssertEqual(o.metrics.values["held.minLevel"], 1)

        var flicker = Rig()
        flicker.set(state { $0.buttons = [.a] }, at: 100)
        flicker.set(PadState(), at: 2000)
        flicker.set(state { $0.buttons = [.a] }, at: 2010)
        assertFail(run(aHold, expected: DevExpectedItems(buttons: ["A"]), rig: flicker, windowMs: 5000), containing: "A did not stay held: drops 1")

        var hat = DevStep(id: "w-hold", kind: .held, controls: ["paddle_outer_left"], title: "t", seconds: 5)
        var e = DevExpect(); e.item = "W"
        hat.expect = e
        var west = Rig()
        west.set(state { $0.buttons = [.dpadLeft] }, at: 100)
        assertPass(run(hat, expected: DevExpectedItems(hat: "W"), rig: west, windowMs: 5000))
    }

    func testHeldInconclusiveCases() {
        var rig = Rig()
        holdRT(&rig)
        guard case .inconclusive(let why) = run(rtHold, rig: rig, windowMs: holdMs, matched: 2).verdict else { return XCTFail() }
        XCTAssertEqual(why, "reader matched 2 pads")
        guard case .inconclusive(let why2) = run(rtHold, entry: nil, rig: rig, windowMs: holdMs).verdict else { return XCTFail() }
        XCTAssertEqual(why2, "pad state unknown")
        // A G key puts nothing on the pad: there is nothing to hold.
        let g1 = DevStep(id: "g1-hold", kind: .held, controls: ["g1"], title: "t", seconds: 5)
        guard case .inconclusive(let why3) = run(g1, rig: rig, windowMs: 5000).verdict else { return XCTFail() }
        XCTAssertEqual(why3, "nothing on the pad to hold")
        var bad = rtHold
        var e = DevExpect(); e.item = "Q"
        bad.expect = e
        guard case .inconclusive(let why4) = run(bad, rig: rig, windowMs: 5000).verdict else { return XCTFail() }
        XCTAssertTrue(why4.hasPrefix("unknown item"), why4)
    }

    func testHeldItemNames() {
        XCTAssertEqual(DevHeldItem(name: "RT"), .trigger(.right))
        XCTAssertEqual(DevHeldItem(name: "lt"), .trigger(.left))
        XCTAssertEqual(DevHeldItem(name: "A"), .item(.a))
        XCTAssertEqual(DevHeldItem(name: "D-pad left"), .item(.dpadLeft))
        XCTAssertEqual(DevHeldItem(name: "NE"), .hat(2))
        XCTAssertNil(DevHeldItem(name: "none"))
        XCTAssertNil(DevHeldItem(name: "Q"))
        XCTAssertTrue(DevHeldItem.hat(2).isHeld(decoded(state { $0.buttons = [.dpadUp, .dpadRight] }), minLevel: 0.5))
        XCTAssertFalse(DevHeldItem.hat(2).isHeld(decoded(state { $0.buttons = [.dpadUp] }), minLevel: 0.5))
    }
}

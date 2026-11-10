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
                     reference: DevJudge.Reference? = nil, rules: DevJudge.Rules = .init(), handOvers: Int = 0,
                     activity: [DevJudge.ControlSample] = []) -> DevJudge.Outcome {
        let input = DevJudge.Input(step: step, expected: expected, entryState: entry.map(decoded), reports: rig.reports,
                                   windowStartNs: Rig.ns(0), windowEndNs: Rig.ns(windowMs), endNs: Rig.ns(windowMs + releaseMs),
                                   matchedCount: matched, reference: reference, handOvers: handOvers, controlActivity: activity)
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

    /// What the first real run showed (2026-11-09): every source switch posts the design's switch neutral and the new
    /// source reposts the full state 0.4-0.9 ms later. Those are blips, counted and reported, not drops.
    func testHeldSwitchBlipsUnderFiveMillisecondsPass() {
        var rig = Rig()
        holdRT(&rig, until: 30_000, letGoAt: nil)
        for t in [5_000.0, 11_000.0, 17_000.0] {
            rig.set(PadState(), at: t)                                // the switch neutral ...
            rig.set(state { $0.rt = 1.0 }, at: t + 0.9)              // ... reposted under a millisecond later
        }
        rig.set(PadState(), at: 38_200)
        let o = run(rtHold, rig: rig, windowMs: holdMs, releaseMs: 500, handOvers: 12)
        assertPass(o)
        XCTAssertEqual(o.metrics.values["held.drops"], 0)
        XCTAssertEqual(o.metrics.values["held.blips"], 3)
        XCTAssertEqual(o.metrics.values["held.longestReleaseMs"] ?? 0, 0.9, accuracy: 0.05)
        XCTAssertTrue(o.metrics.detail.contains("3 switch blips of at most 0.90 ms"), o.metrics.detail)
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

    // MARK: held with expect.releases (remap R4)

    /// "Hold G1, then also hold Y, let go of G1, keep Y held": G1 is sent to Y, so the pad's Y comes up with G1.
    private var g1ThenY: DevStep {
        var s = DevStep(id: "hold-g1-then-y", kind: .held, controls: ["g1", "y"], title: "t", seconds: 5)
        var e = DevExpect(); e.item = "Y"; e.releases = ["g1"]
        s.expect = e
        return s
    }
    private func sample(_ ms: Double, _ active: Set<String>) -> DevJudge.ControlSample { .init(tNs: Rig.ns(ms), active: active) }
    /// G1 down from 0 to `letGoAt` (nil = never let go), Y down on the physical key from 800 to the end.
    private func g1Frames(letGoAt: Double?) -> [DevJudge.ControlSample] {
        var out: [DevJudge.ControlSample] = []
        var t = 0.0
        while t <= 5000 {
            var a: Set<String> = []
            if letGoAt.map({ t < $0 }) ?? true { a.insert("g1") }
            if t >= 800 { a.insert("y") }
            out.append(sample(t, a))
            t += 100
        }
        return out
    }
    private var yHeld: Rig {
        var rig = Rig()
        rig.set(state { $0.buttons = [.y] }, at: 20)            // G1 reaches the pad as Y, then the real Y joins and G1 goes
        return rig
    }

    func testHeldReleasesPassesWhenG1IsLetGoWhileYStaysHeld() {
        let o = run(g1ThenY, expected: DevExpectedItems(buttons: ["Y"]), rig: yHeld, activity: g1Frames(letGoAt: 2000))
        assertPass(o)
        XCTAssertEqual(o.metrics.values["held.drops"], 0)
        XCTAssertEqual(o.metrics.values["held.released"], 1)
        XCTAssertTrue(o.metrics.detail.contains("G1 let go while Y stayed held"), o.metrics.detail)
    }

    func testHeldReleasesFailsWhenG1IsNeverLetGo() {
        let o = run(g1ThenY, expected: DevExpectedItems(buttons: ["Y"]), rig: yHeld, activity: g1Frames(letGoAt: nil))
        assertFail(o, containing: "G1 was never let go while Y stayed held")
        XCTAssertEqual(o.metrics.values["held.drops"], 0, "Y itself never dropped")
        XCTAssertEqual(o.metrics.values["held.released"], 0)
    }

    func testHeldReleasesFailsWhenG1WasNeverSeenPressed() {
        let none = (0...50).map { sample(Double($0) * 100, $0 >= 8 ? ["y"] : []) }
        assertFail(run(g1ThenY, expected: DevExpectedItems(buttons: ["Y"]), rig: yHeld, activity: none),
                   containing: "G1 was never seen pressed while Y stayed held")
    }

    func testHeldReleasesStillFailsWhenYDropsAndSaysSoToo() {
        var rig = Rig()
        rig.set(state { $0.buttons = [.y] }, at: 20)
        rig.set(PadState(), at: 3000)                           // Y falls out, G1 was let go at 2000
        let o = run(g1ThenY, expected: DevExpectedItems(buttons: ["Y"]), rig: rig, activity: g1Frames(letGoAt: 2000))
        assertFail(o, containing: "Y did not stay held: drops 1")
        XCTAssertEqual(o.metrics.values["held.released"], 1)
    }

    func testHeldReleasesCountsOnlyALetGoWhileTheItemIsHeldAndInsideTheWindow() {
        // Y reaches the pad only at 1000; G1 was let go at 500, before that: not a hand-over.
        var late = Rig()
        late.set(state { $0.buttons = [.y] }, at: 1000)
        assertFail(run(g1ThenY, expected: DevExpectedItems(buttons: ["Y"]), rig: late, activity: g1Frames(letGoAt: 500)),
                   containing: "G1 was never let go")
        // Let go after the window ends (in the release tail): the window is what is judged.
        let tail = (0...55).map { sample(Double($0) * 100, $0 * 100 < 5200 ? ["g1", "y"] : ["y"]) }
        assertFail(run(g1ThenY, expected: DevExpectedItems(buttons: ["Y"]), rig: yHeld, activity: tail),
                   containing: "G1 was never let go while Y stayed held")
        // A second press after a let-go is fine; only one let-go is needed.
        var twice = g1Frames(letGoAt: 2000)
        twice += (31...40).map { sample(Double($0) * 100, ["g1", "y"]) }
        assertPass(run(g1ThenY, expected: DevExpectedItems(buttons: ["Y"]), rig: yHeld, activity: twice))
    }

    func testHeldReleasesWithoutReceiverFramesCannotBeJudged() {
        let o = run(g1ThenY, expected: DevExpectedItems(buttons: ["Y"]), rig: yHeld)
        guard case .inconclusive(let why) = o.verdict else { return XCTFail("\(o.verdict)") }
        XCTAssertTrue(why.contains("G1"), why)
        // A held step without releases is unchanged by the samples.
        var plain = g1ThenY
        plain.expect?.releases = nil
        assertPass(run(plain, expected: DevExpectedItems(buttons: ["Y"]), rig: yHeld))
    }

    func testControlWordIsTheOwnersWord() {
        XCTAssertEqual(DevJudge.controlWord("g1"), "G1")
        XCTAssertEqual(DevJudge.controlWord("paddle_outer_left"), "paddle outer left")
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

    // MARK: per-event latency

    private func frame(_ ms: Double, _ make: (inout PadState) -> Void = { _ in }) -> DevJudge.Reference.Frame {
        .init(tNs: Rig.ns(ms), pad: state(make))
    }
    private func referenceWith(_ frames: [DevJudge.Reference.Frame]) -> DevJudge.Reference {
        DevJudge.Reference(expectedChanges: frames.count, firstFrameChangeNs: frames.first?.tNs, frames: frames)
    }
    private func tapA(times: Int, pressDelayMs: (Int) -> Double, releaseDelayMs: (Int) -> Double, dropPadFor dropped: Set<Int> = [])
        -> (rig: Rig, frames: [DevJudge.Reference.Frame]) {
        var rig = Rig()
        var frames: [DevJudge.Reference.Frame] = []
        for i in 0..<times {
            let down = 200 + Double(i) * 400, up = down + 150
            frames.append(frame(down) { $0.buttons = [.a] })
            frames.append(frame(up))
            if dropped.contains(i) { continue }
            rig.set(state { $0.buttons = [.a] }, at: down + pressDelayMs(i))
            rig.set(PadState(), at: up + releaseDelayMs(i))
        }
        return (rig, frames)
    }

    func testLatencyDigitalGivesExactPercentilesAndTheDetailLine() {
        // 10 taps: press delays 0.10 ... 0.19 ms, release delays 0.20 ms except the last, 0.40 ms.
        let (rig, frames) = tapA(times: 10, pressDelayMs: { 0.10 + 0.01 * Double($0) }, releaseDelayMs: { $0 == 9 ? 0.40 : 0.20 })
        var step = aStep
        var e = DevExpect(); e.times = 10
        step.expect = e
        let o = run(step, expected: aExpected, rig: rig, windowMs: 4500, releaseMs: 0, reference: referenceWith(frames))
        assertPass(o)
        let v = o.metrics.values
        XCTAssertEqual(v["lat.n"], 20)
        XCTAssertEqual(v["lat.unmatched"], 0)
        // sorted: 0.10 ... 0.19, then 0.20 x 9, then 0.40; padlat's nearest rank: index Int((n - 1) * p + 0.5)
        XCTAssertEqual(v["lat.p50Ms"] ?? 0, 0.20, accuracy: 1e-3)      // index 10
        XCTAssertEqual(v["lat.p95Ms"] ?? 0, 0.20, accuracy: 1e-3)      // index 18
        XCTAssertEqual(v["lat.p99Ms"] ?? 0, 0.40, accuracy: 1e-3)      // index 19
        XCTAssertEqual(v["lat.maxMs"] ?? 0, 0.40, accuracy: 1e-3)
        XCTAssertTrue(o.metrics.detail.hasSuffix("latency p50 0.20 ms (n=20, p99 0.40, max 0.40)."), o.metrics.detail)
    }

    func testLatencyAnEdgeThePadNeverAnsweredIsUnmatchedAndNotPaidByTheNextOne() {
        // The pad drops the whole middle tap. The press of tap 3 must not answer the press of tap 2, nor the release of 3
        // the release of 2: each edge only looks until the next edge of the same kind.
        let (rig, frames) = tapA(times: 3, pressDelayMs: { _ in 0.1 }, releaseDelayMs: { _ in 0.1 }, dropPadFor: [1])
        var step = aStep
        var e = DevExpect(); e.times = 2
        step.expect = e
        let o = run(step, expected: aExpected, rig: rig, windowMs: 1500, releaseMs: 0, reference: referenceWith(frames))
        XCTAssertEqual(o.metrics.values["lat.n"], 4)
        XCTAssertEqual(o.metrics.values["lat.unmatched"], 2)
        XCTAssertEqual(o.metrics.values["lat.p50Ms"] ?? 0, 0.1, accuracy: 1e-3)
        XCTAssertTrue(o.metrics.detail.contains("(n=4, p99 0.10, max 0.10, 2 unanswered)"), o.metrics.detail)
    }

    func testLatencyWhenThePadNeverAnswersAtAll() {
        let frames = [frame(200) { $0.buttons = [.a] }, frame(350)]
        let o = run(aStep, expected: aExpected, rig: Rig(), releaseMs: 0, reference: referenceWith(frames))
        XCTAssertEqual(o.metrics.values["lat.n"], 0)
        XCTAssertEqual(o.metrics.values["lat.unmatched"], 2)
        XCTAssertNil(o.metrics.values["lat.p50Ms"])
        XCTAssertTrue(o.metrics.detail.contains("none of 2 receiver edges was answered"), o.metrics.detail)
    }

    func testLatencyOnlyCountsTheExpectedItems() {
        // The receiver also moves B; the pad answers it; only A is watched.
        var rig = Rig()
        rig.set(state { $0.buttons = [.a, .b] }, at: 200.3)
        rig.set(PadState(), at: 350.3)
        let frames = [frame(200) { $0.buttons = [.a, .b] }, frame(350)]
        var step = aStep
        var e = DevExpect(); e.times = 1
        step.expect = e
        let o = run(step, expected: aExpected, rig: rig, releaseMs: 0, reference: referenceWith(frames))
        XCTAssertEqual(o.metrics.values["lat.n"], 2)
        XCTAssertEqual(o.metrics.values["lat.p50Ms"] ?? 0, 0.3, accuracy: 1e-3)
    }

    /// A flick: out to 0.9 at `t`, back inside 20 ms later, a 5 ms wobble outside again, then rest. The receiver frames
    /// and the pad mirror each other, the pad `delay` ms late.
    private func flick(_ rig: inout Rig, _ frames: inout [DevJudge.Reference.Frame], at t: Double, delay: Double) {
        let seq: [(Double, Double)] = [(0, 0.9), (10, 0.9), (20, 0.0), (25, 0.25), (30, 0.0)]
        for (dt, x) in seq {
            frames.append(frame(t + dt) { $0.lx = x })
            rig.set(state { $0.lx = x }, at: t + dt + delay)
        }
    }

    func testLatencyStickOnsetsCountSpringBackWobbleOnce() {
        var rig = Rig()
        var frames = [frame(0) { _ in }]
        // 3 flicks; the first frame of the window is the first onset (the window opens on the first movement).
        for (i, d) in [0.25, 0.30, 0.35].enumerated() { flick(&rig, &frames, at: 100 + Double(i) * 300, delay: d) }
        var step = leftStick
        var e = DevExpect(); e.flicks = 3; e.requireDirections = false
        step.expect = e
        let o = run(step, rig: rig, windowMs: 1500, releaseMs: 500, reference: referenceWith(frames))
        assertPass(o)
        XCTAssertEqual(o.metrics.values["ls.onsets"], 3, "the wobble after the spring-back is not a new flick")
        XCTAssertEqual(o.metrics.values["lat.n"], 3)
        XCTAssertEqual(o.metrics.values["lat.unmatched"], 0)
        XCTAssertEqual(o.metrics.values["lat.p50Ms"] ?? 0, 0.30, accuracy: 1e-3)     // index Int(2 * 0.5 + 0.5) = 1 of [0.25, 0.30, 0.35]
        XCTAssertEqual(o.metrics.values["lat.maxMs"] ?? 0, 0.35, accuracy: 1e-3)
        XCTAssertTrue(o.metrics.detail.hasSuffix("latency p50 0.30 ms (n=3, p99 0.35, max 0.35)."), o.metrics.detail)
        XCTAssertTrue(o.metrics.detail.contains("3 flicks (needs 3)"), o.metrics.detail)
    }

    func testLatencyStickOnsetAfterAShortRestIsNotAnEdgeButAfterALongOneIs() {
        // Back inside for 30 ms only, then out again: one onset. Back inside for 80 ms, then out: a second one.
        let frames = [frame(0) { $0.lx = 0.9 }, frame(10), frame(40) { $0.lx = 0.9 }, frame(50), frame(130) { $0.lx = 0.9 }, frame(140)]
        let edges = DevLatency.receiverEdges(frames: frames, watch: .init(stick: .left), config: .init())
        XCTAssertEqual(edges.map(\.tNs), [Rig.ns(0), Rig.ns(130)])
    }

    func testStickFlickRuleNeedsEnoughFlicksAndRequireDirectionsOffDropsTheCircle() {
        var rig = Rig()
        var frames: [DevJudge.Reference.Frame] = []
        for i in 0..<2 { flick(&rig, &frames, at: 100 + Double(i) * 300, delay: 0.2) }
        var step = leftStick
        var e = DevExpect(); e.flicks = 3; e.requireDirections = false
        step.expect = e
        assertFail(run(step, rig: rig, windowMs: 1500), containing: "left the dead zone from rest 2 times (needs 3 flicks)")
        e.flicks = 2
        step.expect = e
        assertPass(run(step, rig: rig, windowMs: 1500))
        // The same flicks fail the circle rule: they never went round.
        e.flicks = nil; e.requireDirections = nil
        step.expect = e
        assertFail(run(step, rig: rig, windowMs: 1500), containing: "never reached")
    }

    func testLatencyTriggerPullsAndReleasesWithFiveFullPulls() {
        var rig = Rig()
        var frames: [DevJudge.Reference.Frame] = []
        for i in 0..<5 {
            let b = 100 + Double(i) * 400, d = 0.10 + 0.05 * Double(i)
            // value / delay: the 0.6 frame is the pull edge (>= 0.5), the 0.0 frame the release edge (<= 0.05)
            for (dt, v, delay) in [(0.0, 0.3, d), (5.0, 0.6, d), (10.0, 1.0, d), (100.0, 0.4, 0.2), (105.0, 0.0, 0.2)] {
                frames.append(frame(b + dt) { $0.rt = v })
                rig.set(state { $0.rt = v }, at: b + dt + delay)
            }
        }
        var step = DevStep(id: "rt", kind: .trigger, controls: ["rt"], title: "t", seconds: 10, releaseSeconds: 0.5)
        var e = DevExpect(); e.times = 5
        step.expect = e
        let o = run(step, rig: rig, windowMs: 2500, releaseMs: 500, reference: referenceWith(frames))
        assertPass(o)
        XCTAssertEqual(o.metrics.values["rt.pulls"], 5)
        XCTAssertEqual(o.metrics.values["lat.n"], 10)
        XCTAssertEqual(o.metrics.values["lat.unmatched"], 0)
        // pulls 0.10 0.15 0.20 0.25 0.30, releases 0.20 x 5: sorted index 5 of 10 is 0.20
        XCTAssertEqual(o.metrics.values["lat.p50Ms"] ?? 0, 0.20, accuracy: 1e-3)
        XCTAssertEqual(o.metrics.values["lat.maxMs"] ?? 0, 0.30, accuracy: 1e-3)

        // Only four pulls: the rule fails and says how many.
        var four = Rig()
        for i in 0..<4 { four.reports += rig.reports.filter { $0.tNs >= Rig.ns(100 + Double(i) * 400 - 1) && $0.tNs < Rig.ns(100 + Double(i + 1) * 400 - 1) } }
        assertFail(run(step, rig: four, windowMs: 2500, releaseMs: 500), containing: "released 4 times (needs 5)")
        // times 1 (the default) is unchanged: one pull is enough and the old message stays
        step.expect = nil
        assertPass(run(step, rig: four, windowMs: 2500, releaseMs: 500))
    }

    func testLatencyIsLeftOutForRestAndWithoutFrames() {
        let frames = [frame(200) { $0.buttons = [.a] }, frame(350)]
        let r = run(rest, rig: Rig(), windowMs: 3000, releaseMs: 0, reference: referenceWith(frames))
        XCTAssertNil(r.metrics.values["lat.n"])
        XCTAssertFalse(r.metrics.detail.contains("latency"))
        let bare = DevJudge.Reference(expectedChanges: 4, firstFrameChangeNs: Rig.ns(300))
        let d = run(aStep, expected: aExpected, rig: Rig(), releaseMs: 0, reference: bare)
        XCTAssertNil(d.metrics.values["lat.n"])
        XCTAssertFalse(d.metrics.detail.contains("latency"))
    }

    func testLatencyOfAHeldStepSeesTheLetGoInTheTail() {
        var rig = Rig()
        holdRT(&rig)       // ramp at 50/100/150 ms, let go at 38 200 ms (in the release tail)
        let frames = [frame(99.9) { $0.rt = 0.8 }, frame(38_199.8)]
        let o = run(rtHold, rig: rig, windowMs: holdMs, releaseMs: 500, reference: referenceWith(frames))
        assertPass(o)
        XCTAssertEqual(o.metrics.values["lat.n"], 2)
        XCTAssertEqual(o.metrics.values["lat.p50Ms"] ?? 0, 0.2, accuracy: 1e-3)     // [0.1, 0.2], index 1
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

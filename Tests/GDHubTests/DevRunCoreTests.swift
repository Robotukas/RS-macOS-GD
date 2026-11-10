import XCTest
@testable import GDHub

/// A scripted world for the runner: a fake clock, a receiver frame and a pad state the test changes, with the same
/// ordering the real thing has (the receiver frame first, the pad report a moment later).
private final class Rig {
    var core = DevRunCore()
    var now: UInt64 = 10_000_000_000
    var log: [DevRunCore.Action] = []
    var frame = GamepadFrame.idle
    var pad = PadState()
    private var lastBytes: [UInt8: [UInt8]] = [:]
    var mapping = ControlMapping.default
    static let layout = ControlLayout.loadFromBundle()!

    @discardableResult
    func send(_ e: DevRunCore.Event) -> [DevRunCore.Action] {
        let a = core.handle(e, now: now)
        log += a
        return a
    }

    func advance(_ ms: Double, step: Double = 5) {
        var left = ms
        while left > 0 {
            let d = min(step, left)
            now += UInt64(d * 1e6)
            send(.frame(frame, tNs: now))
            send(.tick(now))
            left -= d
        }
    }

    /// Posts the reports that changed, like the sink does.
    func setPad(_ s: PadState) {
        pad = s
        var reps: [DevJudge.TimedReport] = []
        for r in PadReportBuilders.xboxBT16(s) where lastBytes[r.id] != r.bytes {
            reps.append(.init(tNs: now, id: r.id, bytes: r.bytes))
            lastBytes[r.id] = r.bytes
        }
        if !reps.isEmpty { send(.reports(reps)) }
    }

    /// The receiver moves first; the pad follows 5 ms later.
    func move(_ f: GamepadFrame, _ p: PadState, hold ms: Double = 150) {
        frame = f
        advance(5)
        setPad(p)
        advance(ms - 5)
    }

    func releaseAll(hold ms: Double = 150) { move(.idle, PadState(), hold: ms) }

    func pressA(times n: Int = 2) {
        var f = GamepadFrame.idle
        f.buttons = 1
        var p = PadState()
        p.buttons = [.a]
        for _ in 0..<n {
            move(f, p)
            releaseAll()
        }
    }

    static func status(armed: String = "inert", path: String = "engine", pid: Int32 = 100,
                       _ edit: (inout TapStatusReport) -> Void = { _ in }) -> TapStatusReport {
        var r = TapStatusReport()
        r.pid = pid; r.path = path; r.armed = armed; r.connected = true; r.capTap = true; r.capXlate = true
        edit(&r)
        return r
    }

    var states: [DevRunCore.State] { [core.state] }
    func count(_ match: (DevRunCore.Action) -> Bool) -> Int { log.filter(match).count }
    var reportsWritten: [DevRunReport] {
        log.compactMap { if case .writeReport(let r, _) = $0 { return r } else { return nil } }
    }
    var pathWrites: [String] { log.compactMap { if case .writePath(let v) = $0 { return v } else { return nil } } }
    var restores: Int { count { $0 == .restorePath } }
    var dones: Int { count { $0 == .done } }
    var prompts: [DevPrompt] { log.compactMap { if case .needsPrompt(let p) = $0 { return p } else { return nil } } }
    var lastInstruction: (title: String, detail: String)? {
        for a in log.reversed() { if case .setInstruction(let t, let d, _, _) = a { return (t, d) } }
        return nil
    }

    // MARK: Setup

    static let restStep = DevStep(id: "rest", kind: .rest, title: "Hands off", seconds: 2, readySeconds: 1)
    static let aStep = DevStep(id: "a", kind: .digital, controls: ["a"], title: "Press A twice", seconds: 3, readySeconds: 1)
    static let bStep = DevStep(id: "b", kind: .digital, controls: ["b"], title: "Press B twice", seconds: 3, readySeconds: 1)
    static let leftStick = DevStep(id: "left_stick", kind: .stick, controls: ["left_stick"], title: "Roll", seconds: 5, readySeconds: 1, releaseSeconds: 0.5)

    /// RT held, with hand-overs between Driver and App (`count` writes, `intervalMs` apart).
    static func heldStep(interval: Int = 100, count: Int? = 3, seconds: Double = 45) -> DevStep {
        var s = DevStep(id: "rt-hold", kind: .held, controls: ["rt"], title: "Pull RT all the way in and just hold it still", seconds: seconds, readySeconds: 1)
        var e = DevExpect(); e.item = "RT"; e.minLevel = 0.5
        s.expect = e
        if let count {
            var t = DevToggleInputPath(); t.values = ["driver", "engine"]; t.intervalMs = interval; t.count = count
            var a = DevAction(); a.toggleInputPath = t
            s.actions = [a]
        }
        return s
    }

    var rtDown: (GamepadFrame, PadState) {
        var f = GamepadFrame.idle; f.rt = 1023
        var p = PadState(); p.rt = 1.0
        return (f, p)
    }

    /// Advances like `advance`, and answers every path write like the engine would: armed follows the written value.
    /// `follow` false leaves the engine unmoved.
    func advanceAnswering(_ ms: Double, follow: Bool = true) {
        var left = ms
        while left > 0 {
            advance(5)
            left -= 5
            while answered < pathWrites.count {
                let v = pathWrites[answered]
                answered += 1
                if follow { send(.status(Rig.status(armed: v == "driver" ? "live" : "inert", path: v))) }
            }
        }
    }
    var answered = 0

    func setup(_ target: DevTarget = .engine, steps: [DevStep] = [Rig.restStep, Rig.aStep, Rig.bStep],
               paths: [String]? = nil) -> DevRunSetup {
        let t = DevTemplate(id: "test", title: "Test", paths: paths, steps: steps)
        let resolved = DevResolvedStep.resolve(template: t, mapping: mapping, layout: Rig.layout)
        return DevRunSetup(target: target, template: t, steps: resolved, mapping: mapping,
                           allControlIDs: Rig.layout.controlsByOrder.map(\.id), startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           nowNs: now, padSeed: .neutral)
    }

    /// The world before Start: engine 100 running on the engine path, controller awake, one pad, pad known to be neutral.
    func prepare(status s: TapStatusReport? = Rig.status()) {
        send(.enginePid(100))
        send(.status(s))
        send(.controllerActive(true))
        send(.readerMatched(1))
        advance(400)
    }

    func start(_ target: DevTarget = .engine, steps: [DevStep] = [Rig.restStep, Rig.aStep, Rig.bStep], paths: [String]? = nil) {
        send(.start(setup(target, steps: steps, paths: paths)))
    }

    /// Runs the clock until the step is in its Go state (hands still, ready time over).
    func untilGo(limitMs: Double = 8000) {
        var spent = 0.0
        while !core.isGo, spent < limitMs { advance(10); spent += 10 }
        XCTAssertTrue(core.isGo, "never reached Go; state \(core.state)")
    }

    func untilStep(_ index: Int, phase: DevRunCore.Phase? = nil, limitMs: Double = 12000) {
        var spent = 0.0
        func there() -> Bool {
            if case .step(let i, let p) = core.state, i == index, phase == nil || p == phase { return true }
            return false
        }
        while !there(), spent < limitMs { advance(10); spent += 10 }
        XCTAssertTrue(there(), "never reached step \(index) \(String(describing: phase)); state \(core.state)")
    }

    func verdict(_ index: Int, pass: Int = 0) -> DevVerdict? { DevRunCore.latestVerdict(core.results[pass][index]) }
}

final class DevRunCoreTests: XCTestCase {
    // MARK: Start and the path

    func testStartOnTheAlreadyConfirmedPathWritesNothing() {
        let r = Rig()
        r.prepare()
        r.start()
        XCTAssertEqual(r.pathWrites, [], "engine path already in force, nothing latched")
        XCTAssertEqual(r.count { $0 == .takeSnapshot }, 1)
        XCTAssertEqual(r.count { $0 == .setCapture(true) }, 1)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
    }

    func testSwitchingToDriverWritesThePathAndWaitsForLive() {
        let r = Rig()
        r.prepare()
        r.start(.driver)
        XCTAssertEqual(r.pathWrites, ["driver"])
        guard case .switching(_, let expected) = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertEqual(expected, "live")
        // The request alone is not the confirmation: path says driver, the dext is still SHADOW.
        r.send(.status(Rig.status(armed: "shadow", path: "driver")))
        r.advance(1500)
        guard case .switching = r.core.state else { return XCTFail("confirmed on an echo of the request: \(r.core.state)") }
        r.send(.status(Rig.status(armed: "live", path: "driver")))
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
    }

    func testConfirmNeedsThisEngineNoFallbackNoLatchNoNoteAndLive() {
        for (name, report) in [
            ("other pid", Rig.status(armed: "live", path: "driver", pid: 999)),
            ("fallback", Rig.status(armed: "live", path: "driver") { $0.fallback = "tap stalled" }),
            ("latched", Rig.status(armed: "live", path: "driver") { $0.latched = "breaker" }),
            ("mapping note", Rig.status(armed: "live", path: "driver") { $0.mappingNote = "needs v2" }),
            ("live unavailable", Rig.status(armed: "live", path: "driver") { $0.liveUnavailable = true }),
        ] {
            let r = Rig()
            r.prepare(status: report)
            r.start(.driver)
            if case .step = r.core.state { XCTFail("\(name) must not confirm") }
        }
        let good = Rig()
        good.prepare(status: Rig.status(armed: "live", path: "driver"))
        good.start(.driver)
        XCTAssertEqual(good.pathWrites, [], "path already driver")
        XCTAssertEqual(good.core.state, .step(index: 0, phase: .ready))
    }

    func testConfirmTimeoutAsksAndRunAnywayStampsEveryAttempt() {
        let r = Rig()
        r.prepare()
        r.start(.driver)
        r.send(.status(Rig.status(armed: "shadow", path: "driver", { $0.liveUnavailable = true })))
        r.advance(10_100)
        XCTAssertEqual(r.prompts.count, 1)
        guard case .runAnyway(let text)? = r.prompts.first else { return XCTFail("\(r.prompts)") }
        XCTAssertTrue(text.hasPrefix("Driven by:"), text)
        r.advance(2000)
        XCTAssertEqual(r.prompts.count, 1, "asked once")
        r.send(.runAnyway)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
        r.untilGo()
        r.advance(2200)
        r.untilStep(1)
        XCTAssertTrue(r.core.results[0][0]?.attempts.allSatisfy(\.pathUnconfirmed) ?? false)
        XCTAssertTrue(r.core.notes.contains { $0.contains("Run anyway") })
    }

    func testLatchedBreakerAsksBeforeReArmingAndTheAnswerIsKept() {
        let r = Rig()
        r.prepare(status: Rig.status(armed: "inert", path: "driver") { $0.latched = "breaker" })
        r.start(.driver)
        XCTAssertEqual(r.pathWrites, [], "nothing is written before the owner answers")
        guard case .rearmLatched(let why)? = r.prompts.first else { return XCTFail("\(r.prompts)") }
        XCTAssertTrue(why.contains("breaker"))
        r.send(.runAnyway)
        XCTAssertEqual(r.pathWrites, ["driver"])
        XCTAssertTrue(r.core.notes.contains { $0.contains("re-arm") })
        r.send(.stop)
        XCTAssertEqual(r.restores, 1)
    }

    func testEngineTargetIsNotAskedAboutALatch() {
        let r = Rig()
        r.prepare(status: Rig.status(armed: "inert", path: "driver") { $0.latched = "breaker" })
        r.start(.engine)
        XCTAssertEqual(r.pathWrites, ["engine"])
        XCTAssertTrue(r.prompts.isEmpty)
        r.send(.status(Rig.status(armed: "inert", path: "engine") { $0.latched = "breaker" }))
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready), "the engine path keeps posting whatever the driver latch says")
    }

    func testInAppTargetSwitchesAndRestoresNothing() {
        let r = Rig()
        r.send(.controllerActive(true)); r.send(.readerMatched(1))
        r.advance(400)
        r.start(.inApp)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
        XCTAssertEqual(r.count { $0 == .takeSnapshot }, 0)
        r.send(.stop)
        XCTAssertEqual(r.restores, 0)
        XCTAssertEqual(r.pathWrites, [])
    }

    // MARK: Ready, window, judging

    func testReadyWaitsForTheControllerFramesAndStillness() {
        let r = Rig()
        r.send(.enginePid(100)); r.send(.status(Rig.status())); r.send(.readerMatched(1))
        r.start(steps: [Rig.aStep])
        r.advance(3000)
        XCTAssertFalse(r.core.isGo, "controller not active")
        r.send(.controllerActive(true))
        r.advance(10)
        XCTAssertTrue(r.core.isGo, "still for 3 s and the ready time is over: only the controller was missing")

        let fresh = Rig()
        fresh.send(.enginePid(100)); fresh.send(.status(Rig.status())); fresh.send(.readerMatched(1)); fresh.send(.controllerActive(true))
        fresh.start(steps: [Rig.aStep])
        fresh.advance(100)
        XCTAssertFalse(fresh.core.isGo, "hands not yet still for 300 ms and ready time not over")
        fresh.untilGo()

        let rest = Rig()
        rest.prepare()
        rest.start(steps: [Rig.restStep])
        rest.untilGo()
        XCTAssertEqual(rest.core.state, .step(index: 0, phase: .window), "a rest step opens its window at Go")
    }

    func testMovingKeepsTheHandsStillGateClosed() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep])
        var f = GamepadFrame.idle
        f.buttons = 1 << 1                   // B held: not the wanted control, and not still
        r.frame = f
        r.advance(3000)
        XCTAssertFalse(r.core.isGo)
        r.frame = .idle
        r.untilGo()
    }

    func testDigitalStepPassesAndEndsEarly() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        r.untilGo()
        let goAt = r.now
        r.pressA()
        // Two presses are done; 350 ms of rest later the window ends early and the step passes well before its 3 s.
        r.advance(400)
        XCTAssertEqual(r.verdict(0), .pass, "\(String(describing: r.core.results[0][0]?.attempts.last?.metrics.detail))")
        XCTAssertLessThan(r.now - goAt, 2_500_000_000, "early end, not the full window")
        XCTAssertEqual(r.core.state, .step(index: 1, phase: .ready))
        let att = r.core.results[0][0]!.attempts[0]
        XCTAssertGreaterThan(att.windowStartNs, 0)
        XCTAssertEqual(att.metrics.expectedChanges, 4, "two presses, two releases seen by the receiver")
        XCTAssertEqual(att.metrics.padChanged, 4)
        XCTAssertEqual(att.metrics.lossRatio ?? 0, 1.0, accuracy: 0.001)
        XCTAssertNotNil(att.metrics.onsetMs)
        // Per-event latency: the rig posts the pad report at the instant of the receiver frame (0 ms) for all four edges.
        XCTAssertEqual(att.metrics.values["lat.n"], 4)
        XCTAssertEqual(att.metrics.values["lat.unmatched"], 0)
        XCTAssertEqual(att.metrics.values["lat.p50Ms"] ?? -1, 0, accuracy: 1e-6)
        XCTAssertTrue(att.metrics.detail.contains("latency p50 0.00 ms (n=4"), att.metrics.detail)
    }

    func testOnePressIsNotEnoughToEndEarly() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep])
        r.untilGo()
        r.pressA(times: 1)
        r.advance(1000)
        guard case .step(0, .window) = r.core.state else { return XCTFail("ended after one press: \(r.core.state)") }
        r.advance(3000)
        XCTAssertEqual(r.core.state, .finished)
        guard case .fail(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.contains("went down 1"), why)
    }

    func testStickStepEndsAfterTheReleaseTail() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.leftStick])
        r.untilGo()
        // One slow circle at the rim, receiver first, pad 5 ms later, 5 ms apart.
        for i in 0..<300 {
            let a = Double(i) / 300 * 2 * .pi * 1.5
            var f = GamepadFrame.idle
            f.x = Int16(30000 * cos(a)); f.y = Int16(30000 * sin(a))
            var s = PadState()
            s.lx = 0.9 * cos(a); s.ly = -0.9 * sin(a)
            r.frame = f
            r.advance(5)
            r.setPad(s)
        }
        r.releaseAll(hold: 100)
        // Rest for 350 ms makes the window end early; then a 0.5 s tail; then the verdict.
        r.advance(1500)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.verdict(0), .pass, r.core.results[0][0]?.attempts.last?.metrics.detail ?? "")
        let a = r.core.results[0][0]!.attempts[0]
        XCTAssertGreaterThanOrEqual(a.windowEndNs - a.windowStartNs, 1_000_000_000)
        XCTAssertLessThan(a.windowEndNs - a.windowStartNs, 4_000_000_000, "ended early")
    }

    /// The owner's first real run: rolling until the ring fills, letting go only afterwards. The release tail must
    /// stretch until the stick is back at rest instead of judging a still-deflected stick after 0.5 s.
    func testStickRolledUntilTheRingFillsPassesOnceReleased() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.leftStick])
        r.untilGo()
        // Keep circling for 5.6 s: past the 5 s window and past the nominal 0.5 s tail.
        for i in 0..<1120 {
            let a = Double(i) / 300 * 2 * .pi
            var f = GamepadFrame.idle
            f.x = Int16(30000 * cos(a)); f.y = Int16(30000 * sin(a))
            var s = PadState()
            s.lx = 0.9 * cos(a); s.ly = -0.9 * sin(a)
            r.frame = f
            r.advance(5)
            r.setPad(s)
        }
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .release), "still waiting for the release")
        r.releaseAll(hold: 100)
        r.advance(1000)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.verdict(0), .pass, r.core.results[0][0]?.attempts.last?.metrics.detail ?? "")
    }

    /// Never letting go ends the step after the grace, with the honest failure.
    func testStickNeverReleasedFailsAfterTheReleaseGrace() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.leftStick])
        r.untilGo()
        for i in 0..<2000 {
            let a = Double(i) / 300 * 2 * .pi
            var f = GamepadFrame.idle
            f.x = Int16(30000 * cos(a)); f.y = Int16(30000 * sin(a))
            var s = PadState()
            s.lx = 0.9 * cos(a); s.ly = -0.9 * sin(a)
            r.frame = f
            r.advance(5)
            r.setPad(s)
        }
        XCTAssertEqual(r.core.state, .finished)
        guard case .fail(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.contains("outside the dead zone"), why)
    }

    /// Crash seen on 2026-11-09: a receiver frame stamped by the kernel a little before the step started on the runner's
    /// clock reached readyGate, and `now - startedNs` overflowed. Frames older than the step must simply be tolerated.
    func testFrameStampedBeforeTheStepStartedDoesNotTrap() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.leftStick, Rig.aStep])
        // Right after the step began: frames whose kernel time is 50 ms in the past, then normal flow.
        for _ in 0..<20 { r.send(.frame(r.frame, tNs: r.now - 50_000_000)); r.send(.tick(r.now)) }
        r.untilGo()
        let before = r.core.state
        r.send(.frame(r.frame, tNs: r.now - 2_000_000_000))      // an out-of-order frame changes nothing
        XCTAssertEqual(r.core.state, before)
        XCTAssertTrue(r.core.isGo)
    }

    func testRestStepJudgesTheFullWindow() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep])
        r.untilGo()
        let start = r.now
        r.advance(2100)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertGreaterThanOrEqual(r.now - start, 2_000_000_000)
        XCTAssertEqual(r.verdict(0), .pass)
        XCTAssertEqual(r.reportsWritten.count, 1)
        XCTAssertTrue(r.reportsWritten[0].complete)
    }

    func testNoMovementWithinFiveSecondsOfGoFailsTheAttempt() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        r.untilGo()
        r.advance(5100)
        guard case .fail(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.hasPrefix("no movement"), why)
        XCTAssertEqual(r.core.state, .step(index: 1, phase: .ready))
    }

    func testHeldPadStateComesFromTheSeed() {
        // The first step starts from what the reader held; without one the judge says the pad state is unknown.
        let r = Rig()
        r.prepare()
        var s = r.setup(steps: [Rig.restStep])
        s.padSeed = nil
        r.send(.start(s))
        r.untilGo()
        r.advance(2100)
        guard case .inconclusive(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertEqual(why, "pad state unknown")
    }

    // MARK: Pause and resume

    func testPauseInReadyWindowAndReleaseAndResumeReConfirms() {
        for phase in [DevRunCore.Phase.ready, .window, .release] {
            let r = Rig()
            r.prepare()
            r.start(steps: [Rig.leftStick, Rig.aStep])
            switch phase {
            case .ready: r.advance(100)
            case .window:
                r.untilGo()
                var f = GamepadFrame.idle; f.x = 30000
                r.frame = f
                r.advance(300)
            default:
                r.untilGo()
                var f = GamepadFrame.idle; f.x = 30000
                r.frame = f
                r.advance(50)
                r.frame = .idle
                r.advance(5200)               // the window ran out; now in the tail
            }
            guard case .step(0, let p) = r.core.state else { return XCTFail("\(phase): \(r.core.state)") }
            XCTAssertEqual(p, phase)
            r.send(.pause)
            XCTAssertEqual(r.core.state, .paused(index: 0, resumeTo: .step(0)), "\(phase)")
            XCTAssertEqual(r.core.results[0][0]?.attempts.count ?? 0, phase == .ready ? 0 : 1, "\(phase): only an attempt that reached its window is kept")
            r.advance(2000)
            XCTAssertEqual(r.core.state, .paused(index: 0, resumeTo: .step(0)), "nothing runs while paused")
            // While paused the path goes wrong: Resume re-confirms instead of trusting the old confirmation.
            r.send(.status(Rig.status(armed: "shadow", path: "driver")))
            r.send(.resume)
            XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready), "\(phase)")
            r.advance(3000)
            XCTAssertFalse(r.core.isGo, "path no longer confirmed, so no Go")
            r.send(.status(Rig.status()))
            r.frame = .idle                      // hands off again
            r.untilGo()
            XCTAssertTrue(r.core.results[0][0]?.attempts.allSatisfy { $0.superseded } ?? true, "an abandoned attempt is kept but superseded (\(phase))")
        }
    }

    func testPausedStaysPausedWhenStopped() {
        let r = Rig()
        r.prepare()
        r.start()
        r.advance(100)
        r.send(.pause)
        r.send(.stop)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.restores, 1)
        XCTAssertEqual(r.dones, 1)
    }

    // MARK: Back and Skip

    func testBackAtStepZeroRestartsTheStep() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        XCTAssertFalse(r.core.canGoToPreviousStep)
        r.untilGo()
        var f = GamepadFrame.idle; f.buttons = 1
        r.frame = f
        r.advance(100)
        r.frame = .idle
        r.advance(1500)                       // well into the window
        guard case .step(0, .window) = r.core.state else { return XCTFail("\(r.core.state)") }
        r.send(.back)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
        XCTAssertEqual(r.core.results[0][0]?.attempts.count, 1, "the abandoned window is kept")
        XCTAssertTrue(r.core.results[0][0]!.attempts[0].superseded)
    }

    func testBackDuringReadyGoesToThePreviousStepAndSupersedesItsResult() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        r.untilGo()
        r.pressA()
        r.advance(400)
        XCTAssertEqual(r.verdict(0), .pass)
        guard case .step(1, .ready) = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertTrue(r.core.canGoToPreviousStep)
        r.send(.back)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
        XCTAssertNil(r.verdict(0), "the old verdict is superseded, the step is open again")
        XCTAssertEqual(r.core.results[0][0]?.attempts.count, 1, "kept")
    }

    func testBackWithinTheFirstSecondOfTheWindowActsLikeReady() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        r.untilGo()
        r.pressA()
        r.advance(400)
        r.untilGo()
        var f = GamepadFrame.idle; f.buttons = 1 << 1
        r.frame = f
        r.advance(300)
        guard case .step(1, .window) = r.core.state else { return XCTFail("\(r.core.state)") }
        r.send(.back)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
    }

    func testBackNeverCrossesAPassBoundary() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep], paths: ["engine", "driver"])
        r.untilGo()
        r.advance(2100)
        guard case .betweenPasses = r.core.state else { return XCTFail("\(r.core.state)") }
        r.send(.status(Rig.status(armed: "live", path: "driver")))
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
        XCTAssertEqual(r.core.pass, 1)
        XCTAssertFalse(r.core.canGoToPreviousStep)
        r.send(.back)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
        XCTAssertEqual(r.core.pass, 1, "still the second pass")
    }

    func testSkipRecordsSkippedAndMovesOn() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        r.advance(100)
        r.send(.skip)
        XCTAssertEqual(r.verdict(0), .skipped("by user"))
        XCTAssertEqual(r.core.state, .step(index: 1, phase: .ready))
        r.send(.skip)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.reportsWritten.count, 1)
        XCTAssertEqual(r.reportsWritten[0].steps.count, 2)
    }

    func testStepsWithAMissingMappingRequirementAreSkippedBeforeAsking() {
        var step = DevStep(id: "g1-as-y", kind: .digital, controls: ["g1"], title: "G1", seconds: 3)
        var req = DevRequires()
        req.mapping = ["g1": "y"]
        step.requires = req
        let r = Rig()
        r.prepare()
        r.start(steps: [step, Rig.aStep])
        XCTAssertEqual(r.verdict(0), .skipped("needs G1 → Y: set it in Mapping"))
        XCTAssertEqual(r.core.state, .step(index: 1, phase: .ready))
        XCTAssertFalse(r.core.canGoToPreviousStep, "Back never lands on an automatic skip")
    }

    // MARK: Requirements and trigger remaps (remap plan R1e)

    private func requiring(_ mapping: [String: String], kind: DevKind = .digital, controls: [String] = ["g1"]) -> DevStep {
        var step = DevStep(id: "s", kind: kind, controls: controls, title: "t")
        var req = DevRequires()
        req.mapping = mapping
        step.requires = req
        return step
    }

    private func skip(_ step: DevStep, _ mapping: ControlMapping) -> String? {
        let t = DevTemplate(id: "test", title: "t", steps: [step])
        return DevResolvedStep.resolve(template: t, mapping: mapping, layout: Rig.layout)[0].skipReason
    }

    func testRequiresComparesEffectiveOutputsByValue() {
        var m = ControlMapping.default
        XCTAssertEqual(skip(requiring(["g1": "y"]), m), "needs G1 → Y: set it in Mapping")
        m.setOutput(.pad(.y), for: "g1")
        XCTAssertNil(skip(requiring(["g1": "y"]), m))
        XCTAssertEqual(skip(requiring(["g1": "nothing"]), m), "needs G1 → Nothing: Reset it in Mapping", "Nothing is the factory choice of G1")
        // a control left alone "sends" its default
        XCTAssertNil(skip(requiring(["g1": "nothing", "a": "a", "start": "guide", "g4": "built_in"]), ControlMapping.default))
        XCTAssertNil(skip(requiring(["g2": "nothing"], controls: ["g2"]), { var x = ControlMapping.default; x.setOutput(.nothing, for: "g2"); return x }()))
        // built-in is a thing G2-G4 lose when remapped, even to Nothing
        var n = ControlMapping.default
        n.setOutput(.nothing, for: "g4")
        XCTAssertEqual(skip(requiring(["g4": "built_in"], controls: ["g4"]), n), "needs G4 left at its built-in function: Reset it in Mapping")
        XCTAssertEqual(skip(requiring(["g4": "nothing"], controls: ["g4"]), ControlMapping.default), "needs G4 → Nothing: set it in Mapping")
        // a miss that the default would fix says Reset
        var swapped = ControlMapping.default
        swapped.setOutput(.pad(.b), for: "a")
        XCTAssertEqual(skip(requiring(["a": "a"], controls: ["a"]), swapped), "needs A → A: Reset it in Mapping")
        // the learned bindings no longer matter: g1 carrying y's binding is not "g1 → y"
        var bound = ControlMapping.default
        bound.buttons["g1"] = bound.buttons["y"]
        XCTAssertEqual(skip(requiring(["g1": "y"]), bound), "needs G1 → Y: set it in Mapping")
        // two misses: the first control id in order gives the reason
        XCTAssertEqual(skip(requiring(["g1": "y", "a": "b"], controls: ["a"]), ControlMapping.default), "needs A → B: set it in Mapping")
        // a value outside the vocabulary never matches
        XCTAssertNotNil(skip(requiring(["g1": "Y"]), m))
    }

    func testTriggerRemapsAreSkippedWithAReason() {
        var m = ControlMapping.default
        m.setOutput(.pad(.a), for: "lt")
        XCTAssertEqual(skip(DevStep(id: "s", kind: .trigger, controls: ["lt"], title: "t"), m),
                       "LT is remapped to A; trigger remaps are checked after the next driver update")
        XCTAssertEqual(skip(DevStep(id: "s", kind: .held, controls: ["lt"], title: "t"), m),
                       "LT is remapped to A; trigger remaps are checked after the next driver update")
        XCTAssertNil(skip(DevStep(id: "s", kind: .trigger, controls: ["rt"], title: "t"), m), "RT was left alone")
        var swap = ControlMapping.default
        swap.setOutput(.pad(.rt), for: "lt"); swap.setOutput(.pad(.lt), for: "rt")
        XCTAssertEqual(skip(DevStep(id: "s", kind: .trigger, controls: ["lt"], title: "t"), swap),
                       "LT is remapped to RT; trigger remaps are checked after the next driver update")
        var none = ControlMapping.default
        none.setOutput(.nothing, for: "rt")
        XCTAssertEqual(skip(DevStep(id: "s", kind: .held, controls: ["rt"], title: "t"), none),
                       "RT is remapped to Nothing; trigger remaps are checked after the next driver update")
        // a button sent to a trigger
        var toTrigger = ControlMapping.default
        toTrigger.setOutput(.pad(.lt), for: "g1")
        let why = "a button sent to LT/RT is checked after the next driver update"
        XCTAssertEqual(skip(DevStep(id: "s", kind: .digital, controls: ["g1"], title: "t"), toTrigger), why)
        XCTAssertEqual(skip(DevStep(id: "s", kind: .held, controls: ["g1"], title: "t"), toTrigger), why)
        XCTAssertNil(skip(DevStep(id: "s", kind: .digital, controls: ["g2"], title: "t"), toTrigger))
        XCTAssertNil(skip(DevStep(id: "s", kind: .trigger, controls: ["lt"], title: "t"), toTrigger),
                      "LT itself is where it was; another control also feeding it is not judged here")
    }

    func testTheWindowOfATriggerStepOpensOnThePhysicalPull() {
        // LB is sent to RT; the RT step must not open on LB, only on the trigger itself.
        let r = Rig()
        r.mapping.setOutput(.pad(.rt), for: "lb")
        let step = DevStep(id: "rt", kind: .trigger, controls: ["rt"], title: "Pull RT", seconds: 3, readySeconds: 1)
        r.prepare()
        r.start(steps: [step])
        r.untilGo()
        var lb = GamepadFrame.idle
        lb.buttons = 1 << 4
        var padRT = PadState(); padRT.rt = 1
        r.move(lb, padRT, hold: 200)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready), "LB reaching the pad's RT is not the physical pull")
        r.releaseAll(hold: 400)
        r.untilGo()
        var pull = GamepadFrame.idle
        pull.rt = 1023
        var p = PadState(); p.rt = 1
        r.move(pull, p, hold: 100)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .window))
    }

    func testBuiltInTemplatesResolveWithoutAnySkipOnTheFactoryMapping() {
        let templates = DevBuiltins.generate(layout: Rig.layout)
        XCTAssertFalse(templates.isEmpty)
        // The remap templates are meant to skip until the owner makes their picks; every other one runs as is.
        let others = templates.filter { !$0.id.hasPrefix("remap-") }
        XCTAssertEqual(others.count, templates.count - 2)
        for t in others {
            for r in DevResolvedStep.resolve(template: t, mapping: .default, layout: Rig.layout) {
                XCTAssertNil(r.skipReason, "\(t.id) step \(r.step.id)")
            }
        }
        for t in templates where t.id.hasPrefix("remap-") {
            let skips = DevResolvedStep.resolve(template: t, mapping: .default, layout: Rig.layout).map(\.skipReason)
            XCTAssertTrue(skips.allSatisfy { $0 != nil }, "\(t.id) skips every step on the factory mapping: \(skips)")
        }
    }

    // MARK: expect.releases and the run-anyway text (remap R4)

    private var g1ThenYStep: DevStep {
        var s = DevStep(id: "hold-g1-then-y", kind: .held, controls: ["g1", "y"], title: "t", seconds: 3, readySeconds: 1)
        var e = DevExpect(); e.item = "Y"; e.releases = ["g1"]
        s.expect = e
        var req = DevRequires(); req.mapping = ["g1": "y"]
        s.requires = req
        return s
    }

    /// G1 (sent to Y) is pressed, the real Y joins, G1 is let go (unless `letGoG1` is false), Y is kept (unless `dropY`).
    private func holdG1ThenY(letGoG1: Bool, dropY: Bool = false) throws -> (Rig, DevAttempt) {
        let r = Rig()
        r.mapping.setOutput(.pad(.y), for: "g1")
        let g1 = try XCTUnwrap(DevExpectation.pressedFrame(for: "g1", mapping: r.mapping))
        let y = try XCTUnwrap(DevExpectation.pressedFrame(for: "y", mapping: r.mapping))
        var both = g1
        both.buttons |= y.buttons; both.extra |= y.extra
        var padY = PadState(); padY.buttons = [.y]
        r.prepare()
        r.start(steps: [g1ThenYStep])
        XCTAssertNil(r.core.setupSteps.first?.skipReason)
        r.untilGo()
        r.move(g1, padY, hold: 400)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .window), "G1 opens the window")
        r.move(both, padY, hold: 500)
        r.move(letGoG1 ? y : both, padY, hold: 1000)
        if dropY { r.move(.idle, PadState(), hold: 300) }
        r.advance(dropY ? 950 : 1250)
        r.releaseAll(hold: 100)
        r.advance(1500)
        return (r, try XCTUnwrap(r.core.results[0][0]?.attempts.last))
    }

    func testHeldReleasesPassesWhenG1IsPressedYAddedG1LetGoAndYKept() throws {
        let (r, att) = try holdG1ThenY(letGoG1: true)
        XCTAssertEqual(r.verdict(0), .pass, att.metrics.detail)
        XCTAssertEqual(att.metrics.values["held.released"], 1)
        XCTAssertEqual(att.metrics.values["held.drops"], 0)
    }

    func testHeldReleasesFailsWithAPlainReasonWhenG1IsNeverLetGo() throws {
        let (r, att) = try holdG1ThenY(letGoG1: false)
        XCTAssertEqual(r.verdict(0), .fail("G1 was never let go while Y stayed held"), att.metrics.detail)
        XCTAssertEqual(att.metrics.values["held.drops"], 0)
    }

    func testHeldReleasesFailsAsBeforeWhenYDrops() throws {
        let (r, att) = try holdG1ThenY(letGoG1: true, dropY: true)
        guard case .fail(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0))) \(att.metrics.detail)") }
        XCTAssertTrue(why.contains("Y did not stay held: drops 1"), why)
    }

    func testDriverPassNamesTheMappingNoteWhenItCannotBeConfirmed() {
        let r = Rig()
        r.prepare(status: Rig.status(armed: "inert", path: "driver") { $0.mappingNote = "a button sent to LT needs a driver update" })
        r.start(.driver)
        r.advance(10_100)
        guard case .runAnyway(let text)? = r.prompts.first else { return XCTFail("\(r.prompts)") }
        XCTAssertEqual(text, "Driver pass cannot be confirmed: a button sent to LT needs a driver update. Reset that remap first.")
        // a fault of GDHub's own is not something a reset fixes: the status line stays
        let internalFault = Rig()
        internalFault.prepare(status: Rig.status(armed: "inert", path: "driver") { $0.mappingNote = "internal: blob check failed" })
        internalFault.start(.driver)
        internalFault.advance(10_100)
        guard case .runAnyway(let other)? = internalFault.prompts.first else { return XCTFail("\(internalFault.prompts)") }
        XCTAssertTrue(other.hasPrefix("Driven by:"), other)
        // the engine pass is never asked
        let engine = Rig()
        engine.prepare(status: Rig.status(armed: "inert", path: "engine") { $0.mappingNote = "x" })
        engine.start(.engine)
        XCTAssertTrue(engine.prompts.isEmpty)
    }

    // MARK: Stop, finish, restore

    func testStopInSwitchingFinishesRestoresAndWritesNoEmptyReport() {
        let r = Rig()
        r.prepare()
        r.start(.driver)
        r.advance(500)
        r.send(.stop)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.restores, 1)
        XCTAssertEqual(r.dones, 1)
        XCTAssertEqual(r.reportsWritten.count, 0, "nothing was recorded")
    }

    func testCancelAtThePromptFinishesAndRestores() {
        let r = Rig()
        r.prepare()
        r.start(.driver)
        r.advance(10_500)
        XCTAssertEqual(r.prompts.count, 1)
        r.send(.cancelSwitch)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.restores, 1)
    }

    func testStopBetweenPassesStartsNoFurtherPass() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep], paths: ["engine", "driver"])
        r.untilGo()
        r.advance(2100)
        guard case .betweenPasses = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertEqual(r.reportsWritten.count, 1, "the first pass has its own report")
        XCTAssertEqual(r.pathWrites, ["driver"])
        r.send(.stop)
        XCTAssertEqual(r.core.state, .finished)
        r.advance(5000)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.reportsWritten.count, 1, "no report for a pass that never started")
        XCTAssertEqual(r.restores, 1)
        XCTAssertEqual(r.dones, 1)
        XCTAssertEqual(r.core.results[1].compactMap { $0 }.count, 0)
    }

    func testBothPassesOfAPathsTemplateWriteOneReportEach() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep], paths: ["engine", "driver"])
        r.untilGo(); r.advance(2100)
        r.send(.status(Rig.status(armed: "live", path: "driver")))
        r.untilGo(); r.advance(2100)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.reportsWritten.map(\.requestedPath), ["engine", "driver"])
        XCTAssertEqual(r.reportsWritten.map(\.complete), [true, true])
        XCTAssertEqual(r.reportsWritten[1].effectivePath, "driver")
        XCTAssertEqual(r.restores, 1)
        XCTAssertEqual(r.dones, 1)
    }

    func testFinishWritesExactlyOnceWhateverComesAfter() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep])
        r.untilGo()
        r.advance(2100)
        XCTAssertEqual(r.core.state, .finished)
        for e: DevRunCore.Event in [.stop, .terminate, .stop, .abort("x"), .tick(r.now + 1), .cancelSwitch, .runAnyway] { r.send(e) }
        XCTAssertEqual(r.reportsWritten.count, 1)
        XCTAssertEqual(r.restores, 1)
        XCTAssertEqual(r.dones, 1)
    }

    func testStopInTheWindowClosesTheAttemptAsStoppedAndWritesIncomplete() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        r.untilGo()
        r.move({ var f = GamepadFrame.idle; f.buttons = 1; return f }(), { var p = PadState(); p.buttons = [.a]; return p }(), hold: 300)
        r.send(.stop)
        XCTAssertEqual(r.reportsWritten.count, 1)
        let report = r.reportsWritten[0]
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.steps.count, 1)
        XCTAssertEqual(report.steps[0].verdict, .invalid("stopped"))
        XCTAssertEqual(r.restores, 1)
        // Order of the exit: report, then the path, then done.
        let tail = r.log.suffix(3)
        XCTAssertTrue({ if case .writeReport = tail.first! { return true } else { return false } }(), "\(tail)")
        XCTAssertEqual(Array(tail.dropFirst()), [.restorePath, .done])
    }

    func testTerminateIsAnIncompleteFinishWithANote() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep])
        r.untilGo()
        r.advance(500)
        r.send(.terminate)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.reportsWritten.count, 1)
        XCTAssertFalse(r.reportsWritten[0].complete)
        XCTAssertTrue(r.reportsWritten[0].notes.contains { $0.contains("quit") })
        XCTAssertEqual(r.restores, 1)
    }

    func testAbortFinishesIncompleteWithItsNote() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep])
        r.untilGo()
        r.advance(500)
        r.send(.abort("the GUI left engine mode during the run"))
        XCTAssertTrue(r.reportsWritten[0].notes.contains("the GUI left engine mode during the run"))
        XCTAssertFalse(r.reportsWritten[0].complete)
    }

    // MARK: Watching the path and the pad

    func testArmedChangeMidStepMakesTheStepInvalid() {
        let r = Rig()
        r.prepare(status: Rig.status(armed: "live", path: "driver"))
        r.start(.driver, steps: [Rig.aStep, Rig.bStep])
        r.untilGo()
        r.move({ var f = GamepadFrame.idle; f.buttons = 1; return f }(), { var p = PadState(); p.buttons = [.a]; return p }(), hold: 100)
        r.send(.status(Rig.status(armed: "shadow", path: "driver")))
        guard case .invalid(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.contains("path changed"), why)
        XCTAssertEqual(r.core.state, .step(index: 1, phase: .ready))
        // The next step waits for the path instead of recording on a path it was not asked to test.
        r.advance(4000)
        XCTAssertFalse(r.core.isGo)
        XCTAssertFalse(r.core.pathEvents.isEmpty)
        XCTAssertEqual(r.core.pathEvents.last?.armed, "shadow")
    }

    func testFallbackAppearingAutoPausesWithTheStatusText() {
        let r = Rig()
        r.prepare(status: Rig.status(armed: "live", path: "driver"))
        r.start(.driver)
        r.untilGo()
        r.send(.status(Rig.status(armed: "inert", path: "driver") { $0.fallback = "tap stalled" }))
        guard case .paused(_, .step) = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertTrue(r.core.pauseReason?.contains("tap stalled") ?? false, r.core.pauseReason ?? "nil")
    }

    func testEnginePidChangeAutoPauses() {
        let r = Rig()
        r.prepare()
        r.start()
        r.advance(300)
        r.send(.enginePid(101))
        guard case .paused = r.core.state else { return XCTFail("\(r.core.state)") }
    }

    func testControllerLeavingActiveAutoPausesInTheWindow() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        r.untilGo()
        r.move({ var f = GamepadFrame.idle; f.buttons = 1; return f }(), { var p = PadState(); p.buttons = [.a]; return p }(), hold: 100)
        guard case .step(0, .window) = r.core.state else { return XCTFail("\(r.core.state)") }
        r.send(.controllerActive(false))
        XCTAssertEqual(r.core.state, .paused(index: 0, resumeTo: .step(0)))
        XCTAssertEqual(r.core.results[0][0]?.attempts.count, 1)
        XCTAssertTrue(r.core.results[0][0]!.attempts[0].superseded)
    }

    func testRestStepWindowSurvivesTheControllerDozingOff() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep])
        r.untilGo()
        r.send(.controllerActive(false))
        guard case .step(0, .window) = r.core.state else { return XCTFail("\(r.core.state)") }
        r.advance(2100)
        XCTAssertEqual(r.verdict(0), .pass)
    }

    func testReaderMatchingTwoPadsAutoPauses() {
        let r = Rig()
        r.prepare()
        r.start()
        r.advance(300)
        r.send(.readerMatched(2))
        guard case .paused = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertTrue(r.core.pauseReason?.contains("2") ?? false)
    }

    func testLateTicksFromAnEarlierPhaseAreIgnored() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep])
        r.untilGo()
        let stateBefore = r.core.state
        r.send(.tick(r.now - 5_000_000_000))
        XCTAssertEqual(r.core.state, stateBefore)
        // A tick far in the future that was meant for an older phase would otherwise end the window early; here the
        // tick is simply the current time, so the window ends on time.
        r.advance(2100)
        XCTAssertEqual(r.core.state, .finished)
    }

    // MARK: Outputs

    func testHighlightsFollowTheStepAndTheVerdicts() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        func lastHighlights() -> [String: DevHighlight] {
            for a in r.log.reversed() { if case .setHighlights(let h) = a { return h } }
            return [:]
        }
        XCTAssertEqual(lastHighlights()["a"], .wanted)
        XCTAssertNil(lastHighlights()["b"])
        r.untilGo()
        r.pressA()
        r.advance(400)
        XCTAssertEqual(lastHighlights()["a"], .passed)
        XCTAssertEqual(lastHighlights()["b"], .wanted)
    }

    func testRestStepOutlinesEveryControl() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep, Rig.aStep])
        var found: [String: DevHighlight] = [:]
        for a in r.log { if case .setHighlights(let h) = a { found = h; break } }
        XCTAssertEqual(found["a"], .restOutline)
        XCTAssertEqual(found.count, Rig.layout.controls.count)
    }

    func testPathEventsAreRecordedOnEveryStatusChange() {
        let r = Rig()
        r.prepare()
        r.start(.driver, steps: [Rig.restStep])
        r.send(.status(Rig.status(armed: "shadow", path: "driver")))
        r.send(.status(Rig.status(armed: "shadow", path: "driver")))     // same: no new event
        r.send(.status(Rig.status(armed: "live", path: "driver")))
        XCTAssertEqual(r.core.pathEvents.map(\.armed), ["inert", "shadow", "live"])
    }

    // MARK: Re-run

    func testRerunFailedRunsOnlyThoseStepsAndMergesAttempts() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.aStep, Rig.bStep])
        r.untilGo()
        r.pressA()
        r.advance(400)
        XCTAssertEqual(r.verdict(0), .pass)
        r.send(.skip)                                   // b skipped by the owner
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.reportsWritten.count, 1)
        // Skipped is not failed: nothing to re-run.
        r.send(.rerunFailed())
        XCTAssertEqual(r.core.state, .finished)
        // Re-run step 0 explicitly: a fresh snapshot, the same path, only that step.
        r.send(.rerun(0))
        XCTAssertEqual(r.count { $0 == .takeSnapshot }, 2)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready))
        r.untilGo()
        r.pressA()
        r.advance(400)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.reportsWritten.count, 2)
        XCTAssertEqual(r.reportsWritten[1].steps.map(\.stepId), ["a", "b"], "the report holds the whole pass")
        XCTAssertEqual(r.reportsWritten[1].steps[0].attempts.count, 2)
        XCTAssertTrue(r.reportsWritten[1].steps[0].attempts[0].superseded)
        XCTAssertFalse(r.reportsWritten[1].steps[0].attempts[1].superseded)
        XCTAssertEqual(r.restores, 2)
        XCTAssertEqual(r.dones, 2)
    }

    // MARK: Held steps and actions

    func testHeldWindowOpensWhenRTIsHeldAndHandsOverAtTheCadence() throws {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.heldStep()])
        r.untilGo()
        r.advance(200)
        guard case .step(0, .ready) = r.core.state else { return XCTFail("a held step waits for the hands: \(r.core.state)") }
        XCTAssertEqual(r.pathWrites, [], "nothing is handed over before RT is held")
        let (f, p) = r.rtDown
        r.frame = f
        r.advance(5)
        guard case .step(0, .window) = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertEqual(r.pathWrites, ["driver"], "the first hand-over comes with the window")
        r.setPad(p)
        r.advanceAnswering(600)
        XCTAssertEqual(r.pathWrites, ["driver", "engine", "driver"], "three writes at 100 ms, alternating; no more")
        // Cadence: the path events carry the write times.
        let wrote = r.core.pathEvents.filter { $0.wrote != nil }
        XCTAssertEqual(wrote.map { $0.wrote! }, ["driver", "engine", "driver"])
        XCTAssertEqual(wrote[1].tMs - wrote[0].tMs, 100, accuracy: 1)
        XCTAssertEqual(wrote[2].tMs - wrote[1].tMs, 100, accuracy: 1)
        // The status changes that followed the writes are recorded too.
        XCTAssertEqual(r.core.pathEvents.filter { $0.wrote == nil }.map(\.armed), ["inert", "live", "inert", "live"])
        // The armed changes did not invalidate the step.
        guard case .step(0, .window) = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertNil(r.verdict(0))
    }

    func testHeldWithActionsEndsOneAndAHalfSecondsAfterTheLastActionThenAReleaseTailThenPass() throws {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.heldStep()])
        r.untilGo()
        let (f, p) = r.rtDown
        r.frame = f
        r.advance(5)
        r.setPad(p)
        let windowStart = r.now
        r.advanceAnswering(1700)
        // 3 writes at 100 ms completed at 300 ms; 300 + 1500 = 1800 ms.
        guard case .step(0, .window) = r.core.state else { return XCTFail("window still open at 1.7 s: \(r.core.state)") }
        r.advanceAnswering(150)
        guard case .step(0, .release) = r.core.state else { return XCTFail("release tail after 1.8 s: \(r.core.state)") }
        XCTAssertEqual(r.lastInstruction?.title, "Let go now")
        r.releaseAll(hold: 100)
        r.advanceAnswering(1500)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.verdict(0), .pass, r.core.results[0][0]?.attempts.last?.metrics.detail ?? "")
        let att = try XCTUnwrap(r.core.results[0][0]?.attempts.last)
        XCTAssertEqual(Double(att.windowEndNs - att.windowStartNs) / 1e6, 1800, accuracy: 20)
        XCTAssertEqual(att.windowStartNs, windowStart, "the window opened on the RT frame")
        XCTAssertEqual(att.metrics.values["held.drops"], 0)
        XCTAssertEqual(att.metrics.values["held.handOvers"], 3)
        XCTAssertEqual(att.metrics.values["held.handOversConfirmed"], 3)
        XCTAssertTrue(att.metrics.detail.contains("RT stayed held for"), att.metrics.detail)
        XCTAssertTrue(att.metrics.detail.contains("through 3 hand-overs"), att.metrics.detail)
        XCTAssertTrue(att.metrics.detail.contains("Hand-overs confirmed 3/3 (armed inert 1/1, live 2/2)"), att.metrics.detail)
        // The release at the end is the tail, not a drop.
        // The pass ends on the target path: the last hand-over (driver) is undone when the window is over.
        XCTAssertEqual(r.pathWrites, ["driver", "engine", "driver", "engine"])
        XCTAssertEqual(r.restores, 1)
        XCTAssertEqual(r.reportsWritten.count, 1)
        XCTAssertTrue(r.reportsWritten[0].pathEvents.contains { $0.wrote == "driver" })
    }

    func testHeldFailsWhenThePadLetsGoOfRTForFiftyMilliseconds() throws {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.heldStep()])
        r.untilGo()
        let (f, p) = r.rtDown
        r.frame = f
        r.advance(5)
        r.setPad(p)
        r.advanceAnswering(800)
        r.setPad(PadState())                         // the pad drops RT ...
        r.advanceAnswering(50)
        r.setPad(p)                                  // ... and takes it back
        r.advanceAnswering(1000)
        r.releaseAll(hold: 100)
        r.advanceAnswering(1500)
        XCTAssertEqual(r.core.state, .finished)
        guard case .fail(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.contains("drops 1"), why)
        XCTAssertEqual(r.core.results[0][0]?.attempts.last?.metrics.values["held.drops"], 1)
        XCTAssertEqual(r.core.results[0][0]?.attempts.last?.metrics.values["held.minLevel"] ?? 9, 0, accuracy: 0.001)
    }

    func testHeldDoesNotCountTheEnginesSlowFollowingAgainstTheVerdict() throws {
        // The engine never reports the driver's LIVE in time: the hand-overs are not confirmed, the pad held RT.
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.heldStep()])
        r.untilGo()
        let (f, p) = r.rtDown
        r.frame = f
        r.advance(5)
        r.setPad(p)
        r.advanceAnswering(1900, follow: false)
        r.releaseAll(hold: 100)
        r.advanceAnswering(1500, follow: false)
        XCTAssertEqual(r.verdict(0), .pass)
        let detail = r.core.results[0][0]?.attempts.last?.metrics.detail ?? ""
        // Only the write that asked for the state the engine was already in counts (engine, inert); both driver writes do not.
        XCTAssertTrue(detail.contains("Hand-overs confirmed 1/3"), detail)
        XCTAssertTrue(detail.contains("not seen following every write"), detail)
    }

    func testHeldInstructionNamesTheHandOverAndSaysKeepHoldingInTheLastTwoSeconds() throws {
        let r = Rig()
        let step = Rig.heldStep(interval: 1000, count: 5)       // writes at 0 .. 4 s, window 5 + 1.5 = 6.5 s
        r.prepare()
        r.start(steps: [step])
        r.untilGo()
        let (f, p) = r.rtDown
        r.frame = f
        r.advance(5)
        r.setPad(p)
        XCTAssertEqual(r.lastInstruction?.title, "Pull RT all the way in and just hold it still")
        XCTAssertEqual(r.lastInstruction?.detail, "Keep holding RT still, nothing else to do — switch 1 of 5, now driven by Driver")
        r.advanceAnswering(1500)
        XCTAssertEqual(r.lastInstruction?.detail, "Keep holding RT still, nothing else to do — switch 2 of 5, now driven by App")
        r.advanceAnswering(2000)
        XCTAssertEqual(r.lastInstruction?.detail, "Keep holding RT still, nothing else to do — switch 4 of 5, now driven by App")
        r.advanceAnswering(1000)                                 // 4.5 s in: 2 s left
        XCTAssertEqual(r.lastInstruction?.detail, "Keep holding…")
        XCTAssertEqual(r.pathWrites.count, 5)
        r.advanceAnswering(2100)
        XCTAssertEqual(r.lastInstruction?.title, "Let go now")
        // The ring runs over the whole window.
        let rings = r.log.compactMap { a -> UInt64? in if case .setInstruction(_, let d, let total, _) = a, d.hasPrefix("Keep holding") { return total } else { return nil } }
        XCTAssertEqual(rings.first, 6_500_000_000)
    }

    func testHeldPauseStopsTheCadenceAndPutsThePathBack() throws {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.heldStep(interval: 1000, count: 5)])
        r.untilGo()
        let (f, p) = r.rtDown
        r.frame = f
        r.advance(5)
        r.setPad(p)
        r.advanceAnswering(2300)                                 // writes: driver, engine, driver
        XCTAssertEqual(r.pathWrites, ["driver", "engine", "driver"])
        r.send(.pause)
        XCTAssertEqual(r.core.state, .paused(index: 0, resumeTo: .step(0)))
        XCTAssertEqual(r.pathWrites, ["driver", "engine", "driver", "engine"], "paused on driver: the pass's target is written back")
        r.advanceAnswering(5000)
        XCTAssertEqual(r.pathWrites.count, 4, "the cadence stopped with the pause")
        r.send(.resume)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready), "Resume restarts the step")
        XCTAssertEqual(r.core.results[0][0]?.attempts.count, 1)
        XCTAssertTrue(r.core.results[0][0]!.attempts[0].superseded)
    }

    func testHeldWithoutActionsRunsTheFullWindowAndDoesNotEndEarly() throws {
        let r = Rig()
        let step = Rig.heldStep(count: nil, seconds: 2)
        r.prepare()
        r.start(steps: [step])
        r.untilGo()
        let (f, p) = r.rtDown
        r.frame = f
        r.advance(5)
        r.setPad(p)
        let start = r.now
        r.advance(1900)
        guard case .step(0, .window) = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertEqual(r.lastInstruction?.detail, "Keep holding…")
        XCTAssertEqual(r.pathWrites, [], "no actions, no writes")
        r.advance(150)
        guard case .step(0, .release) = r.core.state else { return XCTFail("\(r.core.state)") }
        XCTAssertGreaterThanOrEqual(r.now - start, 2_000_000_000)
        r.releaseAll(hold: 100)
        r.advance(1500)
        XCTAssertEqual(r.verdict(0), .pass, r.core.results[0][0]?.attempts.last?.metrics.detail ?? "")

        // Letting go early is a drop, and the window still runs to its end.
        let early = Rig()
        early.prepare()
        early.start(steps: [step])
        early.untilGo()
        early.frame = f
        early.advance(5)
        early.setPad(p)
        early.advance(600)
        early.releaseAll(hold: 100)
        guard case .step(0, .window) = early.core.state else { return XCTFail("a held step never ends early: \(early.core.state)") }
        early.advance(2500)
        guard case .fail(let why)? = early.verdict(0) else { return XCTFail("\(String(describing: early.verdict(0)))") }
        XCTAssertTrue(why.contains("drops 1"), why)
    }

    func testStepsWithActionsAreSkippedWithoutTheBackgroundEngine() throws {
        let r = Rig()
        r.send(.controllerActive(true)); r.send(.readerMatched(1))
        r.advance(400)
        r.start(.inApp, steps: [Rig.heldStep(), Rig.aStep])
        guard case .skipped(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertEqual(why, "needs the background engine")
        XCTAssertEqual(r.core.state, .step(index: 1, phase: .ready), "the next step carries on")
        XCTAssertEqual(r.pathWrites, [])
        // The same step without actions is fine in-app.
        let plain = Rig()
        plain.send(.controllerActive(true)); plain.send(.readerMatched(1))
        plain.advance(400)
        plain.start(.inApp, steps: [Rig.heldStep(count: nil)])
        XCTAssertEqual(plain.core.state, .step(index: 0, phase: .ready))
    }

    func testStopDuringHandOversRestoresAndTheRestoreHasTheLastWord() throws {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.heldStep(interval: 1000, count: 5)])
        r.untilGo()
        let (f, p) = r.rtDown
        r.frame = f
        r.advance(5)
        r.setPad(p)
        r.advanceAnswering(1200)                                 // driver, engine
        r.send(.stop)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.pathWrites, ["driver", "engine"], "no write after the finish: restorePath is the last word")
        XCTAssertEqual(Array(r.log.suffix(2)), [.restorePath, .done])
        XCTAssertEqual(r.reportsWritten[0].steps[0].verdict, .invalid("stopped"))
    }

    // MARK: Whole run

    func testCompleteRunReportCarriesHeaderResultsAndEffectivePath() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep, Rig.aStep])
        r.untilGo(); r.advance(2100)
        r.untilGo(); r.pressA(); r.advance(400)
        XCTAssertEqual(r.core.state, .finished)
        let report = r.reportsWritten[0]
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.requestedPath, "engine")
        XCTAssertEqual(report.effectivePath, "engine")
        XCTAssertEqual(report.steps.map(\.stepId), ["rest", "a"])
        XCTAssertEqual(report.steps.map { $0.verdict }, [.pass, .pass])
        XCTAssertEqual(report.steps[1].expected, DevExpectedItems(buttons: ["A"]))
        XCTAssertEqual(report.steps[1].attempts[0].effectivePath.atStart, "engine")
        XCTAssertEqual(report.startedAt, DevRunReport.iso(Date(timeIntervalSince1970: 1_700_000_000)))
    }
}

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
               paths: [String]? = nil, recordReceiver: Bool? = nil) -> DevRunSetup {
        let t = DevTemplate(id: "test", title: "Test", paths: paths, recordReceiver: recordReceiver, steps: steps)
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

    func start(_ target: DevTarget = .engine, steps: [DevStep] = [Rig.restStep, Rig.aStep, Rig.bStep], paths: [String]? = nil,
               recordReceiver: Bool? = nil) {
        send(.start(setup(target, steps: steps, paths: paths, recordReceiver: recordReceiver)))
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

    /// Step 1 skipped every step on a remapped trigger; the judge works out the mapped trigger now, so nothing is skipped
    /// for it (S4). The expectation follows the mapping instead.
    func testTriggerRemapsAreJudgedNotSkipped() {
        var m = ControlMapping.default
        m.setOutput(.pad(.a), for: "lt")
        XCTAssertNil(skip(DevStep(id: "s", kind: .trigger, controls: ["lt"], title: "t"), m))
        XCTAssertNil(skip(DevStep(id: "s", kind: .held, controls: ["lt"], title: "t"), m))
        var swap = ControlMapping.default
        swap.setOutput(.pad(.rt), for: "lt"); swap.setOutput(.pad(.lt), for: "rt")
        XCTAssertNil(skip(DevStep(id: "s", kind: .trigger, controls: ["lt"], title: "t"), swap))
        var toTrigger = ControlMapping.default
        toTrigger.setOutput(.pad(.lt), for: "g1")
        XCTAssertNil(skip(DevStep(id: "s", kind: .digital, controls: ["g1"], title: "t"), toTrigger))
        XCTAssertNil(skip(DevStep(id: "s", kind: .held, controls: ["g1"], title: "t"), toTrigger))
        func resolved(_ step: DevStep, _ mapping: ControlMapping) -> DevResolvedStep {
            DevResolvedStep.resolve(template: DevTemplate(id: "test", title: "t", steps: [step]), mapping: mapping, layout: Rig.layout)[0]
        }
        XCTAssertEqual(resolved(DevStep(id: "s", kind: .trigger, controls: ["lt"], title: "t"), swap).expected, DevExpectedItems(rt: true))
        XCTAssertEqual(resolved(DevStep(id: "s", kind: .digital, controls: ["g1"], title: "t"), toTrigger).expected, DevExpectedItems(lt: true))
        XCTAssertEqual(resolved(DevStep(id: "s", kind: .trigger, controls: ["rt"], title: "t"), .default).expected, DevExpectedItems(rt: true))
        XCTAssertEqual(resolved(DevStep(id: "s", kind: .digital, controls: ["g1"], title: "t"), toTrigger).linked, ["lt"])
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
        // The remap templates (and the volume-key one) are meant to skip until the owner makes their picks; every other one runs as is.
        let needsPicks: (DevTemplate) -> Bool = { $0.id.hasPrefix("remap-") || $0.id == "gkeys-volume" }
        let others = templates.filter { !needsPicks($0) }
        XCTAssertEqual(others.count, templates.count - 5)
        for t in others {
            for r in DevResolvedStep.resolve(template: t, mapping: .default, layout: Rig.layout) {
                XCTAssertNil(r.skipReason, "\(t.id) step \(r.step.id)")
            }
        }
        for t in templates where needsPicks(t) {
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
        if dropY { r.move(y, PadState(), hold: 300) }          // the pad loses Y while the button is still down: a real drop
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
        XCTAssertEqual(text, "Driver pass cannot be confirmed: a button sent to LT needs a driver update. Press Stop to keep the App result, or Reset that remap first.")
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

// MARK: - Volume steps (remap R4b)

extension DevRunCoreTests {
    private func volumeStep(_ control: String, buttons: [String], volume: String, times: Int) -> DevStep {
        var s = DevStep(id: control, kind: .digital, controls: [control], title: "t", seconds: 4, readySeconds: 1, releaseSeconds: 1)
        var e = DevExpect(); e.items = DevExpectedItems(buttons: buttons); e.times = times; e.volume = volume
        s.expect = e
        return s
    }

    private func key(_ r: Rig, _ payload: UInt8) -> DevRunCore.Event {
        .consumerReport(DevConsumerReport(tNs: r.now, bytes: [0x11, payload]))
    }

    private func change(_ r: Rig, _ kind: VolumeEventKind, _ state: VolumeState = .device(scalar: 0.4375)) -> DevRunCore.Event {
        .volumeEvent(VolumeEvent(tNs: r.now, kind: kind, state: state))
    }

    /// The key is pressed `times` times with its 0x11 reports (`payload` nil = the receiver reports nothing), `during`
    /// runs while the key is down, `after` 700 ms after the last release (inside the 1 s tail). Runs to the end.
    private func volumeRun(control: String, output: ControlOutput?, buttons: [String], volume: String, times: Int,
                           start: VolumeState = .device(scalar: 0.5), payload: UInt8? = 0x01, padShows: Bool = true,
                           beforeGo: (Rig) -> Void = { _ in }, during: (Rig, Int) -> Void = { _, _ in },
                           after: (Rig) -> Void = { _ in }) throws -> (Rig, DevAttempt) {
        let r = Rig()
        if let output { r.mapping.setOutput(output, for: control) }
        let down = try XCTUnwrap(DevExpectation.pressedFrame(for: control, mapping: r.mapping))
        var pad = PadState()
        if padShows, !buttons.isEmpty { pad.buttons = [.rb] }
        r.prepare()
        r.start(steps: [volumeStep(control, buttons: buttons, volume: volume, times: times)])
        r.send(.volumeState(start, tNs: r.now))
        beforeGo(r)
        r.untilGo()
        for i in 0..<times {
            if let payload { r.send(key(r, payload)) }
            r.move(down, pad)
            during(r, i)
            r.releaseAll()
            if let payload { r.send(key(r, 0x00)); _ = payload }
        }
        r.advance(700)
        after(r)
        var spent = 0.0
        while r.core.state != .finished, spent < 12_000 { r.advance(50); spent += 50 }
        XCTAssertEqual(r.core.state, .finished)
        return (r, try XCTUnwrap(r.core.results[0][0]?.attempts.last))
    }

    func testVolumeUnchangedPassesForAKeySentToThePadWhenTheMacStaysQuiet() throws {
        let (r, att) = try volumeRun(control: "g3", output: .pad(.rb), buttons: ["RB"], volume: "unchanged", times: 2)
        XCTAssertEqual(r.verdict(0), .pass, att.metrics.detail)
        let v = try XCTUnwrap(att.volume)
        XCTAssertEqual(v.verdict, .pass)
        XCTAssertEqual(v.keyReports, 2)
        XCTAssertEqual(v.consumerReports, 4)
        XCTAssertEqual([v.volumeEvents, v.muteEvents, v.deviceEvents], [0, 0, 0])
        XCTAssertEqual(v.startScalar, 0.5); XCTAssertEqual(v.endScalar, 0.5)
        XCTAssertEqual(r.reportsWritten.last?.steps[0].attempts.last?.volume, v, "the report carries it")
    }

    func testVolumeUnchangedFailsWhenTheMacsVolumeMovesWhileTheKeyIsDown() throws {
        let (r, att) = try volumeRun(control: "g3", output: .pad(.rb), buttons: ["RB"], volume: "unchanged", times: 2,
                                     during: { r, i in if i == 0 { r.send(self.change(r, .volume, .device(scalar: 0.5625))) } })
        guard case .fail(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.contains("1 volume and 0 mute change"), why)
        XCTAssertEqual(att.volume?.endScalar, 0.5625)
    }

    func testAChangeInTheReleaseTailCountsAndOneBeforeGoDoesNot() throws {
        let (r, _) = try volumeRun(control: "g3", output: .pad(.rb), buttons: ["RB"], volume: "unchanged", times: 2,
                                   after: { r in r.send(self.change(r, .volume, .device(scalar: 0.5625))) })
        XCTAssertEqual(r.verdict(0)?.tag, "fail", "700 ms after the last release is still inside the 1 s tail")
        let (early, att) = try volumeRun(control: "g3", output: .pad(.rb), buttons: ["RB"], volume: "unchanged", times: 2,
                                         beforeGo: { r in r.send(self.change(r, .volume, .device(scalar: 0.5))) })
        XCTAssertEqual(early.verdict(0), .pass, "a change before Go is not the key's: \(att.metrics.detail)")
        XCTAssertEqual(att.volume?.volumeEvents, 0)
    }

    func testVolumeChangesPassesOnAMuteAndFailsOnSilence() throws {
        let (r, att) = try volumeRun(control: "g4", output: nil, buttons: [], volume: "changes", times: 1, payload: 0x04,
                                     during: { r, _ in r.send(self.change(r, .mute, .device(scalar: 0.5, muted: true))) })
        XCTAssertEqual(r.verdict(0), .pass, att.metrics.detail)
        XCTAssertEqual(att.volume?.muteEvents, 1)
        XCTAssertEqual(att.volume?.startMuted, false)
        XCTAssertEqual(att.volume?.endMuted, true)
        let (silent, att2) = try volumeRun(control: "g4", output: nil, buttons: [], volume: "changes", times: 1, payload: 0x04)
        guard case .fail(let why)? = silent.verdict(0) else { return XCTFail("\(String(describing: silent.verdict(0))) \(att2.metrics.detail)") }
        XCTAssertTrue(why.contains("neither the volume nor the mute changed"), why)
    }

    func testNoKeyReportIsInconclusiveAndShownAsSuchNotAsAFailure() throws {
        let (r, att) = try volumeRun(control: "g3", output: .pad(.rb), buttons: ["RB"], volume: "unchanged", times: 2, payload: nil)
        guard case .inconclusive(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0))) \(att.metrics.detail)") }
        XCTAssertTrue(why.hasPrefix("cannot judge the volume: no volume-key report"), why)
        XCTAssertEqual(att.volume?.consumerReports, 0)
    }

    func testVolumeAtItsLimitAtGoIsInconclusive() throws {
        // G2 (volume down) with the volume at zero.
        let (r, att) = try volumeRun(control: "g2", output: .nothing, buttons: [], volume: "unchanged", times: 2,
                                     start: .device(scalar: 0), payload: 0x02)
        guard case .inconclusive(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0))) \(att.metrics.detail)") }
        XCTAssertTrue(why.contains("already at its lowest"), why)
        // G3 (volume up) with the volume at full.
        let (top, _) = try volumeRun(control: "g3", output: .pad(.rb), buttons: ["RB"], volume: "unchanged", times: 2,
                                     start: .device(scalar: 1), payload: 0x01)
        guard case .inconclusive(let why2)? = top.verdict(0) else { return XCTFail("\(String(describing: top.verdict(0)))") }
        XCTAssertTrue(why2.contains("already at its highest"), why2)
    }

    func testADeviceWithNoVolumeOrMuteIsInconclusive() throws {
        let (r, _) = try volumeRun(control: "g3", output: .pad(.rb), buttons: ["RB"], volume: "unchanged", times: 2,
                                   start: VolumeState(deviceID: 5, hasVolume: false, hasMute: false))
        guard case .inconclusive(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.contains("neither a software volume nor a mute"), why)
    }

    func testAnOutputDeviceChangeDuringTheStepIsInconclusive() throws {
        let (r, att) = try volumeRun(control: "g3", output: .pad(.rb), buttons: ["RB"], volume: "unchanged", times: 2,
                                     during: { r, i in if i == 1 { r.send(self.change(r, .device, .device(9, scalar: 0.8))) } })
        guard case .inconclusive(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.contains("output device changed"), why)
        XCTAssertEqual(att.volume?.deviceEvents, 1)
    }

    func testAPadFailureWinsOverAnInconclusiveVolume() throws {
        // The pad never shows RB although the step expects it: the pad part fails, and the missing key report does not hide it.
        let (r, _) = try volumeRun(control: "g3", output: nil, buttons: ["RB"], volume: "unchanged", times: 2, payload: nil, padShows: false)
        XCTAssertEqual(r.verdict(0)?.tag, "fail")
    }

    func testOnlyAStepWithExpectVolumeKeepsOrReportsAnything() {
        let r = Rig()
        r.prepare()
        r.start(steps: [Rig.restStep, Rig.aStep])
        r.send(.volumeState(.device(), tNs: r.now))
        r.untilGo(); r.advance(2100)
        r.send(key(r, 0x01))
        r.send(change(r, .volume))
        r.untilGo(); r.pressA(); r.advance(400)
        XCTAssertEqual(r.core.state, .finished)
        let report = r.reportsWritten[0]
        XCTAssertEqual(report.steps.map { $0.verdict }, [.pass, .pass], "volume events do not touch a step that did not ask")
        XCTAssertTrue(report.steps.allSatisfy { $0.attempts.allSatisfy { $0.volume == nil } })
        let json = String(decoding: (try? report.encoded()) ?? Data(), as: UTF8.self)
        XCTAssertFalse(json.contains("\"volume\""), "such a report is byte for byte what it was")
    }
}


// MARK: - Record steps and the receiver recording (remap step 2, S1(e))

final class DevRecordTests: XCTestCase {
    private func recordStep(_ controls: [String], rises: Int? = nil, seconds: Double = 6) -> DevStep {
        var s = DevStep(id: "survey", kind: .record, controls: controls, title: "Press it", seconds: seconds, readySeconds: 1)
        if let rises { var e = DevExpect(); e.rises = rises; s.expect = e }
        return s
    }

    /// Outer right paddle: its own extra bit and, in the factory profile, D-pad right (hat 2) in the same report.
    private func paddleFrame(echo: Bool = true, extra: UInt16 = 1) -> GamepadFrame {
        var f = GamepadFrame.idle
        f.extra = extra
        if echo { f.hat = 2 }
        return f
    }

    private func attempt(_ r: Rig, _ index: Int = 0) -> DevAttempt? { r.core.results[0][index]?.attempts.last }

    func testTheWindowOpensOnAListedControlAndTheChangedReportsAreStored() {
        let r = Rig()
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right"], rises: 2)])
        r.untilGo()
        for _ in 0..<2 {
            r.frame = paddleFrame(); r.advance(100)
            r.frame = .idle; r.advance(100)
        }
        r.advance(500)
        guard case .recorded(let text)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(text.hasPrefix("Recorded 5 receiver reports that changed"), text)
        XCTAssertTrue(text.hasSuffix("nothing was judged."), text)
        XCTAssertEqual(r.core.results[0][0]?.attempts.last?.metrics.detail, "receiver frames kept: 5")
        let att = attempt(r)!
        let rec = att.receiver ?? []
        XCTAssertEqual(rec.count, 5, "the first report of the step, then press, release, press, release")
        XCTAssertTrue(rec.allSatisfy { $0.byteValues.count == 16 && $0.byteValues[0] == 6 })
        XCTAssertEqual(rec.map(\.n), rec.map(\.n).sorted())
        XCTAssertEqual(Set(rec.map(\.n)).count, 5)
        let frames = rec.compactMap { GamepadFrame.parse($0.byteValues) }
        XCTAssertEqual(frames.map(\.extra), [0, 1, 0, 1, 0])
        XCTAssertEqual(frames.map(\.hat), [8, 2, 8, 2, 8], "the echo and the bit change in the same report")
        XCTAssertLessThan(rec[0].t, 0, "before the window")
        XCTAssertEqual(rec[1].t, 0, accuracy: 1e-9, "the report that opens the window is time zero")
        XCTAssertGreaterThan(rec[2].t, 90)
        XCTAssertNil(att.receiverDropped)
        XCTAssertEqual(att.metrics.detail, "receiver frames kept: 5", "the table shows how many frames were kept (mockup v7)")
        XCTAssertEqual(att.verdict, .recorded(text))
        XCTAssertEqual(r.core.state, .finished)
    }

    func testStickMovesAndUnchangedReportsAreNotStored() {
        let r = Rig()
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right"], rises: 1)])
        r.untilGo()
        var press = paddleFrame(); press.x = 12000; press.y = -9000
        r.frame = press; r.advance(200)
        var moved = press; moved.x = -5000; moved.rz = 3000       // sticks only: the non-stick bytes are the same
        r.frame = moved; r.advance(200)
        r.frame = .idle; r.advance(900)
        let frames = (attempt(r)?.receiver ?? []).compactMap { GamepadFrame.parse($0.byteValues) }
        XCTAssertEqual(frames.map(\.extra), [0, 1, 0], "baseline, press, release: stick movement adds nothing")
        XCTAssertEqual(frames[1].x, 12000, "the stored report is the whole 16 bytes, sticks included")
    }

    func testAWrongStoredBitDoesNotStopTheWindowFromOpening() {
        let r = Rig()
        r.mapping.physicalBits["paddle_outer_right"] = 8          // a mis-learn: the table says bit 0
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right"], rises: 1)])
        r.untilGo()
        r.frame = paddleFrame(); r.advance(120)
        r.frame = .idle; r.advance(800)
        guard case .recorded? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
    }

    func testNoEarlyEndWhileAnEchoIsStillShownThenEarlyEndAfterTheRestTime() {
        let r = Rig()
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right"], rises: 1)])
        r.untilGo()
        r.frame = paddleFrame(); r.advance(100)
        // The key is up but the echo (hat 2) is still on: the receiver is not at rest, the step goes on.
        r.frame = paddleFrame(echo: true, extra: 0); r.advance(900)
        guard case .step(0, .window) = r.core.state else { return XCTFail("ended while the echo was still set: \(r.core.state)") }
        r.frame = .idle; r.advance(300)
        guard case .step(0, .window) = r.core.state else { return XCTFail("ended before the rest time: \(r.core.state)") }
        r.advance(150)
        guard case .recorded? = r.verdict(0) else { return XCTFail("\(r.core.state)") }
        let frames = (attempt(r)?.receiver ?? []).compactMap { GamepadFrame.parse($0.byteValues) }
        XCTAssertEqual(frames.map(\.hat), [8, 2, 2, 8])
        XCTAssertEqual(frames.map(\.extra), [0, 1, 0, 0], "the late echo release is in the file")
    }

    func testTheStepRunsToItsSecondsWhenTheAskedForPressesAreNotAllIn() {
        let r = Rig()
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right"], rises: 3, seconds: 4)])
        r.untilGo()
        for _ in 0..<2 {
            r.frame = paddleFrame(); r.advance(100)
            r.frame = .idle; r.advance(100)
        }
        r.advance(1500)
        guard case .step(0, .window) = r.core.state else { return XCTFail("ended early with two of three presses: \(r.core.state)") }
        r.advance(3000)
        guard case .recorded? = r.verdict(0) else { return XCTFail("\(r.core.state)") }
    }

    func testEveryListedControlMustGoDownAndUpBeforeAnEarlyEnd() {
        let r = Rig()
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right", "paddle_inner_left"], rises: 2)])
        r.untilGo()
        // Two presses of the first key only: the count is reached but the second key never moved.
        for _ in 0..<2 {
            r.frame = paddleFrame(); r.advance(100)
            r.frame = .idle; r.advance(100)
        }
        r.advance(1000)
        guard case .step(0, .window) = r.core.state else { return XCTFail("ended with one key unpressed: \(r.core.state)") }
        var inner = GamepadFrame.idle; inner.extra = 4; inner.hat = 0
        r.frame = inner; r.advance(100)
        r.frame = .idle; r.advance(600)
        guard case .recorded? = r.verdict(0) else { return XCTFail("\(r.core.state)") }
    }

    func testNoMovementStillFailsAndKeepsWhatWasRecorded() {
        let r = Rig()
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right"], rises: 1), Rig.aStep])
        r.untilGo()
        r.advance(5100)
        guard case .fail(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.hasPrefix("no movement"), why)
        XCTAssertEqual(attempt(r)?.receiver?.count, 1, "the baseline report is kept")
        XCTAssertEqual(r.core.state, .step(index: 1, phase: .ready))
    }

    func testOtherStepsStoreNothingUnlessTheTemplateAsks() {
        let plain = Rig()
        plain.prepare()
        plain.start(steps: [Rig.aStep])
        plain.untilGo(); plain.pressA(); plain.advance(500)
        XCTAssertEqual(plain.verdict(0), .pass)
        XCTAssertNil(plain.core.results[0][0]?.attempts.last?.receiver)

        let rec = Rig()
        rec.prepare()
        rec.start(steps: [Rig.aStep], recordReceiver: true)
        rec.untilGo(); rec.pressA(); rec.advance(500)
        XCTAssertEqual(rec.verdict(0), .pass, "recording does not change the verdict of an ordinary step")
        let frames = (rec.core.results[0][0]?.attempts.last?.receiver ?? []).compactMap { GamepadFrame.parse($0.byteValues) }
        XCTAssertEqual(frames.map(\.buttons), [0, 1, 0, 1, 0])
    }

    func testTheRecordingIsCappedPerStep() {
        let r = Rig()
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right"], rises: 1, seconds: 100)])
        r.untilGo()
        r.frame = paddleFrame(); r.advance(50)
        for i in 0..<(DevRecorder.maxFramesPerStep + 150) {
            var f = paddleFrame()
            f.lt = UInt16(i % 2 == 0 ? 500 : 600)                  // an analog field moving: every report differs
            r.frame = f
            r.advance(5)
        }
        r.frame = .idle; r.advance(2000)
        let att = attempt(r)
        XCTAssertEqual(att?.receiver?.count, DevRecorder.maxFramesPerStep)
        XCTAssertGreaterThan(att?.receiverDropped ?? 0, 100)
    }

    func testAFinishedRunSaysHowManyStepsWereRecorded() {
        let r = Rig()
        r.prepare()
        r.start(steps: [recordStep(["paddle_outer_right"], rises: 1)])
        r.untilGo()
        r.frame = paddleFrame(); r.advance(100)
        r.frame = .idle; r.advance(800)
        XCTAssertEqual(r.core.state, .finished)
        XCTAssertEqual(r.lastInstruction?.detail, "0 passed, 0 failed, 0 skipped or unclear. 1 recorded.")
        XCTAssertEqual(r.core.results[0][0]?.attempts.last?.verdict.tag, "recorded")
    }

    func testARecordStepHasNothingToJudge() {
        var input = DevJudge.Input(step: recordStep(["paddle_outer_right"]), entryState: nil, reports: [],
                                   windowStartNs: 0, windowEndNs: 1, endNs: 1, matchedCount: 7)
        input.expected = DevExpectedItems()
        let out = DevJudge.judge(input)
        XCTAssertEqual(out.verdict, .recorded("nothing was judged"), "not inconclusive for a missing pad state or a wrong reader count")
    }

    func testTheReceiverReportReadsBackFromItsFrame() {
        var rng = SplitMix64(seed: 0x5EC7)
        for _ in 0..<2000 {
            var raw = XlateFixtures.randomRaw(&rng)
            raw[0] = 6
            // bits above bit 31 do not exist; byte 15 is fully used (bits 24..31 = extra bits 5..12)
            guard let f = GamepadFrame.parse(raw) else { continue }
            XCTAssertEqual(f.rawBytes, raw)
            XCTAssertEqual(f.nonStickBytes, Array(raw[9...]))
        }
    }

    func testPaddleAndSAXKeysOpenByTheTableNotByTheStoredBits() {
        var wrong = ControlMapping.default
        wrong.physicalBits["sax_left"] = 2
        for (id, bit) in DevRecorder.keyBits {
            var f = GamepadFrame.idle
            f.extra = bit
            XCTAssertTrue(DevRecorder.isActive(id, f, mapping: wrong), id)
            f.extra = ~bit & 0x3f
            XCTAssertFalse(DevRecorder.isActive(id, f, mapping: wrong), id)
        }
        XCTAssertEqual(Set(DevRecorder.keyBits.values), [1, 2, 4, 8, 16, 32])
        var a = GamepadFrame.idle; a.buttons = 1
        XCTAssertTrue(DevRecorder.isActive("a", a, mapping: wrong), "another control is read the way the mapping reads it")
    }
}

// MARK: - Row 11 and row 12 end to end: the run-long filter, `background` and the hiding verdict (remap step 2, S4)

/// The real built-in steps of rows 11 and 12 run through the runner against a model of the controller (`EchoSim`): the
/// controller adds each held key's echo and combines the D-pad itself, the runner cleans the receiver's reports with its own
/// filter, and the pad is what the sink would post (the same rule, stepped on its own).
final class DevRemapRunTests: XCTestCase {
    private static let layout = ControlLayout.loadFromBundle()!

    private final class World {
        let r = Rig()
        var sim = EchoState()
        var echoes = EchoSim.factoryEchoes
        var real: UInt16 = 0
        var keys: UInt8 = 0
        /// A pad fed with the report as the controller sent it, not cleaned: what the Swift sink would show without the rule.
        var padFromRaw = false

        init(_ mapping: ControlMapping) { r.mapping = mapping }

        func frame() -> GamepadFrame {
            let c = EchoSim.controller(real: real, keys: keys, echoes: echoes)
            var f = GamepadFrame.idle
            f.buttons = c.buttons; f.hat = c.hat; f.extra = c.extra
            return f
        }

        /// One report: "+OR +up", "-up", "E=OR:A" (the controller now adds A for that key). Holds for `ms`.
        func report(_ tokens: String, hold ms: Double = 90) {
            for t in tokens.split(separator: " ").map(String.init) {
                if t.hasPrefix("E=") {
                    let p = t.dropFirst(2).split(separator: ":").map(String.init)
                    echoes[EchoSim.keyNames.firstIndex(of: p[0])!] = EchoSim.itemTokens[p[1]]!
                    continue
                }
                let on = t.hasPrefix("+"), name = String(t.dropFirst())
                if let k = EchoSim.keyNames.firstIndex(of: name) {
                    if on { keys |= 1 << UInt8(k) } else { keys &= ~(1 << UInt8(k)) }
                } else if let m = EchoSim.itemTokens[name] {
                    if on { real |= m } else { real &= ~m }
                } else { fatalError("unknown token \(t)") }
            }
            let f = frame()
            let word = sim.step(r.mapping.echoParams, frame: f)
            let shown = padFromRaw ? f : EchoFilter.apply(word, to: f)
            r.move(f, PassthroughPadMapper.padState(shown, r.mapping), hold: ms)
        }

        func play(_ script: [String], hold ms: Double = 90) { for t in script { report(t, hold: ms) } }
    }

    private func row11Mapping() -> ControlMapping {
        var m = ControlMapping.default
        m.setOutput(.pad(.r3), for: "paddle_outer_right")
        m.setOutput(.pad(.l3), for: "paddle_outer_left")
        m.setOutput(.nothing, for: "paddle_inner_left")
        m.setOutput(.pad(.view), for: "sax_left")
        m.setOutput(.pad(.menu), for: "sax_right")
        return m
    }

    private func step(_ id: String) -> DevStep {
        DevBuiltins.remapPaddles(layout: Self.layout).steps.first { $0.id == id }!
    }

    /// Runs one step of row 11 and returns the world after `script` (played after Go).
    private func run(_ id: String, mapping: ControlMapping? = nil, script: [String], prelude: [String] = [],
                     padFromRaw: Bool = false, hold: Double = 90) -> (World, DevAttempt) {
        let w = World(mapping ?? row11Mapping())
        w.padFromRaw = padFromRaw
        w.r.prepare()
        w.r.start(steps: [step(id)], recordReceiver: true)
        w.r.untilGo()
        w.play(script, hold: hold)
        var spent = 0.0
        while w.r.core.isRunning, spent < 40_000 { w.r.advance(100); spent += 100 }
        XCTAssertFalse(w.r.core.isRunning, "step \(id) never ended: \(w.r.core.state)")
        return (w, w.r.core.results[0][0]!.attempts.last!)
    }

    private func presses(_ key: String, times n: Int) -> [String] {
        Array((0..<n).map { _ in ["+\(key)", "-\(key)"] }.joined())
    }

    func testTenPressesOfARemappedKeyPassAndTheHidingIsConclusive() {
        let (w, att) = run("outer-right", script: presses("OR", times: 10))
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertEqual(w.r.verdict(0), .pass)
        guard let hiding = att.hiding else { return XCTFail("no hiding check: \(att.verdict) \(att.metrics.detail)") }
        XCTAssertTrue(hiding.conclusive)
        XCTAssertEqual(hiding.line, "controller's own button hidden: pass (D-pad right seen on the receiver, never on the pad)")
        XCTAssertEqual(hiding.presses.count, 10)
        XCTAssertTrue(hiding.presses.allSatisfy { $0.result == "hidden" && $0.item == "D-pad right" && $0.found == "seen" })
        XCTAssertTrue(att.metrics.detail.contains("Controller's own button hidden: pass"), att.metrics.detail)
        // the run's own filter counted its work, before and after the step
        XCTAssertGreaterThan(att.metrics.values["echo.hiddenFramesAfter"] ?? 0, att.metrics.values["echo.hiddenFramesBefore"] ?? 1)
        XCTAssertEqual(att.metrics.values["echo.validAfter"], 1, "the filter has seen reports")
    }

    func testALeakedEchoIsAnUnexpectedChangeAndFailsTheStep() {
        let (_, att) = run("outer-right", script: presses("OR", times: 10), padFromRaw: true)
        guard case .fail(let why) = att.verdict else { return XCTFail("\(att.verdict)") }
        XCTAssertTrue(why.contains("unexpected change on D-pad right"), why)
        // Review of S4, finding 11: a step that leaked cannot also say the button was never on the pad
        XCTAssertEqual(att.hiding?.conclusive, false)
        XCTAssertEqual(att.hiding?.line, "controller's own button hidden: cannot judge: the step did not pass")
        XCTAssertTrue(att.hiding?.presses.allSatisfy { $0.result == "cannot judge" && $0.reason == "the step did not pass" } ?? false)
        XCTAssertFalse(att.metrics.detail.contains("never on the pad"), att.metrics.detail)
    }

    func testAKeyOnNothingExpectsNoPadChangeAndItsHidingIsJudgedToo() {
        let (_, att) = run("inner-left", script: presses("IL", times: 10))
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertEqual(att.hiding?.conclusive, true)
        XCTAssertEqual(att.hiding?.presses.first?.item, "D-pad up")
        let (_, leak) = run("inner-left", script: presses("IL", times: 10), padFromRaw: true)
        guard case .fail(let why) = leak.verdict else { return XCTFail("\(leak.verdict)") }
        XCTAssertTrue(why.contains("D-pad up"), why)
        XCTAssertEqual(leak.hiding?.conclusive, false)
        XCTAssertFalse(leak.metrics.detail.contains("never on the pad"), leak.metrics.detail)
    }

    func testPaddleHeldFirstThenDpadUpPassesWithRThreeHeldInTheBackground() {
        let (_, att) = run("outer-right-dpad-up", script: ["+OR"] + ["+up", "-up", "+up", "-up"] + ["-OR"])
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertEqual(att.hiding?.conclusive, true)
        XCTAssertEqual(att.hiding?.line, "controller's own button hidden: pass (D-pad right seen on the receiver, never on the pad)")
        XCTAssertTrue(att.metrics.detail.contains("R3 held throughout"), att.metrics.detail)
        // the held paddle stays down the whole step, but only the presses count towards the early end: it does not run 15 s
        XCTAssertLessThan(Double(att.windowEndNs - att.windowStartNs) / 1e9, 6, "the step ends once both are let go and the receiver is quiet")
    }

    func testPaddleHeldFirstThenDpadLeftPassesOnCleanedFramesAndFailsOnRawOnes() {
        let script = ["+OR", "+left", "-left", "+left", "-left", "-OR"]
        let (_, att) = run("outer-right-dpad-left", script: script)
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        guard let hiding = att.hiding else { return XCTFail("no hiding check: \(att.verdict) \(att.metrics.detail)") }
        XCTAssertTrue(hiding.conclusive)
        XCTAssertEqual(hiding.line, "controller's own button hidden: pass (D-pad right was seen on the receiver before D-pad left; the pad showed D-pad left while the controller sent no direction)")
        // raw: the controller sends no direction while D-pad left is down, so the pad would not show it
        let (_, raw) = run("outer-right-dpad-left", script: script, padFromRaw: true)
        guard case .fail = raw.verdict else { return XCTFail("\(raw.verdict): \(raw.metrics.detail)") }
    }

    func testDpadLeftHeldFirstThenThePaddlePassesAndIsNotExercised() {
        let script = ["+left", "+OR", "-OR", "+OR", "-OR", "-left"]
        let (_, att) = run("dpad-left-outer-right", script: script)
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertTrue(att.metrics.detail.contains("D-pad left held throughout"), att.metrics.detail)
        guard let hiding = att.hiding else { return XCTFail("no hiding check: \(att.verdict) \(att.metrics.detail)") }
        XCTAssertFalse(hiding.conclusive)
        XCTAssertEqual(hiding.line, "controller's own button hidden: not exercised (the controller sent no D-pad right during the hold)")
        // without the rule the controller's cancel would drop D-pad left from the pad
        let (_, raw) = run("dpad-left-outer-right", script: script, padFromRaw: true)
        guard case .fail(let why) = raw.verdict else { return XCTFail("\(raw.verdict)") }
        XCTAssertTrue(why.contains("D-pad left dropped while R3 was being pressed"), why)
    }

    func testAHeldAMakesSAXLeftCannotJudgeBecauseItsEchoIsTheBackgroundItem() {
        let (_, att) = run("a-held-sax-left", script: ["+A", "+SL", "-SL", "+SL", "-SL", "-A"])
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        guard let hiding = att.hiding else { return XCTFail("no hiding check: \(att.verdict) \(att.metrics.detail)") }
        XCTAssertFalse(hiding.conclusive)
        XCTAssertEqual(hiding.line, "controller's own button hidden: cannot judge: the controller's current profile sends A for this key")
    }

    func testAPressTheFilterCouldNotReadIsCannotJudgeNotSeenAtItsPress() {
        // A real A is held (the background item) and the controller now adds A for outer right (a profile change): the press
        // changes nothing but the key's bit, so the item cannot be seen or confirmed.
        var bg = step("outer-right")
        bg.id = "bg"
        bg.controls = ["a", "paddle_outer_right"]
        var e = DevExpect(); e.items = DevExpectedItems(buttons: ["RS"]); e.background = ["a"]; e.times = 3
        bg.expect = e
        let w = World(row11Mapping())
        w.r.prepare()
        w.r.start(steps: [bg], recordReceiver: true)
        w.r.untilGo()
        w.play(["+A", "E=OR:A"] + presses("OR", times: 3) + ["-A"])
        var spent = 0.0
        while w.r.core.isRunning, spent < 40_000 { w.r.advance(100); spent += 100 }
        guard let att = w.r.core.results[0][0]?.attempts.last, let hiding = att.hiding else { return XCTFail("no hiding check") }
        XCTAssertFalse(hiding.conclusive, hiding.line)
        XCTAssertEqual(hiding.presses.first?.found, "unconfirmed")
        XCTAssertEqual(hiding.line, "controller's own button hidden: cannot judge: the controller's button for this key was not seen at its press (it sent none or several)")
    }

    func testBothOuterPaddlesTogetherPassWithNoDpadOnThePad() {
        let (_, att) = run("together-outer", script: ["+OL +OR", "-OL -OR", "+OL +OR", "-OL -OR"])
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertNotNil(att.hiding)
        // Review of S4, finding 10: two keys in one report are agreed with, not read off a single press: "confirmed"
        XCTAssertEqual(att.hiding?.presses.count, 4)
        XCTAssertTrue(att.hiding?.presses.allSatisfy { $0.found == "confirmed" } ?? false, "\(String(describing: att.hiding?.presses))")
    }

    func testAnUntouchedPaddleIsJudgedByTheEchoWhateverTheProfileGives() {
        let (_, factory) = run("inner-right-profile", script: presses("IR", times: 2))
        XCTAssertEqual(factory.verdict, .pass, factory.metrics.detail)
        XCTAssertTrue(factory.metrics.detail.hasPrefix("Saw D-pad down on each press"), factory.metrics.detail)
        XCTAssertNil(factory.hiding, "no claim about an untouched key")
        XCTAssertEqual(factory.echoItem, "D-pad down", "the report names the item, for dev-run-compare.py")
        // another profile: the key now adds Y, the same step passes and names Y
        let (_, other) = run("inner-right-profile", script: ["E=IR:Y"] + presses("IR", times: 2))
        XCTAssertEqual(other.verdict, .pass, other.metrics.detail)
        XCTAssertTrue(other.metrics.detail.hasPrefix("Saw Y on each press"), other.metrics.detail)
        XCTAssertEqual(other.echoItem, "Y")
    }

    func testAnUntouchedKeyThatSendsNothingCannotBeJudgedAndIsNotAFailure() {
        // The profile adds nothing for this key (the echo is the key's own bit only).
        let w = World(row11Mapping())
        w.echoes[1] = 0
        w.r.prepare()
        w.r.start(steps: [step("inner-right-profile")], recordReceiver: true)
        w.r.untilGo()
        w.play(presses("IR", times: 2))
        var spent = 0.0
        while w.r.core.isRunning, spent < 40_000 { w.r.advance(100); spent += 100 }
        let att = w.r.core.results[0][0]!.attempts.last!
        XCTAssertEqual(att.verdict, .inconclusive("cannot judge: the controller sent no button for this key"))
        XCTAssertEqual(att.verdict.reason, "cannot judge: the controller sent no button for this key")
    }

    func testRowElevenHasFourteenStepsAndItsOwnTitlesAndPicks() {
        let t = DevBuiltins.remapPaddles(layout: Self.layout)
        XCTAssertEqual(t.title, "Remap check: paddles and SAX (App, then Driver)")
        XCTAssertEqual(t.steps.count, 14)
        XCTAssertEqual(t.recordReceiver, true)
        XCTAssertEqual(t.paths ?? [], ["engine", "driver"])
        XCTAssertTrue(t.steps.allSatisfy { $0.requires != nil })
        XCTAssertEqual(t.validation(layout: Self.layout).errors, [])
        // on the owner's picks nothing is skipped; on the factory mapping every step is
        let on = DevResolvedStep.resolve(template: t, mapping: row11Mapping(), layout: Self.layout)
        XCTAssertTrue(on.allSatisfy { $0.skipReason == nil }, "\(on.compactMap(\.skipReason))")
        let off = DevResolvedStep.resolve(template: t, mapping: .default, layout: Self.layout)
        XCTAssertTrue(off.allSatisfy { $0.skipReason != nil })
        XCTAssertEqual(off[1].skipReason, "needs Paddle inner left → Nothing: set it in Mapping", "the first miss, in control order")
        var innerRightRemapped = row11Mapping()
        innerRightRemapped.setOutput(.pad(.y), for: "paddle_inner_right")
        XCTAssertEqual(DevResolvedStep.resolve(template: t, mapping: innerRightRemapped, layout: Self.layout)[1].skipReason,
                       "needs Paddle inner right on Controller's profile: Reset it in Mapping")
        // the paddle inner right step takes the builtInEcho rule; the remapped keys' steps carry the hiding check
        XCTAssertTrue(on[6].builtInEcho)
        XCTAssertEqual(on[1].hiddenKeys, ["paddle_outer_right"])
        XCTAssertEqual(on[7].background, [.rs])
        XCTAssertEqual(on[9].background, [.dpadLeft])
        XCTAssertEqual(on[10].background, [.a])
    }

    // MARK: The run-long filter

    func testTheReferenceAndTheWindowSeeTheCleanedReportsNotTheEcho() {
        // Paddle outer right sent to Y, with its D-pad-right echo arriving a report AFTER the key's bit.
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        let r = Rig()
        r.mapping = m
        let yStep = DevStep(id: "y", kind: .digital, controls: ["paddle_outer_right"], title: "t", seconds: 6, readySeconds: 1)
        var e = DevExpect(); e.items = DevExpectedItems(buttons: ["Y"])
        var step = yStep; step.expect = e
        r.prepare()
        r.start(steps: [step])
        r.untilGo()
        func f(extra: UInt16, hat: UInt8) -> GamepadFrame { var g = GamepadFrame.idle; g.extra = extra; g.hat = hat; return g }
        for _ in 0..<2 {
            r.move(f(extra: 1, hat: 8), PassthroughPadMapper.padState(EchoFilter.apply(0, to: f(extra: 1, hat: 8)), m).with { $0.buttons = [.y] }, hold: 120)
            r.frame = f(extra: 1, hat: 2); r.advance(120)           // the echo comes a report later
            r.move(.idle, PadState(), hold: 200)
        }
        var spent = 0.0
        while r.core.isRunning, spent < 10_000 { r.advance(100); spent += 100 }
        let att = r.core.results[0][0]!.attempts.last!
        XCTAssertEqual(att.metrics.expectedChanges, 4, "Y down and up twice; the late D-pad right edge is not an expected change")
        XCTAssertEqual(r.core.results[0][0]!.expected, DevExpectedItems(buttons: ["Y"]))
    }

    func testADpadRightStepDoesNotOpenItsWindowOnAHiddenPaddleHold() {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        let r = Rig()
        r.mapping = m
        var step = DevStep(id: "right", kind: .digital, controls: ["dpad_right"], title: "t", seconds: 6, readySeconds: 1)
        var e = DevExpect(); e.items = DevExpectedItems(hat: "E"); step.expect = e
        r.prepare()
        r.start(steps: [step])
        r.untilGo()
        var held = GamepadFrame.idle; held.extra = 1; held.hat = 2          // the paddle and its echo in one report
        r.frame = held; r.advance(300)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .ready), "the paddle's D-pad right is hidden: it does not start the D-pad step")
        r.frame = .idle; r.advance(500)
        r.untilGo()
        var real = GamepadFrame.idle; real.hat = 2
        r.frame = real; r.advance(50)
        XCTAssertEqual(r.core.state, .step(index: 0, phase: .window), "a real D-pad right does")
    }

    func testStoppingAtTheDriverPassQuestionOnAMappingTheDriverCannotTakeStandsTheDriverPassDown() {
        let r = Rig()
        r.mapping.setOutput(.pad(.r3), for: "paddle_outer_right")
        r.prepare()
        r.start(.engine, steps: [Rig.restStep], paths: ["engine", "driver"])
        r.untilGo()
        r.advance(2500)
        let note = "Paddle outer right sends R3: this driver version cannot hide the controller's own press"
        r.send(.status(Rig.status(armed: "inert", path: "driver") { $0.mappingNote = note }))
        r.advance(10_100)
        guard case .runAnyway(let text)? = r.prompts.last else { return XCTFail("\(r.prompts)") }
        XCTAssertEqual(text, "Driver pass cannot be confirmed: \(note). Press Stop to keep the App result, or Reset that remap first.")
        r.send(.stop)
        XCTAssertEqual(r.core.standDownPass, 1)
        let words = "Driver pass not run: this driver version cannot take this mapping (\(note)). The App pass is the result of this run."
        XCTAssertEqual(r.core.standDownNote, words)
        XCTAssertTrue(r.core.notes.contains(words))
        XCTAssertEqual(r.reportsWritten.first?.complete, true, "the App pass has its report")
        XCTAssertEqual(r.reportsWritten.count, 1, "no report for a pass that never ran")
        // Run anyway is not a stand-down
        let other = Rig()
        other.mapping.setOutput(.pad(.r3), for: "paddle_outer_right")
        other.prepare(status: Rig.status(armed: "inert", path: "driver") { $0.mappingNote = note })
        other.start(.driver)
        other.advance(10_100)
        other.send(.runAnyway)
        other.send(.stop)
        XCTAssertNil(other.core.standDownPass)
    }

    /// Review of S4, findings 4, 7 and 8: after the stand-down the finished screen counts the App pass (the Driver pass has
    /// an empty row), and a re-run without a pass goes to the App pass.
    func testAfterAStoodDownDriverPassTheShownPassIsTheAppPass() {
        let r = Rig()
        r.mapping.setOutput(.pad(.r3), for: "paddle_outer_right")
        r.prepare()
        r.start(.engine, steps: [Rig.restStep], paths: ["engine", "driver"])
        r.untilGo()
        r.advance(2500)
        r.send(.status(Rig.status(armed: "inert", path: "driver") { $0.mappingNote = "Paddle outer right sends R3: this driver version cannot hide the controller's own press" }))
        r.advance(10_100)
        XCTAssertEqual(r.core.shownPass, 1, "before the stop, the last pass is the shown one")
        r.send(.stop)
        XCTAssertEqual(r.core.standDownPass, 1)
        XCTAssertEqual(r.core.shownPass, 0, "the App pass")
        XCTAssertEqual(r.core.results[0].compactMap { $0 }.count, 1)
        XCTAssertTrue(r.core.results[1].allSatisfy { $0 == nil }, "the Driver pass has nothing")
        let text = r.lastInstruction
        XCTAssertEqual(text?.title, "Run complete")
        XCTAssertEqual(text?.detail, "1 passed, 0 failed, 0 skipped or unclear.", "counted from the App pass, not the empty Driver pass")
        // a re-run with no pass named goes to the App pass
        r.send(.rerun(0, pass: nil))
        XCTAssertEqual(r.core.pass, 0)
    }

    // MARK: Row 12 on the model

    private func row12Mapping() -> ControlMapping {
        var m = ControlMapping.default
        m.setOutput(.pad(.lt), for: "g1"); m.setOutput(.pad(.rt), for: "lt"); m.setOutput(.pad(.a), for: "x"); m.setOutput(.pad(.a), for: "g5")
        return m
    }

    /// Runs one step of row 12; each entry of `script` is a receiver frame held for `hold` ms, the pad shows what the mapper gives.
    private func run12(_ id: String, _ script: [GamepadFrame], hold: Double = 120, mapping: ControlMapping? = nil,
                       padOverride: ((GamepadFrame) -> PadState)? = nil) -> DevAttempt {
        let r = Rig()
        r.mapping = mapping ?? row12Mapping()
        r.prepare()
        r.start(steps: [DevBuiltins.remapTriggers().steps.first { $0.id == id }!], recordReceiver: nil)
        r.untilGo()
        for f in script { r.move(f, padOverride?(f) ?? PassthroughPadMapper.padState(f, r.mapping), hold: hold) }
        var spent = 0.0
        while r.core.isRunning, spent < 20_000 { r.advance(100); spent += 100 }
        return r.core.results[0][0]!.attempts.last!
    }

    private func frame(_ edit: (inout GamepadFrame) -> Void) -> GamepadFrame { var f = GamepadFrame.idle; edit(&f); return f }

    func testG1SentToLTPullsLTInFullEachPressAndRTStaysStill() {
        let down = frame { $0.buttons = 1 << 11 }
        let att = run12("g1", [down, .idle, down, .idle])
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertEqual(att.metrics.values["lt.pulls"], 2)
        // RT moving as well is a failure
        let bad = run12("g1", [down, .idle, down, .idle], padOverride: { f in var p = PassthroughPadMapper.padState(f, self.row12Mapping()); if f.buttons != 0 { p.rt = 0.7 }; return p })
        guard case .fail(let why) = bad.verdict else { return XCTFail("\(bad.verdict)") }
        XCTAssertTrue(why.contains("RT moved although only LT was expected"), why)
    }

    func testLTSentToRTJudgesRTAndLTStill() {
        let pull = frame { $0.lt = 1023 }
        let att = run12("lt", [pull, .idle, pull, .idle])
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertEqual(att.metrics.values["rt.pulls"], 2)
        XCTAssertEqual(att.metrics.values["lt.peak"], 0)
        // the pad showing LT instead (LT not remapped after all) fails
        let wrong = run12("lt", [pull, .idle, pull, .idle], padOverride: { f in var p = PadState(); p.lt = f.lt > 0 ? 1 : 0; return p })
        guard case .fail(let why) = wrong.verdict else { return XCTFail("\(wrong.verdict)") }
        XCTAssertTrue(why.contains("RT only reached"), why)
    }

    func testRTStillSendsRTAndAButtonChangeIsUnexpected() {
        let pull = frame { $0.rt = 1023 }
        XCTAssertEqual(run12("rt", [pull, .idle, pull, .idle]).verdict, .pass)
        let leak = run12("rt", [pull, .idle, pull, .idle], padOverride: { f in var p = PassthroughPadMapper.padState(f, self.row12Mapping()); if f.rt > 0 { p.buttons = [.a] }; return p })
        guard case .fail(let why) = leak.verdict else { return XCTFail("\(leak.verdict)") }
        XCTAssertTrue(why.contains("unexpected change on A"), why)
    }

    func testThreeSourcesOnAEachShowAAndAHeldHandOverStaysHeld() {
        let x = frame { $0.buttons = 1 << 2 }
        let g5 = frame { $0.buttons = 1 << 15 }
        XCTAssertEqual(run12("x", [x, .idle, x, .idle]).verdict, .pass)
        XCTAssertEqual(run12("g5", [g5, .idle, g5, .idle]).verdict, .pass)
        let both = frame { $0.buttons = (1 << 2) | (1 << 15) }
        let att = run12("hold-x-then-g5", [x, both, g5, g5, .idle], hold: 700)
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertEqual(att.metrics.values["held.released"], 1)
        // A dropping when X is let go is the failure the step is about
        let drop = run12("hold-x-then-g5", [x, both, g5, g5, .idle], hold: 700,
                         padOverride: { f in var p = PassthroughPadMapper.padState(f, self.row12Mapping()); if f == g5 { p.buttons = [] }; return p })
        guard case .fail = drop.verdict else { return XCTFail("\(drop.verdict): \(drop.metrics.detail)") }
    }

    func testPullingLTAndRTThenLettingGoOfLTKeepsRTHeld() {
        let both = frame { $0.lt = 1023; $0.rt = 1023 }
        let rt = frame { $0.rt = 1023 }
        let att = run12("pull-lt-rt-let-go-lt", [both, rt, rt, .idle], hold: 700)
        XCTAssertEqual(att.verdict, .pass, att.metrics.detail)
        XCTAssertEqual(att.metrics.values["held.released"], 1)
    }

    func testRowTwelveStepsPassOnTheModelAndNeedTheirPicks() {
        let t = DevBuiltins.remapTriggers()
        XCTAssertEqual(t.title, "Remap check: triggers and three sources (App, then Driver)")
        XCTAssertEqual(t.steps.count, 9)
        XCTAssertEqual(t.validation(layout: Self.layout).errors, [])
        XCTAssertEqual(t.steps[0].requires?.mapping, ["g1": "lt", "lt": "rt", "x": "a", "g5": "a", "a": "a", "rt": "rt"])
        XCTAssertTrue(t.steps.allSatisfy { $0.requires?.mapping == t.steps[0].requires?.mapping })
        var m = ControlMapping.default
        m.setOutput(.pad(.lt), for: "g1"); m.setOutput(.pad(.rt), for: "lt"); m.setOutput(.pad(.a), for: "x"); m.setOutput(.pad(.a), for: "g5")
        let on = DevResolvedStep.resolve(template: t, mapping: m, layout: Self.layout)
        XCTAssertTrue(on.allSatisfy { $0.skipReason == nil }, "\(on.compactMap(\.skipReason))")
        XCTAssertEqual(on[1].expected, DevExpectedItems(lt: true))
        XCTAssertEqual(on[2].expected, DevExpectedItems(rt: true))
        XCTAssertEqual(on[3].expected, DevExpectedItems(rt: true))
        XCTAssertTrue(DevResolvedStep.resolve(template: t, mapping: .default, layout: Self.layout).allSatisfy { $0.skipReason != nil })
    }
}

private extension PadState {
    func with(_ edit: (inout PadState) -> Void) -> PadState { var s = self; edit(&s); return s }
}

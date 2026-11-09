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
    let mapping = ControlMapping.default
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
        guard case .skipped(let why)? = r.verdict(0) else { return XCTFail("\(String(describing: r.verdict(0)))") }
        XCTAssertTrue(why.contains("g1"), why)
        XCTAssertEqual(r.core.state, .step(index: 1, phase: .ready))
        XCTAssertFalse(r.core.canGoToPreviousStep, "Back never lands on an automatic skip")
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

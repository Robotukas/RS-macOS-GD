import XCTest
import IOKit
@testable import GDHub

// MARK: - Fakes

/// Manual clock and timer wheel. `advance(to:)` fires timers in due order, setting `now` to each due time first.
final class ManualScheduler: SinkScheduler {
    final class Timer: SinkTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private struct Entry { let timer: Timer; var due: UInt64; let interval: UInt64?; let block: () -> Void }

    private(set) var now: UInt64 = 10_000_000_000
    private var entries: [Entry] = []

    func after(_ ns: UInt64, _ block: @escaping () -> Void) -> SinkTimer {
        let t = Timer(); entries.append(Entry(timer: t, due: now + ns, interval: nil, block: block)); return t
    }
    func every(_ ns: UInt64, _ block: @escaping () -> Void) -> SinkTimer {
        let t = Timer(); entries.append(Entry(timer: t, due: now + ns, interval: ns, block: block)); return t
    }

    var activeTimers: Int { entries.filter { !$0.timer.cancelled }.count }

    func advance(by ns: UInt64) { advance(to: now + ns) }
    func advance(by ms: Int) { advance(to: now + UInt64(ms) * 1_000_000) }

    func advance(to target: UInt64) {
        while true {
            entries.removeAll { $0.timer.cancelled }
            guard let i = entries.indices.filter({ entries[$0].due <= target }).min(by: { entries[$0].due < entries[$1].due })
            else { break }
            let e = entries[i]
            now = max(now, e.due)
            if let iv = e.interval { entries[i].due = e.due + iv } else { entries.remove(at: i) }
            e.block()
        }
        now = max(now, target)
    }

    /// The process was frozen until `target`: every due timer fires once, late, and repeating ones are re-armed from
    /// `target`.
    func stall(until target: UInt64) {
        now = target
        for e in entries where !e.timer.cancelled && e.due <= target {
            if let iv = e.interval, let i = entries.firstIndex(where: { $0.timer === e.timer }) { entries[i].due = target + iv }
            else { e.timer.cancel() }
            e.block()
        }
    }
}

final class FakeTransport: PadTransport {
    enum Call: Equatable { case create(UInt32), destroy, post([UInt8]), neutral, heartbeat }
    let env: ManualScheduler
    private(set) var calls: [(at: UInt64, call: Call)] = []
    var createResult: kern_return_t = KERN_SUCCESS
    var postResult: kern_return_t = KERN_SUCCESS
    var heartbeatResult: kern_return_t = KERN_SUCCESS
    init(env: ManualScheduler) { self.env = env }

    func createDevice(_ spec: DeviceSpec) -> kern_return_t { calls.append((env.now, .create(spec.productID))); return createResult }
    func destroyDevice(slot: UInt8) -> kern_return_t { calls.append((env.now, .destroy)); return KERN_SUCCESS }
    func post(slot: UInt8, report: [UInt8]) -> kern_return_t {
        calls.append((env.now, .post(report)))
        return postResult
    }
    func postNeutral(slot: UInt8) -> kern_return_t { calls.append((env.now, .neutral)); return KERN_SUCCESS }
    func heartbeat() -> kern_return_t { calls.append((env.now, .heartbeat)); return heartbeatResult }

    var posts: [[UInt8]] { calls.compactMap { if case .post(let b) = $0.call { return b } else { return nil } } }
    func count(_ c: Call) -> Int { calls.filter { $0.call == c }.count }
    var heartbeats: Int { count(.heartbeat) }
    var neutrals: Int { count(.neutral) }
    var creates: [(at: UInt64, call: Call)] { calls.filter { if case .create = $0.call { return true } else { return false } } }
    func clear() { calls.removeAll() }
}

// MARK: - Tests

final class VirtualPadSinkTests: XCTestCase {
    private var queue: DispatchQueue!
    private var env: ManualScheduler!
    private var transport: FakeTransport!
    private var defaults: UserDefaults!
    private var suite = ""
    private var duplicate: String?

    override func setUp() {
        queue = DispatchQueue(label: "test.vhid")
        env = ManualScheduler()
        transport = FakeTransport(env: env)
        suite = "gdhub.tests.sink.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        duplicate = nil
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeSink(_ config: VirtualPadSink.Config = .init()) -> VirtualPadSink {
        VirtualPadSink(queue: queue, transport: transport, clock: { [env] in env!.now }, scheduler: env, config: config,
                       defaults: defaults, duplicateCheck: { [unowned self] _ in self.duplicate })
    }

    /// A connected sink with the default identity published and the creation traffic cleared.
    private func publishedSink(_ config: VirtualPadSink.Config = .init(), identity: PadIdentity = .default) -> VirtualPadSink {
        let sink = makeSink(config)
        queue.sync {
            sink.transportConnected()
            sink.publish(identity, persist: false)
        }
        transport.clear()
        return sink
    }

    private func report1(_ s: PadState, _ id: PadIdentity = .default) -> [UInt8] { id.reports(for: s)[0].bytes }

    // MARK: Send on change

    func testSameStateTwiceGivesOnePost() {
        let sink = publishedSink()
        let s = PadState(buttons: .a, lx: 0.5)
        queue.sync { sink.submit(state: s); env.advance(by: 20); sink.submit(state: s) }
        XCTAssertEqual(transport.posts, [report1(s)])
    }

    func testOnlyChangedReportsArePosted() {
        let sink = publishedSink()
        queue.sync { sink.submit(state: PadState(buttons: .a)) }
        XCTAssertEqual(transport.posts.count, 1, "Guide report 0x02 is unchanged")
        transport.clear()
        env.advance(by: 20)
        queue.sync { sink.submit(state: PadState(buttons: [.a, .guide])) }
        XCTAssertEqual(transport.posts, [[0x02, 0x01]], "only the Guide report changed")
    }

    // MARK: Rate cap and trailing flush

    func testThousandDistinctStatesOverOneSecondStayUnderTheCap() {
        let sink = publishedSink()
        let t0 = env.now
        var last = PadState()
        queue.sync {
            for i in 0..<1000 {
                env.advance(to: t0 + UInt64(i) * 1_000_000)
                last = PadState(lx: -1 + 2 * Double(i) / 999, ly: 0.25)
                sink.submit(state: last)
            }
            env.advance(by: 20)
        }
        let n = transport.posts.count
        XCTAssertLessThanOrEqual(n, 251)
        XCTAssertGreaterThan(n, 240, "the cap should be close to 250 Hz under continuous change")
        XCTAssertEqual(transport.posts.last, report1(last), "the last state is always delivered")
    }

    func testRateCapHonoursAConfiguredLowerRate() {
        var cfg = VirtualPadSink.Config(); cfg.maxRateHz = 125
        let sink = publishedSink(cfg)
        let t0 = env.now
        queue.sync {
            for i in 0..<1000 {
                env.advance(to: t0 + UInt64(i) * 1_000_000)
                sink.submit(state: PadState(lx: -1 + 2 * Double(i) / 999))
            }
            env.advance(by: 20)
        }
        XCTAssertLessThanOrEqual(transport.posts.count, 126)
    }

    func testCoalescedStatesDeliverOnlyTheLastOneWithTheTrailingFlush() {
        let sink = publishedSink()
        let a = PadState(lx: 0.2), b = PadState(lx: 0.4), c = PadState(lx: 0.6)
        queue.sync {
            sink.submit(state: a)                  // posted at once
            env.advance(by: 1); sink.submit(state: b)
            env.advance(by: 1); sink.submit(state: c)
            XCTAssertEqual(transport.posts, [report1(a)], "inside the interval nothing more is posted yet")
            env.advance(by: 2)                     // 4 ms after the first post
        }
        XCTAssertEqual(transport.posts, [report1(a), report1(c)])
        XCTAssertEqual(transport.calls.last!.at - transport.calls.first!.at, 4_000_000, "trailing flush at the interval")
    }

    func testReturningToTheSentStateCancelsTheTrailingFlush() {
        let sink = publishedSink()
        let a = PadState(lx: 0.2), b = PadState(lx: 0.9)
        queue.sync {
            sink.submit(state: a)
            env.advance(by: 1); sink.submit(state: b)      // waiting for the trailing flush
            env.advance(by: 1); sink.submit(state: a)      // back to what the host has
            env.advance(by: 20)
        }
        XCTAssertEqual(transport.posts, [report1(a)])
    }

    // MARK: Deadband

    func testIdleStickJitterGivesNoPosts() {
        let sink = publishedSink()
        queue.sync {
            for i in 0..<1000 {
                env.advance(by: 1)
                let n = i % 2 == 0 ? 0.001 : -0.001
                sink.submit(state: PadState(lx: n, ly: -n, rx: n * 1.5, ry: 0.0019, lt: 0.0015, rt: 0.001))
            }
            env.advance(by: 20)
        }
        XCTAssertEqual(transport.posts.count, 0)
    }

    func testSlowDriftEventuallyPostsAndEndsWithinTheDeadband() {
        let sink = publishedSink()
        var x = 0.0
        queue.sync {
            for _ in 0..<1000 {
                env.advance(by: 1)
                x += 0.0005
                sink.submit(state: PadState(lx: x))
            }
            env.advance(by: 20)
        }
        XCTAssertGreaterThan(transport.posts.count, 10, "drift measured against the last sent value must accumulate")
        let last = transport.posts.last!
        let sent = Double(UInt16(last[1]) | UInt16(last[2]) << 8) / 32767.5 - 1
        XCTAssertEqual(sent, x, accuracy: 0.002)
    }

    func testReturnToRestIsAlwaysPosted() {
        let sink = publishedSink()
        queue.sync {
            sink.submit(state: PadState(lx: 0.5, lt: 0.8))
            env.advance(by: 10)
            sink.submit(state: PadState(lx: 0.0015, lt: 0.0019))      // inside the deadband of 0, not of the held value
            env.advance(by: 10)
        }
        XCTAssertEqual(transport.posts.last, report1(.neutral))

        transport.clear()
        queue.sync {
            sink.submit(state: PadState(lx: 0.0025))
            env.advance(by: 10)
            sink.submit(state: .neutral)
            env.advance(by: 10)
        }
        XCTAssertEqual(transport.posts.count, 2)
        XCTAssertEqual(transport.posts.last, report1(.neutral))
    }

    func testFullDeflectionIsNotLeftADeadbandShort() {
        let sink = publishedSink()
        queue.sync {
            sink.submit(state: PadState(rx: 0.9992, lt: 0.9992))
            env.advance(by: 10)
            sink.submit(state: PadState(rx: 1, lt: 1))
            env.advance(by: 10)
        }
        XCTAssertEqual(transport.posts.last, report1(PadState(rx: 1, lt: 1)))
        XCTAssertEqual(Array(transport.posts.last![9...10]), [0xFF, 0x03])
    }

    // MARK: Neutral

    func testNeutralCallsPostNeutralOnceAndDiscardsPendingState() {
        let sink = publishedSink()
        queue.sync {
            sink.submit(state: PadState(lx: 0.2))
            env.advance(by: 1); sink.submit(state: PadState(lx: 0.9))      // pending trailing flush
            transport.clear()
            sink.neutral()
            env.advance(by: 20)
        }
        XCTAssertEqual(transport.neutrals, 1)
        XCTAssertEqual(transport.posts.count, 0, "the stale pending state must not be posted after neutral")
        // The host already has neutral, so the same neutral state posts nothing; a real change posts again.
        queue.sync { sink.submit(state: .neutral); env.advance(by: 10); sink.submit(state: PadState(buttons: .b)) }
        XCTAssertEqual(transport.posts, [report1(PadState(buttons: .b))])
    }

    func testNeutralWithNothingPublishedDoesNothing() {
        let sink = makeSink()
        queue.sync { sink.neutral() }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testStopAndUnpublishSendNeutralFirst() {
        let sink = publishedSink()
        queue.sync { sink.unpublish(persist: false) }
        XCTAssertEqual(transport.calls.map(\.call), [.neutral, .destroy])
        XCTAssertEqual(sink.state, .off)

        let sink2 = publishedSink()
        transport.clear()
        queue.sync { sink2.shutdown() }
        XCTAssertEqual(transport.calls.map(\.call), [.neutral, .destroy])
    }

    func testStateIsIgnoredWhenNothingIsPublished() {
        let sink = makeSink()
        queue.sync {
            sink.transportConnected()
            sink.submit(state: PadState(buttons: .a))
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // MARK: Heartbeat

    func testHeartbeatRunsEvery500msOnlyWhilePublished() {
        let sink = makeSink()
        queue.sync { sink.transportConnected() }
        env.advance(by: 3000)
        XCTAssertEqual(transport.heartbeats, 0, "no heartbeat before a pad exists")

        queue.sync { sink.publish(.default, persist: false) }
        transport.clear()
        env.advance(by: 2000)
        XCTAssertEqual(transport.heartbeats, 4)
        XCTAssertEqual(transport.calls.map(\.at).adjacentGaps(), [500_000_000, 500_000_000, 500_000_000])

        queue.sync { sink.unpublish(persist: false) }
        transport.clear()
        env.advance(by: 3000)
        XCTAssertEqual(transport.heartbeats, 0, "heartbeat stops with the device")
        XCTAssertEqual(env.activeTimers, 0)
    }

    func testHeartbeatStopsWhenTheConnectionIsLost() {
        let sink = publishedSink()
        queue.sync { sink.transportLost() }
        transport.clear()
        env.advance(by: 2000)
        XCTAssertEqual(transport.heartbeats, 0)
    }

    func testPostsKeepTheWatchdogHappyAndHeartbeatsCoverTheRest() {
        // At rest nothing is posted, so only the heartbeat keeps the dext watchdog (2 s) quiet.
        let sink = publishedSink()
        queue.sync { sink.submit(state: PadState(buttons: .a)) }
        transport.clear()
        env.advance(by: 10_000)
        XCTAssertEqual(transport.posts.count, 0)
        XCTAssertEqual(transport.heartbeats, 20)
    }

    func testAStalledProcessResendsTheHeldStateAfterTheWatchdogMayHaveNeutralisedIt() {
        let sink = publishedSink()
        let held = PadState(buttons: .a, rt: 1)
        queue.sync { sink.submit(state: held) }
        XCTAssertEqual(transport.posts.count, 1)
        transport.clear()

        queue.sync { env.stall(until: env.now + 5_000_000_000) }          // SIGSTOP for 5 s, then SIGCONT
        queue.sync { sink.submit(state: held) }            // the controller still holds the same state
        XCTAssertEqual(transport.posts, PadIdentity.default.reports(for: held).map(\.bytes),
                       "every report must be re-sent in full after a stall")

        transport.clear()
        env.advance(by: 100)
        queue.sync { sink.submit(state: held) }
        XCTAssertEqual(transport.posts.count, 0, "and only once")
    }

    func testAStallResendsTheHeldFrameThroughTheFramePath() {
        let sink = publishedSink()
        var f = GamepadFrame(); f.buttons = 1; f.rt = 1023
        sink.submit(frame: f, mapping: .default)
        queue.sync {}
        XCTAssertEqual(transport.posts.count, 1)
        transport.clear()
        sink.submit(frame: f, mapping: .default)                // identical: dropped
        queue.sync { env.stall(until: env.now + 5_000_000_000) }
        sink.submit(frame: f, mapping: .default)                // identical again, but the stall invalidated the dext state
        queue.sync {}
        XCTAssertEqual(transport.posts.count, 2, "both reports are re-sent")
    }

    // MARK: Identity switch, reconnect, failures

    func testIdentitySwitchDestroysWaits300msThenCreates() {
        let sink = publishedSink()
        let t0 = env.now
        queue.sync { sink.publish(.xboxBT16, persist: false) }
        XCTAssertEqual(transport.calls.map(\.call), [.destroy])
        XCTAssertEqual(sink.state, .publishing("xbox-bt16"))
        env.advance(by: 299)
        XCTAssertTrue(transport.creates.isEmpty, "no create before the 300 ms gap")
        env.advance(by: 2)
        XCTAssertEqual(transport.creates.count, 1)
        XCTAssertEqual(transport.creates[0].call, .create(PadIdentity.xboxBT16.productID))
        XCTAssertEqual(transport.creates[0].at - t0, 300_000_000)
        XCTAssertEqual(sink.state, .published("xbox-bt16"))
    }

    func testReconnectRepublishesAndRestartsTheHeartbeat() {
        let sink = publishedSink()
        queue.sync { sink.transportLost() }
        XCTAssertEqual(sink.state, .publishing("xbox-bt16-02e0"))
        transport.clear()
        env.advance(by: 2000)
        XCTAssertEqual(transport.heartbeats, 0)

        queue.sync { sink.transportConnected() }
        XCTAssertEqual(transport.creates.count, 1, "the pad is created again on the new connection")
        XCTAssertEqual(sink.state, .published("xbox-bt16-02e0"))
        transport.clear()
        env.advance(by: 1000)
        XCTAssertEqual(transport.heartbeats, 2)
        queue.sync { sink.submit(state: PadState(buttons: .x)) }
        XCTAssertEqual(transport.posts.count, 1)
    }

    func testPublishWaitsForTheConnection() {
        let sink = makeSink()
        queue.sync { sink.publish(.default, persist: false) }
        XCTAssertEqual(sink.state, .publishing("xbox-bt16-02e0"))
        XCTAssertTrue(transport.creates.isEmpty)
        queue.sync { sink.transportConnected() }
        XCTAssertEqual(sink.state, .published("xbox-bt16-02e0"))
    }

    func testPersistedPublicationIsRestoredOnConnect() {
        let first = makeSink()
        queue.sync { first.transportConnected(); first.publish(.xboxBT16) }
        XCTAssertTrue(defaults.bool(forKey: VirtualPadSink.enabledKey))

        let second = makeSink()
        queue.sync { second.transportConnected() }
        XCTAssertEqual(second.state, .published("xbox-bt16"))
        queue.sync { second.unpublish() }
        XCTAssertFalse(defaults.bool(forKey: VirtualPadSink.enabledKey))
    }

    func testDuplicatePadGuardBlocksPublishing() {
        duplicate = "Xbox Wireless Controller (serial 123)"
        let sink = makeSink()
        queue.sync { sink.transportConnected(); sink.publish(.default, persist: false) }
        XCTAssertEqual(sink.state, .blockedDuplicate("Xbox Wireless Controller (serial 123)"))
        XCTAssertTrue(transport.creates.isEmpty, "nothing is created while another device has the ID")
        queue.sync { sink.submit(state: PadState(buttons: .a)) }
        XCTAssertTrue(transport.posts.isEmpty)

        duplicate = nil
        queue.sync { sink.publish(.default, persist: false) }
        XCTAssertEqual(sink.state, .published("xbox-bt16-02e0"))
        XCTAssertEqual(transport.creates.count, 1)
    }

    func testDuplicateGuardIgnoresOurOwnDeviceAndUnknownIDs() {
        // No device has this ID.
        XCTAssertNil(DuplicatePadGuard.conflict(vendorID: 0xFFFF, productID: 0xFFFF))
    }

    func testALostDeviceIsRecreatedOnceAfterOneSecond() {
        let sink = publishedSink()
        transport.postResult = DextProtocol.krNotReady
        queue.sync { sink.submit(state: PadState(buttons: .a)) }
        XCTAssertEqual(sink.state, .publishing("xbox-bt16-02e0"))
        transport.postResult = KERN_SUCCESS
        env.advance(by: 999)
        XCTAssertTrue(transport.creates.isEmpty)
        env.advance(by: 2)
        XCTAssertEqual(transport.creates.count, 1)
        XCTAssertEqual(sink.state, .published("xbox-bt16-02e0"))
        // Heartbeat and posting work again.
        transport.clear()
        queue.sync { sink.submit(state: PadState(buttons: .b)) }
        XCTAssertEqual(transport.posts.count, 1)
    }

    func testCreateFailureShowsAnError() {
        transport.createResult = DextProtocol.krBusy
        let sink = makeSink()
        queue.sync { sink.transportConnected(); sink.publish(.default, persist: false) }
        guard case .error = sink.state else { return XCTFail("expected an error state, got \(sink.state)") }
        XCTAssertEqual(env.activeTimers, 0, "no heartbeat without a device")
    }

    // MARK: Frames and test pattern

    func testFramesGoThroughTheMapperAndTheCap() {
        let sink = publishedSink()
        var f = GamepadFrame(); f.buttons = 1
        queue.sync {
            sink.handle(frame: f, mapping: .default)
            sink.handle(frame: f, mapping: .default)
        }
        XCTAssertEqual(transport.posts, [report1(PadState(buttons: .a))])
        XCTAssertEqual(sink.stats.posts, 1)
    }

    func testSubmitFrameHopsToTheQueue() {
        let sink = publishedSink()
        var f = GamepadFrame(); f.buttons = 1 << 3   // Y
        sink.submit(frame: f, mapping: .default)      // callable from any thread
        queue.sync {}
        XCTAssertEqual(transport.posts, [report1(PadState(buttons: .y))])
    }

    func testIdenticalFramesAreDroppedBeforeTheQueueAndCountedAsReceived() {
        let sink = publishedSink()
        var f = GamepadFrame(); f.buttons = 1
        for _ in 0..<100 { sink.submit(frame: f, mapping: .default, revision: 1) }
        queue.sync {}
        XCTAssertEqual(sink.framesReceived, 100)
        XCTAssertEqual(transport.posts.count, 1)
        // A new mapping revision makes the same frame count again.
        var m = ControlMapping.default
        m.buttons["a"] = .button(2)
        sink.submit(frame: f, mapping: m, revision: 2)
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.last, report1(.neutral), "button 1 no longer maps to A")
        // After neutral() the next frame is processed even if it equals the previous one.
        queue.sync { sink.neutral() }
        transport.clear()
        sink.submit(frame: f, mapping: m, revision: 2)
        sink.submit(frame: f, mapping: .default, revision: 3)
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.last, report1(PadState(buttons: .a)))
    }

    func testAHeldStateSeenBeforePublishingIsStillDelivered() {
        let sink = makeSink()
        var f = GamepadFrame(); f.buttons = 1
        queue.sync { sink.transportConnected() }
        sink.submit(frame: f, mapping: .default)               // nothing published yet: dropped
        queue.sync { sink.publish(.default, persist: false) }
        sink.submit(frame: f, mapping: .default)               // the same frame again must now go through
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.last, report1(PadState(buttons: .a)))
    }

    func testABusyQueueOnlyProcessesTheNewestFrame() {
        let sink = publishedSink()
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }                             // keep the sink's queue busy
        for i in 0..<50 {
            var f = GamepadFrame(); f.x = Int16(i * 600)
            sink.submit(frame: f, mapping: .default)
        }
        gate.signal()
        queue.sync {}
        var last = GamepadFrame(); last.x = Int16(49 * 600)
        XCTAssertEqual(transport.posts.count, 1, "50 frames queued, one processed")
        XCTAssertEqual(transport.posts.last, report1(PassthroughPadMapper.padState(last, .default)))
        XCTAssertEqual(sink.framesReceived, 50)
    }

    func testTestPatternRunsAndIgnoresControllerFrames() {
        let sink = publishedSink()
        var f = GamepadFrame(); f.buttons = 1 << 3
        queue.sync { sink.runTestPattern() }
        XCTAssertTrue(sink.isPatternRunning)
        queue.sync { env.advance(by: 100) }                     // first pattern button (A) is showing
        XCTAssertEqual(transport.posts.last, report1(PadState(buttons: .a)))
        let n = transport.posts.count
        queue.sync { sink.handle(frame: f, mapping: .default); env.advance(by: 10) }
        XCTAssertFalse(transport.posts.dropFirst(n).contains(report1(PadState(buttons: .y))), "frames are ignored during the pattern")

        transport.clear()
        queue.sync { sink.stopTestPattern() }
        XCTAssertEqual(transport.neutrals, 1)
        XCTAssertFalse(sink.isPatternRunning)
    }

    func testTestPatternFinishesWithNeutral() {
        let sink = publishedSink()
        queue.sync { sink.runTestPattern() }
        queue.sync { env.advance(by: VirtualPadSink.testPatternDurationMs + 50) }
        XCTAssertFalse(sink.isPatternRunning)
        XCTAssertGreaterThanOrEqual(transport.neutrals, 1)
    }
}

private extension Array where Element == UInt64 {
    func adjacentGaps() -> [UInt64] { zip(self.dropFirst(), self).map { $0 - $1 } }
}

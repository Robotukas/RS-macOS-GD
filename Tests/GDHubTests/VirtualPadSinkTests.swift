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
    /// Every one-shot timer requested, in order, with its `strict` flag.
    private(set) var oneShots: [(ns: UInt64, strict: Bool)] = []

    func after(_ ns: UInt64, strict: Bool, _ block: @escaping () -> Void) -> SinkTimer {
        oneShots.append((ns, strict))
        let t = Timer(); entries.append(Entry(timer: t, due: now + ns, interval: nil, block: block)); return t
    }
    func every(_ ns: UInt64, _ block: @escaping () -> Void) -> SinkTimer {
        let t = Timer(); entries.append(Entry(timer: t, due: now + ns, interval: ns, block: block)); return t
    }

    /// Time passes without any timer firing: stands in for a call that takes `ns` to return (e.g. IOConnect).
    func elapse(_ ns: UInt64) { now += ns }

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
    /// Simulated duration of one `post` call; the call is recorded at its start time.
    var postDuration: UInt64 = 0
    init(env: ManualScheduler) { self.env = env }

    // T7: createDevice2 (adoption). `adoptNext` makes the next successful create an adoption by a pad whose source is `padSourceNext`;
    // `busyReplies` answers Busy that many times first (the dext removed an orphan with another spec).
    var adoptNext = false
    var padSourceNext: UInt64 = 1
    var busyReplies = 0
    func createDevice(_ spec: DeviceSpec) -> kern_return_t { calls.append((env.now, .create(spec.productID))); return createResult }
    func createDevice2(_ spec: DeviceSpec) -> (kr: kern_return_t, adopted: Bool, padSource: UInt64) {
        calls.append((env.now, .create(spec.productID)))
        if busyReplies > 0 { busyReplies -= 1; return (DextProtocol.krBusy, false, 0) }
        return (createResult, adoptNext && createResult == KERN_SUCCESS, padSourceNext)
    }
    func destroyDevice(slot: UInt8) -> kern_return_t { calls.append((env.now, .destroy)); return KERN_SUCCESS }
    func post(slot: UInt8, report: [UInt8]) -> kern_return_t {
        calls.append((env.now, .post(report)))
        env.elapse(postDuration)
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

    // MARK: Rate cap measured from post start

    private let slowPost: UInt64 = 400_000          // 0.4 ms of simulated IOConnect time

    func testCapIntervalIsMeasuredFromPostStartNotCompletion() {
        let sink = publishedSink()
        transport.postDuration = slowPost
        let t0 = env.now
        let a = PadState(lx: 0.2), b = PadState(lx: 0.4)
        queue.sync {
            sink.submit(state: a)                                   // starts at t0, returns at t0 + 0.4 ms
            env.advance(to: t0 + 4_000_000)                         // exactly one cap interval after the start
            sink.submit(state: b)
        }
        XCTAssertEqual(transport.posts, [report1(a), report1(b)])
        XCTAssertEqual(transport.calls.map(\.at), [t0, t0 + 4_000_000], "no extra cap wait: b starts at t0 + interval")
    }

    func testTrailingFlushFiresAtStartPlusIntervalWithASlowPost() {
        let sink = publishedSink()
        transport.postDuration = slowPost
        let t0 = env.now
        let a = PadState(lx: 0.2), b = PadState(lx: 0.4)
        queue.sync {
            sink.submit(state: a)
            env.advance(to: t0 + 1_000_000); sink.submit(state: b)  // inside the window: waits for the flush timer
            XCTAssertEqual(transport.posts.count, 1)
            env.advance(to: t0 + 5_000_000)
        }
        XCTAssertEqual(transport.posts, [report1(a), report1(b)])
        XCTAssertEqual(transport.calls.map(\.at), [t0, t0 + 4_000_000], "flush at start + interval, not completion + interval")
    }

    func testCapStillHoldsWithASlowPost() {
        let sink = publishedSink()
        transport.postDuration = slowPost
        let t0 = env.now
        var last = PadState()
        queue.sync {
            for i in 0..<1000 {
                env.advance(to: max(env.now, t0 + UInt64(i) * 1_000_000))
                last = PadState(lx: -1 + 2 * Double(i) / 999, ly: 0.25)
                sink.submit(state: last)
            }
            env.advance(by: 20)
        }
        let starts = transport.calls.compactMap { c -> UInt64? in if case .post = c.call { return c.at } else { return nil } }
        XCTAssertLessThanOrEqual(starts.count, 251)
        XCTAssertGreaterThan(starts.count, 240)
        for (x, y) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(y - x, 4_000_000, "post starts are never closer than the cap interval")
        }
        XCTAssertEqual(transport.posts.last, report1(last), "the last state is always delivered")
    }

    func testFasterChangesAreStillCoalescedWithASlowPost() {
        let sink = publishedSink()
        transport.postDuration = slowPost
        let t0 = env.now
        let a = PadState(lx: 0.2), b = PadState(lx: 0.4), c = PadState(lx: 0.6)
        queue.sync {
            sink.submit(state: a)
            env.advance(to: t0 + 1_000_000); sink.submit(state: b)
            env.advance(to: t0 + 2_000_000); sink.submit(state: c)
            env.advance(to: t0 + 10_000_000)
        }
        XCTAssertEqual(transport.posts, [report1(a), report1(c)], "b is coalesced into c")
    }

    func testNeutralIsImmediateAndDoesNotMoveTheCapWithASlowPost() {
        let sink = publishedSink()
        transport.postDuration = slowPost
        let t0 = env.now
        queue.sync {
            sink.submit(state: PadState(lx: 0.2))
            env.advance(to: t0 + 1_000_000); sink.submit(state: PadState(lx: 0.9))     // pending
            sink.neutral()
            XCTAssertEqual(transport.neutrals, 1, "neutral goes out at once, inside the cap window")
            env.advance(to: t0 + 4_000_000); sink.submit(state: PadState(buttons: .b))
            env.advance(by: 20)
        }
        XCTAssertEqual(transport.posts, [report1(PadState(lx: 0.2)), report1(PadState(buttons: .b))],
                       "the pending state is discarded by neutral")
        XCTAssertEqual(transport.calls.last!.at, t0 + 4_000_000, "the next post is still start-of-previous-post + interval")
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
        transport.createResult = DextProtocol.krNotPermitted
        let sink = makeSink()
        queue.sync { sink.transportConnected(); sink.publish(.default, persist: false) }
        guard case .error = sink.state else { return XCTFail("expected an error state, got \(sink.state)") }
        XCTAssertEqual(env.activeTimers, 0, "no heartbeat without a device")
    }

    // MARK: T7: the posting gate, adoption, the neutral rules

    func testWhileTheDriverDrivesTheEnginePostsNothingAndOnFallbackTheVeryNextFramePostsInFull() {
        let sink = publishedSink()
        var f = GamepadFrame(); f.lt = 1023; f.buttons = 1                      // LT held fully
        queue.sync { sink.handle(frame: f, mapping: .default) }
        XCTAssertEqual(transport.posts.count, 1)
        var changes: [Bool] = []
        sink.onDriveChange = { changes.append($0) }
        queue.sync { sink.setDriverDrives(true) }
        XCTAssertTrue(sink.driverDrives); XCTAssertEqual(changes, [true])
        transport.clear()
        var g = f; g.buttons = 2
        sink.submit(frame: g, mapping: .default); queue.sync {}
        queue.sync { sink.handle(frame: g, mapping: .default) }
        XCTAssertTrue(transport.posts.isEmpty, "the gate is closed on both entry points")
        XCTAssertEqual(sink.framesReceived, 1, "frames that reach submit are still counted")
        queue.sync { sink.setDriverDrives(true) }
        XCTAssertEqual(changes, [true], "no change, no callback")
        // the driver stalls and the supervisor falls back: the pad shows neutral (the driver posted it), the held LT must come back
        queue.sync { sink.setDriverDrives(false) }
        XCTAssertEqual(changes, [true, false]); XCTAssertGreaterThan(env.activeTimers, 0, "the heartbeat is running again")
        queue.sync { sink.handle(frame: f, mapping: .default) }                  // the SAME frame as before the gate closed
        XCTAssertTrue(transport.posts.contains(report1(PadState(buttons: .a, lt: 1.0))), "delivery state was reset: the identical frame is posted again, LT = 1.0 included")
    }

    func testIdenticalFrameReachesTheSinkAfterTheGateOpensEvenThroughTheMailbox() {
        let sink = publishedSink()
        var f = GamepadFrame(); f.buttons = 4
        sink.submit(frame: f, mapping: .default); queue.sync {}
        queue.sync { sink.setDriverDrives(true) }
        transport.clear()
        queue.sync { sink.setDriverDrives(false) }
        sink.submit(frame: f, mapping: .default); queue.sync {}                    // identical to the last one the mailbox saw
        XCTAssertTrue(transport.posts.contains(report1(PadState(buttons: PadButtons(rawValue: 0)))) == false && !transport.posts.isEmpty, "it was posted, not dropped as a duplicate")
    }

    func testAdoptingAPinnedPadSkipsTheNeutralAndRemembersWhoDrivesIt() {
        transport.adoptNext = true; transport.padSourceNext = 2
        let sink = makeSink()
        queue.sync { sink.transportConnected(); sink.publish(.default, persist: false) }
        XCTAssertEqual(transport.neutrals, 0, "no neutral: the pad already shows the controller")
        XCTAssertTrue(sink.createdAdopted); XCTAssertEqual(sink.createdPadSource, 2)
        XCTAssertGreaterThan(env.activeTimers, 0, "the heartbeat runs")
        if case .published = sink.state {} else { XCTFail("\(sink.state)") }
        // a normal create posts the neutral
        let t2 = FakeTransport(env: env)
        let s2 = VirtualPadSink(queue: queue, transport: t2, clock: { [env] in env!.now }, scheduler: env, config: .init(), defaults: defaults, duplicateCheck: { _ in nil })
        queue.sync { s2.transportConnected(); s2.publish(.default, persist: false) }
        XCTAssertEqual(t2.neutrals, 1); XCTAssertFalse(s2.createdAdopted)
    }

    /// R7: what the dext said about the device in force is forgotten with the device: `createdAdoptedTapPad` (the supervisor's
    /// `padAdopted`) is false after a destroy, a lost connection, a lost device and a reconnect.
    func testTheAdoptedOriginIsForgottenWithTheDevice() {
        func adopted() -> VirtualPadSink {
            transport.adoptNext = true; transport.padSourceNext = 2
            let sink = makeSink()
            queue.sync { sink.transportConnected(); sink.publish(.default, persist: false) }
            XCTAssertTrue(sink.createdAdoptedTapPad); XCTAssertTrue(sink.createdAdopted)
            transport.adoptNext = false; transport.padSourceNext = 1
            return sink
        }
        var sink = adopted()
        queue.sync { sink.unpublish(persist: false) }
        XCTAssertFalse(sink.createdAdoptedTapPad, "destroyed"); XCTAssertFalse(sink.createdAdopted); XCTAssertEqual(sink.createdPadSource, 1)
        sink = adopted()
        queue.sync { sink.transportLost() }
        XCTAssertFalse(sink.createdAdoptedTapPad, "connection lost"); XCTAssertFalse(sink.createdAdopted)
        sink = adopted()
        transport.postResult = DextProtocol.krNotReady               // the device is gone (post answers NotReady)
        var f = GamepadFrame(); f.buttons = 1
        queue.sync { sink.handle(frame: f, mapping: .default) }
        XCTAssertFalse(sink.createdAdoptedTapPad, "device lost"); XCTAssertFalse(sink.createdAdopted)
        transport.postResult = KERN_SUCCESS
        sink = adopted()
        queue.sync { sink.transportConnected() }
        XCTAssertFalse(sink.createdAdoptedTapPad, "a new connection starts with no devices")
        // and the next create (not an adoption) says so
        queue.sync { sink.publish(.default, persist: false) }
        XCTAssertTrue(sink.isPublished); XCTAssertFalse(sink.createdAdoptedTapPad)
    }

    func testBusyFromCreateDevice2MeansTryAgainAfterTheHIDGap() {
        transport.busyReplies = 2
        let sink = makeSink()
        queue.sync { sink.transportConnected(); sink.publish(.default, persist: false) }
        XCTAssertEqual(transport.creates.count, 1)
        if case .publishing = sink.state {} else { XCTFail("\(sink.state)") }
        queue.sync { env.advance(by: 399) }; XCTAssertEqual(transport.creates.count, 1)
        queue.sync { env.advance(by: 2) }; XCTAssertEqual(transport.creates.count, 2)
        queue.sync { env.advance(by: 401) }; XCTAssertEqual(transport.creates.count, 3)
        if case .published = sink.state {} else { XCTFail("\(sink.state)") }
        // and it does not retry forever
        transport.busyReplies = 100
        let s2 = makeSink()
        queue.sync { s2.transportConnected(); s2.publish(.default, persist: false) }
        for _ in 0..<8 { queue.sync { env.advance(by: 450) } }
        guard case .error = s2.state else { return XCTFail("\(s2.state)") }
    }

    func testControllerSleepNeutralIsLeftToTheDriverWhileItDrivesButSystemSleepIsHonoured() {
        let sink = publishedSink()
        queue.sync { sink.setDriverDrives(true) }
        transport.clear()
        queue.sync { sink.neutral(force: false) }
        XCTAssertEqual(transport.neutrals, 0, "the driver's silence and Stop neutrals cover the controller going quiet; a request here would set its hold")
        queue.sync { sink.neutral() }
        XCTAssertEqual(transport.neutrals, 1, "system sleep: the hold is wanted")
        queue.sync { sink.setDriverDrives(false) }
        transport.clear()
        queue.sync { sink.neutral(force: false) }
        XCTAssertEqual(transport.neutrals, 1, "engine path: as before")
    }

    func testLosingTheConnectionOpensTheGate() {
        let sink = publishedSink()
        var changes: [Bool] = []
        sink.onDriveChange = { changes.append($0) }
        queue.sync { sink.setDriverDrives(true); sink.transportLost() }
        XCTAssertFalse(sink.driverDrives); XCTAssertEqual(changes, [true, false])
        queue.sync { sink.setDriverDrives(true); sink.transportConnected() }
        XCTAssertFalse(sink.driverDrives, "a new connection starts with the engine path")
    }

    /// E7: the sink opens the gate by itself (connection lost, device destroyed): the supervisor is told. Its own `setDriverDrives`
    /// is not reported through that callback.
    func testTheSinkReportsAGateItOpenedByItselfAndNotTheOneTheSupervisorOpened() {
        let sink = publishedSink()
        var forced = 0
        sink.onGateForcedOpen = { forced += 1 }
        queue.sync { sink.setDriverDrives(true); sink.setDriverDrives(false) }
        XCTAssertEqual(forced, 0, "the supervisor's own call")
        queue.sync { sink.setDriverDrives(true); sink.transportLost() }
        XCTAssertEqual(forced, 1)
        let s2 = publishedSink()
        s2.onGateForcedOpen = { forced += 1 }
        queue.sync { s2.setDriverDrives(true); s2.unpublish(persist: false) }
        XCTAssertEqual(forced, 2, "the device is gone")
        queue.sync { s2.unpublish(persist: false) }
        XCTAssertEqual(forced, 2, "a gate that was already open reports nothing")
    }

    /// E8: closing the gate posts no neutral (the driver posted its own at the switch; a forced one would set its hold), also when a
    /// test pattern was running; and the pattern is refused while the driver drives.
    func testClosingTheGateSendsNoNeutralAndThePatternIsRefusedWhileTheDriverDrives() {
        let sink = publishedSink()
        queue.sync { sink.runTestPattern() }
        XCTAssertTrue(sink.isPatternRunning)
        transport.clear()
        queue.sync { sink.setDriverDrives(true) }
        XCTAssertFalse(sink.isPatternRunning, "the pattern needs source UC and ends")
        XCTAssertEqual(transport.neutrals, 0, "and no neutral is posted for it")
        queue.sync { sink.runTestPattern() }
        XCTAssertFalse(sink.isPatternRunning, "refused while the driver drives")
        queue.sync { env.advance(by: 500) }
        XCTAssertEqual(transport.neutrals, 0); XCTAssertTrue(transport.posts.isEmpty)
        queue.sync { sink.setDriverDrives(false) }
        queue.sync { sink.runTestPattern() }
        XCTAssertTrue(sink.isPatternRunning, "and allowed again once the engine drives")
    }

    /// E10: the Busy retries of a create are counted afresh for the next publish.
    func testBusyRetriesStartAfreshAtTheNextPublish() {
        transport.busyReplies = 100
        let sink = makeSink()
        queue.sync { sink.transportConnected(); sink.publish(.default, persist: false) }
        for _ in 0..<8 { queue.sync { env.advance(by: 450) } }
        guard case .error = sink.state else { return XCTFail("\(sink.state)") }
        let first = transport.creates.count
        XCTAssertEqual(first, VirtualPadSink.createRetryLimit + 1)
        transport.busyReplies = 0
        queue.sync { sink.publish(.default, persist: false) }
        for _ in 0..<3 { queue.sync { env.advance(by: 450) } }
        if case .published = sink.state {} else { XCTFail("a new publish after the tries ran out works: \(sink.state)") }
        // and a success also resets the count: two sequences of limit-1 Busy answers in a row both succeed
        for _ in 0..<2 {
            transport.busyReplies = VirtualPadSink.createRetryLimit - 1
            queue.sync { sink.unpublish(persist: false) }
            queue.sync { sink.publish(.default, persist: false) }
            for _ in 0..<8 { queue.sync { env.advance(by: 450) } }
            if case .published = sink.state {} else { XCTFail("\(sink.state)") }
        }
    }

    func testUnpublishWhileTheDriverDrivesLeavesTheGateOpenAndDestroys() {
        let sink = publishedSink()
        queue.sync { sink.setDriverDrives(true) }
        transport.clear()
        queue.sync { sink.unpublish(persist: false) }
        XCTAssertEqual(transport.count(.destroy), 1); XCTAssertFalse(sink.driverDrives)
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

    // MARK: The echo filter at the sink (remap step 2)

    private func echoFrame(buttons: UInt32 = 0, hat: UInt8 = 8, extra: UInt16 = 0) -> GamepadFrame {
        var f = GamepadFrame(); f.buttons = buttons; f.hat = hat; f.extra = extra
        return f
    }

    /// Paddle outer right sends R3 (its own button, D-pad right, is hidden); SAX left sends View.
    private func paddleMapping() -> ControlMapping {
        var m = ControlMapping.default
        m.setOutput(.pad(.r3), for: "paddle_outer_right")
        m.setOutput(.pad(.view), for: "sax_left")
        return m
    }

    private func pad(_ items: PadButtons) -> [UInt8] { report1(PadState(buttons: items)) }

    func testARemappedPaddleSendsOnlyItsPickWithTheControllersOwnButtonHidden() {
        let sink = publishedSink()
        let m = paddleMapping()
        // The controller sends the paddle's bit and its own D-pad right in the same report.
        sink.submit(frame: echoFrame(), mapping: m, revision: 1)                       // at rest: nothing to post
        for (frame, want) in [(echoFrame(hat: 2, extra: 1), PadButtons.rs),
                              (echoFrame(), PadButtons())] {
            sink.submit(frame: frame, mapping: m, revision: 1)
            queue.sync { env.advance(by: 10) }
            XCTAssertEqual(transport.posts.last, pad(want))
        }
        XCTAssertFalse(transport.posts.contains(pad(.dpadRight)), "D-pad right never reaches the pad")
        XCTAssertFalse(transport.posts.contains(pad([.rs, .dpadRight])))
        // The mapping needs the echo hidden: the driver's v1 blob cannot say it, so the Swift mapper runs.
        XCTAssertTrue(sink.xlateStatus.hasPrefix("swift (fallback"), sink.xlateStatus)
        // Untouched paddle on Controller's profile: its D-pad right passes as before.
        let plain = publishedSink()
        transport.clear()
        plain.submit(frame: echoFrame(hat: 2, extra: 1), mapping: .default, revision: 1)
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.last, pad(.dpadRight))
    }

    func testTheFilterSeesEveryReportAlthoughTheSinkOnlyProcessesTheNewest() {
        let sink = publishedSink()
        let m = paddleMapping()
        sink.submit(frame: echoFrame(), mapping: m, revision: 1)                       // at rest
        sink.submit(frame: echoFrame(hat: 6), mapping: m, revision: 1)                 // D-pad left held
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.last, pad(.dpadLeft))
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }                                                    // a busy queue: reports are coalesced
        // Paddle outer right goes down: the controller cancels left against its own right (no direction), then X is pressed.
        sink.submit(frame: echoFrame(hat: 8, extra: 1), mapping: m, revision: 1)
        sink.submit(frame: echoFrame(buttons: 1 << 2, hat: 8, extra: 1), mapping: m, revision: 1)
        gate.signal()
        queue.sync {}
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.last, pad([.dpadLeft, .x, .rs]), "the cancel was worked out from the dropped report: left stays")
        XCTAssertEqual(sink.framesReceived, 4)
    }

    func testARepeatedReportIsDroppedAndChangesNothing() {
        let sink = publishedSink()
        let m = paddleMapping()
        sink.submit(frame: echoFrame(), mapping: m, revision: 1)
        for _ in 0..<50 { sink.submit(frame: echoFrame(hat: 2, extra: 1), mapping: m, revision: 1) }
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.filter { $0 == pad(.rs) }.count, 1)
        XCTAssertEqual(transport.posts.last, pad(.rs))
        XCTAssertEqual(sink.framesReceived, 51)
    }

    func testAHeldButtonAndARemappedKeyAcrossTheGateKeepTheirState() {
        let sink = publishedSink()
        let m = paddleMapping()
        sink.submit(frame: echoFrame(), mapping: m, revision: 1)
        sink.submit(frame: echoFrame(buttons: 1), mapping: m, revision: 1)             // A held
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.last, pad(.a))
        queue.sync { sink.setDriverDrives(true) }                                      // the driver drives: the engine posts nothing
        transport.clear()
        sink.submit(frame: echoFrame(buttons: 1, extra: 16), mapping: m, revision: 1)  // SAX left down (the controller adds A, already on)
        sink.submit(frame: echoFrame(buttons: 0, extra: 16), mapping: m, revision: 1)  // A let go during the hold
        queue.sync { env.advance(by: 10) }
        XCTAssertTrue(transport.posts.isEmpty)
        queue.sync { sink.setDriverDrives(false) }                                     // fallback: the next report posts in full
        sink.submit(frame: echoFrame(buttons: 0, hat: 8, extra: 16), mapping: m, revision: 1)
        queue.sync { env.advance(by: 10) }
        XCTAssertTrue(transport.posts.contains(pad([.a, .view])), "A stays on until the key is let go, and the key sends its pick")
        sink.submit(frame: echoFrame(), mapping: m, revision: 1)
        queue.sync { env.advance(by: 10) }
        XCTAssertEqual(transport.posts.last, pad([]), "nothing stays covered after the key is let go")
    }

    func testTheFilterKeepsItsStateAcrossAMappingChangeWithTheSameParametersAndResetsWhenTheyChange() {
        func run(_ second: ControlMapping) -> [UInt8]? {
            let sink = publishedSink()
            let first = paddleMapping()
            sink.submit(frame: echoFrame(), mapping: first, revision: 1)
            sink.submit(frame: echoFrame(hat: 6), mapping: first, revision: 1)         // D-pad left held
            sink.submit(frame: echoFrame(hat: 8, extra: 1), mapping: first, revision: 1)   // paddle down: the cancel, left recovered
            queue.sync { env.advance(by: 10) }
            XCTAssertEqual(transport.posts.last, pad([.dpadLeft, .rs]))
            sink.submit(frame: echoFrame(buttons: 1 << 2, hat: 8, extra: 1), mapping: second, revision: 2)
            queue.sync { env.advance(by: 10) }
            return transport.posts.last
        }
        var sameParams = paddleMapping()
        sameParams.setOutput(.pad(.a), for: "g1")                                       // another remap: the echo parameters are the same
        XCTAssertEqual(run(sameParams), pad([.dpadLeft, .x, .rs]), "the state went on: left is still worked out")
        var otherParams = paddleMapping()
        otherParams.setOutput(.pad(.b), for: "paddle_outer_left")                       // the hide mask changes: a fresh state
        XCTAssertEqual(run(otherParams), pad([.x, .rs]), "a reset in the middle of a hold loses the worked-out direction")
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

    // MARK: 1000 Hz cap, strict flush timers (latency plan fix #4)

    func testThousandHertzCapPostsEveryMillisecondAndDeliversTheLastState() {
        var cfg = VirtualPadSink.Config(); cfg.maxRateHz = 1000
        let sink = publishedSink(cfg)
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
        XCTAssertLessThanOrEqual(n, 1001)
        XCTAssertGreaterThan(n, 990)
        XCTAssertEqual(transport.posts.last, report1(last), "the last state is always delivered")
    }

    func testThousandHertzTrailingFlushIsOneIntervalAfterTheFirstPost() {
        var cfg = VirtualPadSink.Config(); cfg.maxRateHz = 1000
        let sink = publishedSink(cfg)
        let a = PadState(lx: 0.2), b = PadState(lx: 0.4)
        queue.sync {
            sink.submit(state: a)                          // posted at once
            env.advance(by: UInt64(500_000)); sink.submit(state: b)      // 0.5 ms later: inside the interval
            XCTAssertEqual(transport.posts, [report1(a)])
            env.advance(by: UInt64(500_000))
        }
        XCTAssertEqual(transport.posts, [report1(a), report1(b)])
        XCTAssertEqual(transport.calls.last!.at - transport.calls.first!.at, 1_000_000)
    }

    // MARK: 2000 Hz default cap against a jittered 1 kHz source

    func testJitteredOneKilohertzFramesAreAllPostedAtArrivalAt2000Hz() {
        var cfg = VirtualPadSink.Config(); cfg.maxRateHz = 2000
        let sink = publishedSink(cfg)
        transport.postDuration = 300_000                    // 0.3 ms IOConnect
        let t0 = env.now + 10_000_000
        var arrivals: [UInt64] = []
        queue.sync {
            for k in 1...200 {
                // 1.000 ms grid, alternating -0.05 / +0.05 ms jitter: gaps of 1.1 and 0.9 ms
                let t = UInt64(Int64(t0) + Int64(k) * 1_000_000 + (k % 2 == 0 ? -50_000 : 50_000))
                env.advance(to: max(env.now, t))
                arrivals.append(env.now)
                sink.submit(state: PadState(lx: Double(k) / 250))
            }
            env.advance(by: 20)
        }
        let starts = transport.calls.compactMap { c -> UInt64? in if case .post = c.call { return c.at } else { return nil } }
        XCTAssertEqual(starts, arrivals, "every changed frame is posted at its own arrival")
        XCTAssertEqual(env.oneShots.count, 0, "no flush timer was ever needed")
        XCTAssertEqual(sink.meter.coalesced, 0)
    }

    func testTwoChangesTwoTenthsOfAMillisecondApartAreStillCoalescedAt2000Hz() {
        var cfg = VirtualPadSink.Config(); cfg.maxRateHz = 2000
        let sink = publishedSink(cfg)
        let t0 = env.now
        let a = PadState(lx: 0.1), b = PadState(lx: 0.2), c = PadState(lx: 0.3), d = PadState(lx: 0.4)
        queue.sync {
            sink.submit(state: a)
            env.advance(to: t0 + 600_000); sink.submit(state: b)       // past the 0.5 ms interval: posted at once
            env.advance(to: t0 + 800_000); sink.submit(state: c)       // 0.2 ms after b: parked
            env.advance(to: t0 + 1_000_000); sink.submit(state: d)     // 0.2 ms after c: replaces it
            XCTAssertEqual(transport.posts, [report1(a), report1(b)])
            env.advance(to: t0 + 2_000_000)
        }
        XCTAssertEqual(transport.posts, [report1(a), report1(b), report1(d)], "c is coalesced into d")
        XCTAssertEqual(transport.calls.last!.at, t0 + 1_100_000, "flush at the previous post's start + 0.5 ms")
        XCTAssertEqual(sink.meter.coalesced, 1)
    }

    func testQuarterMillisecondIntervalNeverArmsAPastTimerOrSpins() {
        var cfg = VirtualPadSink.Config(); cfg.maxRateHz = 4000
        let sink = publishedSink(cfg)
        let t0 = env.now
        queue.sync {
            sink.submit(state: PadState(lx: 0.1))
            env.advance(to: t0 + 100_000); sink.submit(state: PadState(lx: 0.2))
            env.advance(to: t0 + 1_000_000)
        }
        XCTAssertEqual(env.oneShots.map(\.ns), [150_000], "one timer, for exactly the remaining 0.15 ms")
        XCTAssertEqual(transport.calls.map(\.at), [t0, t0 + 250_000])
    }

    func testOnlyTheFlushTimersAreStrict() {
        let sink = publishedSink()
        let a = PadState(lx: 0.2), b = PadState(lx: 0.4)
        queue.sync {
            sink.submit(state: a)
            env.advance(by: 1); sink.submit(state: b)       // trailing flush timer, from submit(state:)
            env.advance(by: 10)
        }
        XCTAssertEqual(env.oneShots.map(\.strict), [true], "the trailing flush is strict")

        queue.sync { sink.publish(.xboxBT16, persist: false) }      // identity switch: 300 ms gap timer
        queue.sync { env.advance(by: 400) }
        XCTAssertEqual(env.oneShots.map(\.strict), [true, false], "the identity-switch gap is not strict")

        transport.postResult = DextProtocol.krNotReady               // the next post loses the device: 1 s recreate timer
        queue.sync { env.advance(by: 20); sink.submit(state: PadState(lx: -0.5)) }
        XCTAssertEqual(env.oneShots.map(\.strict), [true, false, false], "the recreate timer is not strict")
    }

    func testTheRuntimeRateDefaultsTo2000AndIsClamped() {
        XCTAssertEqual(VirtualPadSink.Config().maxRateHz, 250, "Config's own default keeps the tests' meaning")
        XCTAssertEqual(VirtualPadSink.runtimeMaxRateHz(defaults: defaults), 2000, "unset key")
        defaults.set(125.0, forKey: VirtualPadSink.maxRateKey)
        XCTAssertEqual(VirtualPadSink.runtimeMaxRateHz(defaults: defaults), 125)
        defaults.set(Float(500), forKey: VirtualPadSink.maxRateKey)
        XCTAssertEqual(VirtualPadSink.runtimeMaxRateHz(defaults: defaults), 500)
        defaults.set(5.0, forKey: VirtualPadSink.maxRateKey)
        XCTAssertEqual(VirtualPadSink.runtimeMaxRateHz(defaults: defaults), 60)
        defaults.set(9000.0, forKey: VirtualPadSink.maxRateKey)
        XCTAssertEqual(VirtualPadSink.runtimeMaxRateHz(defaults: defaults), 4000)
        defaults.set(1500.0, forKey: VirtualPadSink.maxRateKey)
        XCTAssertEqual(VirtualPadSink.runtimeMaxRateHz(defaults: defaults), 1500)
        defaults.set("fast", forKey: VirtualPadSink.maxRateKey)
        XCTAssertEqual(VirtualPadSink.runtimeMaxRateHz(defaults: defaults), 2000, "not a number")
    }

    // MARK: Latency meter wiring (latency plan §3)

    func testAPostedStateRecordsAllFiveStages() {
        let sink = publishedSink()
        let t = env.now
        queue.sync { sink.submit(state: PadState(lx: 0.5), stamp: LatencyStamp(tK: t - 300_000, tC: t - 200_000, tD: t)) }
        let e = sink.meter.entries()
        XCTAssertEqual(e, [LatencyMeter.Entry(tK: t - 300_000, tC: t - 200_000, tD: t, tS: t, tR: t)])
        XCTAssertEqual(sink.meter.flushes, 1)
        XCTAssertEqual(sink.meter.changed, 1)
        XCTAssertEqual(sink.meter.coalesced, 0)
    }

    func testACoalescedStateIsAttributedToTheOldestInput() {
        let sink = publishedSink()
        let t0 = env.now
        let a = PadState(lx: 0.2), b = PadState(lx: 0.4), c = PadState(lx: 0.6)
        queue.sync {
            sink.submit(state: a, stamp: LatencyStamp(tK: 1000, tC: 1100, tD: 1200))        // posted at once
            env.advance(by: 1); sink.submit(state: b, stamp: LatencyStamp(tK: 2000, tC: 2100, tD: 2200))
            env.advance(by: 1); sink.submit(state: c, stamp: LatencyStamp(tK: 3000, tC: 3100, tD: 3200))
            env.advance(by: 2)                                                              // trailing flush at +4 ms
        }
        let e = sink.meter.entries()
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e[1].tK, 2000, "the flush carries c but counts from b, the oldest input still waiting")
        XCTAssertEqual(e[1].tC, 2100)
        XCTAssertEqual(e[1].tD, 2200)
        XCTAssertEqual(e[1].tS, t0 + 4_000_000)
        XCTAssertEqual(e[1].tR, t0 + 4_000_000)
        XCTAssertEqual(sink.meter.coalesced, 1, "b was replaced by c before it was sent")
        XCTAssertEqual(sink.meter.changed, 3)
    }

    func testFramesCoalescedInTheMailboxKeepTheOldestTimestamp() {
        let sink = publishedSink()
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }                             // keep the sink's queue busy
        for i in 0..<5 {
            var f = GamepadFrame(); f.x = Int16(i * 600)
            sink.submit(frame: f, mapping: .default, tK: UInt64(100 + i * 100), tC: UInt64(150 + i * 100))
        }
        gate.signal()
        queue.sync {}
        let e = sink.meter.entries()
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].tK, 100)
        XCTAssertEqual(e[0].tC, 150)
    }

    func testReturningToTheSentStateDropsTheWaitingStamp() {
        let sink = publishedSink()
        let a = PadState(lx: 0.2), b = PadState(lx: 0.9)
        queue.sync {
            sink.submit(state: a, stamp: LatencyStamp(tK: 1, tC: 2, tD: 3))
            env.advance(by: 1); sink.submit(state: b, stamp: LatencyStamp(tK: 10, tC: 20, tD: 30))
            env.advance(by: 1); sink.submit(state: a, stamp: LatencyStamp(tK: 100, tC: 200, tD: 300))   // back to what the host has
            env.advance(by: 20)
            sink.submit(state: PadState(lx: 0.5), stamp: LatencyStamp(tK: 7, tC: 8, tD: 9))
        }
        XCTAssertEqual(sink.meter.entries().map(\.tK), [1, 7], "the abandoned b left no stale stamp behind")
    }
}

private extension Array where Element == UInt64 {
    func adjacentGaps() -> [UInt64] { zip(self.dropFirst(), self).map { $0 - $1 } }
}

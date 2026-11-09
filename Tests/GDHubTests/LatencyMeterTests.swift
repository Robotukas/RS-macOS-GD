import XCTest
@testable import GDHub

final class LatencyMeterTests: XCTestCase {
    private var now: UInt64 = 100_000_000_000
    private func makeMeter() -> LatencyMeter { LatencyMeter(clock: { [unowned self] in self.now }) }

    // MARK: Percentile math

    func testNearestRankPercentiles() {
        let v = (1...100).map { UInt64($0) }
        XCTAssertEqual(LatencyMeter.percentile(v, 50), 50)
        XCTAssertEqual(LatencyMeter.percentile(v, 95), 95)
        XCTAssertEqual(LatencyMeter.percentile(v, 99), 99)
        XCTAssertEqual(LatencyMeter.percentile(v, 100), 100)
        XCTAssertEqual(LatencyMeter.percentile([7], 99), 7)
        XCTAssertEqual(LatencyMeter.percentile([], 50), 0)
        XCTAssertEqual(LatencyMeter.percentile([1, 2, 3, 4], 50), 2)
        XCTAssertEqual(LatencyMeter.percentile([1, 2, 3, 4], 51), 3)
    }

    /// Records `n` frames whose total (tR − tK) is 1…n ms, with fixed stage splits, one per 10 ms.
    private func fill(_ m: LatencyMeter, n: Int) {
        for i in 1...n {
            let tK = now
            m.noteChanged()
            m.record(tK: tK, tC: tK + 100_000, tD: tK + 200_000, tS: tK + UInt64(i) * 1_000_000 - 50_000, tR: tK + UInt64(i) * 1_000_000)
            now += 10_000_000
        }
    }

    func testSnapshotPercentilesAndStageSplit() {
        let m = makeMeter()
        _ = m.collect(framesReceived: 0, napped: false)      // first mark, so the next collect has a counter window
        fill(m, n: 100)                                       // spans 1 s
        let w = m.collect(framesReceived: 1000, napped: false)
        let s = LatencyMeter.snapshot(from: w)
        XCTAssertEqual(s.samples, 100)
        XCTAssertEqual(s.total.p50, 50, accuracy: 1e-9)
        XCTAssertEqual(s.total.p95, 95, accuracy: 1e-9)
        XCTAssertEqual(s.total.p99, 99, accuracy: 1e-9)
        XCTAssertEqual(s.total.max, 100, accuracy: 1e-9)
        XCTAssertEqual(s.kernelToCallback.p50, 0.1, accuracy: 1e-9)
        XCTAssertEqual(s.kernelToDrain.max, 0.2, accuracy: 1e-9)
        XCTAssertEqual(s.ioconnect.p50, 0.05, accuracy: 1e-9)
        XCTAssertEqual(s.cap.max, 99.75, accuracy: 1e-9, "tS − tD for i = 100")
        XCTAssertEqual(s.postsHz, 100, accuracy: 1)
        XCTAssertEqual(s.framesInHz, 1000, accuracy: 10)
        XCTAssertTrue(s.everSeen)
    }

    func testCoalescedPercentAndPostRate() {
        let m = makeMeter()
        _ = m.collect(framesReceived: 0, napped: false)
        for _ in 0..<40 { m.noteChanged() }
        for _ in 0..<10 { m.noteCoalesced() }
        for _ in 0..<30 { m.record(tK: now, tC: now, tD: now, tS: now, tR: now) }
        now += 2_000_000_000
        let s = LatencyMeter.snapshot(from: m.collect(framesReceived: 0, napped: true))
        XCTAssertEqual(s.coalescedPercent, 25, accuracy: 1e-9)
        XCTAssertEqual(s.postsHz, 15, accuracy: 1e-9)
        XCTAssertTrue(s.napped)
    }

    func testOnlyTheLastTenSecondsCount() {
        let m = makeMeter()
        m.record(tK: now, tC: now, tD: now, tS: now, tR: now + 9_000_000)       // 9 ms, soon to be old
        now += 11_000_000_000
        m.record(tK: now, tC: now, tD: now, tS: now, tR: now + 1_000_000)       // 1 ms
        now += 1_000_000
        let s = LatencyMeter.snapshot(from: m.collect(framesReceived: 0, napped: false))
        XCTAssertEqual(s.samples, 1)
        XCTAssertEqual(s.total.max, 1, accuracy: 1e-9)
    }

    func testTheRingKeepsTheNewestEntries() {
        let m = makeMeter()
        let n = LatencyMeter.ringCapacity + 10
        for i in 0..<n { m.record(tK: UInt64(i + 1), tC: 0, tD: 0, tS: 0, tR: now) }
        let e = m.entries()
        XCTAssertEqual(e.count, LatencyMeter.ringCapacity)
        XCTAssertEqual(e.first?.tK, 11)
        XCTAssertEqual(e.last?.tK, UInt64(n))
    }

    func testPollerWorstIsTheWorstFrameRightAfterATick() {
        let m = makeMeter()
        m.record(tK: now, tC: now, tD: now, tS: now, tR: now + 9_000_000)                // before any tick: not counted
        now += 100_000_000
        m.markPollerTick()
        let tick = now
        m.record(tK: tick, tC: tick, tD: tick + 1_000_000, tS: tick + 1_000_000, tR: tick + 4_000_000)       // 1 ms after the tick, total 4 ms
        m.record(tK: tick, tC: tick, tD: tick + 3_000_000, tS: tick + 3_000_000, tR: tick + 40_000_000)      // 3 ms after: outside
        now += 50_000_000
        let s = LatencyMeter.snapshot(from: m.collect(framesReceived: 0, napped: false))
        XCTAssertEqual(try XCTUnwrap(s.pollerWorstMs), 4, accuracy: 1e-9)
    }

    func testNoPollerWorstWithoutFramesNearATick() {
        let m = makeMeter()
        m.record(tK: now, tC: now, tD: now, tS: now, tR: now + 1_000_000)
        now += 10_000_000
        let s = LatencyMeter.snapshot(from: m.collect(framesReceived: 0, napped: false))
        XCTAssertNil(s.pollerWorstMs)
    }

    func testBackwardsTimestampsClampToZero() {
        let m = makeMeter()
        m.record(tK: 5_000, tC: 1_000, tD: 1_000, tS: 1_000, tR: 1_000)
        now = 5_000
        let s = LatencyMeter.snapshot(from: m.collect(framesReceived: 0, napped: false))
        XCTAssertEqual(s.total.max, 0)
    }

    // MARK: Text

    func testMenuLinesBeforeAndAfterInput() {
        XCTAssertEqual(LatencySnapshot().menuLines, ["Latency: no input yet"])
        var idle = LatencySnapshot(); idle.everSeen = true
        XCTAssertEqual(idle.menuLines, ["Latency: no input in the last 10 s"])

        var s = LatencySnapshot()
        s.samples = 5; s.everSeen = true
        s.total = .init(p50: 0.21, p95: 0.8, p99: 1.2, max: 3.1)
        s.postsHz = 812; s.coalescedPercent = 3; s.napped = false
        XCTAssertEqual(s.menuLines.count, 3)
        XCTAssertEqual(s.menuLines[0], "Latency (10 s): total p50 0.21 · p95 0.80 · max 3.10 ms")
        XCTAssertEqual(s.menuLines[2], "Posts 812 Hz · coalesced 3 % · App Nap: no")
        XCTAssertTrue(s.logLine.contains("posts=812Hz"))
        XCTAssertTrue(s.logLine.contains("nap=no"))
        XCTAssertTrue(s.logLine.hasSuffix("pollerWorst=-"))
    }

    func testMachTicksConvertToNanoseconds() {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ticks: UInt64 = 24_000_000
        XCTAssertEqual(LatencyMeter.nanos(fromMach: ticks), ticks * UInt64(tb.numer) / UInt64(tb.denom))
        // The two clocks the meter mixes are one timeline.
        let a = LatencyMeter.nanos(fromMach: mach_absolute_time()), b = LatencyMeter.nowNs()
        XCTAssertLessThan(b > a ? b - a : a - b, 5_000_000)
    }
}

@MainActor
final class PadActivityTests: XCTestCase {
    func testOneTokenAtATimeAndBalancedEnd() {
        var begun = 0, ended = 0
        let a = PadActivity(begin: { begun += 1; return NSObject() }, end: { _ in ended += 1 })
        XCTAssertFalse(a.isHeld)
        XCTAssertTrue(a.setHeld(true))
        XCTAssertFalse(a.setHeld(true), "already held: no second token")
        XCTAssertTrue(a.isHeld)
        XCTAssertEqual(begun, 1)
        XCTAssertTrue(a.setHeld(false))
        XCTAssertFalse(a.setHeld(false))
        XCTAssertEqual(ended, 1)
        XCTAssertTrue(a.setHeld(true))
        XCTAssertEqual(begun, 2)
    }

    func testTheRealActivityOptions() {
        XCTAssertTrue(PadActivity.options.contains(.latencyCritical))
        XCTAssertTrue(PadActivity.options.contains(.userInitiatedAllowingIdleSystemSleep))
        let a = PadActivity()
        a.setHeld(true); XCTAssertTrue(a.isHeld)
        a.setHeld(false); XCTAssertFalse(a.isHeld)
    }
}

final class SyntheticPadWatcherTests: XCTestCase {
    func testOnlyOurSyntheticDevicesCount() {
        XCTAssertTrue(SyntheticPadWatcher.identifier("LOGICAL_DEVICE(GDHub-1)", belongsTo: "GDHub-1"))
        XCTAssertFalse(SyntheticPadWatcher.identifier("LOGICAL_DEVICE(Razer-9)", belongsTo: "GDHub-1"))
    }

    func testTheWatcherArmsAndStopsWithoutAPad() {
        let w = SyntheticPadWatcher(serial: "no-such-serial-\(UUID().uuidString)")
        let armed = expectation(description: "reported once after arming")
        w.onCount = { count in XCTAssertEqual(count, 0); armed.fulfill() }
        w.start()
        wait(for: [armed], timeout: 5)
        w.stop()
    }
}

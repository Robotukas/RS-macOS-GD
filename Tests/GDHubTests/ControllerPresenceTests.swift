import XCTest
@testable import GDHub

final class ControllerPresenceTests: XCTestCase {
    private var now: UInt64 = 1_000_000_000
    private var changes: [ControllerStatus] = []

    private func make() -> ControllerPresence {
        let p = ControllerPresence(clock: { [unowned self] in self.now })
        p.onChange = { [unowned self] in self.changes.append($0) }
        return p
    }

    private func ms(_ n: UInt64) -> UInt64 { n * 1_000_000 }

    func testFirstReportMakesTheControllerActive() {
        let p = make()
        p.report(atNs: now)
        XCTAssertEqual(p.status, .active)
        XCTAssertEqual(changes, [.active])
    }

    func testInterfaceUpMeansAsleepUntilReportsArrive() {
        let p = make()
        p.interfaceUp()
        XCTAssertEqual(p.status, .asleep)
        p.report(atNs: now)
        XCTAssertEqual(p.status, .active)
    }

    func testAsleepAfterTwoSecondsWithoutReportsButNotBefore() {
        let p = make()
        p.interfaceUp()
        p.report(atNs: now)
        now += ms(1900)
        p.tick()
        XCTAssertEqual(p.status, .active, "1.9 s is not asleep yet")
        now += ms(100)
        p.tick()
        XCTAssertEqual(p.status, .asleep, "2.0 s is asleep")
    }

    func testIdenticalFramesKeepItActive() {
        let p = make()
        p.interfaceUp()
        for i in 0..<5000 {                         // 5 s of 1 kHz reports
            now += ms(1)
            p.report(atNs: now)
            if i % 500 == 0 { p.tick() }
        }
        p.tick()
        XCTAssertEqual(p.status, .active)
        XCTAssertEqual(changes, [.asleep, .active], "no flapping")
    }

    func testLastInterfaceDownMeansDisconnected() {
        let p = make()
        p.interfaceUp(); p.interfaceUp()
        p.report(atNs: now)
        p.interfaceDown()
        XCTAssertEqual(p.status, .active, "one interface is still up")
        p.interfaceDown()
        XCTAssertEqual(p.status, .disconnected)
        XCTAssertNil(p.lastReportAt)
    }

    func testDidWakeClearsLastReportAndWaitsForRealReports() {
        let p = make()
        p.interfaceUp()
        p.report(atNs: now)
        p.didWake()
        XCTAssertNil(p.lastReportAt)
        XCTAssertEqual(p.status, .asleep, "the pad stays neutral until reports arrive")
        now += ms(5000)
        p.tick()
        XCTAssertEqual(p.status, .asleep)
        p.report(atNs: now)
        XCTAssertEqual(p.status, .active)
    }
}

final class CallbackStatTests: XCTestCase {
    func testPercentilesOverAllFramesAndMaxGap() {
        let stat = CallbackStat(now: 0)
        var tC: UInt64 = 1_000_000
        for i in 0..<100 {
            tC += i == 50 ? 7_000_000 : 1_000_000                       // one 7 ms gap
            stat.record(tK: tC - UInt64(i + 1) * 10_000, tC: tC)        // delay (i+1) * 10 us
        }
        let w = stat.collect(now: 1_000_000_000)
        let s = CallbackStat.summary(of: w)
        XCTAssertEqual(s.frames, 100)
        XCTAssertEqual(s.hz, 100, accuracy: 0.001)
        XCTAssertEqual(s.p50, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s.p99, 0.99, accuracy: 0.0001)
        XCTAssertEqual(s.max, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.maxGapMs, 7, accuracy: 0.0001)
        XCTAssertEqual(CallbackStat.summary(of: stat.collect(now: 2_000_000_000)).frames, 0, "the window resets")
    }

    func testThrottleDecision() {
        XCTAssertTrue(ThrottleCheck.isThrottled(backgroundFlag: true, basePriority: 47))
        XCTAssertTrue(ThrottleCheck.isThrottled(backgroundFlag: false, basePriority: 4))
        XCTAssertFalse(ThrottleCheck.isThrottled(backgroundFlag: false, basePriority: 31))
    }
}

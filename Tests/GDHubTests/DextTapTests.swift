import XCTest
import GDHubDextCore
@testable import GDHub

/// T4: the registry's tap fields and the pure decisions the tap makes (Dext/GDHubVirtualHID/Core), plus the tap-related
/// status2 fields and the engine-side pieces that need no device.
final class DextCoreTapTests: XCTestCase {
    private var world: FakeWorld { .shared }
    private var reg: UnsafeMutablePointer<gdhr>!

    override func setUp() {
        world.reset()
        reg = UnsafeMutablePointer<gdhr>.allocate(capacity: 1)
        reg.initialize(to: gdhr())
        XCTAssertEqual(gdhr_ensure(reg, tapFakeOps), 1)
    }
    override func tearDown() { reg.deallocate() }

    // MARK: selector 9 arguments and the tap's decisions

    func testForwardingArgumentCheck() {
        XCTAssertEqual(gdh_fwd_validate(0, 0), 0, "INERT")
        XCTAssertEqual(gdh_fwd_validate(1, 0), 0, "COUNT")
        XCTAssertEqual(gdh_fwd_validate(2, 0), 0, "SHADOW (T5)")
        XCTAssertEqual(gdh_fwd_validate(3, 0), 0, "LIVE (T7)")
        for state: UInt64 in [4, 255, UInt64.max] { XCTAssertEqual(gdh_fwd_validate(state, 0), 1, "state \(state) is Unsupported") }
        for flags: UInt64 in [1, 2, 0x80, 0x400, UInt64.max] {
            for st: UInt64 in 0...3 { XCTAssertEqual(gdh_fwd_validate(st, flags), 1, "flags \(flags) are not implemented (bit 0 STAMP_SOURCE_TIME included)") }
        }
        for st: UInt64 in 0...3 { XCTAssertEqual(gdh_fwd_validate(st, 0x100), 0, "the pause flag goes with any state") }
        XCTAssertEqual(gdh_fwd_validate(0, 0x200), 0, "release-pad goes with INERT")
        for st: UInt64 in 1...3 { XCTAssertEqual(gdh_fwd_validate(st, 0x200), 1, "and only with INERT") }
        XCTAssertEqual(gdh_fwd_validate(0, 0x300), 1, "release-pad and pause together make no sense")
        // the Swift mirror agrees
        for state: UInt64 in 0...5 { for flags: UInt64 in [0, 1, 0x100, 0x200, 0x300] {
            XCTAssertEqual(DextProtocol.Forwarding.isAccepted(state: state, flags: flags), gdh_fwd_validate(state, flags) == 0)
        } }
    }

    /// Rule A: Open is called under exactly one condition.
    func testOpenOnlyWhenAskedForCountPoweredNotStoppingNotOpenAndRetryDue() {
        var opens = 0
        for desired: UInt32 in 0...3 { for opened: UInt32 in 0...1 { for powered: UInt32 in 0...1 {
            for stopping: UInt32 in 0...1 { for retry: UInt32 in 0...1 {
                let a = gdh_tap_decide(desired, opened, powered, stopping, retry)
                if a == Int32(GDH_TAP_OPEN) {
                    opens += 1
                    XCTAssertTrue(desired >= UInt32(GDH_FWD_COUNT) && desired <= UInt32(GDH_FWD_LIVE)); XCTAssertEqual(opened, 0); XCTAssertEqual(powered, 1)
                    XCTAssertEqual(stopping, 0); XCTAssertEqual(retry, 1)
                }
            } }
        } } }
        XCTAssertEqual(opens, 3, "of 64 input combinations exactly three open the interface: COUNT, SHADOW and LIVE, each powered, not open, not stopping, retry due")
    }

    func testCloseWhenNoLongerAskedForOrStopping() {
        let count = UInt32(GDH_FWD_COUNT), inert = UInt32(GDH_FWD_INERT)
        XCTAssertEqual(gdh_tap_decide(inert, 1, 1, 0, 1), Int32(GDH_TAP_CLOSE), "COUNT -> INERT closes")
        XCTAssertEqual(gdh_tap_decide(inert, 1, 0, 0, 0), Int32(GDH_TAP_CLOSE), "also while powered down")
        XCTAssertEqual(gdh_tap_decide(count, 1, 1, 1, 1), Int32(GDH_TAP_CLOSE), "Stop closes an open interface")
        XCTAssertEqual(gdh_tap_decide(count, 1, 1, 0, 1), Int32(GDH_TAP_NONE), "still armed: nothing to do")
        XCTAssertEqual(gdh_tap_decide(count, 1, 0, 0, 1), Int32(GDH_TAP_NONE), "SetPowerState(Off) pauses: frames are ignored, no Close")
        XCTAssertEqual(gdh_tap_decide(count, 0, 0, 0, 1), Int32(GDH_TAP_NONE), "no Open while the Mac is going to sleep")
        XCTAssertEqual(gdh_tap_decide(count, 0, 1, 0, 0), Int32(GDH_TAP_NONE), "no Open before the retry time (never a spin)")
        XCTAssertEqual(gdh_tap_decide(inert, 0, 1, 0, 1), Int32(GDH_TAP_NONE), "INERT never opens")
        XCTAssertEqual(gdh_tap_decide(count, 0, 1, 1, 1), Int32(GDH_TAP_NONE), "a stopping tap never opens")
    }

    // MARK: registry tap fields

    func testNothingIsArmedInAFreshProcess() {
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_INERT), "a relaunched dext comes up INERT")
        let tap = world.newObject(), q = world.newObject()
        var desired: UInt32 = 99
        XCTAssertEqual(gdhr_register_tap(reg, tap, q, 4242, &desired), 0)
        XCTAssertEqual(desired, UInt32(GDH_FWD_INERT), "the tap reads INERT at Start, whichever of root and tap started first")
        var s = gdhr_snap(); gdhr_snapshot(reg, &s)
        XCTAssertEqual(s.tapPresent, 1); XCTAssertEqual(s.tapOpened, 0); XCTAssertEqual(s.tapApplied, 0)
        XCTAssertEqual(s.tapPowered, 1); XCTAssertEqual(s.tapPid, 4242)
        gdhr_unregister_tap(reg, tap)
        for o in [tap, q] { world.release(o) }
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
    }

    func testTapStartedBeforeAnyRootOrOwnerWorks() {
        // T0.3: the tap's Start can run before the root's, in the same process. Nothing but the registry is touched.
        let tap = world.newObject(), q = world.newObject()
        XCTAssertEqual(gdhr_register_tap(reg, tap, q, 1, nil), 0)
        XCTAssertNil(gdhr_copy_root(reg)); XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        var qq: UnsafeMutableRawPointer?
        let c = gdhr_copy_tap(reg, &qq)
        XCTAssertEqual(c, tap); XCTAssertEqual(qq, q)
        XCTAssertEqual(world.refCount(tap), 3, "registry + test + copy"); XCTAssertEqual(world.refCount(q), 3)
        world.release(c!); world.release(qq!)
        let root = world.newObject()
        XCTAssertEqual(gdhr_register_root(reg, root), 0, "the root arrives later")
        gdhr_unregister_root(reg, root); gdhr_unregister_tap(reg, tap)
        for o in [tap, q, root] { world.release(o) }
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
    }

    func testDesiredStateIsReadAtomicallyWithRegistration() {
        gdhr_set_desired(reg, UInt32(GDH_FWD_COUNT))
        let tap = world.newObject(), q = world.newObject()
        var desired: UInt32 = 0
        _ = gdhr_register_tap(reg, tap, q, 1, &desired)
        XCTAssertEqual(desired, UInt32(GDH_FWD_COUNT), "a new instance after a re-enumeration finds COUNT still asked for")
        gdhr_unregister_tap(reg, tap)
        for o in [tap, q] { world.release(o) }
    }

    /// Rule C: the owner going away returns the tap to INERT inside the same critical section.
    func testOwnerLossResetsDesiredToInert() {
        let uc = world.newObject()
        let gen = gdhr_claim_owner(reg, uc)
        XCTAssertGreaterThan(gen, 0)
        gdhr_set_desired(reg, UInt32(GDH_FWD_COUNT))
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_COUNT))
        let other = world.newObject()
        XCTAssertNil(gdhr_release_owner(reg, other), "a stranger's release changes nothing")
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_COUNT))
        XCTAssertNil(gdhr_release_owner(reg, uc))
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_INERT), "nothing keeps counting for a dead owner")
        let gen2 = gdhr_claim_owner(reg, other)
        XCTAssertGreaterThan(gen2, gen)
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_INERT), "a new owner starts from INERT")
        XCTAssertNil(gdhr_release_owner(reg, other))
        world.release(uc); world.release(other)
    }

    func testStaleTapCannotClobberTheNewOnesState() {
        let a = world.newObject(), b = world.newObject(), q1 = world.newObject(), q2 = world.newObject()
        XCTAssertEqual(gdhr_register_tap(reg, a, q1, 10, nil), 0)
        gdhr_tap_publish(reg, a, 1, UInt32(GDH_FWD_COUNT))
        XCTAssertEqual(gdhr_register_tap(reg, b, q2, 11, nil), 1, "re-enumeration: the new instance replaces the old")
        var s = gdhr_snap(); gdhr_snapshot(reg, &s)
        XCTAssertEqual(s.tapPid, 11); XCTAssertEqual(s.tapOpened, 0, "the new instance starts unopened")
        gdhr_tap_publish(reg, b, 1, UInt32(GDH_FWD_COUNT))
        gdhr_tap_publish(reg, a, 0, 0)                           // the old instance's late Close
        gdhr_tap_set_power(reg, a, 0, 0)
        gdhr_unregister_tap(reg, a)                              // and its late Stop
        gdhr_snapshot(reg, &s)
        XCTAssertEqual(s.tapOpened, 1); XCTAssertEqual(s.tapApplied, 1); XCTAssertEqual(s.tapPowered, 1); XCTAssertEqual(s.tapPresent, 1)
        XCTAssertEqual(gdhr_tap_is(reg, b), 1); XCTAssertEqual(gdhr_tap_is(reg, a), 0)
        gdhr_unregister_tap(reg, b)
        gdhr_snapshot(reg, &s)
        XCTAssertEqual(s.tapPresent, 0); XCTAssertEqual(s.tapOpened, 0, "no tap: status2 reads opened = 0")
        for o in [a, b, q1, q2] { world.release(o) }
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 }, "\(world.allRefCounts)")
        XCTAssertEqual(world.releasesUnderLock, 0); XCTAssertEqual(world.retainsOfDead, 0); XCTAssertEqual(world.negativeRefs, 0)
    }

    func testPowerStateAndLastError() {
        let tap = world.newObject(), q = world.newObject()
        _ = gdhr_register_tap(reg, tap, q, 1, nil)
        gdhr_tap_set_power(reg, tap, 0, 0)
        var s = gdhr_snap(); gdhr_snapshot(reg, &s)
        XCTAssertEqual(s.tapPowered, 0); XCTAssertEqual(s.tapLastPowerFlags, 0)
        gdhr_tap_set_power(reg, tap, 1, 2)
        gdhr_set_last_error(reg, 0xE00002C5)
        gdhr_snapshot(reg, &s)
        XCTAssertEqual(s.tapPowered, 1); XCTAssertEqual(s.tapLastPowerFlags, 2); XCTAssertEqual(s.lastError, 0xE00002C5)
        gdhr_unregister_tap(reg, tap)
        for o in [tap, q] { world.release(o) }
    }

    func testTerminatingFlagIsOneWay() {
        XCTAssertEqual(gdhr_terminating(reg), 0)
        gdhr_set_terminating(reg)
        XCTAssertEqual(gdhr_terminating(reg), 1, "a tap that starts after devTerminate declines")
        XCTAssertEqual(gdhr_terminating(nil), 0)
    }

    func testCountersCoverTheTapFields() {
        gdhr_ctr_add(reg, Int32(GDHR_CTR_FRAMES_IN.rawValue), 7)
        gdhr_ctr_add(reg, Int32(GDHR_CTR_POOL_MISS.rawValue), 2)
        gdhr_ctr_add(reg, Int32(GDHR_CTR_OPEN_FAILURES.rawValue), 3)
        XCTAssertEqual(gdhr_ctr_get(reg, Int32(GDHR_CTR_FRAMES_IN.rawValue)), 7)
        XCTAssertEqual(gdhr_ctr_get(reg, Int32(GDHR_CTR_POOL_MISS.rawValue)), 2)
        XCTAssertEqual(gdhr_ctr_get(reg, Int32(GDHR_CTR_OPEN_FAILURES.rawValue)), 3)
        XCTAssertLessThan(Int(GDHR_CTR_COUNT.rawValue), 64, "counters stay a small fixed array")
    }

    func testConcurrentTapRegistrationAndCopies() {
        let taps = (0..<6).map { _ in world.newObject() }, qs = (0..<6).map { _ in world.newObject() }
        DispatchQueue.concurrentPerform(iterations: taps.count) { t in
            for i in 0..<1500 {
                _ = gdhr_register_tap(self.reg, taps[t], qs[t], UInt32(t), nil)
                var qq: UnsafeMutableRawPointer?
                if let c = gdhr_copy_tap(self.reg, &qq) { self.world.release(c); if let qq { self.world.release(qq) } }
                gdhr_tap_publish(self.reg, taps[t], UInt32(i & 1), 0)
                gdhr_unregister_tap(self.reg, taps[t])
            }
        }
        for t in taps { gdhr_unregister_tap(reg, t) }
        XCTAssertNil(gdhr_copy_tap(reg, nil))
        for o in taps + qs { world.release(o) }
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 }, "\(world.allRefCounts)")
        XCTAssertEqual(world.releasesUnderLock, 0); XCTAssertEqual(world.retainsOfDead, 0); XCTAssertEqual(world.negativeRefs, 0)
    }

    // MARK: status2 tap fields, C packer against the Swift decoder

    func testTapFieldsRoundTripThroughStatus2() throws {
        var s = gdhr_snap()
        s.pid = 500; s.tapPresent = 1; s.tapOpened = 1; s.tapApplied = 1; s.tapPowered = 1; s.tapPid = 500
        s.tapLastPowerFlags = 2; s.lastError = 0xE00002C5; s.desiredState = 1
        withUnsafeMutableBytes(of: &s.counters) { raw in
            let c = raw.bindMemory(to: UInt64.self)
            c[Int(GDHR_CTR_TAP_STARTS.rawValue)] = 4
            c[Int(GDHR_CTR_FRAMES_IN.rawValue)] = 31_483_360
            c[Int(GDHR_CTR_FRAMES_R06.rawValue)] = 31_483_000
            c[Int(GDHR_CTR_FRAMES_OTHER.rawValue)] = 360
            c[Int(GDHR_CTR_FRAMES_IGNORED.rawValue)] = 5
            c[Int(GDHR_CTR_FRAMES_BAD.rawValue)] = 6
            c[Int(GDHR_CTR_POOL_MISS.rawValue)] = 7
            c[Int(GDHR_CTR_READD_FAIL.rawValue)] = 8
            c[Int(GDHR_CTR_OPEN_FAILURES.rawValue)] = 9
        }
        var k2d = gdh_summary(count: 9000, p50Ns: 60_000, p99Ns: 110_000, maxNs: 400_000, meanNs: 65_400)
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, &k2d, nil)
        XCTAssertEqual(n, DextStatus2.size)
        let d = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(n))))
        XCTAssertTrue(d.tapPresent); XCTAssertTrue(d.tapOpened); XCTAssertEqual(d.appliedState, 1); XCTAssertEqual(d.desiredState, 1)
        XCTAssertTrue(d.powered); XCTAssertEqual(d.tapPid, 500); XCTAssertEqual(d.rootPid, 500); XCTAssertEqual(d.tapStarts, 4)
        XCTAssertEqual(d.lastPowerFlags, 2); XCTAssertEqual(d.lastError, 0xE00002C5)
        XCTAssertEqual(d.framesIn, 31_483_360); XCTAssertEqual(d.framesR06, 31_483_000); XCTAssertEqual(d.framesOther, 360)
        XCTAssertEqual(d.framesIgnored, 5); XCTAssertEqual(d.framesBad, 6); XCTAssertEqual(d.poolMiss, 7)
        XCTAssertEqual(d.readdFail, 8); XCTAssertEqual(d.openFailures, 9)
        XCTAssertEqual(d.k2d, DextMeterSummary(count: 9000, p50Ns: 60_000, p99Ns: 110_000, maxNs: 400_000, meanNs: 65_400))
        XCTAssertEqual(d.tapLogText, "tap: state=1/1 opened=1 frames=31483360 r06=31483000 other=360 poolMiss=7 readdFail=8 openFail=9 starts=4 frees=0 k2d p50/p99/max/mean 60/110/400/65.4 us")
    }

    func testNoTapMeansNoTapText() throws {
        var s = gdhr_snap(); s.tapPresent = 0
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, nil, nil)
        let d = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(n))))
        XCTAssertFalse(d.tapPresent); XCTAssertNil(d.tapLogText); XCTAssertFalse(d.tapOpened)
    }

    func testTapPidMismatchIsVisibleInTheText() {
        var d = DextStatus2(); d.tapPresent = true; d.rootPid = 10; d.tapPid = 11
        XCTAssertTrue(d.tapLogText!.contains("tapPid=11!=rootPid"))
    }

    // MARK: review fixes (m1, m3, M3, tick cadence, new status2 fields)

    /// m1: the state can only be set by the current owner, decided under the registry lock.
    func testOnlyTheCurrentOwnerSetsTheDesiredState() {
        let uc = world.newObject(), late = world.newObject()
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, uc, 1), GDHR_E_NOT_OWNER, "no owner at all")
        XCTAssertEqual(gdhr_desired_state(reg), 0)
        let gen = gdhr_claim_owner(reg, uc)
        XCTAssertGreaterThan(gen, 0)
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, late, 1), GDHR_E_NOT_OWNER, "a stranger")
        XCTAssertEqual(gdhr_desired_state(reg), 0)
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, uc, 1), GDHR_OK)
        XCTAssertEqual(gdhr_desired_state(reg), 1)
        XCTAssertNil(gdhr_release_owner(reg, uc))
        XCTAssertEqual(gdhr_desired_state(reg), 0, "owner loss resets")
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, uc, 1), GDHR_E_NOT_OWNER, "a stale COUNT from the dying client lands after the reset: refused")
        XCTAssertEqual(gdhr_desired_state(reg), 0, "the tap stays INERT")
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, nil, 1), GDHR_E_STATE)
        world.release(uc); world.release(late)
    }

    func testStaleSetRacingOwnerReleaseNeverLeavesCountBehind() {
        for _ in 0..<500 {
            let uc = world.newObject()
            _ = gdhr_claim_owner(reg, uc)
            let g = DispatchGroup()
            DispatchQueue.global().async(group: g) { _ = gdhr_set_desired_if_owner(self.reg, uc, 1) }
            DispatchQueue.global().async(group: g) { _ = gdhr_release_owner(self.reg, uc) }
            g.wait()
            XCTAssertEqual(gdhr_desired_state(reg), 0, "whatever the interleaving, no owner means INERT")
            world.release(uc)
        }
    }

    func testTerminatingCanBeCleared() {
        gdhr_set_terminating(reg)
        XCTAssertEqual(gdhr_terminating(reg), 1)
        gdhr_clear_terminating(reg)
        XCTAssertEqual(gdhr_terminating(reg), 0, "devTerminate failed: taps may attach again")
        gdhr_clear_terminating(nil)
    }

    func testTickCadence() {
        let inert = UInt32(GDH_FWD_INERT), count = UInt32(GDH_FWD_COUNT)
        XCTAssertEqual(gdh_tap_fast_tick(inert, 0, 1, 0, 0), 0, "INERT and settled: 1 s")
        XCTAssertEqual(gdh_tap_fast_tick(count, 1, 1, 0, 0), 0, "COUNT and open: 1 s")
        XCTAssertEqual(gdh_tap_fast_tick(count, 0, 1, 0, 0), 1, "wants to open: 50 ms (also the Open retry)")
        XCTAssertEqual(gdh_tap_fast_tick(inert, 1, 1, 0, 0), 1, "wants to close: 50 ms")
        XCTAssertEqual(gdh_tap_fast_tick(count, 0, 0, 0, 0), 0, "asleep: nothing to do")
        XCTAssertEqual(gdh_tap_fast_tick(inert, 0, 1, 0, 1), 1, "terminating: 50 ms")
        XCTAssertEqual(gdh_tap_fast_tick(count, 1, 1, 0, 1), 1)
    }

    // MARK: M3 pool bookkeeping

    private func fillPool(_ p: UnsafeMutablePointer<gdh_pool>) -> [UnsafeMutableRawPointer] {
        let bufs = (0..<8).map { _ in world.newObject() }
        for (i, b) in bufs.enumerated() { gdh_pool_set(p, Int32(i), b); gdh_pool_added(p, Int32(i)) }
        p.pointee.ready = 1
        return bufs
    }

    func testPoolBookkeepingDeliveredAndReadded() {
        let p = UnsafeMutablePointer<gdh_pool>.allocate(capacity: 1); p.initialize(to: gdh_pool()); defer { p.deallocate() }
        XCTAssertEqual(gdh_pool_find(p, nil), -1, "NULL never matches an empty slot")
        let bufs = fillPool(p)
        XCTAssertEqual(gdh_pool_next_missing(p, 0), -1, "all in the kernel's pool")
        XCTAssertEqual(gdh_pool_find(p, bufs[3]), 3)
        XCTAssertEqual(gdh_pool_find(p, world.newObject()), -1, "a kernel buffer is not ours")
        gdh_pool_delivered(p, 3)                                    // ReportAvailable before its early return
        gdh_pool_delivered(p, 5)
        XCTAssertEqual(gdh_pool_next_missing(p, 0), 3); XCTAssertEqual(gdh_pool_next_missing(p, 4), 5)
        gdh_pool_added(p, 3)
        XCTAssertEqual(gdh_pool_next_missing(p, 0), 5)
        gdh_pool_added(p, 5)
        XCTAssertEqual(gdh_pool_next_missing(p, 0), -1)
        gdh_pool_delivered(p, -1); gdh_pool_delivered(p, 99); gdh_pool_added(p, 99)   // out of range: ignored
        gdh_pool_set(p, 99, nil)
        XCTAssertEqual(gdh_pool_next_missing(p, 0), -1)
    }

    /// After a Close the whole pool is dropped: a late report that carries an old buffer matches nothing, a fresh pool is a
    /// new generation, and the old buffers are handed back exactly once for release.
    func testPoolResetDropsEveryBufferAndALateReportMatchesNothing() {
        let p = UnsafeMutablePointer<gdh_pool>.allocate(capacity: 1); p.initialize(to: gdh_pool()); defer { p.deallocate() }
        let old = fillPool(p)
        gdh_pool_delivered(p, 2)
        var back = [UnsafeMutableRawPointer?](repeating: nil, count: Int(GDH_POOL_SLOTS))
        let n = gdh_pool_reset(p, &back)
        XCTAssertEqual(n, 8)
        XCTAssertEqual(Set(back.compactMap { $0 }.map { UInt(bitPattern: $0) }), Set(old.map { UInt(bitPattern: $0) }), "every buffer comes back to be released")
        XCTAssertEqual(p.pointee.ready, 0, "the next Open builds a fresh pool")
        for b in old { XCTAssertEqual(gdh_pool_find(p, b), -1, "a late report with an old buffer matches nothing (a pool miss)") }
        XCTAssertEqual(gdh_pool_next_missing(p, 0), -1)
        XCTAssertEqual(gdh_pool_reset(p, nil), 0, "a second reset is harmless")
        // a new generation at the same slots
        let fresh = fillPool(p)
        XCTAssertEqual(gdh_pool_find(p, fresh[0]), 0); XCTAssertEqual(gdh_pool_find(p, old[0]), -1)
    }

    func testPoolWithMissingBuffersStillWorks() {
        // some Create calls failed: only the slots that exist are tracked
        let p = UnsafeMutablePointer<gdh_pool>.allocate(capacity: 1); p.initialize(to: gdh_pool()); defer { p.deallocate() }
        let a = world.newObject(), b = world.newObject()
        gdh_pool_set(p, 1, a); gdh_pool_set(p, 6, b)
        XCTAssertEqual(gdh_pool_next_missing(p, 0), 1)
        gdh_pool_added(p, 0)                                        // an empty slot cannot be marked
        XCTAssertEqual(gdh_pool_next_missing(p, 0), 1)
        gdh_pool_added(p, 1)
        XCTAssertEqual(gdh_pool_next_missing(p, 0), 6)
        XCTAssertEqual(gdh_pool_reset(p, nil), 2)
    }

    // MARK: new status2 fields

    func testReviewCountersRoundTripThroughStatus2() throws {
        var s = gdhr_snap(); s.tapPresent = 1
        withUnsafeMutableBytes(of: &s.counters) { raw in
            let c = raw.bindMemory(to: UInt64.self)
            c[Int(GDHR_CTR_POKES_RUN.rawValue)] = 11; c[Int(GDHR_CTR_TICK_APPLIES.rawValue)] = 12
            c[Int(GDHR_CTR_CLOSE_FAILURES.rawValue)] = 13; c[Int(GDHR_CTR_REOPENS.rawValue)] = 14
            c[Int(GDHR_CTR_TAP_FREES.rawValue)] = 15; c[Int(GDHR_CTR_TAP_STARTS.rawValue)] = 16
        }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, nil, nil)
        XCTAssertEqual(n, DextStatus2.size); XCTAssertEqual(DextStatus2.size, 676)
        let d = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(n))))
        XCTAssertEqual(d.pokesRun, 11); XCTAssertEqual(d.tickApplies, 12); XCTAssertEqual(d.closeFailures, 13)
        XCTAssertEqual(d.reopens, 14); XCTAssertEqual(d.tapFrees, 15); XCTAssertEqual(d.tapStarts, 16)
        XCTAssertTrue(d.tapLogText!.contains("closeFail=13")); XCTAssertTrue(d.tapLogText!.contains("reopens=14"))
        // old offsets unchanged: a 276-byte (T4 as first installed) reader sees the same words
        XCTAssertEqual([DextStatus2.Offset.k2dMean, DextStatus2.Offset.framesIn, DextStatus2.Offset.tapPresent], [272, 192, 172])
        XCTAssertEqual([DextStatus2.Offset.pokesRun, DextStatus2.Offset.tickApplies, DextStatus2.Offset.closeFailures,
                        DextStatus2.Offset.reopens, DextStatus2.Offset.tapFrees], [276, 284, 292, 300, 308])
        var older = Array(buf.prefix(276)); older[DextStatus2.Offset.size] = UInt8(276 & 0xFF); older[DextStatus2.Offset.size + 1] = UInt8(276 >> 8)
        let o = try XCTUnwrap(DextStatus2.decode(older))
        XCTAssertEqual(o.pokesRun, 0, "a dext that wrote 276 bytes has no review counters"); XCTAssertTrue(o.tapPresent)
    }

    func testBuild19StyleShortStatus2HasNoTap() throws {
        // A build-19 dext sends 172 bytes: the T4 fields read as zero.
        var s = gdhr_snap(); s.tapPresent = 1
        var buf = [UInt8](repeating: 0, count: 1024)
        _ = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, nil, nil)
        var old = Array(buf.prefix(172))
        old[DextStatus2.Offset.size] = 172; old[DextStatus2.Offset.size + 1] = 0
        let d = try XCTUnwrap(DextStatus2.decode(old))
        XCTAssertFalse(d.tapPresent, "fields beyond the declared size are zero"); XCTAssertEqual(d.framesIn, 0)
    }
}

/// Same fake environment as the registry tests (FakeWorld), re-declared here so this file stands alone.
private let tapFakeOps: UnsafeMutablePointer<gdhr_ops> = {
    let p = UnsafeMutablePointer<gdhr_ops>.allocate(capacity: 1)
    p.initialize(to: gdhr_ops(
        lock_new: { FakeWorld.shared.lockNew() },
        lock_free: { if let l = $0 { FakeWorld.shared.lockFree(l) } },
        lock: { if let l = $0 { FakeWorld.shared.lock(l) } },
        unlock: { if let l = $0 { FakeWorld.shared.unlock(l) } },
        retain: { if let o = $0 { FakeWorld.shared.retain(o) } },
        release: { if let o = $0 { FakeWorld.shared.release(o) } }))
    return p
}()

final class InputPathTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(InputPath(defaultsValue: nil), .driver, "T8: nothing stored means the driver path")
        XCTAssertEqual(InputPath(defaultsValue: "engine"), .engine)
        XCTAssertEqual(InputPath(defaultsValue: "count"), .count)
        XCTAssertEqual(InputPath(defaultsValue: " Count\n"), .count, "case and surrounding spaces are ignored")
        XCTAssertEqual(InputPath(defaultsValue: "shadow"), .shadow)
        XCTAssertEqual(InputPath(defaultsValue: "driver"), .driver)
        for bad: Any? in ["", "counts", "1", 1, true, ["count"], NSNull(), "count count"] {
            XCTAssertEqual(InputPath(defaultsValue: bad), .engine, "\(String(describing: bad)) is not a value")
        }
    }

    func testWhichPathsArmTheTap() {
        XCTAssertEqual(InputPath.engine.forwardingState, DextProtocol.Forwarding.inert)
        XCTAssertEqual(InputPath.count.forwardingState, DextProtocol.Forwarding.count)
        XCTAssertEqual(InputPath.shadow.forwardingState, DextProtocol.Forwarding.shadow, "T5: shadow arms SHADOW")
        XCTAssertEqual(InputPath.driver.forwardingState, DextProtocol.Forwarding.shadow, "T6: driver runs as shadow until the dext has LIVE")
        XCTAssertTrue(InputPath.driver.isRecognisedButNotYetSupported)
        XCTAssertFalse(InputPath.shadow.isRecognisedButNotYetSupported); XCTAssertFalse(InputPath.count.isRecognisedButNotYetSupported)
        XCTAssertEqual(InputPath.allCases.filter(\.arms), [.count, .shadow, .driver])
        XCTAssertEqual(InputPath.defaultsKey, "inputPath"); XCTAssertEqual(InputPath.drillKey, "tapDrill")
        XCTAssertEqual(InputPath.breakerKey, "tapBreakerTrippedAt")
    }
}

final class TapSupervisorTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.vhid.tap")

    private final class FakeTap: TapControlling, @unchecked Sendable {
        var calls: [UInt64] = []
        var status = DextStatus2()
        var hasTap = true
        var hasXlate = true
        var hasLive = false
        var autoApply = false                                   // the fake dext's tap applies what it is told at once (and moves padSource)
        var liveResult: kern_return_t?                          // the answer to LIVE (nil: success)
        var liveAsked = 0
        var noEffectUntilOwned = false                          // the real driver: a client that does not own the pad yet gets success and NO effect for INERT
        var freezeApplied = false                               // tests: the tap does not apply pushed mappings (appliedRevision stays)
        var supportsPauseDrill = false
        var pauseCalls: [UInt64] = []
        var pauseKr: kern_return_t = KERN_SUCCESS
        var pauseStates: [UInt64] = []
        func pauseTap(state: UInt64, ms: UInt64) -> kern_return_t { pauseCalls.append(ms); pauseStates.append(state); return pauseKr }
        var mapCalls: [[UInt8]] = []
        var mapKr: kern_return_t = KERN_SUCCESS
        var mapReason: UInt32 = 0
        func setMapping(_ blob: [UInt8]) -> (kr: kern_return_t, result: DextMappingResult?) {
            mapCalls.append(blob)
            if dieOnMapping { relaunch(nonce: status.instanceNonce + 1000); return (Self.transportError, nil) }
            guard mapKr == KERN_SUCCESS else { return (mapKr, nil) }
            if mapReason == 0 { status.hasMap = true; status.acceptedRevision = (try? XlateCore(blob: blob, spec: XlateFixtures.spec))?.revision ?? 0 }   // the blob's own revision, as the dext reports it
            return (KERN_SUCCESS, DextMappingResult(words: [mapReason == 0 ? UInt64(status.acceptedRevision) : 0, UInt64(mapReason)]))
        }
        var setResult: kern_return_t = KERN_SUCCESS
        var status2Calls = 0
        init(nonce: UInt64 = 1000) { status.instanceNonce = nonce; status.version = 1 }
        /// The driver process dies INSIDE the call: a new instance, nothing armed, and the caller gets a transport error.
        var dieOnForwarding = false, dieOnMapping = false
        static let transportError: kern_return_t = 0x10000003          // MACH_SEND_INVALID_DEST
        func setForwarding(_ state: UInt64) -> (kr: kern_return_t, result: DextForwardingResult?) {
            calls.append(state)
            if dieOnForwarding && state != 0 { relaunch(nonce: status.instanceNonce + 1000); return (Self.transportError, nil) }
            // A refusal (NotPermitted, Unsupported) is about COUNT/SHADOW; the real dext always accepts INERT.
            if noEffectUntilOwned && state != 0 { return (DextProtocol.krBusy, nil) }          // COUNT / SHADOW / LIVE from a client that does not own the pad
            let refuses = setResult != KERN_SUCCESS && !(state == 0 && (setResult == DextProtocol.krNotPermitted || setResult == DextProtocol.krUnsupported))
            if state == 3, let lr = liveResult, lr != KERN_SUCCESS { liveAsked += 1; return (lr, nil) }
            if !refuses && !(noEffectUntilOwned && state == 0) {
                status.desiredState = UInt8(state)          // a real dext remembers what it was told
                if autoApply { status.appliedState = UInt8(state); status.padSource = state == 3 ? 2 : 1 }
            }
            return refuses ? (setResult, nil) : (KERN_SUCCESS, DextForwardingResult(words: [0, status.tapPresent ? 1 : 0, 1, 0]))
        }
        func status2() -> DextStatus2? { status2Calls += 1; return status }
        /// The dext process was relaunched or replaced: a new instance, INERT, nothing armed.
        func relaunch(nonce: UInt64) { status = DextStatus2(); status.version = 1; status.instanceNonce = nonce }
    }

    private final class Clock: @unchecked Sendable { var ns: UInt64 = 1_000_000_000 }
    private final class ValueBox: @unchecked Sendable { var value: Any?; init(_ v: Any?) { value = v } }

    /// In-memory stand-ins for the breaker key and the drill key (the real ones are process-wide defaults).
    private final class Keys: @unchecked Sendable {
        var breaker: (since: Double, reason: String)?
        var drill: Any?
        var drillCleared = 0
        var choice = 0                              // the Driver menu's pick counter
    }
    private var keys = Keys()
    override func setUp() { keys = Keys() }

    private func make(_ box: ValueBox, tap: FakeTap, clock: Clock = Clock(), continuous: Clock? = nil) -> TapSupervisor {
        let k = keys
        return TapSupervisor(queue: queue, dext: tap, readDefault: { box.value },
                             readDrill: { k.drill }, clearDrill: { k.drill = nil; k.drillCleared += 1 },
                             readChoice: { k.choice }, readBreaker: { k.breaker }, writeBreaker: { k.breaker = $0 },
                             clock: { clock.ns }, continuousClock: { continuous?.ns ?? 0 }, pid: 4242)
    }
    private func make(path: Any?, tap: FakeTap, clock: Clock = Clock(), continuous: Clock? = nil) -> TapSupervisor {
        make(ValueBox(path), tap: tap, clock: clock, continuous: continuous)
    }
    private func ticks(_ s: TapSupervisor, _ n: Int) { queue.sync { for _ in 0..<n { s.onTick() } } }

    func testCountPathSendsCountAfterHello() {
        let tap = FakeTap()
        let s = make(path: "count", tap: tap)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.count])
        ticks(s, 30)
        XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.count], "sent once per connection")
    }

    func testEveryOtherValueSendsInert() {
        for v: Any? in ["engine", "bogus", 7] {            // nil is the driver path since T8
            let tap = FakeTap()
            let s = make(path: v, tap: tap)
            queue.sync { s.connection(up: true) }
            XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.inert], "\(String(describing: v))")
        }
    }

    func testNothingIsSentWhileDisconnected() {
        let tap = FakeTap()
        let s = make(path: "count", tap: tap)
        ticks(s, 20)
        XCTAssertTrue(tap.calls.isEmpty); XCTAssertEqual(tap.status2Calls, 0)
    }

    /// A20: another process's `defaults write` is seen within 1 s = 10 ticks of 100 ms.
    func testPathChangeIsSeenWithinTenTicks() {
        let tap = FakeTap(); let box = ValueBox("count")
        let s = make(box, tap: tap)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [1])
        box.value = "engine"
        ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertEqual(tap.calls, [1, 0], "COUNT -> INERT within 10 ticks (1 s)")
        box.value = "count"
        ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertEqual(tap.calls, [1, 0, 1])
        XCTAssertEqual(TapSupervisor.tickMs * TapSupervisor.defaultsEveryTicks, 1000)
    }

    func testDextWithoutTapIsNotAskedTwice() {
        let tap = FakeTap(); tap.hasTap = false; tap.setResult = DextProtocol.krUnsupported
        let s = make(path: "count", tap: tap)
        queue.sync { s.connection(up: true) }
        ticks(s, 30)
        XCTAssertEqual(tap.calls.count, 1, "Unsupported ends the asking for this connection")
    }

    func testTransientFailureIsRetried() {
        let tap = FakeTap(); tap.setResult = DextProtocol.krNotReady
        let clock = Clock()
        let s = make(path: "count", tap: tap, clock: clock)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls.count, 1)
        ticks(s, 5); XCTAssertEqual(tap.calls.count, 1, "not repeated within a second: selector 9 is not retried at the tick rate")
        clock.ns += 1_100_000_000
        ticks(s, 1); XCTAssertEqual(tap.calls.count, 2, "retried after a second")
    }

    func testShutdownLeavesTheDextInert() {
        let tap = FakeTap()
        let s = make(path: "count", tap: tap)
        queue.sync { s.connection(up: true); s.shutdown() }
        XCTAssertEqual(tap.calls, [1, 0])
        let tap2 = FakeTap()
        let s2 = make(path: "engine", tap: tap2)
        queue.sync { s2.connection(up: true); s2.shutdown() }
        XCTAssertEqual(tap2.calls, [0], "already INERT: not sent twice")
    }

    // MARK: T5 SHADOW

    private func offer(_ rev: UInt32) -> MappingOffer {
        switch MapBlobEncoder.encode(XlateFixtures.liveShaped, identity: XlateFixtures.identity, spec: XlateFixtures.spec, revision: rev) {
        case .blob(let b): return .blob(b, spec: XlateFixtures.spec)
        case .unsupported(let why): return .unsupported(why)
        }
    }

    private func shadowSupervisor(_ tap: FakeTap, path: Any? = "shadow", clock: Clock = Clock(), continuous: Clock? = nil) -> TapSupervisor {
        let s = make(path: path, tap: tap, clock: clock, continuous: continuous)
        s.mappingOffer = { [unowned self] rev in self.offer(rev) }
        return s
    }

    func testShadowPathSendsShadowThenTheMappingRightAfterHello() {
        let tap = FakeTap()
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.shadow])
        XCTAssertEqual(tap.mapCalls.count, 1, "pushed after hello, not at a later tick")
        XCTAssertEqual(XlateFixtures.validate(tap.mapCalls[0]), 0, "a blob the translator accepts against the pad's spec")
        XCTAssertTrue(s.parity.ring.enabled, "the engine records frames only while SHADOW is armed")
        ticks(s, 30)
        XCTAssertEqual(tap.mapCalls.count, 1, "not pushed again while the dext holds it")
    }

    func testCountPathNeverPushesAMapping() {
        let tap = FakeTap()
        let s = shadowSupervisor(tap, path: "count")
        queue.sync { s.connection(up: true); s.invalidateMapping() }
        ticks(s, 30)
        XCTAssertTrue(tap.mapCalls.isEmpty); XCTAssertFalse(s.parity.ring.enabled)
    }

    func testMappingChangeIsPushedAtOnceWithTheNextRevision() {
        let tap = FakeTap()
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        queue.sync { s.invalidateMapping() }
        XCTAssertEqual(tap.mapCalls.count, 2, "a learn edit: pushed immediately")
        queue.sync { s.invalidateMapping() }
        XCTAssertEqual(tap.mapCalls.count, 3, "and again for the next edit, no throttle after a success")
        XCTAssertNotEqual(tap.mapCalls[0], tap.mapCalls[1], "each push carries the next revision")
    }

    func testNoPadYetMeansNoPushUntilThereIsOne() {
        let tap = FakeTap()
        let s = make(path: "shadow", tap: tap)
        var have = false
        s.mappingOffer = { [unowned self] rev in have ? self.offer(rev) : .none }
        queue.sync { s.connection(up: true) }
        ticks(s, 10)
        XCTAssertTrue(tap.mapCalls.isEmpty)
        have = true
        queue.sync { s.invalidateMapping() }
        XCTAssertEqual(tap.mapCalls.count, 1, "pushed once the pad exists (the engine calls invalidateMapping on .published)")
    }

    func testUnsupportedMappingPushesNothingAndTheTapJustCounts() {
        let tap = FakeTap()
        let s = make(path: "shadow", tap: tap)
        s.mappingOffer = { _ in .unsupported("test") }
        queue.sync { s.connection(up: true) }
        ticks(s, 20)
        XCTAssertTrue(tap.mapCalls.isEmpty); XCTAssertEqual(tap.calls, [2, 0], "T7: the driver path stands down (INERT clears the driver's map) and the engine posts")
        XCTAssertFalse(s.parity.ring.enabled)
    }

    func testDriverRefusalIsNotRetriedInALoop() {
        let tap = FakeTap(); tap.mapReason = 20
        let clock = Clock()
        let s = shadowSupervisor(tap, clock: clock)
        queue.sync { s.connection(up: true) }
        ticks(s, 50)
        XCTAssertEqual(tap.mapCalls.count, 1, "a refused mapping waits for the next change")
        XCTAssertFalse(s.parity.ring.enabled)
    }

    func testNoPadReasonIsRetriedAtMostTwiceASecond() {
        let tap = FakeTap(); tap.mapReason = DextProtocol.MapReason.noPad
        let clock = Clock()
        let s = shadowSupervisor(tap, clock: clock)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.mapCalls.count, 1)
        ticks(s, 3); XCTAssertEqual(tap.mapCalls.count, 1, "within 500 ms: no retry")
        clock.ns += 600_000_000
        ticks(s, 5); XCTAssertEqual(tap.mapCalls.count, 2)
        tap.mapReason = 0
        clock.ns += 600_000_000
        ticks(s, 5); XCTAssertEqual(tap.mapCalls.count, 2, "the second failure doubled the wait to 1 s")
        clock.ns += 600_000_000
        ticks(s, 5); XCTAssertEqual(tap.mapCalls.count, 3, "accepted at last")
        clock.ns += 600_000_000
        ticks(s, 20); XCTAssertEqual(tap.mapCalls.count, 3)
    }

    func testDextThatLostTheMapGetsItAgain() {
        let tap = FakeTap()
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.mapCalls.count, 1)
        tap.status.hasMap = false; tap.status.acceptedRevision = 0       // the pad was recreated, the owner changed
        ticks(s, 5)
        XCTAssertEqual(tap.mapCalls.count, 2)
    }

    func testStatusIsReadAt4HzInShadowAndAt1HzInCount() {
        let shadow = FakeTap(); let s = shadowSupervisor(shadow)
        queue.sync { s.connection(up: true) }
        let before = shadow.status2Calls
        ticks(s, 50)
        XCTAssertEqual(shadow.status2Calls - before, 10, "every 5th tick: 2 Hz over 5 s")
        let count = FakeTap(); let c = shadowSupervisor(count, path: "count")
        queue.sync { c.connection(up: true) }
        let b2 = count.status2Calls
        ticks(c, 50)
        XCTAssertEqual(count.status2Calls - b2, 5, "1 Hz")
    }

    func testRelaunchedDextIsNotRearmedForShadowEither() {
        let tap = FakeTap(nonce: 1000)
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [2])
        queue.sync { s.connection(up: false) }
        tap.relaunch(nonce: 2000)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [2], "no SHADOW request on the new instance")
        XCTAssertTrue(s.tripped)
        ticks(s, 100)
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [2]); XCTAssertEqual(tap.mapCalls.count, 1, "no mapping pushed to the relaunched instance")
        XCTAssertFalse(s.parity.ring.enabled)
    }

    func testRefusedShadowIsLoggedOnceAndNotAskedAgain() {
        let tap = FakeTap(); tap.setResult = DextProtocol.krNotPermitted
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        ticks(s, 50)
        XCTAssertEqual(tap.calls, [2, 0], "one request on this connection, then INERT; a failed self-test does not clear itself")
        XCTAssertEqual(s.fallback?.reason, .driverRefused("SHADOW refused: the driver's self-test failed"))
        XCTAssertNil(s.fallback?.rearmAtNs, "final")
        XCTAssertTrue(tap.mapCalls.isEmpty, "no mapping for a driver that is not in SHADOW")
    }

    func testShadowToEngineSendsInertAndStopsRecording() {
        let tap = FakeTap(); let box = ValueBox("shadow")
        let s = make(box, tap: tap); s.mappingOffer = { [unowned self] rev in self.offer(rev) }
        queue.sync { s.connection(up: true) }
        XCTAssertTrue(s.parity.ring.enabled)
        box.value = "engine"
        ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertEqual(tap.calls, [2, 0])
        XCTAssertFalse(s.parity.ring.enabled)
    }

    func testParityRecordFromStatusIsSampledAgainstTheEnginesCore() throws {
        let tap = FakeTap()
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        let rev = tap.status.acceptedRevision
        let core = try XlateFixtures.core(XlateFixtures.liveShaped, revision: rev)
        var raw = [UInt8](repeating: 0, count: 16); raw[0] = 0x06; raw[3] = 0x40; raw[9] = 0x22
        raw.withUnsafeBufferPointer { s.parity.ring.record(timestamp: 4242, report: $0.baseAddress!, length: 16) }
        let pad = try XCTUnwrap(core.eval(raw: raw)); let rp = core.reports(pad)
        let out = rp[0].bytes + rp[1].bytes
        tap.status.parity = DextParityRecord(count: 1, revision: rev, timestamp: 4242, frame: raw, out01: Array(out.prefix(16)), out02: Array(out.suffix(2)))
        ticks(s, 5)
        XCTAssertEqual(s.parity.stats.matched, 1)
        XCTAssertEqual(s.parity.stats.mismatched, 0)
        XCTAssertTrue(s.shadowText?.contains("ok=1") ?? false)
    }

    // MARK: Review: the arming call is inside the fuse

    /// The driver dies INSIDE selector 9 (for SHADOW it is where the self-test runs). The supervisor never saw an answer, but it
    /// marked the instance as armed before sending, so the next hello (a new nonce) trips it and nothing is sent again.
    func testDeathDuringTheArmingCallTripsAfterTheReconnect() {
        for path in ["count", "shadow"] {
            let tap = FakeTap(nonce: 1000); tap.dieOnForwarding = true
            let s = shadowSupervisor(tap, path: path)
            queue.sync { s.connection(up: true) }
            let first = path == "count" ? DextProtocol.Forwarding.count : DextProtocol.Forwarding.shadow
            XCTAssertEqual(tap.calls, [first], path)
            queue.sync { s.connection(up: false) }
            queue.sync { s.connection(up: true) }                      // the new instance (nonce 2000)
            XCTAssertTrue(s.tripped, "\(path): tripped on the reconnect")
            ticks(s, 100)
            XCTAssertEqual(tap.calls.filter { $0 != 0 }, [first], "\(path): the request is not sent to the new instance, however often it reconnects")
            XCTAssertTrue(tap.mapCalls.isEmpty)
            for _ in 0..<3 { queue.sync { s.connection(up: false); s.connection(up: true) } }
            XCTAssertEqual(tap.calls.filter { $0 != 0 }, [first], "\(path): still the one arming call (INERT, which is harmless, is re-sent on each connection)")
        }
    }

    func testDefiniteRefusalDoesNotTrip() {
        for kr in [DextProtocol.krNotPermitted, DextProtocol.krUnsupported] {
            let tap = FakeTap(nonce: 1000); tap.setResult = kr
            let s = shadowSupervisor(tap)
            queue.sync { s.connection(up: true) }
            XCTAssertEqual(tap.calls, kr == DextProtocol.krNotPermitted ? [2, 0] : [2], "kr \(kr)")
            tap.relaunch(nonce: 2000)                                   // a later restart of the driver
            queue.sync { s.connection(up: false); s.connection(up: true) }
            XCTAssertFalse(s.tripped, "a refusal armed nothing, so a new instance is not 'a relaunch while armed' (kr \(kr))")
            XCTAssertEqual(tap.calls.filter { $0 == 2 }.count, 2, "and the request is asked again on the new instance (kr \(kr))")
        }
    }

    func testRefusalAfterAnEarlierCountKeepsTheCountMark() {
        let box = ValueBox("count")
        let tap = FakeTap(nonce: 1000)
        let s = make(box, tap: tap); s.mappingOffer = { [unowned self] rev in self.offer(rev) }
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [1])
        tap.setResult = DextProtocol.krNotPermitted
        box.value = "shadow"
        ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertEqual(tap.calls, [1, 2, 0], "SHADOW refused: the supervisor ends INERT")
        tap.relaunch(nonce: 2000)
        queue.sync { s.connection(up: false); s.connection(up: true) }
        XCTAssertTrue(s.tripped, "COUNT was accepted on the old instance: the refusal of SHADOW does not clear that")
    }

    func testNonDefiniteFailureKeepsTheMark() {
        let tap = FakeTap(nonce: 1000); tap.setResult = DextProtocol.krNotReady
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        tap.relaunch(nonce: 2000)
        queue.sync { s.connection(up: false); s.connection(up: true) }
        XCTAssertTrue(s.tripped, "NotReady is not a refusal: the driver may have started to arm")
    }

    /// A crash inside selector 10 (the push): SHADOW was accepted earlier, so the instance is armed and the reconnect trips.
    func testDeathDuringThePushTripsAfterTheReconnect() {
        let tap = FakeTap(nonce: 1000); tap.dieOnMapping = true
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [2]); XCTAssertEqual(tap.mapCalls.count, 1)
        queue.sync { s.connection(up: false); s.connection(up: true) }
        XCTAssertTrue(s.tripped)
        ticks(s, 100)
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [2]); XCTAssertEqual(tap.mapCalls.count, 1, "nothing is sent to the new instance")
    }

    // MARK: Review: refusals are final for their generation

    private func runSeconds(_ s: TapSupervisor, _ clock: Clock, _ seconds: Int) {
        for _ in 0..<(seconds * 10) { clock.ns += 100_000_000; ticks(s, 1) }
    }

    func testPersistentRefusalIsNotPushedAgainUntilSomethingChanges() {
        let tap = FakeTap(); tap.mapReason = 20
        let clock = Clock()
        let s = shadowSupervisor(tap, clock: clock)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.mapCalls.count, 1)
        runSeconds(s, clock, 60)
        XCTAssertEqual(tap.mapCalls.count, 1, "one push, one refusal, nothing for a minute")
        queue.sync { s.invalidateMapping() }
        XCTAssertEqual(tap.mapCalls.count, 2, "a mapping change or a new pad offers it again")
        runSeconds(s, clock, 30)
        XCTAssertEqual(tap.mapCalls.count, 2)
        queue.sync { s.connection(up: false); s.connection(up: true) }
        XCTAssertEqual(tap.mapCalls.count, 3, "and so does a new connection")
        runSeconds(s, clock, 30)
        XCTAssertEqual(tap.mapCalls.count, 3)
    }

    func testUnsupportedMappingIsNotEncodedAgainUntilItChanges() {
        let tap = FakeTap(); let clock = Clock()
        let s = make(path: "shadow", tap: tap, clock: clock)
        var offers = 0
        s.mappingOffer = { _ in offers += 1; return .unsupported("test") }
        queue.sync { s.connection(up: true) }
        runSeconds(s, clock, 60)
        XCTAssertEqual(offers, 1, "asked once for 60 s")
        queue.sync { s.invalidateMapping() }
        XCTAssertEqual(offers, 2)
        runSeconds(s, clock, 30)
        XCTAssertEqual(offers, 2)
    }

    func testTransientFailuresBackOffAndStopAtFiveSeconds() {
        let tap = FakeTap(); tap.mapReason = DextProtocol.MapReason.noPad
        let clock = Clock()
        let s = shadowSupervisor(tap, clock: clock)
        queue.sync { s.connection(up: true) }
        runSeconds(s, clock, 60)
        // pushes at about 0, 0.5, 1.5, 3.5, 7.5 s, then every 5 s: far below the 2 Hz of the status reads
        XCTAssertLessThan(tap.mapCalls.count, 20); XCTAssertGreaterThan(tap.mapCalls.count, 8)
    }

    // MARK: Review: selector 11 per second in each state

    func testStatusReadsPerSecondInEachState() {
        func reads(path: Any?, seconds: Int, interfaceUp: Bool = false) -> Int {
            let tap = FakeTap(); let clock = Clock()
            let s = shadowSupervisor(tap, path: path, clock: clock)
            queue.sync { s.connection(up: true); if interfaceUp { s.controllerInterface(up: true) } }
            let before = tap.status2Calls
            runSeconds(s, clock, seconds)
            return tap.status2Calls - before
        }
        XCTAssertEqual(reads(path: "engine", seconds: 10), 0, "INERT settled: none")
        XCTAssertEqual(reads(path: "count", seconds: 10), 10, "COUNT: 1 Hz")
        XCTAssertEqual(reads(path: "shadow", seconds: 10), 20, "SHADOW: 2 Hz")
        XCTAssertEqual(reads(path: "engine", seconds: 1, interfaceUp: true), 10, "attach timing window (tap not present yet): 10 Hz, for at most 5 s")
    }

    // MARK: T6: F1-F5, the breaker, the limiter, polling

    private final class Counter: @unchecked Sendable { var value: UInt64 = 0 }

    /// An armed supervisor with a healthy tap: interface up, tap present, `state` applied, the clock past the grace period.
    private func armedSupervisor(path: String, clock: Clock, frames: Counter, tap: FakeTap = FakeTap(nonce: 1000)) -> (TapSupervisor, FakeTap) {
        let s = shadowSupervisor(tap, path: path, clock: clock)
        s.engineFrames = { frames.value }
        tap.status.tapPresent = true
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        tap.status.appliedState = UInt8(path == "count" ? 1 : 2)
        ticks(s, 1)                                                     // the attach timing records the tap present at once (about 0 ms)
        clock.ns += 2_000_000_000                                       // past the 1 s grace
        return (s, tap)
    }

    /// One 100 ms step: the engine's reader sees `perTick` frames; the tap's counter follows unless `stalled`.
    private func step(_ s: TapSupervisor, _ clock: Clock, _ tap: FakeTap, _ frames: Counter, perTick: UInt64 = 91, stalled: Bool = false) {
        clock.ns += 100_000_000
        frames.value += perTick
        if !stalled { tap.status.framesIn += perTick }
        ticks(s, 1)
    }

    func testF1StallInShadowFallsBackToInertWithinTwoReadingsAndRearmsAfterTheHold() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        for _ in 0..<100 { step(s, clock, tap, frames) }                // 10 s of healthy traffic
        XCTAssertNil(s.fallback); XCTAssertEqual(tap.calls, [2])
        var ticksToFallback = 0
        while s.fallback == nil, ticksToFallback < 40 { step(s, clock, tap, frames, stalled: true); ticksToFallback += 1 }
        XCTAssertEqual(s.fallback?.reason, .stall)
        XCTAssertLessThanOrEqual(ticksToFallback, 15, "three readings 0.5 s apart (2 Hz in SHADOW): 1 to 1.5 s")
        XCTAssertEqual(tap.calls, [2, 0], "INERT sent, the engine path keeps posting")
        XCTAssertEqual(s.makeReport().fallback, "tap stalled"); XCTAssertTrue(s.makeReport().fallbackRetrying)
        XCTAssertEqual(s.makeReport().armed, "inert")
        // the hold-off is 5 s; then SHADOW again, on the same instance
        for _ in 0..<45 { step(s, clock, tap, frames, stalled: true) }
        XCTAssertEqual(tap.calls, [2, 0], "not before the 5 s hold-off")
        for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertEqual(tap.calls, [2, 0, 2], "re-armed after the hold-off")
        XCTAssertNil(s.fallback)
    }

    func testF1InCountUsesTheOneHertzReadings() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "count", clock: clock, frames: frames)
        for _ in 0..<50 { step(s, clock, tap, frames) }
        XCTAssertNil(s.fallback)
        var n = 0
        while s.fallback == nil, n < 80 { step(s, clock, tap, frames, stalled: true); n += 1 }
        XCTAssertEqual(s.fallback?.reason, .stall)
        XCTAssertLessThanOrEqual(n, 30, "3 readings 1 s apart at most")
    }

    func testF1NeedsEngineFramesAndATapThatShouldBeCounting() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        // no engine frames (controller asleep, receiver idle): a quiet tap is not a stall
        for _ in 0..<100 { step(s, clock, tap, frames, perTick: 0, stalled: true) }
        XCTAssertNil(s.fallback)
        // the tap has not applied the state yet (appliedState != asked): not a stall
        tap.status.appliedState = 0
        for _ in 0..<100 { step(s, clock, tap, frames, stalled: true) }
        XCTAssertNil(s.fallback)
        // fewer than 50 frames between readings
        tap.status.appliedState = 2
        for _ in 0..<100 { step(s, clock, tap, frames, perTick: 5, stalled: true) }
        XCTAssertNil(s.fallback, "5 frames per tick = 25 per reading")
    }

    func testF1HasAGracePeriodAfterTheInterfaceComesUp() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        for _ in 0..<20 { step(s, clock, tap, frames) }
        queue.sync { s.controllerInterface(up: false); s.controllerInterface(up: true) }       // controller switched off and on
        for _ in 0..<9 { step(s, clock, tap, frames, stalled: true) }                        // < 1 s: the tap is still re-attaching
        XCTAssertNil(s.fallback, "no F1 within the grace period")
    }

    func testWakeStartsAFreshGracePeriod() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        for _ in 0..<20 { step(s, clock, tap, frames) }
        queue.sync { s.didWake() }
        for _ in 0..<9 { step(s, clock, tap, frames, stalled: true) }       // the tap re-opens after the engine's reader is already flowing
        XCTAssertNil(s.fallback, "no F1 within 1 s of the wake")
        tap.status.tapPresent = false
        for _ in 0..<9 { step(s, clock, tap, frames) }
        XCTAssertNil(s.fallback, "and no F2 either")
    }

    func testF2TapAbsentAfterTheGraceNotBefore() {
        let clock = Clock(), frames = Counter()
        let tap = FakeTap(nonce: 1000); tap.status.tapPresent = false
        let s = shadowSupervisor(tap, path: "count", clock: clock)
        s.engineFrames = { frames.value }
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        for _ in 0..<9 { step(s, clock, tap, frames) }                  // 0.9 s: inside the grace
        XCTAssertNil(s.fallback)
        tap.status.tapPresent = true                                    // the tap attached in time ("controller on")
        for _ in 0..<30 { step(s, clock, tap, frames) }
        XCTAssertNil(s.fallback, "the tap came within the grace: no F2")

        let clock2 = Clock(), tap2 = FakeTap(nonce: 1000); tap2.status.tapPresent = false
        let s2 = shadowSupervisor(tap2, path: "count", clock: clock2)
        queue.sync { s2.controllerInterface(up: true); s2.connection(up: true) }
        var n = 0
        while s2.fallback == nil, n < 30 { clock2.ns += 100_000_000; ticks(s2, 1); n += 1 }
        XCTAssertEqual(s2.fallback?.reason, .tapAbsent)
        XCTAssertGreaterThanOrEqual(n, 13, "not before 1 s plus the second reading 300 ms later"); XCTAssertLessThanOrEqual(n, 15)
        XCTAssertEqual(tap2.calls, [1, 0])
        XCTAssertTrue(s2.makeReport().fallbackRetrying)
    }

    func testF2UsesThreeTimesTheMeasuredP99WhenThatIsLarger() {
        let clock = Clock()
        let tap = FakeTap(nonce: 1000); tap.status.tapPresent = false
        let s = shadowSupervisor(tap, path: "engine", clock: clock)
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        clock.ns += 700_000_000; tap.status.tapPresent = true; ticks(s, 1)          // the timing records 700 ms
        XCTAssertEqual(s.timing.samplesMs.count, 1)
        XCTAssertEqual(s.graceNs, 2_100_000_000, "3 x 700 ms")
        let fresh = shadowSupervisor(FakeTap(), path: "engine"); XCTAssertEqual(fresh.graceNs, 1_000_000_000, "1 s when nothing was measured (T4: 118-119 ms)")
    }

    func testNoF2OnTheEnginePathOrWithoutATapCapability() {
        let clock = Clock()
        let tap = FakeTap(nonce: 1000); tap.status.tapPresent = false
        let s = shadowSupervisor(tap, path: "engine", clock: clock)
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        for _ in 0..<60 { clock.ns += 100_000_000; ticks(s, 1) }
        XCTAssertNil(s.fallback, "inputPath = engine: a missing tap is not a fault")
        let old = FakeTap(nonce: 1000); old.hasTap = false; old.status.tapPresent = false; old.setResult = DextProtocol.krUnsupported
        let s2 = shadowSupervisor(old, path: "count", clock: clock)
        queue.sync { s2.controllerInterface(up: true); s2.connection(up: true) }
        for _ in 0..<60 { clock.ns += 100_000_000; ticks(s2, 1) }
        XCTAssertNil(s2.fallback, "a driver without CAP_TAP is not 'tap absent'")
        XCTAssertFalse(s2.makeReport().capTap)
    }

    func testF3CountersGoingBackwardsOnOneInstanceTripsTheSupervisor() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        for _ in 0..<20 { step(s, clock, tap, frames) }
        tap.status.framesIn = 5                                         // the same nonce, but the counters restarted
        for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertTrue(s.tripped)
        if case .driverRestarted(let why)? = s.fallback?.reason { XCTAssertTrue(why.contains("backwards")) } else { XCTFail("\(String(describing: s.fallback))") }
        XCTAssertNil(s.fallback?.rearmAtNs, "final")
        for _ in 0..<200 { step(s, clock, tap, frames) }
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [2], "never armed again")
    }

    func testF4SelfTestFailureInStatus2FallsBack() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        tap.status.selfTest = DextProtocol.SelfTest.fail
        for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertEqual(s.fallback?.reason, .driverRefused("self-test failed in the driver"))
        XCTAssertNil(s.fallback?.rearmAtNs)
        XCTAssertEqual(tap.calls, [2, 0])
    }

    func testF4MappingRefusalFallsBackAndEndsWithTheNextMappingChange() {
        let tap = FakeTap(); tap.mapReason = 20
        let clock = Clock()
        let s = shadowSupervisor(tap, clock: clock)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.mapCalls.count, 1)
        if case .driverRefused(let why)? = s.fallback?.reason { XCTAssertTrue(why.hasPrefix("mapping")) } else { XCTFail("\(String(describing: s.fallback))") }
        XCTAssertEqual(tap.calls, [2, 0], "INERT after the refusal")
        XCTAssertTrue(s.fallback?.clearOnMapping ?? false)
        tap.mapReason = 0
        queue.sync { s.invalidateMapping() }                            // the owner fixed the mapping
        XCTAssertNil(s.fallback)
        XCTAssertEqual(tap.calls, [2, 0, 2]); XCTAssertEqual(tap.mapCalls.count, 2)
        XCTAssertEqual(s.pushedRevision, 1)
    }

    private func mismatch(_ s: TapSupervisor, _ tap: FakeTap, count: UInt32, ts: UInt64) throws {
        let rev = tap.status.acceptedRevision
        let core = try XlateFixtures.core(XlateFixtures.liveShaped, revision: rev)
        var raw = [UInt8](repeating: 0, count: 16); raw[0] = 0x06; raw[3] = UInt8(count & 0xff)
        raw.withUnsafeBufferPointer { s.parity.ring.record(timestamp: ts, report: $0.baseAddress!, length: 16) }
        let pad = try XCTUnwrap(core.eval(raw: raw)); let rp = core.reports(pad)
        var out = rp[0].bytes + rp[1].bytes; out[4] ^= 1
        tap.status.parity = DextParityRecord(count: count, revision: rev, timestamp: ts, frame: raw, out01: Array(out.prefix(16)), out02: Array(out.suffix(2)))
    }

    func testF5ThreeMismatchesWithinTenSecondsFallBackFinally() throws {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        for i in 1...2 { try mismatch(s, tap, count: UInt32(i), ts: UInt64(100 + i)); for _ in 0..<5 { step(s, clock, tap, frames) } }
        XCTAssertNil(s.fallback, "two are not enough")
        try mismatch(s, tap, count: 3, ts: 103)
        for _ in 0..<5 { step(s, clock, tap, frames) }
        XCTAssertEqual(s.fallback?.reason, .parityMismatch)
        XCTAssertNil(s.fallback?.rearmAtNs, "final: a parity bug does not heal by retrying")
        XCTAssertEqual(tap.calls, [2, 0])
    }

    func testF5MismatchesSpreadOverMoreThanTenSecondsAndNoMatchesDoNotCount() throws {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        for i in 1...6 { try mismatch(s, tap, count: UInt32(i), ts: UInt64(200 + i)); for _ in 0..<60 { step(s, clock, tap, frames) } }   // one per 6 s
        XCTAssertNil(s.fallback, "never 3 within 10 s")
        for i in 20...80 {                                              // frames the engine never saw: noMatch, not mismatch
            let rev = tap.status.acceptedRevision
            tap.status.parity = DextParityRecord(count: UInt32(i), revision: rev, timestamp: UInt64(9000 + i), frame: [UInt8](repeating: 6, count: 16), out01: [UInt8](repeating: 0, count: 16), out02: [0, 0])
            for _ in 0..<5 { step(s, clock, tap, frames) }
        }
        XCTAssertNil(s.fallback); XCTAssertGreaterThan(s.parity.stats.noMatch, 40)
    }

    func testBreakerTripsOnTheThirdInstanceChangeWithin120SecondsAndOnlyTheOwnerClearsIt() {
        let clock = Clock()
        let tap = FakeTap(nonce: 1000)
        let s = shadowSupervisor(tap, path: "shadow", clock: clock)
        queue.sync { s.connection(up: true) }
        for n in [2000, 3000] as [UInt64] {
            tap.relaunch(nonce: n); clock.ns += 10_000_000_000
            queue.sync { s.connection(up: false); s.connection(up: true) }
            XCTAssertNil(s.latched, "after change \(n / 1000 - 1)")
        }
        tap.relaunch(nonce: 4000); clock.ns += 10_000_000_000
        queue.sync { s.connection(up: false); s.connection(up: true) }
        XCTAssertEqual(s.latched, .breaker)
        XCTAssertEqual(keys.breaker?.reason, "breaker"); XCTAssertNotNil(keys.breaker)
        XCTAssertEqual(s.makeReport().latched, "breaker")
        // a path change does NOT clear it (only the key does)
        tap.status.instanceNonce = 4000
        ticks(s, 30)
        XCTAssertEqual(s.latched, .breaker)
        XCTAssertEqual(tap.calls.filter { $0 == 2 }.count, 1, "armed once, on the first instance only")
        keys.breaker = nil                                              // the menu (or defaults delete) removes the key
        ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertNil(s.latched)
    }

    func testBreakerDoesNotTripWhenTheChangesAreSpreadOut() {
        let clock = Clock(); let tap = FakeTap(nonce: 1000)
        let s = shadowSupervisor(tap, path: "engine", clock: clock)
        queue.sync { s.connection(up: true) }
        for n in 2...6 as ClosedRange<UInt64> {
            tap.relaunch(nonce: n * 1000); clock.ns += 130_000_000_000
            queue.sync { s.connection(up: false); s.connection(up: true) }
        }
        XCTAssertNil(s.latched)
    }

    func testABreakerLeftByAnEarlierEngineRunKeepsTheDriverPathOff() {
        keys.breaker = (1.0e9, "limiter")
        let tap = FakeTap(); let s = shadowSupervisor(tap, path: "shadow")
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(s.latched, .limiter)
        XCTAssertEqual(tap.calls, [0], "INERT only, never SHADOW")
        ticks(s, 50)
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [])
    }

    func testLimiterLatchesOnTheThirdFallbackWithinTenMinutes() {
        let clock = Clock()
        let tap = FakeTap(nonce: 1000); tap.status.tapPresent = false           // the tap never comes: F2, re-arm after 5 s, F2, ...
        let s = shadowSupervisor(tap, path: "count", clock: clock)
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        for _ in 0..<400 { clock.ns += 100_000_000; ticks(s, 1) }               // 40 s
        XCTAssertEqual(s.latched, .limiter)
        XCTAssertEqual(tap.calls.filter { $0 == 1 }.count, 3, "armed three times, then the limiter stopped it")
        XCTAssertEqual(keys.breaker?.reason, "limiter")
        XCTAssertEqual(s.makeReport().latched, "limiter"); XCTAssertFalse(s.makeReport().fallbackRetrying)
        for _ in 0..<6000 { clock.ns += 100_000_000; ticks(s, 1) }              // 10 more minutes
        XCTAssertEqual(tap.calls.filter { $0 == 1 }.count, 3, "no re-arm after the limiter, however long")
    }

    func testLimiterDoesNotLatchWhenFallbacksAreMoreThanTenMinutesApart() {
        let clock = Clock()
        let tap = FakeTap(nonce: 1000); tap.status.tapPresent = false
        let s = shadowSupervisor(tap, path: "count", clock: clock)
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        for _ in 0..<4 {
            var n = 0; while s.fallback == nil, n < 200 { clock.ns += 100_000_000; ticks(s, 1); n += 1 }
            XCTAssertEqual(s.fallback?.reason, .tapAbsent)
            clock.ns += 700_000_000_000                                 // 11+ minutes of quiet
            queue.sync { s.controllerInterface(up: false); s.controllerInterface(up: true) }    // the controller came back
            ticks(s, 1)                                                 // re-armed
            XCTAssertNil(s.fallback)
        }
        XCTAssertNil(s.latched)
    }

    func testNoRearmAcrossAnInstanceChangeAfterAFallback() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        while s.fallback == nil { step(s, clock, tap, frames, stalled: true) }
        XCTAssertEqual(s.fallback?.reason, .stall)
        tap.relaunch(nonce: 2000)                                       // the driver died during the hold-off
        queue.sync { s.connection(up: false); s.connection(up: true) }
        XCTAssertTrue(s.tripped, "the mark of the old instance is still there")
        for _ in 0..<200 { clock.ns += 100_000_000; ticks(s, 1) }
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [2], "never armed on the new instance")
    }

    func testAChangedInputPathValueEndsAFallback() {
        let clock = Clock(), frames = Counter(); let box = ValueBox("shadow")
        let tap = FakeTap(nonce: 1000)
        let s = make(box, tap: tap, clock: clock); s.mappingOffer = { [unowned self] rev in self.offer(rev) }
        s.engineFrames = { frames.value }
        tap.status.tapPresent = true
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        tap.status.appliedState = 2; clock.ns += 2_000_000_000
        tap.status.selfTest = DextProtocol.SelfTest.fail
        for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertNotNil(s.fallback)
        tap.status.selfTest = 0
        box.value = "Shadow"                                           // another spelling is a change of the stored value
        for _ in 0..<TapSupervisor.defaultsEveryTicks { step(s, clock, tap, frames) }
        XCTAssertNil(s.fallback)
        XCTAssertEqual(tap.calls.filter { $0 == 2 }.count, 2)
    }

    // MARK: T6: both defaults keys, driver, drill

    func testDriverRunsAsShadowAndTheReportSaysLiveIsUnavailable() {
        let tap = FakeTap(); let s = shadowSupervisor(tap, path: "driver")
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [2])
        let r = s.makeReport()
        XCTAssertEqual(r.path, "driver"); XCTAssertEqual(r.armed, "shadow"); XCTAssertTrue(r.liveUnavailable)
        XCTAssertTrue(s.parity.ring.enabled)
        let live = FakeTap(); live.hasLive = true
        let s2 = shadowSupervisor(live, path: "driver")
        queue.sync { s2.connection(up: true) }
        XCTAssertFalse(s2.makeReport().liveUnavailable, "a dext with LIVE does not need the note (T7 will ask for LIVE then)")
    }

    func testBothKeysAreReadOncePerSecond() {
        let box = ValueBox("engine"); let tap = FakeTap()
        var pathReads = 0, drillReads = 0, breakerReads = 0
        let s = TapSupervisor(queue: queue, dext: tap, readDefault: { pathReads += 1; return box.value }, readDrill: { drillReads += 1; return nil },
                              clearDrill: {}, readBreaker: { breakerReads += 1; return nil }, writeBreaker: { _ in }, clock: { 1 }, pid: 1)
        queue.sync { s.connection(up: true) }
        let (p0, d0, b0) = (pathReads, drillReads, breakerReads)
        ticks(s, 100)                                                   // 10 s
        XCTAssertEqual(pathReads - p0, 10); XCTAssertEqual(drillReads - d0, 10); XCTAssertEqual(breakerReads - b0, 10)
    }

    func testDrillIsReadDeletedAndCarriedOutOnlyWhenTheDriverCan() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        tap.supportsPauseDrill = true
        keys.drill = "pause5"
        for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertEqual(tap.pauseCalls, [5000]); XCTAssertEqual(keys.drillCleared, 1); XCTAssertNil(keys.drill)
        for _ in 0..<30 { step(s, clock, tap, frames) }
        XCTAssertEqual(tap.pauseCalls, [5000], "once per write")
        // F1 then follows from the pause: the tap stops counting while the engine's frames keep coming
        while s.fallback == nil { step(s, clock, tap, frames, stalled: true) }
        XCTAssertEqual(s.fallback?.reason, .stall)
        for _ in 0..<80 { step(s, clock, tap, frames) }
        XCTAssertEqual(tap.calls, [2, 0, 2], "and re-armed after the pause")
    }

    func testDrillOnADriverWithoutThePauseFlagIsIgnoredButStillDeleted() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)       // build 23: supportsPauseDrill == false
        keys.drill = "pause5"
        for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertTrue(tap.pauseCalls.isEmpty); XCTAssertEqual(keys.drillCleared, 1)
        keys.drill = "bogus"; for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertEqual(keys.drillCleared, 2); XCTAssertTrue(tap.pauseCalls.isEmpty)
        let engine = FakeTap(); engine.supportsPauseDrill = true
        let e = shadowSupervisor(engine, path: "engine")
        queue.sync { e.connection(up: true) }
        keys.drill = "pause5"; ticks(e, 10)
        XCTAssertTrue(engine.pauseCalls.isEmpty, "not armed: nothing to pause")
        XCTAssertFalse(DextClientWithoutLiveSupportsThePauseDrill())
    }

    private func DextClientWithoutLiveSupportsThePauseDrill() -> Bool {
        let c = DextClient(queue: queue)
        return queue.sync { c.supportsPauseDrill || c.hasLive }
    }

    // MARK: T6: the report the Driver menu reads

    func testReportsAreSentOnlyWhenTheyChange() {
        let clock = Clock(), frames = Counter()
        let tap = FakeTap(nonce: 1000); tap.status.tapPresent = true
        let s = shadowSupervisor(tap, path: "shadow", clock: clock)
        s.engineFrames = { frames.value }
        var reports: [TapStatusReport] = []
        s.statusSink = { reports.append($0) }
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        tap.status.appliedState = 2; clock.ns += 2_000_000_000
        let afterArming = reports.count
        XCTAssertGreaterThanOrEqual(afterArming, 1)
        XCTAssertEqual(reports.last?.armed, "shadow"); XCTAssertEqual(reports.last?.pid, 4242)
        for _ in 0..<200 { step(s, clock, tap, frames) }                // 20 s of healthy traffic: polls and ticks change nothing
        XCTAssertEqual(reports.count, afterArming)
        tap.status.selfTest = DextProtocol.SelfTest.fail
        for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertEqual(reports.last?.fallback, "driver refused (self-test failed in the driver)")
        XCTAssertEqual(reports.last?.armed, "inert"); XCTAssertEqual(reports.last?.fallbackRetrying, false)
    }

    func testUnsupportedMappingIsInTheReportAndTheEnginePathKeepsPosting() {
        let tap = FakeTap(); let s = make(path: "shadow", tap: tap)
        s.mappingOffer = { _ in .unsupported("echo suppression (paddle_outer_right -> y)") }
        queue.sync { s.connection(up: true) }
        let r = s.makeReport()
        XCTAssertEqual(r.mappingNote, "echo suppression (paddle_outer_right -> y)")
        XCTAssertEqual(r.armed, "inert", "T7: the driver path stands down: INERT, the map is cleared in the driver, the engine posts")
        XCTAssertNil(r.fallback, "not a fault: no fallback, no limiter entry")
        queue.sync { s.invalidateMapping() }
        XCTAssertNotNil(s.unsupportedNote)
        s.mappingOffer = { [unowned self] rev in self.offer(rev) }
        queue.sync { s.invalidateMapping() }
        XCTAssertNil(s.makeReport().mappingNote, "cleared when the mapping is supported again")
        XCTAssertEqual(s.makeReport().armed, "shadow", "and the driver path comes back by itself")
    }

    // MARK: R1d: the local blob check, and an edit that stays unsupported

    private final class Reports: @unchecked Sendable { var all: [TapStatusReport] = [] }

    /// What the engine's `mappingOffer` does for a mapping: the real encoder, for the fixture pad.
    private func offer(of m: ControlMapping, _ rev: UInt32) -> MappingOffer {
        switch MapBlobEncoder.encode(m, identity: XlateFixtures.identity, spec: XlateFixtures.spec, revision: rev) {
        case .blob(let b): return .blob(b, spec: XlateFixtures.spec)
        case .unsupported(let why): return .unsupported(why)
        }
    }

    private func remapped(_ picks: [(String, ControlOutput)]) -> ControlMapping {
        var m = XlateFixtures.liveShaped
        for (id, o) in picks { m.setOutput(o, for: id) }
        return m
    }

    private final class MappingBox: @unchecked Sendable { var mapping: ControlMapping; init(_ m: ControlMapping) { mapping = m } }

    func testAnEditThatStaysUnsupportedMakesNoDriverCallAndUpdatesTheNote() {
        let tap = FakeTap(); let s = make(path: "shadow", tap: tap)
        let box = MappingBox(remapped([("g1", .pad(.y)), ("g2", .pad(.y))]))
        s.mappingOffer = { [unowned self] rev in self.offer(of: box.mapping, rev) }
        let reports = Reports()
        s.statusSink = { reports.all.append($0) }
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(s.unsupportedNote, "three buttons send Y: Y, G1, G2", "the engine says it in the screen's words")
        XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.shadow, DextProtocol.Forwarding.inert], "SHADOW, then the push finds it unsupported: INERT")
        XCTAssertTrue(tap.mapCalls.isEmpty)
        let callsBefore = tap.calls, readsBefore = s.status2Reads

        // Another edit that the driver cannot say either: the hold stays, the note follows, the driver is not touched.
        box.mapping = remapped([("g1", .pad(.lt))])
        queue.sync { s.invalidateMapping() }
        XCTAssertEqual(tap.calls, callsBefore, "no INERT -> SHADOW -> INERT for nothing")
        XCTAssertTrue(tap.mapCalls.isEmpty)
        XCTAssertTrue(s.unsupportedHold)
        XCTAssertEqual(s.unsupportedNote, "G1 sends LT: a button cannot pull a trigger in this driver version")
        XCTAssertEqual(reports.all.last?.mappingNote, s.unsupportedNote, "the status file follows the new reason")
        XCTAssertEqual(reports.all.last?.armed, "inert")
        XCTAssertNil(s.makeReport().fallback, "not a fault"); XCTAssertNil(s.latched); XCTAssertNil(s.fallback)

        // Many edits and ticks: still nothing, and the limiter (3 fallbacks) never sees an entry.
        for _ in 0..<6 { queue.sync { s.invalidateMapping() } }
        ticks(s, 40)
        XCTAssertEqual(tap.calls, callsBefore); XCTAssertTrue(tap.mapCalls.isEmpty); XCTAssertNil(s.latched)
        XCTAssertEqual(s.status2Reads, readsBefore, "and the driver's status is not read for it either")
        XCTAssertEqual(s.pushes, 0)
    }

    func testAnEditThatBecomesExpressibleReleasesTheHoldAsBefore() {
        let tap = FakeTap(); let s = make(path: "shadow", tap: tap)
        let box = MappingBox(remapped([("g1", .pad(.y)), ("g2", .pad(.y))]))
        s.mappingOffer = { [unowned self] rev in self.offer(of: box.mapping, rev) }
        queue.sync { s.connection(up: true) }
        XCTAssertTrue(s.unsupportedHold)
        box.mapping = remapped([("g1", .pad(.y))])                  // two sources on Y: GDHM v1 can say it
        queue.sync { s.invalidateMapping() }
        XCTAssertFalse(s.unsupportedHold); XCTAssertNil(s.unsupportedNote); XCTAssertNil(s.makeReport().mappingNote)
        XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.shadow, DextProtocol.Forwarding.inert, DextProtocol.Forwarding.shadow])
        XCTAssertEqual(tap.mapCalls.count, 1, "and the blob is pushed at once")
        XCTAssertEqual(s.makeReport().armed, "shadow")
        // Back to unsupported through the normal push: the hold is taken again, the driver goes INERT.
        box.mapping = remapped([("g1", .pad(.lt))])
        queue.sync { s.invalidateMapping() }
        XCTAssertTrue(s.unsupportedHold)
        XCTAssertEqual(tap.calls.last, DextProtocol.Forwarding.inert)
        XCTAssertEqual(tap.mapCalls.count, 1, "nothing more was pushed")
    }

    func testABlobTheLocalCheckRejectsIsNeverPushedAndIsNotAFault() {
        let tap = FakeTap(); let s = make(path: "shadow", tap: tap)
        let good = offer(1)
        guard case .blob(let blob, let spec) = good else { return XCTFail("the fixture mapping encodes") }
        var damaged = spec; damaged[damaged.count - 1] ^= 0xFF      // a valid blob for a different pad
        var offered: MappingOffer = .blob([1, 2, 3, 4], spec: spec)
        XCTAssertNotEqual(XlateFixtures.validate([1, 2, 3, 4]), 0)
        XCTAssertNotEqual(XlateFixtures.validate(blob, spec: damaged), 0)
        s.mappingOffer = { _ in offered }
        queue.sync { s.connection(up: true) }
        XCTAssertTrue(tap.mapCalls.isEmpty, "never offered to the driver")
        XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.shadow, DextProtocol.Forwarding.inert])
        XCTAssertTrue(s.unsupportedHold)
        let note = s.makeReport().mappingNote ?? ""
        XCTAssertTrue(note.hasPrefix("internal: blob rejected locally (GDHM rejected: "), note)
        XCTAssertNil(s.fallback, "no fallback trip"); XCTAssertNil(s.latched)

        // Edits that stay rejected: still no driver call and, many times over, no limiter entry (3 would latch).
        offered = .blob(blob, spec: damaged)
        for _ in 0..<6 { queue.sync { s.invalidateMapping() } }
        ticks(s, 40)
        XCTAssertTrue(tap.mapCalls.isEmpty); XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.shadow, DextProtocol.Forwarding.inert])
        XCTAssertNil(s.fallback); XCTAssertNil(s.latched); XCTAssertEqual(s.pushes, 0)
        XCTAssertTrue(s.unsupportedNote?.hasPrefix("internal: blob rejected locally") == true)

        // The next good blob is pushed as usual.
        offered = good
        queue.sync { s.invalidateMapping() }
        XCTAssertEqual(tap.mapCalls.count, 1); XCTAssertFalse(s.unsupportedHold); XCTAssertNil(s.makeReport().mappingNote)
    }

    func testATwoSourceRemapIsPushedAndStaysOnTheDriverPath() {
        let tap = FakeTap(); let s = make(path: "driver", tap: tap)
        let m = remapped([("g1", .pad(.y))])
        XCTAssertNil(MapBlobEncoder.remapLimit(m))
        s.mappingOffer = { [unowned self] rev in self.offer(of: m, rev) }
        queue.sync { s.connection(up: true) }
        ticks(s, 20)
        XCTAssertEqual(tap.mapCalls.count, 1, "pushed, once")
        XCTAssertEqual(XlateFixtures.validate(tap.mapCalls[0]), 0)
        XCTAssertFalse(s.unsupportedHold)
        let r = s.makeReport()
        XCTAssertNil(r.mappingNote); XCTAssertNil(r.fallback); XCTAssertNil(r.latched)
        XCTAssertEqual(r.armed, "shadow", "this fake driver has no LIVE; the driver path is armed and translating")
        XCTAssertEqual(tap.calls, [DextProtocol.Forwarding.shadow])
    }

    // MARK: T6 review: the owner's pick reaches the engine every time

    private func armCount(_ tap: FakeTap, _ state: UInt64) -> Int { tap.calls.filter { $0 == state }.count }

    func testPickingDriverAgainClearsTheBreakerLatchAndArmsOnce() {
        let clock = Clock(); let tap = FakeTap(nonce: 1000)
        let s = shadowSupervisor(tap, clock: clock)
        queue.sync { s.connection(up: true) }
        for n in [2000, 3000, 4000] as [UInt64] {
            tap.relaunch(nonce: n); clock.ns += 10_000_000_000
            queue.sync { s.connection(up: false); s.connection(up: true) }
        }
        XCTAssertEqual(s.latched, .breaker); XCTAssertTrue(s.tripped)
        ticks(s, 30); XCTAssertEqual(armCount(tap, 2), 1, "still off")
        // the menu: same inputPath text, the choice counter moves, the latch key is removed
        keys.breaker = nil; keys.choice += 1
        ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertNil(s.latched); XCTAssertFalse(s.tripped); XCTAssertNil(s.fallback)
        XCTAssertEqual(armCount(tap, 2), 2, "armed again, once, on the instance that is there now")
        ticks(s, 100)
        XCTAssertEqual(armCount(tap, 2), 2)
        XCTAssertEqual(s.makeReport().armed, "shadow")
    }

    func testPickingDriverAgainEndsAFinalFallbackOnceAndNothingElseDoes() throws {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        for i in 1...3 { try mismatch(s, tap, count: UInt32(i), ts: UInt64(300 + i)); for _ in 0..<5 { step(s, clock, tap, frames) } }
        XCTAssertEqual(s.fallback?.reason, .parityMismatch); XCTAssertNil(s.fallback?.rearmAtNs)
        for _ in 0..<200 { step(s, clock, tap, frames) }
        XCTAssertEqual(armCount(tap, 2), 1, "a final fallback does not heal by itself")
        keys.choice += 1                                                // the owner clicks Driver (already selected)
        for _ in 0..<TapSupervisor.defaultsEveryTicks { step(s, clock, tap, frames) }
        XCTAssertNil(s.fallback); XCTAssertEqual(armCount(tap, 2), 2)
        for _ in 0..<100 { step(s, clock, tap, frames) }
        XCTAssertEqual(armCount(tap, 2), 2, "exactly once")
    }

    func testPickingTheSameItemWithNothingWrongMakesNoCall() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        let callsBefore = tap.calls, mapsBefore = tap.mapCalls.count
        for _ in 0..<3 { keys.choice += 1; for _ in 0..<TapSupervisor.defaultsEveryTicks { step(s, clock, tap, frames) } }
        XCTAssertEqual(tap.calls, callsBefore); XCTAssertEqual(tap.mapCalls.count, mapsBefore)
        XCTAssertNil(s.fallback)
    }

    func testRestartsDuringAnEngineDrillAreNotCountedAndLeaveNoLatch() {
        let clock = Clock(); let tap = FakeTap(nonce: 1000)
        let s = shadowSupervisor(tap, path: "engine", clock: clock)
        queue.sync { s.connection(up: true) }
        for n in 2...6 as ClosedRange<UInt64> {
            tap.relaunch(nonce: n * 1000); clock.ns += 5_000_000_000      // five restarts in 25 s: an upgrade / rollback drill
            queue.sync { s.connection(up: false); s.connection(up: true) }
        }
        XCTAssertNil(s.latched); XCTAssertNil(keys.breaker, "nothing persisted for later")
        XCTAssertFalse(s.tripped)
    }

    func testLeavingTheDriverPathAfterAFallbackDropsTheArmingMark() {
        let clock = Clock(), frames = Counter(); let box = ValueBox("shadow")
        let tap = FakeTap(nonce: 1000)
        let s = make(box, tap: tap, clock: clock); s.mappingOffer = { [unowned self] rev in self.offer(rev) }
        s.engineFrames = { frames.value }
        tap.status.tapPresent = true
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        tap.status.appliedState = 2; clock.ns += 2_000_000_000
        while s.fallback == nil { step(s, clock, tap, frames, stalled: true) }          // F1
        box.value = "engine"
        for _ in 0..<TapSupervisor.defaultsEveryTicks { step(s, clock, tap, frames) }
        XCTAssertNil(s.fallback, "the owner chose App: no fault state is left")
        let limiterEntries = s.makeReport()
        tap.relaunch(nonce: 2000)                                        // a later driver restart
        queue.sync { s.connection(up: false); s.connection(up: true) }
        for _ in 0..<30 { step(s, clock, tap, frames) }
        XCTAssertFalse(s.tripped); XCTAssertNil(s.fallback); XCTAssertNil(limiterEntries.fallback)
        XCTAssertNil(s.makeReport().fallback, "no fallback shown for a path the owner left")
        XCTAssertNil(s.latched)
    }

    func testNothingReadsStatusWhileLatchedAfterAnF2() {
        let clock = Clock()
        let tap = FakeTap(nonce: 1000); tap.status.tapPresent = false
        let s = shadowSupervisor(tap, path: "count", clock: clock)
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        for _ in 0..<400 { clock.ns += 100_000_000; ticks(s, 1) }
        XCTAssertEqual(s.latched, .limiter)
        XCTAssertNil(s.fallback?.rearmAtNs, "latching ends the pending re-arm")
        let before = tap.status2Calls
        for _ in 0..<600 { clock.ns += 100_000_000; ticks(s, 1) }       // 60 s
        XCTAssertEqual(tap.status2Calls - before, 0, "latched: 0 selector-11 calls per second")
    }

    func testCountersGoingBackwardsReallySendsInert() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "shadow", clock: clock, frames: frames)
        for _ in 0..<20 { step(s, clock, tap, frames) }
        tap.status.framesIn = 5
        for _ in 0..<10 { step(s, clock, tap, frames) }
        XCTAssertTrue(s.tripped)
        XCTAssertEqual(tap.calls.last, 0, "the instance may still be armed: INERT goes out")
        XCTAssertEqual(tap.status.desiredState, 0)
    }

    // MARK: T6 review: F2 needs two readings; a wake starts the grace before the first reading

    func testF2NeedsTwoAbsentReadingsAndAStaleOneDoesNotFallBack() {
        let clock = Clock(), frames = Counter()
        let (s, tap) = armedSupervisor(path: "count", clock: clock, frames: frames)
        for _ in 0..<30 { step(s, clock, tap, frames) }
        // one reading lands after the old tap stopped; the engine then hears the interface go away
        tap.status.tapPresent = false
        clock.ns += 1_000_000_000; ticks(s, 10)                          // the 1 Hz reading sees tapPresent == 0
        XCTAssertNil(s.fallback, "one reading is not enough")
        queue.sync { s.controllerInterface(up: false) }                  // the HID-removal callback arrives
        clock.ns += 1_000_000_000; ticks(s, 10)
        XCTAssertNil(s.fallback)
        // and a good reading in between resets the run
        queue.sync { s.controllerInterface(up: true) }
        clock.ns += 2_000_000_000
        tap.status.tapPresent = true; tap.status.appliedState = 1; step(s, clock, tap, frames)
        tap.status.tapPresent = false; clock.ns += 400_000_000; ticks(s, 10)
        tap.status.tapPresent = true; clock.ns += 1_000_000_000; ticks(s, 10)
        tap.status.tapPresent = false; clock.ns += 1_000_000_000; ticks(s, 10)
        XCTAssertNil(s.fallback, "absent, present, absent: never two in a row")
    }

    func testATickGapIsTreatedAsAWakeBeforeTheFirstReading() {
        let clock = Clock(), continuous = Clock(), frames = Counter()
        let tap = FakeTap(nonce: 1000); tap.status.tapPresent = true
        let s = shadowSupervisor(tap, path: "shadow", clock: clock, continuous: continuous)
        s.engineFrames = { frames.value }
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        tap.status.appliedState = 2; ticks(s, 1); clock.ns += 2_000_000_000
        for _ in 0..<20 { step(s, clock, tap, frames) }; continuous.ns += 2_000_000_000
        // the Mac slept for a minute: the engine clock stood still, the continuous clock jumped
        continuous.ns += 60_000_000_000
        tap.status.tapPresent = false                                    // the old tap stopped; the removal callback has not run
        for _ in 0..<12 { clock.ns += 100_000_000; continuous.ns += 100_000_000; ticks(s, 1) }
        print("DBG fallback=\(String(describing: s.fallback)) reads=\(tap.status2Calls)")
        XCTAssertNil(s.fallback, "the gap restarted the grace period before the first post-wake reading")
        tap.status.tapPresent = true
        for _ in 0..<20 { step(s, clock, tap, frames) }
        XCTAssertNil(s.fallback)
    }

    // MARK: T7: LIVE

    private final class Drives: @unchecked Sendable { var events: [Bool] = [] }

    /// A supervisor on a LIVE-capable fake dext, path `driver`, SHADOW sent and the mapping pushed and applied. The fake's tap applies
    /// what it is told at once and moves padSource like the real one.
    private func liveSupervisor(path: String = "driver", clock: Clock, frames: Counter, drives: Drives, hasLive: Bool = true,
                                tap: FakeTap = FakeTap(nonce: 1000)) -> (TapSupervisor, FakeTap, LiveWatch) {
        tap.hasLive = hasLive; tap.autoApply = true
        tap.status.tapPresent = true; tap.status.padLive = true; tap.status.ownerPresent = true; tap.status.selfTest = DextProtocol.SelfTest.pass
        tap.status.padSpecCRC = 0x77; tap.status.padSource = 1
        let s = shadowSupervisor(tap, path: path, clock: clock)
        let watch = LiveWatch(); s.liveWatch = watch
        s.engineFrames = { frames.value }
        s.onDrive = { drives.events.append($0) }
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        ticks(s, 1)
        tap.status.acceptedSpecCRC = 0x77
        tap.status.appliedRevision = tap.status.acceptedRevision
        return (s, tap, watch)
    }

    /// One 100 ms step in which the engine's reader sees `perTick` frames and the (fake) tap translates and counts them.
    private func liveStep(_ s: TapSupervisor, _ clock: Clock, _ tap: FakeTap, _ frames: Counter, perTick: UInt64 = 91, stalled: Bool = false) {
        clock.ns += 100_000_000
        frames.value += perTick
        if !stalled { tap.status.framesIn += perTick; tap.status.framesTranslated += perTick }
        if !tap.freezeApplied { tap.status.appliedRevision = tap.status.acceptedRevision }          // the tap applies a pushed mapping at its next frame
        ticks(s, 1)
    }

    private func runLive(_ s: TapSupervisor, _ clock: Clock, _ tap: FakeTap, _ frames: Counter, steps: Int) {
        for _ in 0..<steps { liveStep(s, clock, tap, frames) }
    }

    func testDriverPathGoesShadowThenLiveAfterTwoSecondsAnd100FramesAndClosesTheGate() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        XCTAssertEqual(tap.calls, [2], "SHADOW first")
        runLive(s, clock, tap, frames, steps: 18)                            // 1.8 s
        XCTAssertEqual(tap.calls, [2], "not before 2 s of SHADOW"); XCTAssertTrue(drives.events.isEmpty)
        runLive(s, clock, tap, frames, steps: 4)
        XCTAssertEqual(tap.calls, [2, 3], "LIVE once SHADOW ran 2 s with >= 100 frames and 0 mismatches")
        XCTAssertEqual(drives.events, [true], "the posting gate closes right after the dext accepted LIVE")
        XCTAssertEqual(s.makeReport().armed, "live"); XCTAssertEqual(s.makeReport().path, "driver")
    }

    func testNoLiveFromADriverWithoutCapLive() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives, hasLive: false)
        runLive(s, clock, tap, frames, steps: 80)
        XCTAssertEqual(tap.calls, [2]); XCTAssertTrue(drives.events.isEmpty)
        XCTAssertTrue(s.makeReport().liveUnavailable)
    }

    func testLiveWaitsForEveryCondition() throws {
        let conditions: [(String, (FakeTap) -> Void)] = [
            ("mapping not applied", { $0.freezeApplied = true; $0.status.appliedRevision = 0 }),
            ("spec crc differs", { $0.status.acceptedSpecCRC = 0x78 }),
            ("no map", { $0.status.hasMap = false }),     // (the supervisor re-pushes; the fake accepts and sets it again, so the check below is on appliedRevision)
            ("self-test not passed", { $0.status.selfTest = DextProtocol.SelfTest.notRun }),
            ("pad not live", { $0.status.padLive = false }),
            ("tap absent", { $0.status.tapPresent = false }),
        ]
        for (name, mutate) in conditions where name != "no map" {
            let clock = Clock(), frames = Counter(), drives = Drives()
            let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
            for _ in 0..<60 { liveStep(s, clock, tap, frames); mutate(tap) }
            XCTAssertFalse(tap.calls.contains(3), name)
            XCTAssertTrue(drives.events.isEmpty, name)
        }
        // too few frames in SHADOW
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        for _ in 0..<60 { liveStep(s, clock, tap, frames, perTick: 1) }       // 60 frames in 6 s
        XCTAssertFalse(tap.calls.contains(3), "fewer than 100 translated frames")
    }

    func testAParityMismatchDuringShadowDelaysLive() throws {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        runLive(s, clock, tap, frames, steps: 5)
        try mismatch(s, tap, count: 1, ts: 900)
        runLive(s, clock, tap, frames, steps: 60)
        XCTAssertFalse(tap.calls.contains(3), "one mismatch since SHADOW was armed: LIVE is not asked for")
    }

    func testLiveRefusalsAreHandledPerAnswer() {
        // NotReady: asked again about a second later; SHADOW goes on
        do {
            let clock = Clock(), frames = Counter(), drives = Drives()
            let tap = FakeTap(nonce: 1000); tap.liveResult = DextProtocol.krNotReady
            let (s, _, _) = liveSupervisor(clock: clock, frames: frames, drives: drives, tap: tap)
            runLive(s, clock, tap, frames, steps: 22)
            XCTAssertEqual(tap.liveAsked, 1)
            runLive(s, clock, tap, frames, steps: 4); XCTAssertEqual(tap.liveAsked, 1, "not within a second")
            runLive(s, clock, tap, frames, steps: 10); XCTAssertEqual(tap.liveAsked, 2)
            XCTAssertTrue(drives.events.isEmpty); XCTAssertNil(s.fallback)
            tap.liveResult = nil
            runLive(s, clock, tap, frames, steps: 20); XCTAssertEqual(drives.events, [true])
        }
        // BadArgument (the accepted mapping targets another pad): the mapping is pushed again, LIVE retried after 2 s
        do {
            let clock = Clock(), frames = Counter(), drives = Drives()
            let tap = FakeTap(nonce: 1000); tap.liveResult = DextProtocol.krBadArgument
            let (s, _, _) = liveSupervisor(clock: clock, frames: frames, drives: drives, tap: tap)
            let before = tap.mapCalls.count
            runLive(s, clock, tap, frames, steps: 40)
            XCTAssertGreaterThan(tap.mapCalls.count, before, "re-pushed"); XCTAssertLessThanOrEqual(tap.liveAsked, 3)
            XCTAssertNil(s.fallback)
        }
        // NotPermitted: final fallback, INERT
        do {
            let clock = Clock(), frames = Counter(), drives = Drives()
            let tap = FakeTap(nonce: 1000); tap.liveResult = DextProtocol.krNotPermitted
            let (s, _, _) = liveSupervisor(clock: clock, frames: frames, drives: drives, tap: tap)
            runLive(s, clock, tap, frames, steps: 30)
            XCTAssertEqual(tap.calls.last, 0); XCTAssertNil(s.fallback?.rearmAtNs)
            if case .driverRefused? = s.fallback?.reason {} else { XCTFail("\(String(describing: s.fallback))") }
        }
        // Unsupported: stays in SHADOW and is not asked again
        do {
            let clock = Clock(), frames = Counter(), drives = Drives()
            let tap = FakeTap(nonce: 1000); tap.liveResult = DextProtocol.krUnsupported
            let (s, _, _) = liveSupervisor(clock: clock, frames: frames, drives: drives, tap: tap)
            runLive(s, clock, tap, frames, steps: 80)
            XCTAssertEqual(tap.liveAsked, 1); XCTAssertNil(s.fallback); XCTAssertTrue(drives.events.isEmpty)
        }
    }

    private func goLive(_ s: TapSupervisor, _ clock: Clock, _ tap: FakeTap, _ frames: Counter) {
        runLive(s, clock, tap, frames, steps: 25)
        XCTAssertEqual(tap.calls.last, 3, "precondition: LIVE")
    }

    func testF1StallInLiveFallsBackToCountWithin400msOpensTheGateAndRearmsThroughShadow() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        runLive(s, clock, tap, frames, steps: 20)
        XCTAssertNil(s.fallback)
        let readsBefore = tap.status2Calls
        var n = 0
        while s.fallback == nil, n < 20 { liveStep(s, clock, tap, frames, stalled: true); n += 1 }
        XCTAssertEqual(s.fallback?.reason, .stall)
        XCTAssertLessThanOrEqual(n, 4, "a 200 ms window, one confirmation, read every 100 ms: the pause drill's 300 ms target (G10)")
        XCTAssertEqual(tap.calls.last, 1, "LIVE falls back to COUNT: the tap keeps counting"); XCTAssertEqual(drives.events, [true, false], "the engine posts again at once")
        XCTAssertGreaterThanOrEqual(tap.status2Calls - readsBefore, n, "LIVE reads status2 every tick")
        XCTAssertEqual(s.makeReport().armed, "inert", "not armed while the fallback lasts"); XCTAssertEqual(s.makeReport().fallback, "tap stalled")
        // 5 s hold-off, then SHADOW (never straight back to LIVE), then LIVE after 2 s of agreement
        for _ in 0..<45 { liveStep(s, clock, tap, frames) }
        XCTAssertEqual(tap.calls.last, 1)
        for _ in 0..<12 { liveStep(s, clock, tap, frames) }
        XCTAssertEqual(tap.calls.suffix(2), [1, 2], "re-armed into SHADOW")
        runLive(s, clock, tap, frames, steps: 30)
        XCTAssertEqual(tap.calls.last, 3, "and LIVE again after the warm-up"); XCTAssertEqual(drives.events, [true, false, true])
    }

    func testF2AndTheStatusSourceTestsFallBackToCountFromLive() {
        // F2
        do {
            let clock = Clock(), frames = Counter(), drives = Drives()
            let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
            goLive(s, clock, tap, frames)
            tap.status.tapPresent = false
            runLive(s, clock, tap, frames, steps: 8)
            XCTAssertEqual(s.fallback?.reason, .tapAbsent); XCTAssertEqual(tap.calls.last, 1)
        }
    }

    func testF6OutputStallInEveryForm() {
        func armedLive(_ body: (TapSupervisor, FakeTap, LiveWatch, Clock, Counter) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            let clock = Clock(), frames = Counter(), drives = Drives()
            let (s, tap, watch) = liveSupervisor(clock: clock, frames: frames, drives: drives)
            goLive(s, clock, tap, frames)
            body(s, tap, watch, clock, frames)
            XCTAssertEqual(s.fallback?.reason, .outputStall, file: file, line: line)
            XCTAssertEqual(tap.calls.last, 1, "COUNT", file: file, line: line); XCTAssertEqual(drives.events.last, false, file: file, line: line)
        }
        // the engine's own step would have posted, the driver's tapPosts does not move
        armedLive { s, tap, watch, clock, frames in
            for _ in 0..<10 { watch.wouldPostReports += 2; liveStep(s, clock, tap, frames) }
        }
        // padSource is no longer TAP
        armedLive { s, tap, _, clock, frames in tap.status.padSource = 1; for _ in 0..<3 { liveStep(s, clock, tap, frames) } }
        // appliedState differs from LIVE for longer than 300 ms
        armedLive { s, tap, _, clock, frames in tap.status.appliedState = 2; for _ in 0..<8 { liveStep(s, clock, tap, frames) } }
        // framesIgnored rises while the tap says it is powered
        armedLive { s, tap, _, clock, frames in
            tap.status.powered = true
            for _ in 0..<5 { tap.status.framesIgnored += 50; liveStep(s, clock, tap, frames) }
        }
    }

    func testF6IsQuietWhenTheDriverKeepsPostingAndForShortGlitches() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, watch) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        for _ in 0..<50 { watch.wouldPostReports += 2; tap.status.tapPosts += 2; liveStep(s, clock, tap, frames) }
        XCTAssertNil(s.fallback)
        for _ in 0..<5 { watch.wouldPostReports += 1; liveStep(s, clock, tap, frames) }         // 1 report per window: below the threshold
        XCTAssertNil(s.fallback)
        tap.status.appliedState = 2; for _ in 0..<2 { liveStep(s, clock, tap, frames) }          // 200 ms of disagreement
        tap.status.appliedState = 3; for _ in 0..<10 { liveStep(s, clock, tap, frames) }
        XCTAssertNil(s.fallback, "appliedState must differ for more than 300 ms")
    }

    func testF4AndF5InLiveFallBackToInertNotCount() throws {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        for i in 1...3 { try mismatch(s, tap, count: UInt32(i), ts: UInt64(700 + i)); for _ in 0..<2 { liveStep(s, clock, tap, frames) } }
        XCTAssertEqual(s.fallback?.reason, .parityMismatch)
        XCTAssertEqual(tap.calls.last, 0, "INERT"); XCTAssertEqual(drives.events, [true, false])
        XCTAssertNil(s.fallback?.rearmAtNs)
    }

    func testAMappingThatBecomesUnsupportedTakesTheDriverPathDownAndTheEnginePosts() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        s.mappingOffer = { _ in .unsupported("echo suppression") }
        queue.sync { s.invalidateMapping() }
        XCTAssertEqual(tap.calls.last, 0, "INERT: the driver clears its map and the engine path resumes")
        XCTAssertEqual(drives.events, [true, false]); XCTAssertEqual(s.makeReport().mappingNote, "echo suppression")
        XCTAssertNil(s.fallback, "not a fault")
        runLive(s, clock, tap, frames, steps: 80)
        XCTAssertEqual(tap.calls.last, 0, "and it stays down while the mapping is unsupported")
        s.mappingOffer = { [unowned self] rev in self.offer(rev) }
        queue.sync { s.invalidateMapping() }
        runLive(s, clock, tap, frames, steps: 40)
        XCTAssertEqual(tap.calls.last, 3, "the mapping is expressible again: SHADOW, then LIVE")
    }

    func testStartupStayLiveAdoptsTheDriversStateWithoutAnyCallAndPushesTheMapping() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let tap = FakeTap(nonce: 5000); tap.hasLive = true; tap.autoApply = true
        tap.status.tapPresent = true; tap.status.padLive = true; tap.status.ownerPresent = true; tap.status.selfTest = DextProtocol.SelfTest.pass
        tap.status.desiredState = 3; tap.status.appliedState = 3; tap.status.padSource = 2; tap.status.padSpecCRC = 0x77
        let s = shadowSupervisor(tap, path: "driver", clock: clock)
        s.onDrive = { drives.events.append($0) }; s.padAdopted = { true }; s.liveWatch = LiveWatch()
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        XCTAssertTrue(tap.calls.isEmpty, "no setForwarding at all: no SHADOW warm-up, no neutral, no interruption")
        XCTAssertEqual(drives.events, [true]); XCTAssertEqual(s.makeReport().armed, "live")
        XCTAssertEqual(tap.mapCalls.count, 1, "the engine's current mapping goes to the driver at once")
        // the instance is armed: a restart of the driver trips instead of re-arming
        tap.relaunch(nonce: 6000)
        queue.sync { s.connection(up: false); s.connection(up: true) }
        XCTAssertTrue(s.tripped)
    }

    func testStartupStayLiveNeedsEveryCondition() {
        func attempt(path: String = "driver", adopted: Bool = true, hasLive: Bool = true, _ mutate: (FakeTap) -> Void = { _ in }) -> (FakeTap, Drives) {
            let clock = Clock(), drives = Drives()
            let tap = FakeTap(nonce: 5000); tap.hasLive = hasLive; tap.autoApply = true
            tap.status.tapPresent = true; tap.status.padLive = true; tap.status.ownerPresent = true; tap.status.selfTest = DextProtocol.SelfTest.pass
            tap.status.desiredState = 3; tap.status.appliedState = 3; tap.status.padSource = 2; tap.status.padSpecCRC = 0x77
            mutate(tap)
            let s = shadowSupervisor(tap, path: path, clock: clock)
            s.onDrive = { drives.events.append($0) }; s.padAdopted = { adopted }; s.liveWatch = LiveWatch()
            queue.sync { s.connection(up: true) }
            return (tap, drives)
        }
        let (ok, okDrives) = attempt(); XCTAssertTrue(ok.calls.isEmpty); XCTAssertEqual(okDrives.events, [true])
        for (name, r) in [("not adopted", attempt(adopted: false)), ("path shadow", attempt(path: "shadow")), ("path engine", attempt(path: "engine")),
                          ("no CAP_LIVE", attempt(hasLive: false)), ("self-test not passed", attempt { $0.status.selfTest = 0 }),
                          ("source UC", attempt { $0.status.padSource = 1 }), ("applied SHADOW", attempt { $0.status.appliedState = 2 }),
                          ("desired SHADOW", attempt { $0.status.desiredState = 2 }), ("pad not live", attempt { $0.status.padLive = false }),
                          ("no owner", attempt { $0.status.ownerPresent = false }), ("tap absent", attempt { $0.status.tapPresent = false })] {
            XCTAssertFalse(r.1.events.contains(true), "\(name): not stay-LIVE")
            XCTAssertFalse(r.0.calls.contains(3), "\(name): LIVE is never sent without the warm-up")
        }
        // an adopted LIVE pad on a path that is not `driver`: the supervisor takes it down properly (INERT: source UC, neutral)
        let (down, _) = attempt(path: "engine"); XCTAssertEqual(down.calls, [0])
    }

    func testPauseDrillCarriesTheCurrentStateAndFallsBackThenRearms() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        tap.supportsPauseDrill = true
        goLive(s, clock, tap, frames)
        keys.drill = "pause5"
        runLive(s, clock, tap, frames, steps: 10)
        XCTAssertEqual(tap.pauseCalls, [5000]); XCTAssertEqual(tap.pauseStates, [3], "the pause flag goes with the state the tap is in")
        XCTAssertEqual(keys.drillCleared, 1)
    }

    func testWakeAsksForLiveAgainToClearTheHold() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        let n = tap.calls.count
        queue.sync { s.didWake() }
        XCTAssertEqual(tap.calls.count, n + 1); XCTAssertEqual(tap.calls.last, 3, "idempotent in the driver: it only clears the hold")
        XCTAssertNil(s.fallback)
    }

    func testLeavingTheDriverPathFromLiveSendsInertAndOpensTheGate() {
        let clock = Clock(), frames = Counter(), drives = Drives(); let box = ValueBox("driver")
        let tap = FakeTap(nonce: 1000)
        tap.hasLive = true; tap.autoApply = true; tap.status.tapPresent = true; tap.status.padLive = true; tap.status.selfTest = DextProtocol.SelfTest.pass
        tap.status.padSpecCRC = 0x77; tap.status.padSource = 1; tap.status.ownerPresent = true
        let s = make(box, tap: tap, clock: clock); s.mappingOffer = { [unowned self] rev in self.offer(rev) }
        s.engineFrames = { frames.value }; s.onDrive = { drives.events.append($0) }; s.liveWatch = LiveWatch()
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        ticks(s, 1); tap.status.acceptedSpecCRC = 0x77; tap.status.appliedRevision = tap.status.acceptedRevision
        goLive(s, clock, tap, frames)
        box.value = "engine"
        for _ in 0..<12 { liveStep(s, clock, tap, frames) }
        XCTAssertEqual(tap.calls.last, 0); XCTAssertEqual(drives.events, [true, false])
        // and a clean exit from LIVE: INERT first
        let clock2 = Clock(), frames2 = Counter(), drives2 = Drives()
        let (s2, tap2, _) = liveSupervisor(clock: clock2, frames: frames2, drives: drives2)
        goLive(s2, clock2, tap2, frames2)
        queue.sync { s2.shutdown() }
        XCTAssertEqual(tap2.calls.last, 0); XCTAssertEqual(drives2.events, [true, false])
    }

    func testAConnectionLostWhileLiveOpensTheGateAndTheRestartTrips() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        queue.sync { s.connection(up: false) }
        XCTAssertEqual(drives.events, [true, false])
        tap.relaunch(nonce: 2000)
        queue.sync { s.connection(up: true) }
        XCTAssertTrue(s.tripped, "a new dext instance is never armed again (its pad died with it)")
        XCTAssertFalse(tap.calls.suffix(1).contains(3))
    }

    func testStatusReadsTenTimesASecondInLive() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        let before = tap.status2Calls
        runLive(s, clock, tap, frames, steps: 50)
        XCTAssertEqual(tap.status2Calls - before, 50, "every tick: 10 Hz while the engine posts nothing")
    }

    // MARK: Review E2-E7

    /// E2: the controller going off and on (the tap goes away and comes back as a new instance, its counters restart or jump) and a
    /// Mac sleep with its wake never trip F6 (or anything else) in LIVE; three cycles of each.
    func testF6StaysQuietAcrossControllerOffOnAndSleepWakeCycles() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        let callsBefore = tap.calls
        for cycle in 1...3 {
            // controller off: the tap goes away (appliedState INERT, padSource stays TAP), the engine sees no frames, a while passes
            queue.sync { s.controllerInterface(up: false) }
            tap.status.tapPresent = false; tap.status.appliedState = 0
            for _ in 0..<6 { liveStep(s, clock, tap, frames, perTick: 0, stalled: true) }
            XCTAssertNil(s.fallback, "cycle \(cycle): tap gone")
            // controller on: a NEW tap instance (tapStarts +1), its first frames are ignored while it comes up
            queue.sync { s.controllerInterface(up: true) }
            tap.status.tapPresent = true; tap.status.tapStarts += 1; tap.status.appliedState = 3
            tap.status.framesIgnored += 7                          // the process-wide counters never go backwards; the new instance ignored its first frames
            for _ in 0..<15 { liveStep(s, clock, tap, frames) }
            XCTAssertNil(s.fallback, "cycle \(cycle): tap back")
            // Mac sleep: the tap powers off and counts the frames it ignores; the engine wakes, the supervisor is told
            tap.status.powered = false
            for _ in 0..<4 { tap.status.framesIgnored += 40; liveStep(s, clock, tap, frames, perTick: 0, stalled: true) }
            tap.status.powered = true
            queue.sync { s.didWake() }
            for _ in 0..<15 { liveStep(s, clock, tap, frames) }
            XCTAssertNil(s.fallback, "cycle \(cycle): asleep and awake")
        }
        XCTAssertEqual(drives.events, [true], "the gate never opened")
        XCTAssertTrue(tap.calls.dropFirst(callsBefore.count).allSatisfy { $0 == 3 }, "only the wake's idempotent LIVE: \(tap.calls)")
        XCTAssertEqual(tap.calls.dropFirst(callsBefore.count).count, 3, "one per wake")
    }

    /// E2: a real stall of the framesIgnored kind is still caught: the same instance, powered on both readings.
    func testFramesIgnoredRisingOnOneInstanceWhilePoweredStillTripsF6() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        tap.status.powered = true
        for _ in 0..<4 { tap.status.framesIgnored += 30; liveStep(s, clock, tap, frames) }
        XCTAssertEqual(s.fallback?.reason, .outputStall)
        XCTAssertEqual(tap.calls.last, 1, "COUNT")
    }

    /// E3: a pinned pad nobody owns is waiting and the engine has none: nothing is sent to the driver until the sink adopts it (the
    /// pad is published on the first controller report), for at most one second after that report; adoption then stays LIVE.
    func testStartupDefersForAnUnownedPinnedPadThenStaysLiveWhenThePadIsPublished() {
        let clock = Clock(), drives = Drives()
        func pinned(hasPadNow: Bool = false) -> (TapSupervisor, FakeTap) {
            let tap = FakeTap(nonce: 5000); tap.hasLive = true; tap.autoApply = true
            tap.status.tapPresent = true; tap.status.padLive = true; tap.status.ownerPresent = true; tap.status.selfTest = DextProtocol.SelfTest.pass
            tap.status.desiredState = 3; tap.status.appliedState = 3; tap.status.padSource = 2; tap.status.padSpecCRC = 0x77
            tap.status.padOrphaned = true
            let s = shadowSupervisor(tap, path: "driver", clock: clock)
            s.onDrive = { drives.events.append($0) }; s.liveWatch = LiveWatch()
            return (s, tap)
        }
        // restart in LIVE with the real-time thread holding: the connection comes up before any controller report
        let (s, tap) = pinned()
        queue.sync { s.connection(up: true) }
        ticks(s, 30)
        XCTAssertTrue(tap.calls.isEmpty, "waiting for the pad, nothing is sent: no SHADOW over a LIVE pad, no INERT")
        // the first controller report arrives; the sink creates its device and adopts the pad
        queue.sync { s.controllerActive() }
        clock.ns += 400_000_000; ticks(s, 4)
        XCTAssertTrue(tap.calls.isEmpty, "still inside the window")
        s.padAdopted = { true }; s.sinkHasPad = { true }
        tap.status.padOrphaned = false
        queue.sync { s.padPublished() }
        XCTAssertTrue(tap.calls.isEmpty, "adopted: stays LIVE without a single call"); XCTAssertEqual(drives.events, [true])
        XCTAssertEqual(s.makeReport().armed, "live"); XCTAssertEqual(tap.mapCalls.count, 1)
        // when no adoption happens the window ends (about a second after the first report) and the normal path takes over
        drives.events = []
        let (s2, tap2) = pinned()
        queue.sync { s2.connection(up: true); s2.controllerActive() }
        clock.ns += 900_000_000; ticks(s2, 3)
        XCTAssertTrue(tap2.calls.isEmpty, "before the second is over")
        clock.ns += 400_000_000; ticks(s2, 5)
        XCTAssertFalse(tap2.calls.isEmpty, "the window ended: the engine goes on by the normal rules")
        XCTAssertFalse(tap2.calls.contains(3), "and never LIVE without the warm-up")
    }

    /// R1: the engine is on a path that never asks for the driver (the runtime rollback during a crash loop: `engine`) and a LIVE pinned
    /// pad is waiting. INERT after hello had no effect (not the owner yet), the sink then adopts the pad at the first controller
    /// report: INERT must be sent again, now that the pad is ours.
    func testEnginePathAdoptsALivePinnedPadLaterAndTakesItBackWithInertAgain() {
        for path in ["engine", "count", "shadow"] {
            let clock = Clock()
            let tap = FakeTap(nonce: 5000); tap.hasLive = true; tap.autoApply = true; tap.noEffectUntilOwned = true
            tap.status.tapPresent = true; tap.status.padLive = true; tap.status.ownerPresent = true; tap.status.selfTest = DextProtocol.SelfTest.pass
            tap.status.desiredState = 3; tap.status.appliedState = 3; tap.status.padSource = 2; tap.status.padSpecCRC = 0x77; tap.status.padOrphaned = true
            let s = shadowSupervisor(tap, path: path, clock: clock); s.liveWatch = LiveWatch()
            queue.sync { s.connection(up: true) }
            if path == "engine" { XCTAssertEqual(tap.calls, [0], "INERT after hello (success with no effect: not the pad's owner yet)") }
            XCTAssertEqual(tap.status.padSource, 2, "\(path): still the tap's")
            // first controller report: the sink auto-publishes and ADOPTS the TAP-driven pad
            s.padAdopted = { true }; s.sinkHasPad = { true }; tap.status.padOrphaned = false; tap.noEffectUntilOwned = false
            let before = tap.calls.count
            clock.ns += 1_100_000_000                                  // past the one-second back-off of a refused call
            queue.sync { s.controllerActive(); s.padPublished() }
            ticks(s, 30)
            XCTAssertGreaterThan(tap.calls.count, before, "\(path): the wanted state is sent again: \(tap.calls)")
            guard tap.calls.count > before else { continue }
            XCTAssertEqual(tap.calls[before], path == "engine" ? 0 : (path == "count" ? 1 : 2), "\(path)")
            XCTAssertEqual(tap.status.desiredState, path == "engine" ? 0 : (path == "count" ? 1 : 2), "\(path)")
            XCTAssertEqual(tap.status.padSource, 1, "\(path): the pad is the engine's again (source UC)")
            XCTAssertNotEqual(tap.status.appliedState, 3)
        }
        // an adopted LIVE pad on the driver path is NOT taken back: it stays LIVE (the startup stay-LIVE case)
        let clock = Clock()
        let tap = FakeTap(nonce: 5000); tap.hasLive = true; tap.autoApply = true
        tap.status.tapPresent = true; tap.status.padLive = true; tap.status.ownerPresent = true; tap.status.selfTest = DextProtocol.SelfTest.pass
        tap.status.desiredState = 3; tap.status.appliedState = 3; tap.status.padSource = 2; tap.status.padSpecCRC = 0x77; tap.status.padOrphaned = true
        let s = shadowSupervisor(tap, path: "driver", clock: clock); s.liveWatch = LiveWatch()
        queue.sync { s.connection(up: true) }
        s.padAdopted = { true }; s.sinkHasPad = { true }; tap.status.padOrphaned = false
        queue.sync { s.controllerActive(); s.padPublished() }
        ticks(s, 10)
        XCTAssertTrue(tap.calls.isEmpty, "stay-LIVE sends nothing: \(tap.calls)")
    }

    /// R2: the engine's willSleep hold stalls the driver's posts on purpose (the tap is still powered until the system sleeps); F6 must
    /// neither fall back nor count it, and what happened before the hold is not compared with what comes after it.
    func testF6IgnoresTheEnginesOwnWillSleepHold() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, watch) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        for _ in 0..<5 { watch.wouldPostReports += 2; tap.status.tapPosts += 2; liveStep(s, clock, tap, frames) }
        tap.status.holdNeutral = true                              // postNeutral while the tap drives: the hold
        for _ in 0..<20 { watch.wouldPostReports += 2; tap.status.framesIgnored += 3; liveStep(s, clock, tap, frames) }   // tapPosts does not move
        XCTAssertNil(s.fallback, "controller input between willSleep and the tap's power-off is not a stall")
        // the wake clears the hold; the driver posts again and nothing from before the hold counts against it
        tap.status.holdNeutral = false
        queue.sync { s.didWake() }
        for _ in 0..<30 { watch.wouldPostReports += 2; tap.status.tapPosts += 2; liveStep(s, clock, tap, frames) }
        XCTAssertNil(s.fallback); XCTAssertEqual(drives.events, [true])
        // and a real stall after the hold is over is still caught
        for _ in 0..<10 { watch.wouldPostReports += 2; liveStep(s, clock, tap, frames) }
        XCTAssertEqual(s.fallback?.reason, .outputStall)
    }

    func testNoDeferralWithoutAnOrphanOrWhenThePadIsAlreadyOurs() {
        let clock = Clock()
        let tap = FakeTap(nonce: 5000); tap.hasLive = true; tap.autoApply = true
        tap.status.tapPresent = true; tap.status.padLive = true; tap.status.ownerPresent = true; tap.status.selfTest = DextProtocol.SelfTest.pass
        tap.status.padSource = 1; tap.status.padSpecCRC = 0x77; tap.status.padOrphaned = false
        let s = shadowSupervisor(tap, path: "driver", clock: clock); s.liveWatch = LiveWatch()
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [2], "no orphan: SHADOW right away as before")
    }

    /// E4: an adopted LIVE session has F6 on: the engine's own step counts what should be posted and a driver that stops posting
    /// is caught like in any other LIVE session.
    func testAnAdoptedLiveSessionEnablesTheWatchAndDetectsAnOutputStall() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let tap = FakeTap(nonce: 5000); tap.hasLive = true; tap.autoApply = true
        tap.status.tapPresent = true; tap.status.padLive = true; tap.status.ownerPresent = true; tap.status.selfTest = DextProtocol.SelfTest.pass
        tap.status.desiredState = 3; tap.status.appliedState = 3; tap.status.padSource = 2; tap.status.padSpecCRC = 0x77
        let s = shadowSupervisor(tap, path: "driver", clock: clock)
        let watch = LiveWatch(); s.liveWatch = watch
        s.engineFrames = { frames.value }
        s.onDrive = { drives.events.append($0) }; s.padAdopted = { true }
        queue.sync { s.controllerInterface(up: true); s.connection(up: true) }
        XCTAssertTrue(watch.enabled, "F6 is on for an adopted session")
        tap.status.acceptedSpecCRC = 0x77; tap.status.appliedRevision = tap.status.acceptedRevision
        // the driver posts as it should
        for _ in 0..<30 { watch.wouldPostReports += 2; tap.status.tapPosts += 2; liveStep(s, clock, tap, frames) }
        XCTAssertNil(s.fallback)
        // the driver stops posting while the engine's own step keeps counting
        for _ in 0..<10 { watch.wouldPostReports += 2; liveStep(s, clock, tap, frames) }
        XCTAssertEqual(s.fallback?.reason, .outputStall)
        XCTAssertEqual(drives.events.last, false); XCTAssertFalse(watch.enabled)
    }

    /// E5: whenever LIVE was in force and the wanted state is not LIVE, the posting gate opens, whatever the driver answers.
    func testTheGateOpensWhenLiveEndsEvenIfTheDriverDoesNotAnswer() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, _) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        tap.setResult = FakeTap.transportError                      // the next state request fails at the transport
        var n = 0
        while s.fallback == nil, n < 20 { liveStep(s, clock, tap, frames, stalled: true); n += 1 }
        XCTAssertEqual(s.fallback?.reason, .stall)
        XCTAssertEqual(drives.events, [true, false], "the engine posts again although COUNT was not confirmed")
    }

    /// E6: a new driver instance seen without a connection drop ends LIVE for the gate too.
    func testANewInstanceSeenInLiveOpensTheGate() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, watch) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        tap.relaunch(nonce: 2000)                                  // replaced under our feet; the connection did not drop
        tap.status.tapPresent = true
        ticks(s, 12)
        XCTAssertTrue(s.tripped); XCTAssertEqual(drives.events, [true, false]); XCTAssertFalse(watch.enabled)
    }

    /// E7: the sink opened the gate by itself (device gone): the supervisor forgets what it armed, no fallback, no limiter entry, and
    /// starts again from SHADOW.
    func testAGateForcedOpenBySinkStartsTheDriverPathAgainWithoutAFallback() {
        let clock = Clock(), frames = Counter(), drives = Drives()
        let (s, tap, watch) = liveSupervisor(clock: clock, frames: frames, drives: drives)
        goLive(s, clock, tap, frames)
        let n = tap.calls.count
        queue.sync { s.gateForcedOpen() }
        XCTAssertNil(s.fallback); XCTAssertFalse(s.tripped); XCTAssertFalse(watch.enabled)
        XCTAssertEqual(tap.calls.count, n, "nothing is sent for it (the driver left LIVE with the pad)")
        tap.status.desiredState = 0; tap.status.appliedState = 0; tap.status.padSource = 1
        runLive(s, clock, tap, frames, steps: 5)
        XCTAssertEqual(tap.calls.dropFirst(n).first, 2, "SHADOW again")
        XCTAssertNil(s.fallback)
        queue.sync { s.gateForcedOpen() }; queue.sync { s.gateForcedOpen() }       // idempotent
        XCTAssertNil(s.fallback)
    }

    // MARK: M1: no re-arm after a relaunch

    /// The dext crashed or was replaced while COUNT was armed. The reconnect must NOT send COUNT again: with a crash in the
    /// COUNT path that would be a crash loop at the reconnect back-off.
    func testRelaunchedDextIsNotRearmed() {
        let tap = FakeTap(nonce: 1000)
        let s = make(path: "count", tap: tap)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls, [1])
        queue.sync { s.connection(up: false) }                  // the dext died
        tap.relaunch(nonce: 2000)
        queue.sync { s.connection(up: true) }
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [1])
        XCTAssertTrue(s.tripped)
        ticks(s, 100)
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [1], "still INERT 10 s later, however long inputPath says count")
        XCTAssertEqual(tap.status.desiredState, 0)
    }

    func testRelaunchWithoutAConnectionDropIsDetectedByTheNonce() {
        let tap = FakeTap(nonce: 1000)
        let s = make(path: "count", tap: tap)
        queue.sync { s.connection(up: true) }
        tap.relaunch(nonce: 2000)                                // the connection did not notice
        ticks(s, TapSupervisor.statusEveryTicks)                 // the 1 Hz status read does
        XCTAssertTrue(s.tripped)
        ticks(s, 50)
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [1])
    }

    /// The trip clears when the stored value changes (the owner's gesture) or the engine restarts; then COUNT is sent once.
    func testRewritingInputPathRearmsOnce() {
        let tap = FakeTap(nonce: 1000); let box = ValueBox("count")
        let s = make(box, tap: tap)
        queue.sync { s.connection(up: true); s.connection(up: false) }
        tap.relaunch(nonce: 2000)
        queue.sync { s.connection(up: true) }
        XCTAssertTrue(s.tripped); XCTAssertEqual(tap.calls.filter { $0 != 0 }, [1])
        // the same stored value: nothing happens
        ticks(s, 30); XCTAssertTrue(s.tripped); XCTAssertEqual(tap.calls.filter { $0 != 0 }, [1])
        // engine, then count: re-armed once, on the NEW instance
        box.value = "engine"; ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertFalse(s.tripped)
        box.value = "count"; ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertEqual(tap.calls.filter { $0 != 0 }, [1, 1], "COUNT again, once, on the new instance")
        XCTAssertEqual(tap.status.desiredState, 1)
        ticks(s, 100)
        XCTAssertEqual(tap.calls.filter { $0 == 1 }.count, 2, "COUNT was sent exactly twice in all: once before the trip, once after the rewrite")
        XCTAssertFalse(s.tripped)
    }

    func testADifferentSpellingOfTheSameValueAlsoRearms() {
        let tap = FakeTap(nonce: 1000); let box = ValueBox("count")
        let s = make(box, tap: tap)
        queue.sync { s.connection(up: true); s.connection(up: false) }
        tap.relaunch(nonce: 2000)
        queue.sync { s.connection(up: true) }
        XCTAssertTrue(s.tripped)
        box.value = "Count"; ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertFalse(s.tripped); XCTAssertEqual(tap.calls.filter { $0 == 1 }.count, 2)
    }

    func testEngineRestartRearms() {
        let tap = FakeTap(nonce: 1000)
        let s1 = make(path: "count", tap: tap)
        queue.sync { s1.connection(up: true) }
        tap.relaunch(nonce: 2000)
        let s2 = make(path: "count", tap: tap)                    // a new engine process: a new supervisor
        queue.sync { s2.connection(up: true) }
        XCTAssertFalse(s2.tripped)
        XCTAssertEqual(tap.calls, [1, 1], "the new engine arms the new instance")
    }

    /// Controller off/on or Mac wake: a new tap instance in the SAME dext process. The nonce is the same, the registry still
    /// holds COUNT, so the engine does nothing and the count continues.
    func testSameProcessReEnumerationNeedsNoEngineAction() {
        let tap = FakeTap(nonce: 1000)
        let s = make(path: "count", tap: tap)
        queue.sync { s.connection(up: true) }
        tap.status.tapPresent = true; tap.status.tapOpened = true
        ticks(s, 20)
        tap.status.tapPresent = false; tap.status.tapOpened = false     // the tap stopped (3A09)
        ticks(s, 20)
        tap.status.tapPresent = true; tap.status.tapOpened = true; tap.status.tapStarts = 2   // a new instance, same process
        ticks(s, 30)
        XCTAssertEqual(tap.calls, [1], "no setForwarding: the dext still has COUNT")
        XCTAssertFalse(s.tripped)
        XCTAssertEqual(tap.status.desiredState, 1)
    }

    func testSwitchingToEngineAndBackOnTheSameInstanceArmsAgain() {
        let tap = FakeTap(nonce: 1000); let box = ValueBox("count")
        let s = make(box, tap: tap)
        queue.sync { s.connection(up: true) }
        box.value = "engine"; ticks(s, 10)
        box.value = "count"; ticks(s, 10)
        XCTAssertEqual(tap.calls, [1, 0, 1]); XCTAssertFalse(s.tripped)
    }

    // MARK: M2: status2 cost

    func testNoStatus2WhileInertAndSettled() {
        let tap = FakeTap()
        let s = make(path: "engine", tap: tap)
        queue.sync { s.connection(up: true) }
        let afterHello = tap.status2Calls
        ticks(s, 600)                                            // a minute
        XCTAssertEqual(tap.status2Calls, afterHello, "INERT and settled: zero selector-11 calls from the supervisor")
    }

    func testCountReadsStatus2OncePerSecond() {
        let tap = FakeTap()
        let s = make(path: "count", tap: tap)
        queue.sync { s.connection(up: true) }
        let base = tap.status2Calls
        ticks(s, 100)                                            // 10 s
        XCTAssertEqual(tap.status2Calls - base, 10, "1 per second")
        XCTAssertEqual(TapSupervisor.tickMs * TapSupervisor.statusEveryTicks, 1000)
    }

    func testAttachTimingPollsAtTenHertzForAtMostFiveSecondsAndOnlyWithATap() {
        // a dext with a tap that never shows up (Apple's driver stayed on interface 3)
        let tap = FakeTap(); let clock = Clock()
        let s = make(path: "engine", tap: tap, clock: clock)
        queue.sync { s.connection(up: true); s.controllerInterface(up: true) }
        let base = tap.status2Calls
        for _ in 0..<80 { clock.ns += 100_000_000; ticks(s, 1) }    // 8 s
        XCTAssertLessThanOrEqual(tap.status2Calls - base, 52, "at most about 50 reads, then it gives up")
        XCTAssertGreaterThanOrEqual(tap.status2Calls - base, 49)
        XCTAssertFalse(s.timing.isWaiting); XCTAssertEqual(s.timing.gaveUp, 1)
        let after = tap.status2Calls
        ticks(s, 100)
        XCTAssertEqual(tap.status2Calls, after, "and it stops reading")
        // no tap in the dext (build 19, decline build): the timing never starts
        let old = FakeTap(); old.hasTap = false
        let s2 = make(path: "engine", tap: old, clock: clock)
        queue.sync { s2.connection(up: true); s2.controllerInterface(up: true) }
        let b2 = old.status2Calls
        ticks(s2, 100)
        XCTAssertEqual(old.status2Calls, b2); XCTAssertFalse(s2.timing.isWaiting)
    }

    func testAttachTimingMeasuresInterfaceUpToTapPresent() {
        let tap = FakeTap(); let clock = Clock()
        let s = make(path: "count", tap: tap, clock: clock)
        queue.sync { s.connection(up: true) }
        clock.ns = 5_000_000_000
        queue.sync { s.controllerInterface(up: true) }
        ticks(s, 1)
        XCTAssertTrue(s.timing.isWaiting, "no tap yet")
        clock.ns += 120_000_000
        tap.status.tapPresent = true
        ticks(s, 1)
        XCTAssertFalse(s.timing.isWaiting)
        XCTAssertEqual(s.timing.samplesMs.count, 1); XCTAssertEqual(s.timing.samplesMs[0], 120, accuracy: 0.001)
        queue.sync { s.controllerInterface(up: false); s.controllerInterface(up: true) }
        clock.ns += 40_000_000
        ticks(s, 1)
        XCTAssertEqual(s.timing.samplesMs, [120, 40])
    }

    func testInterfaceUpBeforeTheConnectionStillGetsTimed() {
        let tap = FakeTap(); let clock = Clock()
        let s = make(path: "engine", tap: tap, clock: clock)
        clock.ns = 2_000_000_000
        queue.sync { s.controllerInterface(up: true) }
        XCTAssertFalse(s.timing.isWaiting, "no connection yet")
        clock.ns = 2_300_000_000
        tap.status.tapPresent = true
        queue.sync { s.connection(up: true) }
        XCTAssertTrue(s.timing.isWaiting)
        ticks(s, 1)
        XCTAssertEqual(s.timing.samplesMs.count, 1); XCTAssertEqual(s.timing.samplesMs[0], 300, accuracy: 0.001, "measured from the interface-up time")
    }

    func testAttachTimingStatistics() {
        var t = TapAttachTiming()
        XCTAssertEqual(t.percentileMs(99), 0)
        for (i, ms) in [10.0, 20, 30, 40, 50, 60, 70, 80, 90, 100].enumerated() {
            t.interfaceUp(atNs: 0)
            XCTAssertEqual(t.observe(tapPresent: false, atNs: 1), nil)
            XCTAssertEqual(t.observe(tapPresent: true, atNs: UInt64(ms * 1e6)), ms, "sample \(i)")
            XCTAssertNil(t.observe(tapPresent: true, atNs: 999), "only the first reading after the interface came up counts")
        }
        XCTAssertEqual(t.percentileMs(50), 50); XCTAssertEqual(t.percentileMs(99), 100); XCTAssertEqual(t.percentileMs(10), 10)
        t.interfaceUp(atNs: 5); t.interfaceDown()
        XCTAssertNil(t.observe(tapPresent: true, atNs: 10), "the controller went away before the tap appeared")
        t.interfaceUp(atNs: 0)
        XCTAssertFalse(t.expire(atNs: TapAttachTiming.limitNs)); XCTAssertTrue(t.expire(atNs: TapAttachTiming.limitNs + 1))
        XCTAssertFalse(t.expire(atNs: TapAttachTiming.limitNs + 2), "once")
    }
}

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
        for state: UInt64 in [3, 4, 255, UInt64.max] { XCTAssertEqual(gdh_fwd_validate(state, 0), 1, "state \(state) is Unsupported: LIVE arrives in T7") }
        for flags: UInt64 in [1, 0x100, 0x200, UInt64.max] {
            XCTAssertEqual(gdh_fwd_validate(0, flags), 1, "flags \(flags): none exist in T4")
            XCTAssertEqual(gdh_fwd_validate(1, flags), 1)
            XCTAssertEqual(gdh_fwd_validate(2, flags), 1)
        }
        // the Swift mirror agrees
        for state: UInt64 in 0...5 { for flags: UInt64 in [0, 1, 0x100] {
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
                    XCTAssertTrue(desired == UInt32(GDH_FWD_COUNT) || desired == UInt32(GDH_FWD_SHADOW)); XCTAssertEqual(opened, 0); XCTAssertEqual(powered, 1)
                    XCTAssertEqual(stopping, 0); XCTAssertEqual(retry, 1)
                }
            } }
        } } }
        XCTAssertEqual(opens, 2, "of 64 input combinations exactly two open the interface: COUNT and SHADOW, both powered, not open, not stopping, retry due")
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
        XCTAssertLessThan(Int(GDHR_CTR_COUNT.rawValue), 40, "counters stay a small fixed array")
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
        var buf = [UInt8](repeating: 0, count: 512)
        let n = gdh_status2_pack(&buf, 512, &s, nil, nil, 0, &k2d, nil)
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
        var buf = [UInt8](repeating: 0, count: 512)
        let n = gdh_status2_pack(&buf, 512, &s, nil, nil, 0, nil, nil)
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
        var buf = [UInt8](repeating: 0, count: 512)
        let n = gdh_status2_pack(&buf, 512, &s, nil, nil, 0, nil, nil)
        XCTAssertEqual(n, DextStatus2.size); XCTAssertEqual(DextStatus2.size, 480)
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
        var buf = [UInt8](repeating: 0, count: 512)
        _ = gdh_status2_pack(&buf, 512, &s, nil, nil, 0, nil, nil)
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
        XCTAssertEqual(InputPath(defaultsValue: nil), .engine)
        XCTAssertEqual(InputPath(defaultsValue: "engine"), .engine)
        XCTAssertEqual(InputPath(defaultsValue: "count"), .count)
        XCTAssertEqual(InputPath(defaultsValue: " Count\n"), .count, "case and surrounding spaces are ignored")
        XCTAssertEqual(InputPath(defaultsValue: "shadow"), .shadow)
        XCTAssertEqual(InputPath(defaultsValue: "driver"), .driver)
        for bad: Any? in ["", "counts", "1", 1, true, ["count"], NSNull(), "count count"] {
            XCTAssertEqual(InputPath(defaultsValue: bad), .engine, "\(String(describing: bad)) is not a value")
        }
    }

    func testOnlyCountArmsTheTap() {
        XCTAssertEqual(InputPath.count.forwardingState, DextProtocol.Forwarding.count)
        XCTAssertEqual(InputPath.shadow.forwardingState, DextProtocol.Forwarding.shadow, "T5: shadow arms SHADOW")
        for p in InputPath.allCases where p != .count && p != .shadow { XCTAssertEqual(p.forwardingState, DextProtocol.Forwarding.inert, "\(p)") }
        XCTAssertFalse(InputPath.shadow.isRecognisedButNotYetSupported); XCTAssertTrue(InputPath.driver.isRecognisedButNotYetSupported)
        XCTAssertEqual(InputPath.allCases.filter(\.arms), [.count, .shadow])
        XCTAssertFalse(InputPath.count.isRecognisedButNotYetSupported)
        XCTAssertEqual(InputPath.defaultsKey, "inputPath")
    }
}

final class TapSupervisorTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.vhid.tap")

    private final class FakeTap: TapControlling, @unchecked Sendable {
        var calls: [UInt64] = []
        var status = DextStatus2()
        var hasTap = true
        var hasXlate = true
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
            if setResult == KERN_SUCCESS { status.desiredState = UInt8(state) }          // a real dext remembers what it was told
            return (setResult, setResult == KERN_SUCCESS ? DextForwardingResult(words: [0, status.tapPresent ? 1 : 0, 1, 0]) : nil)
        }
        func status2() -> DextStatus2? { status2Calls += 1; return status }
        /// The dext process was relaunched or replaced: a new instance, INERT, nothing armed.
        func relaunch(nonce: UInt64) { status = DextStatus2(); status.version = 1; status.instanceNonce = nonce }
    }

    private final class Clock: @unchecked Sendable { var ns: UInt64 = 1_000_000_000 }
    private final class ValueBox: @unchecked Sendable { var value: Any?; init(_ v: Any?) { value = v } }

    private func make(_ box: ValueBox, tap: FakeTap, clock: Clock = Clock()) -> TapSupervisor {
        TapSupervisor(queue: queue, dext: tap, readDefault: { box.value }, clock: { clock.ns })
    }
    private func make(path: Any?, tap: FakeTap, clock: Clock = Clock()) -> TapSupervisor { make(ValueBox(path), tap: tap, clock: clock) }
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
        for v: Any? in [nil, "engine", "driver", "bogus", 7] {
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
        let s = make(path: "count", tap: tap)
        queue.sync { s.connection(up: true) }
        ticks(s, 2)
        XCTAssertGreaterThanOrEqual(tap.calls.count, 3)
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

    private func shadowSupervisor(_ tap: FakeTap, path: Any? = "shadow", clock: Clock = Clock()) -> TapSupervisor {
        let s = make(path: path, tap: tap, clock: clock)
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
        XCTAssertTrue(tap.mapCalls.isEmpty); XCTAssertEqual(tap.calls, [2])
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
        XCTAssertEqual(tap.calls, [2], "no SHADOW request on the new instance")
        XCTAssertTrue(s.tripped)
        ticks(s, 100)
        XCTAssertEqual(tap.calls, [2]); XCTAssertEqual(tap.mapCalls.count, 1, "no mapping pushed to the relaunched instance")
        XCTAssertFalse(s.parity.ring.enabled)
    }

    func testRefusedShadowIsLoggedOnceAndNotAskedAgain() {
        let tap = FakeTap(); tap.setResult = DextProtocol.krNotPermitted
        let s = shadowSupervisor(tap)
        queue.sync { s.connection(up: true) }
        ticks(s, 50)
        XCTAssertEqual(tap.calls, [2], "one request on this connection; a failed self-test does not clear itself")
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
            XCTAssertEqual(tap.calls, [first], "\(path): the request is not sent to the new instance, however often it reconnects")
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
            XCTAssertEqual(tap.calls, [2])
            tap.relaunch(nonce: 2000)                                   // a later restart of the driver
            queue.sync { s.connection(up: false); s.connection(up: true) }
            XCTAssertFalse(s.tripped, "a refusal armed nothing, so a new instance is not 'a relaunch while armed' (kr \(kr))")
            XCTAssertEqual(tap.calls, [2, 2], "and the request is asked again on the new connection")
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
        XCTAssertEqual(tap.calls, [1, 2])
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
        XCTAssertEqual(tap.calls, [2]); XCTAssertEqual(tap.mapCalls.count, 1, "nothing is sent to the new instance")
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
        XCTAssertEqual(tap.calls, [1])
        XCTAssertTrue(s.tripped)
        ticks(s, 100)
        XCTAssertEqual(tap.calls, [1], "still INERT 10 s later, however long inputPath says count")
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
        XCTAssertEqual(tap.calls, [1])
    }

    /// The trip clears when the stored value changes (the owner's gesture) or the engine restarts; then COUNT is sent once.
    func testRewritingInputPathRearmsOnce() {
        let tap = FakeTap(nonce: 1000); let box = ValueBox("count")
        let s = make(box, tap: tap)
        queue.sync { s.connection(up: true); s.connection(up: false) }
        tap.relaunch(nonce: 2000)
        queue.sync { s.connection(up: true) }
        XCTAssertTrue(s.tripped); XCTAssertEqual(tap.calls, [1])
        // the same stored value: nothing happens
        ticks(s, 30); XCTAssertTrue(s.tripped); XCTAssertEqual(tap.calls, [1])
        // engine, then count: re-armed once, on the NEW instance
        box.value = "engine"; ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertFalse(s.tripped)
        box.value = "count"; ticks(s, TapSupervisor.defaultsEveryTicks)
        XCTAssertEqual(tap.calls, [1, 1], "COUNT again, once, on the new instance")
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

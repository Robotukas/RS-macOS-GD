import XCTest
import GDHubDextCore
@testable import GDHub

/// T7 (LIVE) in the DriverKit-free core: the arbitration transitions of `padSource`, pinning, adoption and the orphan timer,
/// the hold and pause words, the per-frame gates, and the status2 T7 block. Threaded tests model the pad's own queue and are
/// the ones to run under ThreadSanitizer (`swift test --sanitize=thread --filter DextLiveCoreTests`).
private let liveFakeOps: UnsafeMutablePointer<gdhr_ops> = {
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

final class DextLiveCoreTests: XCTestCase {
    private var world: FakeWorld { .shared }
    private var reg: UnsafeMutablePointer<gdhr>!
    private let crc: UInt32 = 0xABCD
    private var tap: UnsafeMutableRawPointer!, queue: UnsafeMutableRawPointer!
    private var pad: UnsafeMutableRawPointer!
    private var uc: UnsafeMutableRawPointer!
    private var gen: UInt64 = 0

    override func setUp() {
        world.reset()
        reg = UnsafeMutablePointer<gdhr>.allocate(capacity: 1)
        reg.initialize(to: gdhr())
        XCTAssertEqual(gdhr_ensure(reg, liveFakeOps), 1)
    }
    override func tearDown() { reg.deallocate() }

    /// An owner with a LIVE pad (source UC), a tap that applied SHADOW, a passed self-test and a mapping for the pad's spec.
    private func readyForLive(mapCrc: UInt32? = nil) {
        uc = world.newObject()
        gen = gdhr_claim_owner(reg, uc)
        let spec = world.newObject(); pad = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, crc), GDHR_OK)
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
        XCTAssertEqual(gdhr_pad_started(reg, pad), GDHR_OK)
        world.release(spec)
        tap = world.newObject(); queue = world.newObject()
        var desired: UInt32 = 0; var token: UInt64 = 0
        XCTAssertEqual(gdhr_register_tap_ex(reg, tap, queue, 1, &desired, &token), 0)
        XCTAssertEqual(gdhr_selftest_begin(reg), 1); gdhr_selftest_finish(reg, 1)
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, uc, UInt32(GDH_FWD_SHADOW)), GDHR_OK)
        gdhr_tap_publish(reg, tap, 1, UInt32(GDH_FWD_SHADOW))
        let blob = [UInt8](repeating: 7, count: 100)
        XCTAssertEqual(blob.withUnsafeBufferPointer { gdhr_map_publish(reg, uc, $0.baseAddress, 100, 3, mapCrc ?? crc) }, mapCrc == nil || mapCrc == crc ? GDHR_OK : GDHR_E_SPEC)
    }

    // MARK: Switch to LIVE

    func testLiveBeginChecksEveryPreconditionAndStoresTheSourceLast() {
        uc = world.newObject(); gen = gdhr_claim_owner(reg, uc)
        XCTAssertEqual(gdhr_live_begin(reg, world.newObject()), GDHR_E_NOT_OWNER, "owner only")
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_E_NO_PAD)
        let spec = world.newObject(); pad = world.newObject()
        _ = gdhr_pad_stage(reg, gen, spec, crc); _ = gdhr_pad_begin_create(reg, gen); _ = gdhr_pad_started(reg, pad); world.release(spec)
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_E_SELFTEST)
        _ = gdhr_selftest_begin(reg); gdhr_selftest_finish(reg, 1)
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_E_NO_TAP)
        tap = world.newObject(); queue = world.newObject()
        _ = gdhr_register_tap(reg, tap, queue, 1, nil)
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_E_NOT_SHADOW, "the tap has not applied SHADOW")
        _ = gdhr_set_desired_if_owner(reg, uc, UInt32(GDH_FWD_SHADOW)); gdhr_tap_publish(reg, tap, 1, UInt32(GDH_FWD_SHADOW))
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_E_NO_MAP)
        let other = [UInt8](repeating: 1, count: 64)
        _ = other.withUnsafeBufferPointer { gdhr_map_publish(reg, uc, $0.baseAddress, 64, 1, crc) }
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_UC), "every refusal left the source alone")
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_OK)
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_TAP))
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_SHADOW), "the desired state follows only at commit")
    }

    func testTheMappingMustTargetTheLivePad() {
        readyForLive()
        // a mapping whose spec CRC differs from the pad's cannot be published at all; the arming check is the second line
        let b = [UInt8](repeating: 2, count: 64)
        XCTAssertEqual(b.withUnsafeBufferPointer { gdhr_map_publish(reg, uc, $0.baseAddress, 64, 5, crc ^ 1) }, GDHR_E_SPEC)
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_OK)
    }

    func testCommitMakesItLiveAndDirectLiveStoreIsRefused() {
        readyForLive()
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, uc, UInt32(GDH_FWD_LIVE)), GDHR_E_STATE, "LIVE is never stored directly")
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_OK)
        XCTAssertEqual(gdhr_is_live(reg), 0, "source TAP but not committed")
        gdhr_set_hold(reg, 1)
        XCTAssertEqual(gdhr_live_commit(reg, uc), GDHR_OK)
        XCTAssertEqual(gdhr_is_live(reg), 1); XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_LIVE)); XCTAssertEqual(gdhr_hold(reg), 0, "commit clears the hold")
        XCTAssertEqual(gdhr_live_commit(reg, world.newObject()), GDHR_E_NOT_OWNER)
        // leaving: the source goes first, exactly once
        XCTAssertEqual(gdhr_leave_live(reg), 1); XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_UC))
        XCTAssertEqual(gdhr_leave_live(reg), 0, "idempotent")
        XCTAssertEqual(gdhr_ctr_get(reg, Int32(GDHR_CTR_SOURCE_SWITCHES.rawValue)), 2)
    }

    func testAbortReturnsTheSourceToTheUserClient() {
        readyForLive()
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_OK)
        gdhr_live_abort(reg)
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_UC))
    }

    // MARK: Pinning, adoption, the orphan timer

    func testOwnerLeavingWhileLivePinsThePadAndAnythingElseDestroysIt() {
        readyForLive()
        var pinned: Int32 = 0
        // not LIVE: the old behaviour exactly (the pad comes back for destruction, the mapping and the desired state go)
        let notPinned = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        XCTAssertNotNil(notPinned); XCTAssertEqual(pinned, 0); XCTAssertEqual(gdhr_desired_state(reg), 0)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        world.release(notPinned!)

        world.reset(); reg.initialize(to: gdhr()); XCTAssertEqual(gdhr_ensure(reg, liveFakeOps), 1)
        readyForLive()
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_OK); XCTAssertEqual(gdhr_live_commit(reg, uc), GDHR_OK)
        let p = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        XCTAssertNil(p, "pinned: nothing to terminate"); XCTAssertEqual(pinned, 1)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_LIVE)); XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_LIVE))
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_TAP)); XCTAssertEqual(gdhr_pad_orphaned(reg), 1)
        XCTAssertEqual(gdhr_orphan_deadline(reg), 1100)
        var snap = gdhr_snap(); gdhr_snapshot(reg, &snap)
        XCTAssertEqual(snap.hasMap, 1, "the accepted mapping stays with the pinned pad"); XCTAssertEqual(snap.ownerPresent, 0); XCTAssertEqual(snap.padOrphaned, 1)
    }

    func testTheOldReleaseNeverPins() {
        readyForLive()
        XCTAssertEqual(gdhr_live_begin(reg, uc), GDHR_OK); XCTAssertEqual(gdhr_live_commit(reg, uc), GDHR_OK)
        let p = gdhr_release_owner(reg, uc)
        XCTAssertNotNil(p, "a caller that does not ask about pinning keeps G5"); world.release(p!)
    }

    func testAdoptionNeedsAnOrphanTheSameSpecAndTheNewOwner() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        let newUC = world.newObject()
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        let newGen = gdhr_claim_owner(reg, newUC)
        XCTAssertGreaterThan(newGen, 0)
        XCTAssertEqual(gdhr_pad_adopt(reg, newGen &+ 5, crc), GDHR_E_NOT_OWNER, "only the current owner")
        XCTAssertEqual(gdhr_pad_adopt(reg, newGen, crc ^ 1), GDHR_E_SPEC)
        XCTAssertEqual(gdhr_pad_orphaned(reg), 1, "refusals change nothing")
        XCTAssertEqual(gdhr_pad_adopt(reg, newGen, crc), GDHR_OK)
        XCTAssertEqual(gdhr_pad_orphaned(reg), 0); XCTAssertEqual(gdhr_ctr_get(reg, Int32(GDHR_CTR_ADOPTS.rawValue)), 1)
        XCTAssertEqual(gdhr_pad_adopt(reg, newGen, crc), GDHR_E_NO_PAD, "nothing left to adopt")
        XCTAssertEqual(gdhr_is_live(reg), 1, "adoption touches neither the source nor the state: no neutral, no glitch")
        // the new owner owns it now: its Stop-time release pins it again
        pinned = 0; let again = gdhr_release_owner_pin(reg, newUC, 500, 1000, &pinned)
        XCTAssertNil(again); XCTAssertEqual(pinned, 1)
    }

    func testOrphanExpiryIsTwoStepsAndAnAdoptionInBetweenWins() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        XCTAssertEqual(gdhr_orphan_begin(reg, 1099), 0, "not before the deadline")
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_TAP))
        XCTAssertEqual(gdhr_orphan_begin(reg, 1100), 1)
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_UC), "source first, then the glue posts the neutral")
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_INERT))
        let newUC = world.newObject(); let g = gdhr_claim_owner(reg, newUC)
        XCTAssertEqual(gdhr_pad_adopt(reg, g, crc), GDHR_OK, "an owner that arrives between the two steps keeps the pad")
        XCTAssertNil(gdhr_orphan_finish(reg), "finish sees an owner and removes nothing")
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_LIVE))
    }

    func testOrphanFinishRemovesTheUnownedPadAndTheMapping() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        XCTAssertEqual(gdhr_orphan_begin(reg, 2000), 1)
        let p = gdhr_orphan_finish(reg)
        XCTAssertNotNil(p); world.release(p!)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE)); XCTAssertEqual(gdhr_pad_orphaned(reg), 0)
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE)); XCTAssertEqual(gdhr_ctr_get(reg, Int32(GDHR_CTR_ORPHAN_DESTROYS.rawValue)), 1)
        var snap = gdhr_snap(); gdhr_snapshot(reg, &snap); XCTAssertEqual(snap.hasMap, 0)
        XCTAssertNil(gdhr_orphan_finish(reg), "idempotent")
    }

    func testForceBeginServesReleasePadAndAnOldAppsCreateDevice() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        XCTAssertEqual(gdhr_orphan_force_begin(reg), 0, "an owned pad is not an orphan")
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1_000_000_000, &pinned)
        XCTAssertEqual(gdhr_orphan_force_begin(reg), 1, "no deadline needed")
        let p = gdhr_orphan_finish(reg); XCTAssertNotNil(p); world.release(p!)
    }

    func testEveryPadChangeMovesTheEpoch() {
        readyForLive()
        let e = gdhr_pad_epoch(reg)
        XCTAssertGreaterThan(e, 0)
        var rc: Int32 = 0
        let p = gdhr_pad_take(reg, gen, &rc); XCTAssertNotNil(p); world.release(p!)
        XCTAssertNotEqual(gdhr_pad_epoch(reg), e, "the tap drops its reference when this moves")
    }

    // MARK: Words and gates

    func testHoldPauseAndTokenWords() {
        XCTAssertEqual(gdhr_hold(reg), 0); gdhr_set_hold(reg, 7); XCTAssertEqual(gdhr_hold(reg), 1, "a flag, not a counter")
        gdhr_pause_set(reg, 12345); XCTAssertEqual(gdhr_pause_until(reg), 12345)
        let a = world.newObject(), b = world.newObject(), q = world.newObject()
        var ta: UInt64 = 0, tb: UInt64 = 0
        _ = gdhr_register_tap_ex(reg, a, q, 1, nil, &ta)
        XCTAssertEqual(gdhr_tap_token(reg), ta)
        _ = gdhr_register_tap_ex(reg, b, q, 1, nil, &tb)
        XCTAssertGreaterThan(tb, ta); XCTAssertNotEqual(gdhr_tap_token(reg), ta, "the older instance's token is stale: it can no longer submit")
        gdhr_unregister_tap(reg, a)
        XCTAssertEqual(gdhr_tap_token(reg), tb, "a stale tap's unregister changes nothing")
        gdhr_unregister_tap(reg, b)
        XCTAssertNotEqual(gdhr_tap_token(reg), tb, "and nobody holds a current token after the registered tap left")
    }

    func testPerFrameSubmitGate() {
        func ok(_ live: Int32 = 1, hold: UInt32 = 0, tok: UInt64 = 5, cur: UInt64 = 5, ep: UInt32 = 3, cep: UInt32 = 3, src: UInt32 = UInt32(GDHR_SRC_TAP)) -> Bool {
            gdh_live_submit_ok(live, hold, tok, cur, ep, cep, src) != 0
        }
        XCTAssertTrue(ok())
        XCTAssertFalse(ok(0)); XCTAssertFalse(ok(hold: 1)); XCTAssertFalse(ok(tok: 4)); XCTAssertFalse(ok(ep: 2))
        XCTAssertFalse(ok(src: UInt32(GDHR_SRC_UC))); XCTAssertFalse(ok(src: UInt32(GDHR_SRC_NONE)))
    }

    func testSilenceDecision() {
        let t: UInt64 = 250_000_000
        let tap = UInt32(GDHR_SRC_TAP)
        func due(live: Int32 = 1, opened: Int32 = 1, powered: Int32 = 1, silenced: Int32 = 0, hold: UInt32 = 0, src: UInt32 = tap, last: UInt64 = 1000, now: UInt64 = 1000 + t + 1) -> Bool {
            gdh_silence_due(live, opened, powered, silenced, hold, src, last, now, t) != 0
        }
        XCTAssertTrue(due())
        XCTAssertFalse(due(now: 1000 + t), "exactly 250 ms is not yet silence")
        XCTAssertFalse(due(live: 0)); XCTAssertFalse(due(opened: 0)); XCTAssertFalse(due(powered: 0))
        XCTAssertFalse(due(silenced: 1), "once per silence")
        XCTAssertFalse(due(hold: 1), "the engine's hold already has the pad neutral")
        XCTAssertFalse(due(src: UInt32(GDHR_SRC_UC)), "a pad the tap does not drive is not the tap's to blank")
        XCTAssertFalse(due(last: 0), "nothing delivered yet")
        XCTAssertEqual(GDH_SILENCE_NEUTRAL_MS, 250); XCTAssertEqual(GDH_ORPHAN_MS, 30000); XCTAssertEqual(GDH_PAUSE_MAX_MS, 10000)
        // and the timer period is 50 ms in LIVE so the neutral lands within 250 to 300 ms
        XCTAssertEqual(gdh_tap_fast_tick(UInt32(GDH_FWD_LIVE), 1, 1, 0, 0), 1)
        XCTAssertEqual(gdh_tap_fast_tick(UInt32(GDH_FWD_SHADOW), 1, 1, 0, 0), 0)
    }

    // MARK: Review D1: an orphan can be removed while a client is connected as owner

    /// The reviewer's harness t.c: A pins the pad (LIVE), B hellos and asks for the removal. The plain finish refuses (an owner is
    /// present); the forced one removes the pad, and B can then stage a pad of its own.
    func testForcedRemovalWorksWithAConnectedOwner() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        let b = world.newObject(); let gb = gdhr_claim_owner(reg, b)
        XCTAssertGreaterThan(gb, 0)
        XCTAssertEqual(gdhr_orphan_force_begin(reg), 1)
        XCTAssertNil(gdhr_orphan_finish(reg), "the unforced finish needs no owner and leaves the pad: that was the bug")
        XCTAssertEqual(gdhr_pad_orphaned(reg), 1)
        let spec2 = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gb, spec2, 0x9999), GDHR_E_BUSY, "B cannot stage while the orphan sits there")
        let p = gdhr_orphan_force_finish(reg)
        XCTAssertNotNil(p, "forced: removed although B is connected"); world.release(p!)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE)); XCTAssertEqual(gdhr_pad_orphaned(reg), 0)
        XCTAssertEqual(gdhr_pad_stage(reg, gb, spec2, 0x9999), GDHR_OK, "and B can now create")
        XCTAssertEqual(gdhr_ctr_get(reg, Int32(GDHR_CTR_ORPHAN_DESTROYS.rawValue)), 1)
        XCTAssertNil(gdhr_orphan_force_finish(reg), "idempotent")
    }

    func testForcedRemovalOfADifferentSpecAdoptionAndOfAnOldAppsCreate() {
        // selector 12 with another spec: adoption refused (E_SPEC), then the forced removal, then B stages the new spec
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        let b = world.newObject(); let gb = gdhr_claim_owner(reg, b)
        XCTAssertEqual(gdhr_pad_adopt(reg, gb, crc ^ 5), GDHR_E_SPEC)
        XCTAssertEqual(gdhr_orphan_force_begin(reg), 1)
        let p = gdhr_orphan_force_finish(reg); XCTAssertNotNil(p); world.release(p!)
        XCTAssertEqual(gdhr_pad_stage(reg, gb, world.newObject(), crc ^ 5), GDHR_OK)
        // a pad that is NOT an orphan is never taken by the forced path
        readyForLiveAgain()
        XCTAssertEqual(gdhr_orphan_force_begin(reg), 0)
        XCTAssertNil(gdhr_orphan_force_finish(reg))
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_LIVE))
    }

    private func readyForLiveAgain() {
        world.reset(); reg.initialize(to: gdhr()); XCTAssertEqual(gdhr_ensure(reg, liveFakeOps), 1)
        readyForLive()
    }

    // MARK: Review D2: the orphan timer is armed only when it can do something

    func testOrphanTimerArmTime() {
        let g: UInt64 = 5_000, og: UInt64 = 30_000
        XCTAssertEqual(gdh_orphan_arm_time(0, 0, 1000, 10, g, og), 0, "no orphan: nothing to arm")
        XCTAssertEqual(gdh_orphan_arm_time(0, 1, 1000, 10, g, og), 0, "no orphan, a client connected: nothing to arm")
        XCTAssertEqual(gdh_orphan_arm_time(1, 0, 90_000, 10, 0, og), 90_000, "pinned owner left: the 30 s deadline")
        XCTAssertEqual(gdh_orphan_arm_time(1, 0, 100, 10_000, g, og), 15_000, "an owner left without adopting, deadline long past: now + grace, never a time in the past")
        XCTAssertEqual(gdh_orphan_arm_time(1, 0, 100, 10_000, 0, og), 10_000, "fired with nobody connected: at most now")
        XCTAssertGreaterThanOrEqual(gdh_orphan_arm_time(1, 0, 100, 10_000, g, og), 10_000 + g)
    }

    /// R3: a client connected as owner that never adopts must not keep the tap driving an unowned pad forever. The timer is armed 30 s
    /// on (never at once: no loop), and a client that has sat on the orphan 30 s past the deadline loses it to the forced removal.
    func testAConnectedOwnerThatNeverAdoptsLosesTheOrphanThirtySecondsPastTheDeadline() {
        let og: UInt64 = 30_000
        // the timer fires at the deadline with a client connected: re-armed 30 s later, not now and not never
        XCTAssertEqual(gdh_orphan_arm_time(1, 1, 90_000, 90_000, 0, og), 120_000)
        XCTAssertEqual(gdh_orphan_arm_time(1, 1, 90_000, 91_000, 0, og), 121_000, "30 s from now when the timer fired a little late")
        XCTAssertEqual(gdh_orphan_arm_time(1, 1, 90_000, 10_000, 0, og), 120_000, "armed early (the owner came while the deadline is still ahead): deadline + 30 s")
        for now: UInt64 in [90_000, 91_000, 119_999] { XCTAssertGreaterThan(gdh_orphan_arm_time(1, 1, 90_000, now, 0, og), now, "never a time that fires at once") }
        XCTAssertEqual(gdh_orphan_owner_overstay(1, 1, 90_000, 119_999, og), 0)
        XCTAssertEqual(gdh_orphan_owner_overstay(1, 1, 90_000, 120_000, og), 1)
        XCTAssertEqual(gdh_orphan_owner_overstay(1, 0, 90_000, 500_000, og), 0, "no client: the plain finish does it")
        XCTAssertEqual(gdh_orphan_owner_overstay(0, 1, 90_000, 500_000, og), 0, "nothing orphaned (adopted meanwhile): nothing to remove")
        // the whole sequence against the registry: owner B connected and not adopting; the plain begin refuses, the forced one removes
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 90_000, &pinned)
        let b = world.newObject(); _ = gdhr_claim_owner(reg, b)
        XCTAssertEqual(gdhr_orphan_begin(reg, 91_000), 0, "owner present: the plain removal refuses")
        XCTAssertEqual(gdh_orphan_owner_overstay(UInt32(gdhr_pad_orphaned(reg)), UInt32(gdhr_owner_present(reg)), gdhr_orphan_deadline(reg), 91_000, og), 0)
        let dl = gdhr_orphan_deadline(reg)
        XCTAssertEqual(gdh_orphan_owner_overstay(UInt32(gdhr_pad_orphaned(reg)), UInt32(gdhr_owner_present(reg)), dl, dl + og, og), 1)
        XCTAssertEqual(gdhr_orphan_force_begin(reg), 1)
        let p = gdhr_orphan_force_finish(reg); XCTAssertNotNil(p); world.release(p!)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE)); XCTAssertEqual(gdhr_pad_orphaned(reg), 0)
    }

    /// R4: the adoption of an identical spec fails for a client that is no longer the owner (its Stop ran during its own call): the
    /// registry refuses and the orphan stays, which is what lets the dext answer NotReady without removing anything.
    func testAdoptionByAStaleGenerationRefusesAndTheOrphanStays() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        let b = world.newObject(); let gb = gdhr_claim_owner(reg, b)
        XCTAssertEqual(gdhr_pad_adopt(reg, gb &+ 99, crc), GDHR_E_NOT_OWNER, "a generation that is not the owner's")
        XCTAssertEqual(gdhr_pad_orphaned(reg), 1); XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_LIVE)); XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_TAP))
        XCTAssertNil(gdhr_release_owner(reg, b))
        XCTAssertEqual(gdhr_pad_adopt(reg, gb, crc), GDHR_E_NOT_OWNER, "and after the client has gone")
        XCTAssertEqual(gdhr_pad_orphaned(reg), 1)
    }

    // MARK: Review D3, D5, D6, D7

    /// The reviewer's harness, second half: a client that says hello and leaves without adopting changes nothing about the pad.
    func testAClientThatNeverOwnedThePadLeavesItAlone() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        let b = world.newObject(); _ = gdhr_claim_owner(reg, b)
        XCTAssertEqual(gdhr_orphan_begin(reg, 5000), 0, "an owner is connected: the expiry waits")
        pinned = 0
        let left = gdhr_release_owner_pin(reg, b, 6000, 1000, &pinned)
        XCTAssertNil(left); XCTAssertEqual(pinned, 0)
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_LIVE), "desired state untouched")
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_TAP), "source untouched: the tap keeps driving")
        XCTAssertEqual(gdhr_pad_orphaned(reg), 1); XCTAssertEqual(gdhr_orphan_deadline(reg), 1100, "and the deadline is still the original one")
        var snap = gdhr_snap(); gdhr_snapshot(reg, &snap); XCTAssertEqual(snap.hasMap, 1, "the mapping stays")
        XCTAssertEqual(gdhr_orphan_begin(reg, 6000), 1, "the timer can remove it now")
    }

    func testAConnectedOwnerThatHasNotAdoptedCanChangeNothing() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        let b = world.newObject(); let gb = gdhr_claim_owner(reg, b)
        XCTAssertEqual(gdhr_pad_not_ours(reg, b), 1); XCTAssertEqual(gdhr_owns_pad(reg, b), 0)
        for st in [UInt32(GDH_FWD_INERT), UInt32(GDH_FWD_COUNT), UInt32(GDH_FWD_SHADOW)] {
            XCTAssertEqual(gdhr_set_desired_if_owner(reg, b, st), GDHR_E_NOT_OURS, "state \(st)")
        }
        XCTAssertEqual(gdhr_live_begin(reg, b), GDHR_E_NOT_OURS); XCTAssertEqual(gdhr_live_commit(reg, b), GDHR_E_NOT_OWNER)
        let blob = [UInt8](repeating: 3, count: 80)
        XCTAssertEqual(blob.withUnsafeBufferPointer { gdhr_map_publish(reg, b, $0.baseAddress, 80, 9, crc) }, GDHR_E_NOT_OURS)
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_LIVE)); XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_TAP))
        var snap = gdhr_snap(); gdhr_snapshot(reg, &snap); XCTAssertEqual(snap.acceptedRevision, 3, "the map is the old one")
        // after the adoption it is B's pad
        XCTAssertEqual(gdhr_pad_adopt(reg, gb, crc), GDHR_OK)
        XCTAssertEqual(gdhr_pad_not_ours(reg, b), 0); XCTAssertEqual(gdhr_owns_pad(reg, b), 1)
        XCTAssertEqual(blob.withUnsafeBufferPointer { gdhr_map_publish(reg, b, $0.baseAddress, 80, 9, crc) }, GDHR_OK)
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, b, UInt32(GDH_FWD_SHADOW)), GDHR_OK)
    }

    func testNoPadMeansNothingIsNotOurs() {
        uc = world.newObject(); gen = gdhr_claim_owner(reg, uc)
        XCTAssertEqual(gdhr_pad_not_ours(reg, uc), 0, "arming before any pad exists is the normal start")
        XCTAssertEqual(gdhr_set_desired_if_owner(reg, uc, UInt32(GDH_FWD_SHADOW)), GDHR_OK)
        let spec = world.newObject()
        _ = gdhr_pad_stage(reg, gen, spec, crc)
        XCTAssertEqual(gdhr_pad_not_ours(reg, uc), 0, "a pad it is staging is its own")
    }

    func testAdoptionClearsTheHoldAndAPadLeavingTheSlotResetsLiveButNotSHADOW() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        gdhr_set_hold(reg, 1)
        var pinned: Int32 = 0
        _ = gdhr_release_owner_pin(reg, uc, 100, 1000, &pinned)
        let b = world.newObject(); let gb = gdhr_claim_owner(reg, b)
        XCTAssertEqual(gdhr_hold(reg), 1)
        XCTAssertEqual(gdhr_pad_adopt(reg, gb, crc), GDHR_OK)
        XCTAssertEqual(gdhr_hold(reg), 0, "D6: the previous owner's hold does not survive the adoption")
        // D7: the pad leaves the slot (it stopped by itself): LIVE, the mapping and the hold are gone, the next pad starts UC + INERT
        gdhr_set_hold(reg, 1)
        var rc: Int32 = 0
        let p = gdhr_pad_take(reg, 0, &rc); XCTAssertNotNil(p); world.release(p!)
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_INERT)); XCTAssertEqual(gdhr_hold(reg), 0)
        var snap = gdhr_snap(); gdhr_snapshot(reg, &snap); XCTAssertEqual(snap.hasMap, 0)
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE))
        // SHADOW (an engine that keeps its arming across an identity switch) stays asked for
        world.reset(); reg.initialize(to: gdhr()); XCTAssertEqual(gdhr_ensure(reg, liveFakeOps), 1)
        readyForLive()
        let q = gdhr_pad_take(reg, 0, &rc); XCTAssertNotNil(q); world.release(q!)
        XCTAssertEqual(gdhr_desired_state(reg), UInt32(GDH_FWD_SHADOW), "COUNT and SHADOW are not reset by a pad leaving")
    }

    // MARK: The pad as the only arbiter: a source switch against reports in flight

    /// Models the pad's queue: one thread takes events in order; a TAP submission is accepted only if the word it loads at that
    /// moment is TAP (exactly what GDHubVirtualPad::submitInput does). A switcher thread flips the source the way the user client
    /// does (store, THEN enqueue the neutral) while a tap thread submits continuously. Afterwards, in the pad's order, no accepted TAP
    /// submission may lie between a switch-to-UC neutral and the next switch-to-TAP neutral, and every UC submission accepted
    /// then must lie in a UC period.
    func testNoReportFromTheOldSourceSurvivesASwitch() {
        readyForLive()
        _ = gdhr_live_begin(reg, uc); _ = gdhr_live_commit(reg, uc)
        enum Ev { case tapSubmit, ucSubmit, neutral }
        // State shared with the two threads lives in one class instance (no captured vars), guarded by `lock`.
        final class Shared: @unchecked Sendable { var queueEv: [Ev] = []; var done = false; var log: [(Ev, Bool)] = [] }
        let sh = Shared(), lock = NSLock(), finished = DispatchSemaphore(value: 0)
        let regPtr = UnsafeRawPointer(reg)!
        let padThread = Thread {
            let r = regPtr.assumingMemoryBound(to: gdhr.self)
            while true {
                lock.lock(); let e = sh.queueEv.isEmpty ? nil : sh.queueEv.removeFirst(); let fin = sh.done; lock.unlock()
                guard let e else { if fin { finished.signal(); return }; Thread.sleep(forTimeInterval: 0.00002); continue }
                lock.lock()                                                    // word load and log entry are one step, so log order is load order
                let word = gdhr_pad_source(r)                                  // the one arbitration point: read on the pad's own queue
                switch e {
                case .tapSubmit: sh.log.append((e, word == UInt32(GDHR_SRC_TAP)))
                case .ucSubmit:  sh.log.append((e, word == UInt32(GDHR_SRC_UC)))
                case .neutral:   sh.log.append((e, true))
                }
                lock.unlock()
            }
        }
        let tapThread = Thread {
            for _ in 0..<20000 { lock.lock(); sh.queueEv.append(.tapSubmit); sh.queueEv.append(.ucSubmit); lock.unlock() }
        }
        padThread.start(); tapThread.start()
        func logCount() -> Int { lock.lock(); defer { lock.unlock() }; return sh.log.count }
        var tapWindows: [(Int, Int)] = [], ucWindows: [(Int, Int)] = []
        var lastTapStoreDone: Int?
        for _ in 0..<400 {
            let r = reg!
            if let l3 = lastTapStoreDone { ucWindows.append((l3, logCount())) }          // UC reports processed since the TAP store returned
            XCTAssertEqual(gdhr_leave_live(r), 1)                                       // store UC ...
            let l1 = logCount()                                                         // ... from here on everything processed has seen UC
            XCTAssertEqual(gdhr_set_desired_if_owner(r, uc, UInt32(GDH_FWD_SHADOW)), GDHR_OK)
            lock.lock(); sh.queueEv.append(.neutral); lock.unlock()                         // the switch neutral, queued behind whatever is in flight
            Thread.sleep(forTimeInterval: 0.0002)
            let l2 = logCount()                                                         // everything before this was processed before the TAP store began
            tapWindows.append((l1, l2))
            XCTAssertEqual(gdhr_live_begin(r, uc), GDHR_OK)                              // store TAP
            lastTapStoreDone = logCount()
            lock.lock(); sh.queueEv.append(.neutral); lock.unlock()
            _ = gdhr_live_commit(r, uc)
            Thread.sleep(forTimeInterval: 0.0002)
        }
        lock.lock(); sh.done = true; lock.unlock()                                       // the pad thread drains its queue, then ends
        XCTAssertEqual(finished.wait(timeout: .now() + 60), .success, "the pad thread drained its queue")
        lock.lock(); let final = sh.log; lock.unlock()
        var violations = 0
        for (lo, hi) in tapWindows where hi > lo { for i in lo..<min(hi, final.count) where final[i].0 == .tapSubmit && final[i].1 { violations += 1 } }
        for (lo, hi) in ucWindows where hi > lo { for i in lo..<min(hi, final.count) where final[i].0 == .ucSubmit && final[i].1 { violations += 1 } }
        XCTAssertEqual(violations, 0, "a report of the old source was accepted after the switch had been stored")
        XCTAssertGreaterThan(final.filter { $0.0 == .tapSubmit && $0.1 }.count, 0); XCTAssertGreaterThan(final.filter { $0.0 == .ucSubmit && $0.1 }.count, 0)
        XCTAssertGreaterThan(tapWindows.map { $0.1 - $0.0 }.reduce(0, +), 0, "the windows saw traffic")
    }

    // MARK: status2 T7 block

    func testStatus2T7BlockRoundTripsByOffset() throws {
        var s = gdhr_snap(); s.build = 24; s.holdNeutral = 1; s.padOrphaned = 1
        withUnsafeMutableBytes(of: &s.counters) { c in
            let u = c.bindMemory(to: UInt64.self)
            let ids: [(gdhr_counter, UInt64)] = [(GDHR_CTR_TAP_POSTS, 11), (GDHR_CTR_TAP_REJECTED, 12), (GDHR_CTR_TAP_SUBMIT_ERRORS, 13),
                (GDHR_CTR_FRAMES_UNCHANGED, 14), (GDHR_CTR_SWITCH_NEUTRALS, 15), (GDHR_CTR_STOP_NEUTRALS, 16), (GDHR_CTR_SILENCE_NEUTRALS, 17),
                (GDHR_CTR_POWER_NEUTRALS, 18), (GDHR_CTR_HOLD_NEUTRALS, 19), (GDHR_CTR_ADOPTS, 20), (GDHR_CTR_ORPHAN_DESTROYS, 21),
                (GDHR_CTR_PAUSE_DROPS, 22), (GDHR_CTR_SOURCE_SWITCHES, 23), (GDHR_CTR_LIVE_NO_PAD, 24)]
            for (id, v) in ids { u[Int(id.rawValue)] = v }
        }
        var extra = gdh_status2_extra()
        extra.paused = 1
        extra.total = gdh_summary(count: 9, p50Ns: 100, p99Ns: 200, maxNs: 300, meanNs: 150)
        extra.occ = gdh_summary(count: 8, p50Ns: 101, p99Ns: 201, maxNs: 301, meanNs: 151)
        extra.addPool = gdh_summary(count: 7, p50Ns: 102, p99Ns: 202, maxNs: 302, meanNs: 152)
        extra.submit = gdh_summary(count: 6, p50Ns: 103, p99Ns: 203, maxNs: 303, meanNs: 153)
        var buf = [UInt8](repeating: 0xEE, count: 1024)
        let n = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, nil, &extra)
        XCTAssertEqual(n, DextStatus2.size); XCTAssertEqual(n, 676)
        let d = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(n))))
        XCTAssertTrue(d.holdNeutral); XCTAssertTrue(d.padOrphaned); XCTAssertTrue(d.paused)
        XCTAssertEqual([d.tapPosts, d.tapRejected, d.tapSubmitErrors, d.framesUnchanged, d.switchNeutrals, d.stopNeutrals, d.silenceNeutrals,
                        d.powerNeutrals, d.holdNeutrals, d.adopts, d.orphanDestroys, d.pauseDrops, d.sourceSwitches, d.liveNoPad], Array(11...24).map(UInt64.init))
        XCTAssertEqual(d.total, DextMeterSummary(count: 9, p50Ns: 100, p99Ns: 200, maxNs: 300, meanNs: 150))
        XCTAssertEqual(d.occ.p99Ns, 201); XCTAssertEqual(d.addPool.maxNs, 302); XCTAssertEqual(d.submit.meanNs, 153)
        XCTAssertEqual(DextStatus2.Offset.submitMean + 4, DextStatus2.size, "the layout ends exactly at the declared size")
        // the T5 block did not move
        XCTAssertEqual(DextStatus2.Offset.parityOut02, 476); XCTAssertEqual(DextStatus2.Offset.holdNeutral, 480)
        // an older reader that knows 480 bytes sees the old fields untouched
        let old = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(480))))
        XCTAssertEqual(old.tapPosts, 0, "beyond the 480 bytes it asked for: zero"); XCTAssertEqual(old.build, 24)
    }

    func testPoolHasThirtyTwoBuffers() {
        XCTAssertEqual(GDH_POOL_SLOTS, 32)
        XCTAssertLessThanOrEqual(Int(GDHR_CTR_COUNT.rawValue), 64)
    }
}

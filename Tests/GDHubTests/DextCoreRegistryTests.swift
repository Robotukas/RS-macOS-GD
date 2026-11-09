import XCTest
import GDHubDextCore
@testable import GDHub

/// The dext's registry state machine (Dext/GDHubVirtualHID/Core/GDHubRegistryCore.c), driven with fake retain-counted
/// objects and a real mutex. The same C file runs inside the dext, where the objects are OSObjects and the lock an IOLock.
/// What these tests watch besides the transitions: the reference count of every object (no leak, no use after the last
/// release) and that `release` is never called while the registry lock is held (the "no callout under the lock" rule).
final class FakeWorld: @unchecked Sendable {
    static let shared = FakeWorld()
    private let guardLock = NSLock()
    private var refs: [UInt: Int] = [:]
    private var created: [UnsafeMutableRawPointer] = []
    private var holders = Set<UInt64>()           // threads that currently hold a registry lock
    private(set) var locksCreated = 0, locksFreed = 0
    private(set) var releasesUnderLock = 0, retainsOfDead = 0, negativeRefs = 0

    func reset() {
        guardLock.lock(); defer { guardLock.unlock() }
        refs = [:]; created = []; holders = []
        locksCreated = 0; locksFreed = 0; releasesUnderLock = 0; retainsOfDead = 0; negativeRefs = 0
    }

    static func tid() -> UInt64 { var t: UInt64 = 0; pthread_threadid_np(nil, &t); return t }

    /// A fresh object with reference count 1 (the test's own reference).
    func newObject() -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16)
        guardLock.lock(); refs[UInt(bitPattern: p)] = 1; created.append(p); guardLock.unlock()
        return p
    }
    func refCount(_ p: UnsafeMutableRawPointer) -> Int { guardLock.lock(); defer { guardLock.unlock() }; return refs[UInt(bitPattern: p)] ?? -99 }
    var allRefCounts: [Int] { guardLock.lock(); defer { guardLock.unlock() }; return created.map { refs[UInt(bitPattern: $0)] ?? -99 } }

    func retain(_ p: UnsafeMutableRawPointer) {
        guardLock.lock(); defer { guardLock.unlock() }
        let k = UInt(bitPattern: p)
        if (refs[k] ?? 0) <= 0 { retainsOfDead += 1 }
        refs[k, default: 0] += 1
    }
    func release(_ p: UnsafeMutableRawPointer) {
        guardLock.lock(); defer { guardLock.unlock() }
        if holders.contains(Self.tid()) { releasesUnderLock += 1 }
        let k = UInt(bitPattern: p)
        refs[k, default: 0] -= 1
        if refs[k]! < 0 { negativeRefs += 1 }
    }

    func lockNew() -> UnsafeMutableRawPointer? {
        let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(m, nil)
        guardLock.lock(); locksCreated += 1; guardLock.unlock()
        return UnsafeMutableRawPointer(m)
    }
    func lockFree(_ l: UnsafeMutableRawPointer) {
        guardLock.lock(); locksFreed += 1; guardLock.unlock()
        l.assumingMemoryBound(to: pthread_mutex_t.self).deallocate()
    }
    func lock(_ l: UnsafeMutableRawPointer) {
        pthread_mutex_lock(l.assumingMemoryBound(to: pthread_mutex_t.self))
        guardLock.lock(); holders.insert(Self.tid()); guardLock.unlock()
    }
    func unlock(_ l: UnsafeMutableRawPointer) {
        guardLock.lock(); holders.remove(Self.tid()); guardLock.unlock()
        pthread_mutex_unlock(l.assumingMemoryBound(to: pthread_mutex_t.self))
    }
}

private let fakeOps: UnsafeMutablePointer<gdhr_ops> = {
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

final class DextCoreRegistryTests: XCTestCase {
    private var world: FakeWorld { .shared }
    private var reg: UnsafeMutablePointer<gdhr>!

    override func setUp() {
        world.reset()
        reg = UnsafeMutablePointer<gdhr>.allocate(capacity: 1)
        reg.initialize(to: gdhr())
        XCTAssertEqual(gdhr_ensure(reg, fakeOps), 1)
    }
    override func tearDown() { reg.deallocate() }

    /// Owner claimed, ready to stage. Returns the owner object and its generation.
    private func claimed() -> (uc: UnsafeMutableRawPointer, gen: UInt64) {
        let uc = world.newObject()
        let gen = gdhr_claim_owner(reg, uc)
        XCTAssertGreaterThan(gen, 0)
        return (uc, gen)
    }

    /// stage -> begin_create -> started for a fresh pad. The test's own references to spec and pad are dropped at the
    /// end, so only the registry holds them. Returns the pad pointer (for identity checks only).
    @discardableResult
    private func createPad(gen: UInt64) -> UnsafeMutableRawPointer {
        let spec = world.newObject(), pad = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 0xABCD), GDHR_OK)
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
        XCTAssertEqual(gdhr_pad_started(reg, pad), GDHR_OK)
        world.release(spec); world.release(pad)
        return pad
    }

    private func assertBalanced(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(world.releasesUnderLock, 0, "release() called while the registry lock was held. \(message)", file: file, line: line)
        XCTAssertEqual(world.retainsOfDead, 0, "retain of an object whose last reference was gone. \(message)", file: file, line: line)
        XCTAssertEqual(world.negativeRefs, 0, "over-release. \(message)", file: file, line: line)
    }

    // MARK: lock installation

    func testEnsureIsIdempotentAndInstallsOneLockUnderRace() {
        // setUp already ensured one registry; race a fresh one from 16 threads.
        let r = UnsafeMutablePointer<gdhr>.allocate(capacity: 1); r.initialize(to: gdhr()); defer { r.deallocate() }
        let before = (world.locksCreated, world.locksFreed)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in XCTAssertEqual(gdhr_ensure(r, fakeOps), 1) }
        XCTAssertEqual(gdhr_ensure(r, fakeOps), 1)
        let created = world.locksCreated - before.0, freed = world.locksFreed - before.1
        XCTAssertGreaterThanOrEqual(created, 1)
        XCTAssertEqual(created - freed, 1, "exactly one lock survives; every loser frees its own")
    }

    func testNothingWorksBeforeEnsure() {
        let r = UnsafeMutablePointer<gdhr>.allocate(capacity: 1); r.initialize(to: gdhr()); defer { r.deallocate() }
        let o = world.newObject()
        XCTAssertEqual(gdhr_claim_owner(r, o), 0)
        XCTAssertNil(gdhr_copy_pad(r)); XCTAssertNil(gdhr_copy_root(r))
        XCTAssertEqual(gdhr_pad_stage(r, 1, o, 0), GDHR_E_STATE)
        XCTAssertEqual(gdhr_register_root(r, o), 0)
        XCTAssertEqual(world.refCount(o), 1, "no retain without a registry")
    }

    // MARK: owner

    func testOwnerClaimIsExclusiveAndGenerationsGrow() {
        let a = world.newObject(), b = world.newObject()
        let g1 = gdhr_claim_owner(reg, a)
        XCTAssertEqual(g1, 1)
        XCTAssertEqual(gdhr_claim_owner(reg, b), 0, "a second client is refused")
        XCTAssertEqual(gdhr_claim_owner(reg, a), g1, "the owner may claim again (second hello)")
        XCTAssertEqual(world.refCount(a), 2, "the registry holds one reference, and only one")
        XCTAssertNil(gdhr_release_owner(reg, b), "a non-owner cannot release")
        XCTAssertNil(gdhr_release_owner(reg, a))
        XCTAssertEqual(world.refCount(a), 1)
        let g2 = gdhr_claim_owner(reg, b)
        XCTAssertEqual(g2, 2, "a new owner gets a new generation")
        var gen: UInt64 = 99
        let copy = gdhr_copy_owner(reg, &gen)
        XCTAssertEqual(copy, b); XCTAssertEqual(gen, 2)
        world.release(copy!)
        XCTAssertNil(gdhr_release_owner(reg, b))
        var gen2: UInt64 = 99
        XCTAssertNil(gdhr_copy_owner(reg, &gen2)); XCTAssertEqual(gen2, 0)
        assertBalanced()
    }

    // MARK: pad slot

    func testPadHappyPathAndReferenceCounts() {
        let (uc, gen) = claimed()
        let spec = world.newObject(), pad = world.newObject()
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 0x1234), GDHR_OK)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_STAGED))
        XCTAssertNil(gdhr_pad_copy_spec(reg), "the spec is for the creating pad only, not before CREATING")
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_CREATING))
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE), "nobody may post before the pad is live")
        let s = gdhr_pad_copy_spec(reg)
        XCTAssertEqual(s, spec); world.release(s!)
        XCTAssertEqual(gdhr_pad_started(reg, pad), GDHR_OK)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_LIVE))
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_UC))
        XCTAssertEqual(gdhr_pad_is(reg, pad), 1)
        XCTAssertEqual(world.refCount(pad), 2); XCTAssertEqual(world.refCount(spec), 2)

        let c = gdhr_copy_pad(reg)
        XCTAssertEqual(c, pad); XCTAssertEqual(world.refCount(pad), 3, "accessors return +1")
        world.release(c!)

        var rc: Int32 = -1
        let taken = gdhr_pad_take(reg, gen, &rc)
        XCTAssertEqual(taken, pad); XCTAssertEqual(rc, GDHR_OK)
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE), "source is NONE as soon as the pad is taken")
        XCTAssertNil(gdhr_copy_pad(reg))
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        XCTAssertEqual(world.refCount(spec), 1, "the registry dropped the spec")
        XCTAssertEqual(world.refCount(pad), 2, "the registry's reference moved to the caller of take")
        world.release(taken!); world.release(pad); world.release(spec)
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 }, "\(world.allRefCounts)")
        assertBalanced()
    }

    func testStageRules() {
        let spec = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, 1, spec, 0), GDHR_E_NOT_OWNER, "no owner at all")
        let (uc, gen) = claimed()
        XCTAssertEqual(gdhr_pad_stage(reg, gen + 1, spec, 0), GDHR_E_NOT_OWNER, "stale generation")
        XCTAssertEqual(gdhr_pad_stage(reg, 0, spec, 0), GDHR_E_ARG)
        XCTAssertEqual(gdhr_pad_stage(reg, gen, nil, 0), GDHR_E_ARG)
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 7), GDHR_OK)
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 7), GDHR_E_BUSY, "a second createDevice while one is staged")
        createPadOver: do {
            XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
            XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_E_STATE, "begin twice")
            XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 7), GDHR_E_BUSY, "a second createDevice while CREATING")
        }
        let pad = world.newObject()
        XCTAssertEqual(gdhr_pad_started(reg, pad), GDHR_OK)
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 7), GDHR_E_BUSY, "a second createDevice while LIVE")
        var rc: Int32 = 0
        world.release(gdhr_pad_take(reg, 0, &rc)!)
        world.release(pad); world.release(spec)
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testBeginCreateRequiresStagingAndTheSameGeneration() {
        let (uc, gen) = claimed()
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_E_STATE, "destroy/create without staging")
        let spec = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 0), GDHR_OK)
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen + 5), GDHR_E_NOT_OWNER)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_STAGED), "a refused begin changes nothing")
        XCTAssertEqual(gdhr_pad_unstage(reg, gen + 5), GDHR_E_NOT_OWNER)
        XCTAssertEqual(gdhr_pad_unstage(reg, gen), GDHR_OK)
        XCTAssertEqual(gdhr_pad_unstage(reg, gen), GDHR_OK, "unstage is idempotent")
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        XCTAssertEqual(world.refCount(spec), 1)
        world.release(spec); XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        assertBalanced()
    }

    func testPadCannotStartUnlessTheRootIsCreatingIt() {
        let (uc, gen) = claimed()
        let rogue = world.newObject()
        XCTAssertEqual(gdhr_pad_started(reg, rogue), GDHR_E_STATE, "no staging at all")
        let spec = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 0), GDHR_OK)
        XCTAssertEqual(gdhr_pad_started(reg, rogue), GDHR_E_STATE, "staged but CreatePad not begun")
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
        XCTAssertEqual(gdhr_pad_started(reg, rogue), GDHR_OK)
        let second = world.newObject()
        XCTAssertEqual(gdhr_pad_started(reg, second), GDHR_E_STATE, "a second pad cannot register over the first")
        XCTAssertEqual(gdhr_pad_is(reg, second), 0); XCTAssertEqual(gdhr_pad_is(reg, rogue), 1)
        var rc: Int32 = 0
        world.release(gdhr_pad_take(reg, 0, &rc)!)
        for o in [rogue, second, spec] { world.release(o) }
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testDestroyWithoutCreateAndStaleDestroy() {
        let (uc, gen) = claimed()
        var rc: Int32 = -1
        XCTAssertNil(gdhr_pad_take(reg, gen, &rc)); XCTAssertEqual(rc, GDHR_OK, "destroy without create is a successful no-op")
        XCTAssertNil(gdhr_pad_take(reg, 0, &rc)); XCTAssertEqual(rc, GDHR_OK)
        let pad = createPad(gen: gen)
        XCTAssertNil(gdhr_pad_take(reg, gen + 1, &rc)); XCTAssertEqual(rc, GDHR_E_NOT_OWNER, "a stale client cannot destroy")
        XCTAssertEqual(gdhr_pad_is(reg, pad), 1, "and the pad is untouched")
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_UC))
        world.release(gdhr_pad_take(reg, gen, &rc)!)
        XCTAssertNil(gdhr_pad_take(reg, gen, &rc)); XCTAssertEqual(rc, GDHR_OK, "a second destroy")
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testTakeDuringCreatingEmptiesTheSlotAndTheLateStartIsRefused() {
        let (uc, gen) = claimed()
        let spec = world.newObject(), pad = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 0), GDHR_OK)
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
        var rc: Int32 = 0
        XCTAssertNil(gdhr_pad_take(reg, 0, &rc), "CREATING has no pad yet")
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        XCTAssertEqual(gdhr_pad_started(reg, pad), GDHR_E_STATE, "the pad that was still starting is refused")
        XCTAssertEqual(world.refCount(pad), 1); XCTAssertEqual(world.refCount(spec), 1)
        for o in [spec, pad] { world.release(o) }
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        assertBalanced()
    }

    func testPadStoppedIgnoresOtherPadsAndClearsItsOwn() {
        let (uc, gen) = claimed()
        let old = createPad(gen: gen)
        var rc: Int32 = 0
        world.release(gdhr_pad_take(reg, gen, &rc)!)               // destroyDevice; the old pad's Stop is still to come
        let fresh = createPad(gen: gen)                            // createDevice right after
        gdhr_pad_stopped(reg, old)                                 // the old pad's late Stop
        XCTAssertEqual(gdhr_pad_is(reg, fresh), 1, "a late Stop of a destroyed pad does not touch the new one")
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_UC))
        gdhr_pad_stopped(reg, fresh)                               // the pad stops by itself
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE))
        XCTAssertNil(gdhr_copy_pad(reg))
        gdhr_pad_stopped(reg, fresh)                               // twice is harmless
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testReleasingTheOwnerHandsBackItsPad() {
        let (uc, gen) = claimed()
        let pad = createPad(gen: gen)
        let left = gdhr_release_owner(reg, uc)
        XCTAssertEqual(left, pad, "no pad outlives its owner: the registry hands it back to be terminated")
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE))
        var rc: Int32 = 0
        XCTAssertNil(gdhr_pad_take(reg, gen, &rc))
        let spec = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 0), GDHR_E_NOT_OWNER, "the old generation is dead")
        world.release(left!); world.release(spec); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testANewOwnerCanCreateAfterTheOldOneWentAway() {
        let (uc1, gen1) = claimed()
        createPad(gen: gen1)
        world.release(gdhr_release_owner(reg, uc1)!)
        let uc2 = world.newObject()
        let gen2 = gdhr_claim_owner(reg, uc2)
        XCTAssertGreaterThan(gen2, gen1)
        createPad(gen: gen2)
        var rc: Int32 = 0
        XCTAssertNil(gdhr_pad_take(reg, gen1, &rc)); XCTAssertEqual(rc, GDHR_E_NOT_OWNER, "the first client's generation no longer matches")
        world.release(gdhr_pad_take(reg, gen2, &rc)!)
        XCTAssertNil(gdhr_release_owner(reg, uc2))
        world.release(uc1); world.release(uc2)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    // MARK: slot stuck in CREATING (Create returned before the pad's Start), and a create reported failed while LIVE

    /// stage + begin_create, no pad yet: what the root sees when Create returns first.
    private func stagedAndCreating(gen: UInt64) -> UnsafeMutableRawPointer {
        let spec = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 1), GDHR_OK)
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
        return spec
    }

    func testClassifyAfterCreateReturns() {
        let (uc, gen) = claimed()
        let spec = stagedAndCreating(gen: gen), pad = world.newObject()
        XCTAssertEqual(gdhr_pad_classify(reg, pad, gen), Int32(GDHR_CLS_CREATING), "Create returned first: the pad has not registered")
        XCTAssertEqual(gdhr_pad_classify(reg, pad, gen + 1), Int32(GDHR_CLS_NONE), "another generation's slot is not ours")
        XCTAssertEqual(gdhr_pad_started(reg, pad), GDHR_OK)
        XCTAssertEqual(gdhr_pad_classify(reg, pad, gen), Int32(GDHR_CLS_LIVE))
        let other = world.newObject()
        XCTAssertEqual(gdhr_pad_classify(reg, other, gen), Int32(GDHR_CLS_NONE), "LIVE, but another pad")
        XCTAssertEqual(gdhr_pad_classify(reg, nil, gen), Int32(GDHR_CLS_NONE))
        var rc: Int32 = 0
        world.release(gdhr_pad_take(reg, gen, &rc)!)
        XCTAssertEqual(gdhr_pad_classify(reg, pad, gen), Int32(GDHR_CLS_NONE), "the pad's start was refused or the slot emptied")
        for o in [spec, pad, other] { world.release(o) }
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testCreatingThenDestroyEmptiesTheSlot() {
        let (uc, gen) = claimed()
        let spec = stagedAndCreating(gen: gen)
        var rc: Int32 = -1
        XCTAssertNil(gdhr_pad_take(reg, gen, &rc)); XCTAssertEqual(rc, GDHR_OK, "destroyDevice while the pad is still starting")
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE))
        XCTAssertEqual(world.refCount(spec), 1, "the staged spec was dropped")
        let spec2 = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec2, 2), GDHR_OK, "a new createDevice is possible at once")
        XCTAssertEqual(gdhr_pad_unstage(reg, gen), GDHR_OK)
        for o in [spec, spec2] { world.release(o) }
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testCreatingThenOwnerReleaseEmptiesTheSlot() {
        let (uc, gen) = claimed()
        let spec = stagedAndCreating(gen: gen)
        XCTAssertNil(gdhr_release_owner(reg, uc), "no pad registered yet, so none is handed back")
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE), "but the stuck CREATING slot is emptied")
        XCTAssertEqual(world.refCount(spec), 1)
        let uc2 = world.newObject(), spec2 = world.newObject()
        let gen2 = gdhr_claim_owner(reg, uc2)
        XCTAssertEqual(gdhr_pad_stage(reg, gen2, spec2, 3), GDHR_OK, "the next owner can create")
        XCTAssertEqual(gdhr_pad_unstage(reg, gen2), GDHR_OK)
        XCTAssertNil(gdhr_release_owner(reg, uc2))
        for o in [spec, spec2, uc, uc2] { world.release(o) }
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testCreatingThenRootStopTakeAndLatePadStartIsRefused() {
        let (uc, gen) = claimed()
        let spec = stagedAndCreating(gen: gen)
        var rc: Int32 = 0
        XCTAssertNil(gdhr_pad_take(reg, 0, &rc), "root Stop: take whatever is there")
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        let late = world.newObject()
        XCTAssertEqual(gdhr_pad_started(reg, late), GDHR_E_STATE, "a pad that registers after the slot was emptied fails its start")
        XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE))
        XCTAssertNil(gdhr_copy_pad(reg))
        XCTAssertEqual(world.refCount(late), 1, "and the registry kept no reference to it")
        // a late start must not register into a NEW staging either: it needs CREATING, which only begin_create sets
        let spec2 = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec2, 4), GDHR_OK)
        XCTAssertEqual(gdhr_pad_started(reg, late), GDHR_E_STATE, "STAGED is not CREATING")
        XCTAssertEqual(gdhr_pad_unstage(reg, gen), GDHR_OK)
        for o in [spec, spec2, late] { world.release(o) }
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testCreateReportedFailedWhileLiveLeavesTheSlotEmpty() {
        // CreatePad returned an error to the user client after the pad had gone LIVE: the user client takes the pad out
        // (gdhr_pad_take with its generation) and terminates it, so the next createDevice is not Busy.
        let (uc, gen) = claimed()
        let pad = createPad(gen: gen)
        XCTAssertEqual(gdhr_pad_unstage(reg, gen), GDHR_OK, "unstage alone does not touch a LIVE slot")
        XCTAssertEqual(gdhr_pad_is(reg, pad), 1)
        var rc: Int32 = -1
        let taken = gdhr_pad_take(reg, gen, &rc)
        XCTAssertEqual(taken, pad); XCTAssertEqual(rc, GDHR_OK)
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE)); XCTAssertEqual(gdhr_pad_source(reg), UInt32(GDHR_SRC_NONE))
        world.release(taken!)
        let spec = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, 5), GDHR_OK, "the next stage succeeds")
        XCTAssertEqual(gdhr_pad_unstage(reg, gen), GDHR_OK)
        world.release(spec); XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    // MARK: root

    func testRootRegistrationReplacesAndIgnoresStaleUnregister() {
        let a = world.newObject(), b = world.newObject()
        XCTAssertEqual(gdhr_register_root(reg, a), 0)
        XCTAssertEqual(gdhr_register_root(reg, a), 0, "registering the same root twice")
        XCTAssertEqual(world.refCount(a), 2)
        XCTAssertEqual(gdhr_register_root(reg, b), 1, "a different root replaces the stale one")
        XCTAssertEqual(world.refCount(a), 1, "and the stale one is released")
        gdhr_unregister_root(reg, a)                                // the stale root's late Stop
        let c = gdhr_copy_root(reg)
        XCTAssertEqual(c, b); world.release(c!)
        gdhr_unregister_root(reg, b)
        XCTAssertNil(gdhr_copy_root(reg))
        gdhr_unregister_root(reg, b)
        world.release(a); world.release(b)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    func testStartOrderDoesNotMatter() {
        // Anything may run first after a relaunch: a pad operation, an owner claim, a root registration.
        let uc = world.newObject(), root = world.newObject()
        XCTAssertEqual(gdhr_pad_begin_create(reg, 1), GDHR_E_STATE)
        var rc: Int32 = 0
        XCTAssertNil(gdhr_pad_take(reg, 0, &rc))
        let gen = gdhr_claim_owner(reg, uc)
        XCTAssertEqual(gdhr_register_root(reg, root), 0)
        createPad(gen: gen)
        world.release(gdhr_pad_take(reg, gen, &rc)!)
        gdhr_unregister_root(reg, root)
        XCTAssertNil(gdhr_release_owner(reg, uc))
        world.release(uc); world.release(root)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }

    // MARK: atomic words, counters, snapshot

    func testSnapshotReflectsState() {
        gdhr_set_identity(reg, 0x1122334455667788, 17, 4242)
        let (uc, gen) = claimed()
        var s = gdhr_snap()
        gdhr_snapshot(reg, &s)
        XCTAssertEqual(s.nonce, 0x1122334455667788); XCTAssertEqual(s.build, 17); XCTAssertEqual(s.pid, 4242)
        XCTAssertEqual(s.ownerPresent, 1); XCTAssertEqual(s.rootPresent, 0)
        XCTAssertEqual(s.padSource, UInt32(GDHR_SRC_NONE)); XCTAssertEqual(s.desiredState, 0)
        createPad(gen: gen)
        gdhr_ctr_add(reg, Int32(GDHR_CTR_UC_POSTS.rawValue), 5)
        gdhr_ctr_add(reg, Int32(GDHR_CTR_SYNC_VIOLATIONS.rawValue), 1)
        gdhr_ctr_add(reg, -1, 9); gdhr_ctr_add(reg, 99, 9)          // out-of-range ids are ignored
        gdhr_snapshot(reg, &s)
        XCTAssertEqual(s.padState, UInt32(GDHR_PAD_LIVE)); XCTAssertEqual(s.padSource, UInt32(GDHR_SRC_UC))
        XCTAssertEqual(s.padSpecCrc, 0xABCD)
        withUnsafeBytes(of: s.counters) { raw in
            let c = raw.bindMemory(to: UInt64.self)
            XCTAssertEqual(c[Int(GDHR_CTR_UC_POSTS.rawValue)], 5)
            XCTAssertEqual(c[Int(GDHR_CTR_SYNC_VIOLATIONS.rawValue)], 1)
            XCTAssertEqual(c[Int(GDHR_CTR_UC_REJECTED.rawValue)], 0)
        }
        var rc: Int32 = 0
        world.release(gdhr_pad_take(reg, 0, &rc)!)
        gdhr_snapshot(reg, &s); XCTAssertEqual(s.padSpecCrc, 0, "no pad, no CRC")
        XCTAssertNil(gdhr_release_owner(reg, uc))
    }

    func testCountersAreExactUnderContention() {
        let id = Int32(GDHR_CTR_UC_POSTS.rawValue)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in for _ in 0..<20_000 { gdhr_ctr_add(reg, id, 1) } }
        XCTAssertEqual(gdhr_ctr_get(reg, id), 160_000)
    }

    // MARK: concurrency

    /// One thread cycles the pad slot through stage/begin/started and take-or-stopped while others copy the pad. Every
    /// copy must be a live object (never a retain after the last release), and nothing may leak.
    func testConcurrentPadCyclingAndCopying() {
        let (uc, gen) = claimed()
        let stop = ManagedFlag()
        let readers = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: readers) {
                while !stop.isSet {
                    if let p = gdhr_copy_pad(self.reg) { XCTAssertGreaterThanOrEqual(self.world.refCount(p), 1, "a copy is a live reference"); self.world.release(p) }
                    if let s = gdhr_pad_copy_spec(self.reg) { self.world.release(s) }
                    _ = gdhr_pad_source(self.reg)
                }
            }
        }
        for i in 0..<3000 {
            let spec = world.newObject(), pad = world.newObject()
            XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, UInt32(i)), GDHR_OK)
            XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
            XCTAssertEqual(gdhr_pad_started(reg, pad), GDHR_OK)
            if i % 2 == 0 {
                var rc: Int32 = 0
                world.release(gdhr_pad_take(reg, gen, &rc)!)
            } else {
                gdhr_pad_stopped(reg, pad)
            }
            world.release(spec); world.release(pad)
        }
        stop.set()
        readers.wait()
        XCTAssertEqual(gdhr_pad_state(reg), UInt32(GDHR_PAD_NONE))
        XCTAssertNil(gdhr_release_owner(reg, uc)); world.release(uc)
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 }, "leak or over-release")
        assertBalanced()
    }

    func testConcurrentRootRegisterUnregister() {
        let roots = (0..<8).map { _ in world.newObject() }
        DispatchQueue.concurrentPerform(iterations: roots.count) { t in
            for _ in 0..<2000 {
                _ = gdhr_register_root(self.reg, roots[t])
                if let c = gdhr_copy_root(self.reg) { self.world.release(c) }
                gdhr_unregister_root(self.reg, roots[t])
            }
        }
        for r in roots { gdhr_unregister_root(reg, r) }
        XCTAssertNil(gdhr_copy_root(reg), "every root unregistered or replaced: none left")
        for r in roots { world.release(r) }
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 }, "\(world.allRefCounts)")
        assertBalanced()
    }

    func testConcurrentClaimHasOneWinner() {
        let clients = (0..<8).map { _ in world.newObject() }
        let gens = UnsafeMutablePointer<UInt64>.allocate(capacity: clients.count); gens.initialize(repeating: 0, count: clients.count)
        defer { gens.deallocate() }
        DispatchQueue.concurrentPerform(iterations: clients.count) { i in gens[i] = gdhr_claim_owner(self.reg, clients[i]) }
        let winners = (0..<clients.count).filter { gens[$0] != 0 }
        XCTAssertEqual(winners.count, 1)
        XCTAssertNil(gdhr_release_owner(reg, clients[winners[0]]))
        for c in clients { world.release(c) }
        XCTAssertTrue(world.allRefCounts.allSatisfy { $0 == 0 })
        assertBalanced()
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var isSet: Bool { l.lock(); defer { l.unlock() }; return v }
    func set() { l.lock(); v = true; l.unlock() }
}

import XCTest
import GDHubDextCore
import GDHubXlate
@testable import GDHub

/// T5 (SHADOW): the mapping handoff and self-test word of the DriverKit-free core, the parity record seqlock, the status2
/// T5 layout in lockstep with the Swift decoder, selector 10 and the SHADOW rules in the dext's source, and the engine's
/// side (supervisor pushes, parity sampler).
private let xlateFakeOps: UnsafeMutablePointer<gdhr_ops> = {
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

final class DextMapHandoffTests: XCTestCase {
    private var world: FakeWorld { .shared }
    private var reg: UnsafeMutablePointer<gdhr>!
    private let crc: UInt32 = 0xABCD

    override func setUp() {
        world.reset()
        reg = UnsafeMutablePointer<gdhr>.allocate(capacity: 1)
        reg.initialize(to: gdhr())
        XCTAssertEqual(gdhr_ensure(reg, xlateFakeOps), 1)
    }
    override func tearDown() { reg.deallocate() }

    private func owner() -> (uc: UnsafeMutableRawPointer, gen: UInt64) {
        let uc = world.newObject()
        let gen = gdhr_claim_owner(reg, uc)
        XCTAssertGreaterThan(gen, 0)
        return (uc, gen)
    }

    private func livePad(gen: UInt64) {
        let spec = world.newObject(), pad = world.newObject()
        XCTAssertEqual(gdhr_pad_stage(reg, gen, spec, crc), GDHR_OK)
        XCTAssertEqual(gdhr_pad_begin_create(reg, gen), GDHR_OK)
        XCTAssertEqual(gdhr_pad_started(reg, pad), GDHR_OK)
        world.release(spec); world.release(pad)
    }

    private func publish(_ uc: UnsafeMutableRawPointer, _ bytes: [UInt8], rev: UInt32, crc c: UInt32? = nil) -> Int32 {
        bytes.withUnsafeBufferPointer { gdhr_map_publish(reg, uc, $0.baseAddress, UInt32($0.count), rev, c ?? crc) }
    }

    private func read() -> (ok: Bool, bytes: [UInt8], seq: UInt32, rev: UInt32, crc: UInt32) {
        var buf = [UInt8](repeating: 0, count: Int(GDH_MAP_MAX))
        var len: UInt32 = 0, seq: UInt32 = 0, rev: UInt32 = 0, c: UInt32 = 0
        let ok = gdhr_map_read(reg, &buf, UInt32(buf.count), &len, &seq, &rev, &c) != 0
        return (ok, Array(buf.prefix(Int(len))), seq, rev, c)
    }

    func testNoMapUntilPublished() {
        let r = read()
        XCTAssertTrue(r.ok); XCTAssertTrue(r.bytes.isEmpty); XCTAssertEqual(r.rev, 0)
        XCTAssertEqual(gdhr_map_seq(reg) & 1, 0)
    }

    func testPublishNeedsTheOwnerAPadAndTheSpecAndASize() {
        let (uc, gen) = owner()
        let bytes = [UInt8](repeating: 0x5A, count: 200)
        XCTAssertEqual(publish(uc, bytes, rev: 1), GDHR_E_NO_PAD, "no pad: nothing to target")
        livePad(gen: gen)
        let stranger = world.newObject()
        XCTAssertEqual(publish(stranger, bytes, rev: 1), GDHR_E_NOT_OWNER, "owner only")
        XCTAssertEqual(publish(uc, bytes, rev: 1, crc: crc ^ 1), GDHR_E_SPEC, "another spec CRC")
        XCTAssertEqual(publish(uc, [], rev: 1), GDHR_E_SIZE)
        XCTAssertEqual(publish(uc, [UInt8](repeating: 1, count: Int(GDH_MAP_MAX) + 1), rev: 1), GDHR_E_SIZE)
        XCTAssertTrue(read().bytes.isEmpty, "none of the refusals stored anything")
        XCTAssertEqual(publish(uc, bytes, rev: 7), GDHR_OK)
        let r = read()
        XCTAssertTrue(r.ok); XCTAssertEqual(r.bytes, bytes); XCTAssertEqual(r.rev, 7); XCTAssertEqual(r.crc, crc)
        XCTAssertEqual(publish(uc, [UInt8](repeating: 9, count: Int(GDH_MAP_MAX)), rev: 8), GDHR_OK, "exactly the maximum fits")
    }

    func testSequenceMovesByTwoPerPublishAndStaysEvenAtRest() {
        let (uc, gen) = owner(); livePad(gen: gen)
        var last = gdhr_map_seq(reg)
        for rev in 1...20 as ClosedRange<UInt32> {
            XCTAssertEqual(publish(uc, [UInt8](repeating: UInt8(rev), count: 64), rev: rev), GDHR_OK)
            let s = gdhr_map_seq(reg)
            XCTAssertEqual(s & 1, 0); XCTAssertEqual(s, last &+ 2); last = s
            XCTAssertEqual(read().rev, rev)
        }
    }

    /// Rule C: the mapping goes with the owner and with the pad; it is never carried to the next one.
    func testOwnerLossAndPadLossDropTheMap() {
        let (uc, gen) = owner(); livePad(gen: gen)
        XCTAssertEqual(publish(uc, [UInt8](repeating: 3, count: 100), rev: 4), GDHR_OK)
        let before = gdhr_map_seq(reg)
        let dropped = gdhr_release_owner(reg, uc)
        if let d = dropped { world.release(d) }
        XCTAssertTrue(read().bytes.isEmpty, "owner released: no map")
        XCTAssertNotEqual(gdhr_map_seq(reg), before, "the reader sees the change")
        let (uc2, gen2) = owner(); livePad(gen: gen2)
        XCTAssertTrue(read().bytes.isEmpty, "a new owner starts without a map")
        XCTAssertEqual(publish(uc2, [UInt8](repeating: 5, count: 100), rev: 5), GDHR_OK)
        var rc: Int32 = 0
        if let pad = gdhr_pad_take(reg, gen2, &rc) { world.release(pad) }
        XCTAssertTrue(read().bytes.isEmpty, "the pad was taken: the map targeted it")
    }

    func testClearAndSnapshotFields() {
        let (uc, gen) = owner(); livePad(gen: gen)
        var snap = gdhr_snap()
        gdhr_snapshot(reg, &snap)
        XCTAssertEqual(snap.hasMap, 0); XCTAssertEqual(snap.acceptedRevision, 0)
        XCTAssertEqual(publish(uc, [UInt8](repeating: 1, count: 80), rev: 12), GDHR_OK)
        gdhr_snapshot(reg, &snap)
        XCTAssertEqual(snap.hasMap, 1); XCTAssertEqual(snap.acceptedRevision, 12); XCTAssertEqual(snap.acceptedSpecCrc, crc)
        gdhr_map_clear(reg)
        gdhr_snapshot(reg, &snap)
        XCTAssertEqual(snap.hasMap, 0)
    }

    /// The consistency promise: a reader that gets `ok` holds one whole mapping, never a mix of two. A writer swaps maps of
    /// different lengths whose every byte equals the revision's low byte.
    func testConcurrentSwapVersusReadNeverTears() {
        let (uc, gen) = owner(); livePad(gen: gen)
        // the first mapping obeys the same rule as every later one (length 8 + rev % 1000, every byte the revision's low byte), so a reader that
        // runs before the writer's first swap is not mistaken for a torn read (this was the one flaky failure in ~1 of 8 runs)
        XCTAssertEqual(publish(uc, [UInt8](repeating: 1, count: 9), rev: 1), GDHR_OK)
        let stop = ManagedAtomicFlag(), torn = AtomicCount(), reads = AtomicCount(), publishes = AtomicCount()
        let regPtr = UnsafeRawPointer(reg)!
        let group = DispatchGroup()
        let writer = Thread { [self] in
            defer { group.leave() }
            var rev: UInt32 = 2
            while !stop.isSet {
                let len = 8 + Int(rev % 1000)
                XCTAssertEqual(publish(uc, [UInt8](repeating: UInt8(truncatingIfNeeded: rev), count: len), rev: rev), GDHR_OK)
                publishes.add(); rev &+= 1
            }
        }
        let readers = (0..<3).map { _ in Thread {
            defer { group.leave() }
            var buf = [UInt8](repeating: 0, count: Int(GDH_MAP_MAX))
            let r = regPtr.assumingMemoryBound(to: gdhr.self)
            while !stop.isSet {
                var len: UInt32 = 0, seq: UInt32 = 0, rev: UInt32 = 0, c: UInt32 = 0
                guard gdhr_map_read(r, &buf, UInt32(buf.count), &len, &seq, &rev, &c) != 0 else { continue }
                reads.add()
                if seq & 1 != 0 || len == 0 || len != 8 + rev % 1000 || c != 0xABCD { torn.add(); continue }
                let want = UInt8(truncatingIfNeeded: rev)
                for i in 0..<Int(len) where buf[i] != want { torn.add(); break }
            }
        } }
        group.enter(); readers.forEach { _ in group.enter() }
        writer.start(); readers.forEach { $0.start() }
        // run for at least 0.6 s and until there is enough traffic (a loaded machine takes longer, never fails for being slow)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 0.6 || ((reads.value <= 100 || publishes.value <= 100) && Date().timeIntervalSince(t0) < 10) { Thread.sleep(forTimeInterval: 0.01) }
        stop.set()
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "all threads ended before the registry goes away")
        XCTAssertEqual(torn.value, 0, "torn reads out of \(reads.value)")
        XCTAssertGreaterThan(reads.value, 100); XCTAssertGreaterThan(publishes.value, 100)
        XCTAssertEqual(world.releasesUnderLock, 0)
    }

    func testSelfTestWordRunsOnceAndASecondCallerSeesRunning() {
        XCTAssertEqual(gdhr_selftest_get(reg), UInt32(GDHR_SELFTEST_NOT_RUN))
        XCTAssertEqual(gdhr_selftest_begin(reg), 1)
        XCTAssertEqual(gdhr_selftest_begin(reg), 0, "a second caller does not run it again")
        XCTAssertEqual(gdhr_selftest_get(reg), UInt32(GDHR_SELFTEST_RUNNING), "and sees RUNNING, which the caller answers with NotReady, never with 'failed'")
        gdhr_selftest_finish(reg, 1)
        XCTAssertEqual(gdhr_selftest_get(reg), UInt32(GDHR_SELFTEST_PASS))
        XCTAssertEqual(gdhr_selftest_begin(reg), 0, "a finished test is not run again in this process")
        var snap = gdhr_snap(); gdhr_snapshot(reg, &snap)
        XCTAssertEqual(snap.selfTest, UInt32(GDHR_SELFTEST_PASS))
    }

    func testOwnerCheckForTheSelfTest() {
        let (uc, _) = owner()
        XCTAssertEqual(gdhr_is_owner(reg, uc), 1)
        XCTAssertEqual(gdhr_is_owner(reg, world.newObject()), 0, "a stranger cannot make the process run translator code")
        XCTAssertEqual(gdhr_is_owner(reg, nil), 0)
    }

    func testFailedSelfTestStaysFailed() {
        XCTAssertEqual(gdhr_selftest_begin(reg), 1)
        gdhr_selftest_finish(reg, 0)
        XCTAssertEqual(gdhr_selftest_get(reg), UInt32(GDHR_SELFTEST_FAIL))
        XCTAssertEqual(gdhr_selftest_begin(reg), 0)
    }

    func testShadowIsAnAcceptedForwardingStateAndTheTapDecisionTreatsItLikeCount() {
        XCTAssertEqual(gdh_fwd_validate(0, 0), 0); XCTAssertEqual(gdh_fwd_validate(1, 0), 0); XCTAssertEqual(gdh_fwd_validate(2, 0), 0)
        XCTAssertEqual(gdh_fwd_validate(3, 0), 0, "LIVE (T7)"); XCTAssertNotEqual(gdh_fwd_validate(4, 0), 0)
        XCTAssertNotEqual(gdh_fwd_validate(2, 1), 0, "no flags")
        XCTAssertEqual(gdh_tap_decide(2, 0, 1, 0, 1), gdh_tap_decide(1, 0, 1, 0, 1))
        XCTAssertEqual(gdh_tap_decide(2, 1, 1, 0, 1), gdh_tap_decide(1, 1, 1, 0, 1))
    }
}

private final class AtomicCount: @unchecked Sendable {
    private var n: UInt64 = 0
    private let l = NSLock()
    func add() { l.lock(); n += 1; l.unlock() }
    var value: UInt64 { l.lock(); defer { l.unlock() }; return n }
}
private final class ManagedAtomicFlag: @unchecked Sendable {
    private var v = false
    private let l = NSLock()
    func set() { l.lock(); v = true; l.unlock() }
    var isSet: Bool { l.lock(); defer { l.unlock() }; return v }
}

final class DextParityRecordTests: XCTestCase {
    private func rec(_ n: UInt32) -> gdh_parity_rec {
        var r = gdh_parity_rec()
        withUnsafeMutableBytes(of: &r.frame) { $0.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: n)) }
        withUnsafeMutableBytes(of: &r.out01) { $0.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: n)) }
        withUnsafeMutableBytes(of: &r.out02) { $0.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: n)) }
        r.timestamp = UInt64(n) &* 1000 &+ 1; r.revision = n; r.count = n
        return r
    }

    func testRoundTrip() {
        let p = UnsafeMutablePointer<gdh_parity>.allocate(capacity: 1); p.initialize(to: gdh_parity()); defer { p.deallocate() }
        var out = gdh_parity_rec()
        XCTAssertEqual(gdh_parity_read(p, &out), 1)
        XCTAssertEqual(out.count, 0); XCTAssertEqual(out.timestamp, 0, "nothing recorded yet")
        var w = rec(0x42); gdh_parity_write(p, &w)
        XCTAssertEqual(gdh_parity_read(p, &out), 1)
        XCTAssertEqual(out.count, 0x42); XCTAssertEqual(out.revision, 0x42); XCTAssertEqual(out.timestamp, 0x42 * 1000 + 1)
        withUnsafeBytes(of: &out.frame) { XCTAssertTrue($0.allSatisfy { $0 == 0x42 }) }
        withUnsafeBytes(of: &out.out01) { XCTAssertTrue($0.allSatisfy { $0 == 0x42 }) }
        withUnsafeBytes(of: &out.out02) { XCTAssertTrue($0.allSatisfy { $0 == 0x42 }) }
        XCTAssertEqual(MemoryLayout<gdh_parity_rec>.size, 56)
    }

    func testReaderNeverSeesAMixOfTwoRecords() {
        let p = UnsafeMutablePointer<gdh_parity>.allocate(capacity: 1); p.initialize(to: gdh_parity()); defer { p.deallocate() }
        let ptr = UnsafeRawPointer(p)!
        let stop = ManagedAtomicFlag(), torn = AtomicCount(), reads = AtomicCount()
        let group = DispatchGroup()
        let writer = Thread {
            defer { group.leave() }
            let q = UnsafeMutableRawPointer(mutating: ptr).assumingMemoryBound(to: gdh_parity.self)
            var n: UInt32 = 1
            while !stop.isSet { var r = self.rec(n); gdh_parity_write(q, &r); n &+= 1 }
        }
        let readers = (0..<3).map { _ in Thread {
            defer { group.leave() }
            let q = ptr.assumingMemoryBound(to: gdh_parity.self)
            var out = gdh_parity_rec()
            while !stop.isSet {
                guard gdh_parity_read(q, &out) != 0, out.count != 0 else { continue }
                reads.add()
                let b = UInt8(truncatingIfNeeded: out.count)
                var bad = out.timestamp != UInt64(out.count) &* 1000 &+ 1 || out.revision != out.count
                withUnsafeBytes(of: &out.frame) { if !$0.allSatisfy({ $0 == b }) { bad = true } }
                withUnsafeBytes(of: &out.out01) { if !$0.allSatisfy({ $0 == b }) { bad = true } }
                withUnsafeBytes(of: &out.out02) { if !$0.allSatisfy({ $0 == b }) { bad = true } }
                if bad { torn.add() }
            }
        } }
        group.enter(); readers.forEach { _ in group.enter() }
        writer.start(); readers.forEach { $0.start() }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 0.6 || (reads.value <= 100 && Date().timeIntervalSince(t0) < 10) { Thread.sleep(forTimeInterval: 0.01) }
        stop.set()
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "all threads ended before the record goes away")
        XCTAssertEqual(torn.value, 0, "torn out of \(reads.value)")
        XCTAssertGreaterThan(reads.value, 100)
    }
}

final class DextStatus2T5Tests: XCTestCase {
    func testPackedT5FieldsDecodeByOffset() throws {
        var s = gdhr_snap(); s.build = 23; s.tapPresent = 1; s.tapApplied = 2
        s.selfTest = UInt32(GDHR_SELFTEST_PASS); s.tapTranslating = 1; s.hasMap = 1
        s.acceptedRevision = 9; s.appliedRevision = 8; s.acceptedSpecCrc = 0xCAFEBABE
        withUnsafeMutableBytes(of: &s.counters) { c in
            let u = c.bindMemory(to: UInt64.self)
            u[Int(GDHR_CTR_FRAMES_TRANSLATED.rawValue)] = 1_000_000_000_001
            u[Int(GDHR_CTR_FRAMES_SKIPPED.rawValue)] = 2; u[Int(GDHR_CTR_FRAMES_NOMAP.rawValue)] = 3; u[Int(GDHR_CTR_FRAMES_UNMAPPED.rawValue)] = 4
            u[Int(GDHR_CTR_STATES_CHANGED.rawValue)] = 5; u[Int(GDHR_CTR_REPORTS_WOULD_POST.rawValue)] = 6; u[Int(GDHR_CTR_MAP_ACCEPTED.rawValue)] = 7
            u[Int(GDHR_CTR_MAP_REFUSED.rawValue)] = 8; u[Int(GDHR_CTR_MAP_SWAPS.rawValue)] = 9
        }
        var extra = gdh_status2_extra()
        extra.xlate = gdh_summary(count: 300, p50Ns: 800, p99Ns: 2_000, maxNs: 5_000, meanNs: 900)
        extra.haveParity = 1
        extra.parity.timestamp = 0x1122334455667788; extra.parity.revision = 9; extra.parity.count = 77
        withUnsafeMutableBytes(of: &extra.parity.frame) { for i in 0..<16 { $0[i] = UInt8(0x10 + i) } }
        withUnsafeMutableBytes(of: &extra.parity.out01) { for i in 0..<16 { $0[i] = UInt8(0x30 + i) } }
        withUnsafeMutableBytes(of: &extra.parity.out02) { $0[0] = 0x02; $0[1] = 0x0F }
        var buf = [UInt8](repeating: 0xEE, count: 1024)
        let n = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, nil, &extra)
        XCTAssertEqual(n, DextStatus2.size)
        XCTAssertEqual(n, 676)
        let d = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(n))))
        XCTAssertEqual(d.declaredSize, 676)
        XCTAssertEqual(d.selfTest, DextProtocol.SelfTest.pass); XCTAssertTrue(d.translating); XCTAssertTrue(d.hasMap)
        XCTAssertEqual(d.acceptedRevision, 9); XCTAssertEqual(d.appliedRevision, 8); XCTAssertEqual(d.acceptedSpecCRC, 0xCAFEBABE)
        XCTAssertEqual(d.framesTranslated, 1_000_000_000_001); XCTAssertEqual(d.framesSkipped, 2); XCTAssertEqual(d.framesNoMap, 3)
        XCTAssertEqual(d.framesUnmapped, 4); XCTAssertEqual(d.statesChanged, 5); XCTAssertEqual(d.reportsWouldPost, 6)
        XCTAssertEqual(d.mapAccepted, 7); XCTAssertEqual(d.mapRefused, 8); XCTAssertEqual(d.mapSwaps, 9)
        XCTAssertEqual(d.xlate, DextMeterSummary(count: 300, p50Ns: 800, p99Ns: 2_000, maxNs: 5_000, meanNs: 900))
        let p = try XCTUnwrap(d.parity)
        XCTAssertEqual(p.timestamp, 0x1122334455667788); XCTAssertEqual(p.revision, 9); XCTAssertEqual(p.count, 77)
        XCTAssertEqual(p.frame, (0..<16).map { UInt8(0x10 + $0) })
        XCTAssertEqual(p.out01, (0..<16).map { UInt8(0x30 + $0) })
        XCTAssertEqual(p.out02, [0x02, 0x0F])
        XCTAssertEqual(buf[n], 0xEE, "nothing past the declared size is written")
    }

    func testWithoutExtrasTheT5FieldsAreZeroAndThereIsNoParityRecord() throws {
        var s = gdhr_snap()
        var buf = [UInt8](repeating: 0xEE, count: 1024)
        let n = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, nil, nil)
        let d = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(n))))
        XCTAssertNil(d.parity); XCTAssertEqual(d.xlate, DextMeterSummary()); XCTAssertEqual(d.framesTranslated, 0)
    }

    /// The offsets of the C header and of the Swift decoder are the same numbers (the broader lockstep test is
    /// DextProtocolTests.testEveryHeaderDefineMatchesSwift); here the T5 block is packed and every field is found at the
    /// documented place, the old offsets untouched.
    func testOldOffsetsDidNotMoveAndTheT5BlockFollowsTheLastOldField() {
        typealias O = DextStatus2.Offset
        XCTAssertEqual(O.tapFrees, 308); XCTAssertEqual(O.k2dMean, 272); XCTAssertEqual(O.openFailures, 248)
        XCTAssertEqual(O.selfTest, 316, "right after tapFrees (308) + 8")
        XCTAssertEqual(O.parityOut02 + 2, 478, "the T5 block still ends at 478; T7 appends from 480")
        XCTAssertLessThanOrEqual(DextStatus2.size, DextStatus2.maxSize)
        XCTAssertEqual(DextStatus2.size, 676); XCTAssertEqual(DextStatus2.maxSize, 1024)
    }

    func testOldAppReadsOnlyItsPrefixOfTheNewStructure() throws {
        // A build-22 app: offers 512, reads what it knows (offsets below 316) from the first 480 bytes. The app of build 22
        // decodes by offset, so the same decoder reading only the old prefix sees the old fields unchanged.
        var s = gdhr_snap(); s.build = 23; s.tapPresent = 1; s.tapOpened = 1; s.tapApplied = 1
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, nil, nil)
        let old = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(316))))
        XCTAssertTrue(old.tapPresent); XCTAssertTrue(old.tapOpened); XCTAssertEqual(old.appliedState, 1)
        XCTAssertEqual(old.framesTranslated, 0)
        XCTAssertEqual(n, 676)
    }
}

final class XlateCapabilityGatingTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.vhid.xlate")
    private let build22 = DextProtocol.Capability.pad | DextProtocol.Capability.rootPad | DextProtocol.Capability.tap
    private let build23 = DextProtocol.Capability.pad | DextProtocol.Capability.rootPad | DextProtocol.Capability.tap | DextProtocol.Capability.xlate

    private final class Recorder: @unchecked Sendable {
        var calls: [(UInt32, [UInt64], [UInt8]?)] = []
        func call(_ sel: UInt32, _ sc: [UInt64], _ outCount: Int, _ cap: Int, _ structIn: [UInt8]?) -> DextRawResult {
            calls.append((sel, sc, structIn))
            if sel == DextProtocol.Selector.setMapping { return DextRawResult(kr: KERN_SUCCESS, scalars: [5, 0]) }
            return DextRawResult(kr: KERN_SUCCESS, scalars: [0, 1, 1, 0])
        }
    }

    private func client(_ caps: UInt64, _ rec: Recorder) -> DextClient {
        let c = DextClient(queue: queue)
        queue.sync { c.attachFakeDext(capabilities: caps, call: rec.call) }
        return c
    }

    func testNewAppWithBuild22DextSendsNeitherShadowNorTheMapping() {
        let rec = Recorder(); let c = client(build22, rec)
        queue.sync {
            XCTAssertFalse(c.hasXlate)
            XCTAssertEqual(c.setForwarding(DextProtocol.Forwarding.shadow).kr, DextProtocol.krUnsupported)
            let m = c.setMapping([UInt8](repeating: 0, count: 100))
            XCTAssertEqual(m.kr, DextProtocol.krUnsupported); XCTAssertNil(m.result)
            XCTAssertTrue(rec.calls.isEmpty, "selector 10 and state SHADOW are not sent without CAP_XLATE")
            XCTAssertEqual(c.setForwarding(DextProtocol.Forwarding.count).kr, KERN_SUCCESS, "COUNT still works on build 22")
        }
    }

    func testNewAppWithNewDextSendsShadowAndTheMapping() {
        let rec = Recorder(); let c = client(build23, rec)
        queue.sync {
            XCTAssertTrue(c.hasXlate)
            XCTAssertEqual(c.setForwarding(DextProtocol.Forwarding.shadow).kr, KERN_SUCCESS)
            XCTAssertEqual(rec.calls.last?.0, 9); XCTAssertEqual(rec.calls.last?.1, [2, 0, 0])
            let blob = [UInt8](repeating: 7, count: 300)
            let m = c.setMapping(blob)
            XCTAssertEqual(m.kr, KERN_SUCCESS)
            XCTAssertEqual(m.result, DextMappingResult(words: [5, 0])); XCTAssertEqual(m.result?.accepted, true)
            XCTAssertEqual(rec.calls.last?.0, 10); XCTAssertEqual(rec.calls.last?.1, []); XCTAssertEqual(rec.calls.last?.2, blob)
            XCTAssertEqual(c.setForwarding(3).kr, DextProtocol.krUnsupported, "LIVE is still not sent")
        }
    }

    func testMappingSizeIsCheckedBeforeSending() {
        let rec = Recorder(); let c = client(build23, rec)
        queue.sync {
            XCTAssertEqual(c.setMapping([]).kr, DextProtocol.krBadArgument)
            XCTAssertEqual(c.setMapping([UInt8](repeating: 0, count: 63)).kr, DextProtocol.krBadArgument)
            XCTAssertEqual(c.setMapping([UInt8](repeating: 0, count: 1025)).kr, DextProtocol.krBadArgument)
            XCTAssertTrue(rec.calls.isEmpty)
            XCTAssertEqual(c.setMapping([UInt8](repeating: 0, count: 64)).kr, KERN_SUCCESS)
            XCTAssertEqual(c.setMapping([UInt8](repeating: 0, count: 1024)).kr, KERN_SUCCESS)
            XCTAssertEqual(rec.calls.count, 2)
        }
    }

    /// An old app (build 22) against the new dext: it never asks for SHADOW or selector 10, ignores the capability bit it does
    /// not know, and COUNT behaves as before. Its contracts on the wire are unchanged.
    func testBuild22AppContractsAgainstTheNewDext() {
        XCTAssertEqual(DextProtocol.Selector.setForwarding, 9); XCTAssertEqual(DextProtocol.Selector.getStatus2, 11)
        XCTAssertEqual(DextProtocol.Capability.xlate, 1 << 10)
        XCTAssertEqual(build22 & DextProtocol.Capability.xlate, 0)
        XCTAssertEqual(DextProtocol.Forwarding.count, 1)
        XCTAssertEqual(DextProtocol.Forwarding.inert, 0)
    }

    func testMapReasonTexts() {
        let gdx: (Int32) -> String = { "gdx\($0)" }
        XCTAssertEqual(DextProtocol.MapReason.text(DextProtocol.MapReason.noPad, gdxText: gdx), "no pad has been created yet")
        XCTAssertTrue(DextProtocol.MapReason.text(DextProtocol.MapReason.tooBig, gdxText: gdx).contains("fit"))
        XCTAssertEqual(DextProtocol.MapReason.text(3, gdxText: gdx), "gdx3", "1...21 are the translator's own reasons")
        XCTAssertEqual(DextProtocol.MapReason.text(5, gdxText: gdx), "gdx5")
    }
}

/// Selector 10 and the SHADOW rules in the dext's source, where no device is needed (the same approach as the tap source
/// tests): the order of the checks, what the per-frame path does not contain, the build flag.
final class DextXlateSourceTests: XCTestCase {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func text(_ rel: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8) }

    private func body(_ src: String, from start: String, to end: String? = nil) throws -> String {
        let s = try XCTUnwrap(src.range(of: start), start)
        let rest = src[s.lowerBound...]
        if let end, let e = rest.dropFirst(start.count).range(of: end) { return String(rest[..<e.lowerBound]) }
        return String(rest)
    }

    func testSelectorTenChecksTheSizeThenThePadThenTheMapThenPublishes() throws {
        let g = try body(try text("Dext/GDHubVirtualHID/GDHubXlateGlue.cpp"), from: "kern_return_t GDHubMapAccept")
        let size = try XCTUnwrap(g.range(of: "len > GDX_BLOB_MAX")).lowerBound
        let pad = try XCTUnwrap(g.range(of: "GDHR_PAD_LIVE")).lowerBound
        let validate = try XCTUnwrap(g.range(of: "gdx_validate(")).lowerBound
        let publish = try XCTUnwrap(g.range(of: "gdhr_map_publish(")).lowerBound
        XCTAssertTrue(size < pad && pad < validate && validate < publish, "size, live pad, gdx_validate, then publish")
        XCTAssertTrue(g.contains("GDHUB_MAP_NO_PAD")); XCTAssertTrue(g.contains("GDX_E_SPEC_CRC"), "a distinct reason for another spec CRC")
        XCTAssertTrue(g.contains("kIOReturnNotPermitted"), "a non-owner is refused")
    }

    func testSelectorTenIsInTheTableWithAVariableInputAndTwoScalars() throws {
        let u = try text("Dext/GDHubVirtualHID/GDHubVirtualHIDUserClient.cpp")
        XCTAssertTrue(u.contains("/* 10 setMapping   */ { sSetMapping,     0, 0, kIOUserClientVariableStructureSize,                 2, 0 }"))
        XCTAssertTrue(u.contains("GDHUB_CAP_XLATE"))
        let sel9 = try body(u, from: "static kern_return_t sSetForwarding", to: "static kern_return_t sSetMapping")
        XCTAssertTrue(sel9.contains("st != GDHR_SELFTEST_PASS"), "SHADOW is refused until the self-test passed")
        XCTAssertTrue(sel9.contains("gdhr_set_desired_if_owner"), "owner only, race free against release_owner")
    }

    /// Review 1a: translator code runs only after an OWNER's first SHADOW request, on the root's queue (selector 9). Not from a tap
    /// Start, so an INERT or COUNT-only process never executes any of it.
    func testTheSelfTestRunsOnlyFromSelectorNineForTheOwner() throws {
        let tap = try text("Dext/GDHubVirtualHID/GDHubReceiverTap.cpp")
        XCTAssertFalse(tap.contains("GDHubSelfTestEnsure"), "the tap's Start does not run it")
        let sel9 = try body(try text("Dext/GDHubVirtualHID/GDHubVirtualHIDUserClient.cpp"), from: "static kern_return_t sSetForwarding", to: "static kern_return_t sSetMapping")
        let shadow = try XCTUnwrap(sel9.range(of: "== GDHUB_FWD_SHADOW")).lowerBound
        let owner = try XCTUnwrap(sel9.range(of: "gdhr_is_owner(", range: shadow..<sel9.endIndex)).lowerBound
        let run = try XCTUnwrap(sel9.range(of: "GDHubSelfTestEnsure()")).lowerBound
        let set = try XCTUnwrap(sel9.range(of: "gdhr_set_desired_if_owner(", range: shadow..<sel9.endIndex)).lowerBound
        XCTAssertTrue(shadow < owner && owner < run && run < set, "SHADOW request, owner check, self-test, then the state")
        XCTAssertTrue(sel9.contains("kIOReturnNotReady"), "RUNNING is 'ask again', never 'failed'")
        // no other caller anywhere in the dext sources
        let fm = FileManager.default
        let dir = repo.appendingPathComponent("Dext/GDHubVirtualHID")
        for case let u as URL in fm.enumerator(at: dir, includingPropertiesForKeys: nil)! where ["cpp", "c", "h"].contains(u.pathExtension) {
            let t = try String(contentsOf: u, encoding: .utf8)
            if u.lastPathComponent == "GDHubXlateGlue.cpp" || u.lastPathComponent == "GDHubInternal.h" || u.lastPathComponent == "GDHubVirtualHIDUserClient.cpp" { continue }
            XCTAssertFalse(t.contains("GDHubSelfTestEnsure"), u.lastPathComponent)
            XCTAssertFalse(t.contains("gdx_validate(") && u.pathExtension == "cpp", "only the glue validates: \(u.lastPathComponent)")
        }
        XCTAssertFalse(try text("Dext/GDHubVirtualHID/Core/GDHubRegistryCore.c").contains("gdhr_selftest_wait"), "no spin")
        XCTAssertFalse(try text("Dext/GDHubVirtualHID/Core/GDHubDextCore.h").contains("gdhr_selftest_wait"))
    }

    /// Review 7: on a pool miss the tap never reads a kernel-owned buffer.
    func testReportAvailableNeverReadsAKernelOwnedBuffer() throws {
        let t = try text("Dext/GDHubVirtualHID/GDHubReceiverTap.cpp")
        let ra = try body(t, from: "void IMPL(GDHubReceiverTap, ReportAvailable)", to: "\n}\n")
        XCTAssertFalse(ra.contains("GetAddressRange")); XCTAssertFalse(ra.contains("OSDynamicCast")); XCTAssertFalse(ra.contains("CreateMapping"))
        XCTAssertTrue(ra.contains("iv->poolAddr[slot]")); XCTAssertTrue(ra.contains("GDHR_CTR_FRAMES_UNMAPPED"))
    }

    /// Rule D: what `shadowFrame` does not contain.
    func testShadowFrameHasNoLockAllocationOrLog() throws {
        let t = try text("Dext/GDHubVirtualHID/GDHubReceiverTap.cpp")
        let raw = try body(t, from: "static void shadowFrame", to: "\n}\n")
        let f = raw.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)     // comments may use any word
        let loader = try body(t, from: "static bool loadMap", to: "\n}\n")
        for banned in ["IOLock", "IONew", "OSData::", "GDLog", "os_log", "IOMalloc", "new ", "malloc", "->retain", "->release",
                       "gdhr_copy_", "gdhr_map_publish", "IOLockLock", "libm", "fma", "sqrt", "round("] {
            XCTAssertFalse(f.contains(banned), "shadowFrame must not use \(banned)")
        }
        XCTAssertTrue(f.contains("loadMap("), "the per-frame map check")
        XCTAssertTrue(loader.contains("gdhr_map_seq"), "one acquire load per frame")
        XCTAssertTrue(loader.contains("gdx_reset"), "the translator state is reset on a map change")
        for lived in ["gdhr_hold(", "gdhr_pad_epoch(", "gdhr_tap_token(", "gdhr_pad_source("] { XCTAssertTrue(f.contains(lived), "LIVE gate: \(lived)") }
        XCTAssertFalse(f.contains("GDHubCopyPad"), "no registry lock on the frame path: the pad reference is held across frames")
        XCTAssertTrue(f.contains("GDHR_CTR_FRAMES_SKIPPED"))
        XCTAssertTrue(f.contains("GDHR_CTR_FRAMES_NOMAP"))
        XCTAssertTrue(f.contains("gdh_parity_write"))
    }

    func testMeterLogLineStaysUnder250Characters() throws {
        let t = try text("Dext/GDHubVirtualHID/GDHubReceiverTap.cpp")
        let fmt = try XCTUnwrap(t.range(of: "tap meter b=")).lowerBound
        let line = String(t[fmt...].prefix(while: { $0 != ")" || false }))
        // worst case: every %u as 10 digits, every %llu as 20, literal text as written; the format string ends at the closing quote
        let quoted = try XCTUnwrap(t[fmt...].split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false).first)
        _ = line
        var worst = 0
        var i = quoted.startIndex
        while i < quoted.endIndex {
            if quoted[i] == "%" {
                var j = quoted.index(after: i)
                var long = 0
                while j < quoted.endIndex, !"udxs".contains(quoted[j]) { if quoted[j] == "l" { long += 1 }; j = quoted.index(after: j) }
                worst += long >= 2 ? 20 : 10
                i = quoted.index(after: j)
            } else { worst += 1; i = quoted.index(after: i) }
        }
        XCTAssertLessThan(worst, 250, "estimator \(worst)")
    }

    func testTheTranslatorIsCompiledWithFpContractOff() throws {
        let y = try text("project.yml")
        XCTAssertTrue(y.contains("includes: [GDHubXlate.c]"), "the shared file is a source of the dext target")
        XCTAssertTrue(y.contains("-ffp-contract=off"))
        let dextRange = try XCTUnwrap(y.range(of: "GDHubVirtualHID:"))
        let dext = y[dextRange.lowerBound...]
        XCTAssertTrue(dext.contains("compilerFlags: [\"-ffp-contract=off\"]"), "the file's own flag")
        XCTAssertTrue(dext.contains("OTHER_CFLAGS"), "and the target's")
        XCTAssertFalse(y.contains("-ffast-math") && y.contains("OTHER_CFLAGS: -ffast-math"))
        let b = try text("scripts/build-xcode.sh")
        XCTAssertTrue(b.contains("-ffp-contract=off"), "the build script fails without it")
        XCTAssertTrue(b.contains("GDHubXlate.c"))
        let swiftPM = try text("Package.swift")
        XCTAssertTrue(swiftPM.contains("-ffp-contract=off"), "the SwiftPM C target the tests run against is built the same way")
    }

    func testNoFastMathAnywhereInTheTranslatorsBuilds() throws {
        for rel in ["project.yml", "Package.swift", "scripts/build-xcode.sh"] {
            let t = try text(rel)
            for line in t.split(separator: "\n") where line.contains("fast-math") || line.contains("Ofast") {
                XCTAssertTrue(line.contains("no-") || line.contains("#") || line.contains("fail") || line.contains("refus") || line.contains("grep") || line.contains("not") || line.contains("exit"), "\(rel): \(line)")
            }
        }
    }
}

/// The engine's parity sampler against the real C core, with golden frames.
final class ParitySamplerTests: XCTestCase {
    private func core() throws -> XlateCore { try XlateFixtures.core(XlateFixtures.liveShaped, revision: 3) }

    private func frame(_ seed: UInt8) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 16)
        f[0] = 0x06
        for i in 1..<16 { f[i] = seed &* UInt8(i) &+ UInt8(i * 7) }
        f[15] = 0x00
        return f
    }

    private func record(_ core: XlateCore, _ raw: [UInt8], ts: UInt64, count: UInt32, revision: UInt32 = 3, tamper: Bool = false) throws -> DextParityRecord {
        let pad = try XCTUnwrap(core.eval(raw: raw))
        let reports = core.reports(pad)
        var out = (reports.first?.bytes ?? []) + (reports.count > 1 ? reports[1].bytes : [])
        XCTAssertEqual(out.count, 18, "xbox-bt16: report 1 (16 bytes) and report 2 (2 bytes)")
        if tamper { out[5] ^= 0x01 }
        return DextParityRecord(count: count, revision: revision, timestamp: ts, frame: raw, out01: Array(out.prefix(16)), out02: Array(out.suffix(2)))
    }

    private final class Clock: @unchecked Sendable { var ns: UInt64 = 5_000_000_000 }

    func testMatchedMismatchedNoMatchAndStale() throws {
        let c = try core()
        let clock = Clock(); var lines: [String] = []
        let s = ParitySampler(clock: { clock.ns }, log: { lines.append($0) })
        s.ring.enabled = true
        let f1 = frame(11), f2 = frame(23)
        f1.withUnsafeBufferPointer { s.ring.record(timestamp: 1001, report: $0.baseAddress!, length: 16) }
        f2.withUnsafeBufferPointer { s.ring.record(timestamp: 1002, report: $0.baseAddress!, length: 16) }
        XCTAssertEqual(s.sample(try record(c, f1, ts: 1001, count: 1), core: c, revision: 3), .matched)
        XCTAssertEqual(s.sample(try record(c, f1, ts: 1001, count: 1), core: c, revision: 3), .unchanged, "the same record is not counted twice")
        XCTAssertEqual(s.sample(try record(c, f2, ts: 1002, count: 2), core: c, revision: 3), .matched)
        XCTAssertEqual(s.sample(try record(c, f2, ts: 9999, count: 3), core: c, revision: 3), .noMatch, "a frame the engine never saw")
        XCTAssertEqual(s.sample(try record(c, f2, ts: 1002, count: 4, revision: 2), core: c, revision: 3), .stale)
        XCTAssertEqual(s.stats, ParitySampler.Stats(matched: 2, mismatched: 0, noMatch: 1, stale: 1, frameDiffers: 0, unchangedRecord: 1, skipped: 0))
        XCTAssertEqual(lines.count, 1, "only the first-match line so far"); XCTAssertEqual(lines[0], "parity: first match, ts=1001 (the engine's frame has the driver's kernel timestamp)")
        lines.removeAll()
        let bad = s.sample(try record(c, f1, ts: 1001, count: 5, tamper: true), core: c, revision: 3)
        guard case .mismatch(let engine, let dext, _, let rev) = bad else { return XCTFail("\(bad)") }
        XCTAssertNotEqual(engine, dext); XCTAssertEqual(rev, 3)
        XCTAssertEqual(s.stats.mismatched, 1)
        XCTAssertEqual(lines.count, 1); XCTAssertTrue(lines[0].contains("MISMATCH"))
    }

    func testFirstMatchIsLoggedOnce() throws {
        let c = try core(); var lines: [String] = []
        let s = ParitySampler(log: { lines.append($0) })
        for i in 1...5 {
            let f = frame(UInt8(i))
            f.withUnsafeBufferPointer { s.ring.record(timestamp: UInt64(500 + i), report: $0.baseAddress!, length: 16) }
            XCTAssertEqual(s.sample(try record(c, f, ts: UInt64(500 + i), count: UInt32(i)), core: c, revision: 3), .matched)
        }
        XCTAssertEqual(lines.filter { $0.hasPrefix("parity: first match, ts=501") }.count, 1)
        XCTAssertEqual(lines.count, 1)
    }

    /// Zero comparisons must never look like a pass: the timestamps never agree, and the sampler says so once.
    func testNoMatchWarningAfter40SamplesAndOver90Percent() throws {
        let c = try core(); var lines: [String] = []
        let s = ParitySampler(log: { lines.append($0) })
        for i in 1...39 { _ = s.sample(try record(c, frame(1), ts: UInt64(9000 + i), count: UInt32(i)), core: c, revision: 3) }
        XCTAssertTrue(lines.isEmpty, "39 samples: too early to say")
        _ = s.sample(try record(c, frame(1), ts: 9040, count: 40), core: c, revision: 3)
        XCTAssertEqual(lines, ["parity: the driver's frames are not found in the engine's ring (timestamps differ?) \u{2014} parity is NOT being checked"])
        for i in 41...80 { _ = s.sample(try record(c, frame(1), ts: UInt64(9000 + i), count: UInt32(i)), core: c, revision: 3) }
        XCTAssertEqual(lines.count, 1, "said once")
        XCTAssertFalse(s.stats.isChecked)
        XCTAssertTrue(s.stats.text.contains("ok=0 mismatch=0 noMatch=80") && s.stats.text.contains("(NOT checked"), s.stats.text)
    }

    func testNoWarningWhenMostFramesAreFound() throws {
        let c = try core(); var lines: [String] = []
        let s = ParitySampler(log: { lines.append($0) })
        let f = frame(2)
        f.withUnsafeBufferPointer { s.ring.record(timestamp: 77, report: $0.baseAddress!, length: 16) }
        for i in 1...100 {
            _ = s.sample(try record(c, f, ts: i % 5 == 0 ? 123456 : 77, count: UInt32(i)), core: c, revision: 3)     // 20 % not found
        }
        XCTAssertEqual(s.stats.matched, 80); XCTAssertEqual(s.stats.noMatch, 20)
        XCTAssertFalse(lines.contains { $0.contains("NOT being checked") })
    }

    func testCheckedOnlyAfter1000Matches() throws {
        var st = ParitySampler.Stats()
        st.matched = 999; XCTAssertFalse(st.isChecked); XCTAssertTrue(st.text.hasSuffix("(NOT checked: needs ok>=1000)"))
        st.matched = 1000; XCTAssertTrue(st.isChecked); XCTAssertTrue(st.text.hasSuffix("(checked)"))
        XCTAssertEqual(ParitySampler.checkedThreshold, 1000)
    }

    func testBothSidesCompareTheSameShapeAndOddIdentitiesAreSkipped() throws {
        let c = try core(); var lines: [String] = []
        let s = ParitySampler(log: { lines.append($0) })
        // the shape helper truncates and pads exactly as the dext's shadowFrame does
        let long = ParitySampler.dextShape([PadReport(id: 1, bytes: [UInt8](1...20)), PadReport(id: 2, bytes: [9, 8, 7])])
        XCTAssertEqual(long.out01, [UInt8](1...16)); XCTAssertEqual(long.out02, [9, 8])
        let short = ParitySampler.dextShape([PadReport(id: 1, bytes: [1, 2, 3])])
        XCTAssertEqual(short.out01, [1, 2, 3] + [UInt8](repeating: 0, count: 13)); XCTAssertEqual(short.out02, [0, 0])
        XCTAssertEqual(ParitySampler.dextShape([]).out01, [UInt8](repeating: 0, count: 16))
        // an identity whose reports are not 16 and 2 bytes: skipped, counted, logged once, never a mismatch
        s.reportsHook = { _, _ in [PadReport(id: 1, bytes: [UInt8](repeating: 0, count: 17))] }
        let f = frame(4)
        f.withUnsafeBufferPointer { s.ring.record(timestamp: 31, report: $0.baseAddress!, length: 16) }
        XCTAssertEqual(s.sample(try record(c, f, ts: 31, count: 1), core: c, revision: 3), .skipped)
        XCTAssertEqual(s.sample(try record(c, f, ts: 31, count: 2), core: c, revision: 3), .skipped)
        XCTAssertEqual(s.stats.skipped, 2); XCTAssertEqual(s.stats.mismatched, 0)
        XCTAssertEqual(lines.filter { $0.contains("not 16 and 2 bytes") }.count, 1)
    }

    func testMismatchLoggingIsRateLimitedButEveryOneIsCounted() throws {
        let c = try core()
        let clock = Clock(); var lines: [String] = []
        let s = ParitySampler(clock: { clock.ns }, log: { lines.append($0) })
        let f = frame(5)
        f.withUnsafeBufferPointer { s.ring.record(timestamp: 77, report: $0.baseAddress!, length: 16) }
        for n in 1...50 { _ = s.sample(try record(c, f, ts: 77, count: UInt32(n), tamper: true), core: c, revision: 3); clock.ns += 10_000_000 }
        XCTAssertEqual(s.stats.mismatched, 50)
        XCTAssertEqual(lines.count, 1, "50 mismatches in 0.5 s: one line")
        clock.ns += 2_000_000_000
        _ = s.sample(try record(c, f, ts: 77, count: 51, tamper: true), core: c, revision: 3)
        XCTAssertEqual(lines.count, 2, "another line after the second")
    }

    func testAFrameThatDiffersFromTheEnginesCopyIsNotAMismatch() throws {
        let c = try core()
        let s = ParitySampler()
        let f = frame(9); var other = f; other[3] ^= 0x40
        f.withUnsafeBufferPointer { s.ring.record(timestamp: 5, report: $0.baseAddress!, length: 16) }
        let o = s.sample(try record(c, other, ts: 5, count: 1), core: c, revision: 3)
        guard case .frameDiffers = o else { return XCTFail("\(o)") }
        XCTAssertEqual(s.stats.frameDiffers, 1); XCTAssertEqual(s.stats.mismatched, 0)
    }

    func testRingKeepsTheLast256FramesAndIsOnlyFilledWhileEnabledByTheCaller() {
        let r = FrameRing()
        let f = [UInt8](repeating: 0x06, count: 16)
        for i in 1...300 { f.withUnsafeBufferPointer { r.record(timestamp: UInt64(i), report: $0.baseAddress!, length: 16) } }
        XCTAssertNil(r.find(timestamp: 44), "older than 256 frames")
        XCTAssertNotNil(r.find(timestamp: 45)); XCTAssertNotNil(r.find(timestamp: 300))
        XCTAssertNil(r.find(timestamp: 0), "timestamp 0 is never a match")
        f.withUnsafeBufferPointer { r.record(timestamp: 999, report: $0.baseAddress!, length: 15) }
        XCTAssertNil(r.find(timestamp: 999), "only 16-byte reports are kept")
        r.reset()
        XCTAssertNil(r.find(timestamp: 300))
    }

    func testStatsText() {
        XCTAssertEqual(ParitySampler.Stats().text, "parity: ok=0 mismatch=0 noMatch=0 stale=0 frameDiffers=0 skipped=0 (NOT checked: needs ok>=1000)")
        var st = ParitySampler.Stats(); st.frameDiffers = 2
        XCTAssertTrue(st.text.contains("frameDiffers=2"))
    }
}

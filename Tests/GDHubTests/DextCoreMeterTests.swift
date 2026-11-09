import XCTest
import GDHubDextCore
import GDHubXlate
@testable import GDHub

/// Meter, CRC-32 and the GDHubStatus2 packer of Dext/GDHubVirtualHID/Core, and the Swift decoder that reads what the
/// C packer writes.
final class DextCoreMeterTests: XCTestCase {
    private func meter(numer: UInt32 = 1, denom: UInt32 = 1, windowMs: UInt64 = 10) -> UnsafeMutablePointer<gdh_meter> {
        let m = UnsafeMutablePointer<gdh_meter>.allocate(capacity: 1)
        m.initialize(to: gdh_meter())
        gdh_meter_init(m, numer, denom, windowMs)
        return m
    }

    private func read(_ m: UnsafeMutablePointer<gdh_meter>) -> (hop: gdh_summary, hr: gdh_summary, windows: UInt32, ok: Bool) {
        var hop = gdh_summary(), hr = gdh_summary(), w: UInt32 = 0
        let ok = gdh_meter_read(m, &hop, &hr, &w) != 0
        return (hop, hr, w, ok)
    }

    func testNothingIsPublishedBeforeTheFirstWindowCloses() {
        let m = meter(); defer { m.deallocate() }
        XCTAssertEqual(gdh_meter_sample(m, 1_000, 1, 10_000, 10_000), 0)
        let r = read(m)
        XCTAssertTrue(r.ok); XCTAssertEqual(r.windows, 0); XCTAssertEqual(r.hr.count, 0); XCTAssertEqual(r.hop.count, 0)
    }

    func testWindowClosesOnTheFirstSampleAfterItsEnd() {
        let m = meter(windowMs: 10); defer { m.deallocate() }     // ticks are ns here: 10 ms = 10_000_000
        let start: UInt64 = 5_000_000
        for i in 0..<100 { XCTAssertEqual(gdh_meter_sample(m, start + UInt64(i) * 1000, 1, 10_000, 20_000), 0) }
        XCTAssertEqual(gdh_meter_sample(m, start + 9_999_999, 1, 10_000, 20_000), 0, "one tick short of the window")
        XCTAssertEqual(gdh_meter_sample(m, start + 10_000_000, 1, 10_000, 20_000), 1, "this sample closes the window")
        let r = read(m)
        XCTAssertEqual(r.windows, 1); XCTAssertEqual(r.hr.count, 101); XCTAssertEqual(r.hop.count, 101)
        XCTAssertEqual(r.hr.p50Ns, 20_000, "bucket edge 25 us clamped to the window maximum of 20 us")
        XCTAssertEqual(r.hr.maxNs, 20_000); XCTAssertEqual(r.hr.meanNs, 20_000)
        XCTAssertEqual(r.hop.p99Ns, 10_000)
        // the sample that closed the window belongs to the next one
        for i in 0..<9 { XCTAssertEqual(gdh_meter_sample(m, start + 10_000_001 + UInt64(i), 1, 1, 1), 0) }
        XCTAssertEqual(read(m).windows, 1, "the second window is still open")
    }

    func testPercentilesFromBuckets() {
        let m = meter(); defer { m.deallocate() }
        var t: UInt64 = 1
        for _ in 0..<90 { _ = gdh_meter_sample(m, t, 0, 0, 30_000); t += 1 }       // 25...50 us bucket
        for _ in 0..<10 { _ = gdh_meter_sample(m, t, 0, 0, 300_000); t += 1 }      // 300...325 us bucket
        XCTAssertEqual(gdh_meter_sample(m, t + 10_000_000, 0, 0, 1), 1)
        let r = read(m)
        XCTAssertEqual(r.hr.count, 100)
        XCTAssertEqual(r.hr.p50Ns, 50_000, "upper edge of the bucket holding the 50th sample")
        XCTAssertEqual(r.hr.p99Ns, 300_000, "the 99th sample is a 300 us one; its bucket edge 325 us is clamped to the maximum")
        XCTAssertEqual(r.hr.maxNs, 300_000)
        XCTAssertEqual(r.hr.meanNs, (90 * 30_000 + 10 * 300_000) / 100)
        XCTAssertEqual(r.hop.count, 0, "posts without a source stamp add no hop sample")
    }

    func testBucketLayoutEdges() {
        // 40 x 25 us, 10 x 100 us, then 3, 5, 10, 20 ms, then overflow.
        func p99ForSingle(_ ns: UInt64) -> UInt32 {
            let m = meter(); defer { m.deallocate() }
            _ = gdh_meter_sample(m, 1, 0, 0, ns)
            _ = gdh_meter_sample(m, 1 + 10_000_000, 0, 0, ns)       // closes the window with a 2nd identical sample
            return read(m).hr.p99Ns
        }
        // a value just below an edge is reported at its own max (clamp); check the unclamped edge with a bigger max sample
        func edgeFor(_ ns: UInt64, plusMax: UInt64) -> UInt32 {
            let m = meter(); defer { m.deallocate() }
            for i in 0..<99 { _ = gdh_meter_sample(m, UInt64(i) + 1, 0, 0, ns) }
            _ = gdh_meter_sample(m, 200, 0, 0, plusMax)
            _ = gdh_meter_sample(m, 200 + 10_000_000, 0, 0, 1)
            return read(m).hr.p50Ns
        }
        // below 25 us (the T3 review: a p50 of a few microseconds must be distinguishable from 25)
        for (v, edge) in [(0, 1_000), (999, 1_000), (1_000, 2_000), (1_999, 2_000), (2_000, 3_000), (2_999, 3_000),
                          (3_000, 5_000), (4_999, 5_000), (5_000, 8_000), (7_999, 8_000), (8_000, 12_000),
                          (11_999, 12_000), (12_000, 18_000), (17_999, 18_000), (18_000, 25_000)] as [(UInt64, UInt32)] {
            XCTAssertEqual(edgeFor(v, plusMax: 30_000_000), edge, "\(v) ns")
        }
        XCTAssertEqual(edgeFor(24_999, plusMax: 30_000_000), 25_000)
        XCTAssertEqual(edgeFor(25_000, plusMax: 30_000_000), 50_000)
        XCTAssertEqual(edgeFor(999_999, plusMax: 30_000_000), 1_000_000)
        XCTAssertEqual(edgeFor(1_000_000, plusMax: 30_000_000), 1_100_000)
        XCTAssertEqual(edgeFor(1_999_999, plusMax: 30_000_000), 2_000_000)
        XCTAssertEqual(edgeFor(2_000_000, plusMax: 30_000_000), 3_000_000)
        XCTAssertEqual(edgeFor(4_999_999, plusMax: 30_000_000), 5_000_000)
        XCTAssertEqual(edgeFor(9_999_999, plusMax: 30_000_000), 10_000_000)
        XCTAssertEqual(edgeFor(19_999_999, plusMax: 30_000_000), 20_000_000)
        XCTAssertEqual(edgeFor(25_000_000, plusMax: 30_000_000), 30_000_000, "the overflow bucket reports the maximum")
        XCTAssertEqual(p99ForSingle(7_000), 7_000)
    }

    func testSmallValuesKeepTheirResolution() {
        // Typical hop/hr values: the percentile is clamped to the maximum, so single-valued windows are exact, and a
        // window of 4 us samples with one 40 us outlier reports p50 = 5 us (its bucket edge), not 25.
        let m = meter(); defer { m.deallocate() }
        for i in 0..<99 { _ = gdh_meter_sample(m, UInt64(i) + 1, 1, 4_000, 4_000) }
        _ = gdh_meter_sample(m, 200, 1, 40_000, 40_000)
        _ = gdh_meter_sample(m, 200 + 10_000_000, 1, 1, 1)
        let r = read(m)
        XCTAssertEqual(r.hop.p50Ns, 5_000); XCTAssertEqual(r.hop.p99Ns, 5_000); XCTAssertEqual(r.hop.maxNs, 40_000)
        XCTAssertEqual(r.hop.meanNs, (99 * 4_000 + 40_000) / 100)
    }

    func testMeanIsExactNotBucketed() {
        // 125/3 timebase: sum the ticks first. 3 samples of 1, 1 and 2 ticks: sum 4 ticks = 166 ns, mean 55 ns. (Dividing
        // the ticks first would give 1 tick = 41 ns.)
        let m = meter(numer: 125, denom: 3); defer { m.deallocate() }
        _ = gdh_meter_sample(m, 100, 0, 0, 1); _ = gdh_meter_sample(m, 101, 0, 0, 1); _ = gdh_meter_sample(m, 102, 0, 0, 2)
        _ = gdh_meter_sample(m, 100 + m.pointee.windowTicks, 0, 0, 1)
        // the closing sample belongs to the next window; the published one has the first three
        XCTAssertEqual(read(m).hr.count, 3); XCTAssertEqual(read(m).hr.meanNs, 55)
        // a mean of 18_450 ns reads as 18.4 us on the Swift side (truncated tenth)
        XCTAssertEqual(DextMeterSummary(count: 1, p50Ns: 25_000, p99Ns: 25_000, maxNs: 25_000, meanNs: 18_450).microsecondsText, "25/25/25/18.4")
        XCTAssertEqual(DextMeterSummary(count: 1, p50Ns: 1_000, p99Ns: 3_000, maxNs: 3_000, meanNs: 999).microsecondsText, "1/3/3/0.9")
    }

    func testTimebaseConversion() {
        // Apple silicon: ns = ticks * 125 / 3
        let m = meter(numer: 125, denom: 3); defer { m.deallocate() }
        XCTAssertEqual(gdh_ticks_to_ns(m, 24), 1_000)
        _ = gdh_meter_sample(m, 100, 1, 24, 48)                       // hop 1 us, hr 2 us
        _ = gdh_meter_sample(m, 100 + m.pointee.windowTicks, 1, 24, 48)
        let r = read(m)
        XCTAssertEqual(r.hop.maxNs, 1_000); XCTAssertEqual(r.hr.maxNs, 2_000)
        XCTAssertEqual(m.pointee.windowTicks, 10_000_000 * 3 / 125, "10 ms in ticks")
    }

    /// A reader must never see a half-written window: the writer closes windows as fast as it can, each with the same
    /// numbers in hop and hr, and the reader checks that hop and hr always belong together.
    func testSeqlockSnapshotsAreNeverTorn() {
        let m = meter(windowMs: 1); defer { m.deallocate() }
        let stop = ManagedFlag()
        let torn = Counter(), reads = Counter()
        let readers = DispatchGroup()
        for _ in 0..<3 {
            DispatchQueue.global().async(group: readers) {
                var last: UInt32 = 0
                while !stop.isSet {
                    var hop = gdh_summary(), hr = gdh_summary(), w: UInt32 = 0
                    if gdh_meter_read(m, &hop, &hr, &w) == 0 { continue }
                    reads.add()
                    if w < last || hop.maxNs != hr.maxNs || hop.p50Ns != hr.p50Ns || hop.count != hr.count { torn.add() }
                    if w > 0 && (hop.count != 3 || hr.count != 3) { torn.add() }
                    last = w
                }
            }
        }
        var now: UInt64 = 1
        for w in 0..<20_000 {
            let v = UInt64(1 + (w % 40)) * 1000
            for _ in 0..<3 { _ = gdh_meter_sample(m, now, 1, v, v); now += 1 }
            now += 1_000_000                                          // next sample is past the 1 ms window
        }
        stop.set(); readers.wait()
        XCTAssertGreaterThan(reads.value, 100)
        XCTAssertEqual(torn.value, 0)
    }

    // MARK: CRC-32

    func testCRC32CheckValueAndEqualsTheTranslatorsCRC() throws {
        let check = Array("123456789".utf8)
        XCTAssertEqual(check.withUnsafeBufferPointer { gdh_crc32($0.baseAddress, $0.count) }, 0xCBF43926)
        XCTAssertEqual(gdh_crc32(nil, 0), 0)
        var rng = SystemRandomNumberGenerator()
        for n in [0, 1, 7, 64, 300, 1024] {
            let bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let mine = bytes.withUnsafeBufferPointer { gdh_crc32($0.baseAddress, $0.count) }
            let theirs = bytes.withUnsafeBufferPointer { gdx_crc32($0.baseAddress, $0.count) }
            XCTAssertEqual(mine, theirs, "the dext's CRC and the translator's must agree (GDHM specCRC32), n=\(n)")
        }
        let spec = try PadIdentity.xboxBT16_02E0.spec().encoded()
        XCTAssertEqual(spec.withUnsafeBufferPointer { gdh_crc32($0.baseAddress, $0.count) }, GDHMTable.crc32(spec))
    }

    // MARK: GDHubStatus2

    private func snapshot() -> gdhr_snap {
        var s = gdhr_snap()
        s.nonce = 0x0102030405060708; s.build = 18; s.pid = 777
        s.desiredState = 0; s.padSource = UInt32(GDHR_SRC_UC); s.padState = UInt32(GDHR_PAD_LIVE); s.padSpecCrc = 0xCAFEBABE
        s.ownerPresent = 1; s.rootPresent = 1
        s.topology = 0x77; s.probeExt = 0x83; s.probePad = 0x85
        withUnsafeMutableBytes(of: &s.counters) { raw in
            let c = raw.bindMemory(to: UInt64.self)
            c[Int(GDHR_CTR_UC_POSTS.rawValue)] = 1_000_000_000_001
            c[Int(GDHR_CTR_UC_REJECTED.rawValue)] = 2
            c[Int(GDHR_CTR_NEUTRAL_POSTS.rawValue)] = 3
            c[Int(GDHR_CTR_POST_ERRORS.rawValue)] = 4
            c[Int(GDHR_CTR_SYNC_VIOLATIONS.rawValue)] = 5
            c[Int(GDHR_CTR_PAD_CREATES.rawValue)] = 6
            c[Int(GDHR_CTR_PAD_DESTROYS.rawValue)] = 7
            c[Int(GDHR_CTR_CREATE_FAILS.rawValue)] = 8
            c[Int(GDHR_CTR_OUTPUTS_SEEN.rawValue)] = 9
            c[Int(GDHR_CTR_OUTPUTS_NO_OWNER.rawValue)] = 10
            c[Int(GDHR_CTR_CREATE_EARLY.rawValue)] = 11
            c[Int(GDHR_CTR_SYNC_INLINE.rawValue)] = 12
        }
        return s
    }

    private func packed(cap: Int = 1024) -> [UInt8] {
        var s = snapshot()
        var hop = gdh_summary(count: 220, p50Ns: 25_000, p99Ns: 75_000, maxNs: 120_000, meanNs: 31_000)
        var hr = gdh_summary(count: 220, p50Ns: 50_000, p99Ns: 100_000, maxNs: 140_000, meanNs: 42_000)
        var k2d = gdh_summary(count: 9000, p50Ns: 60_000, p99Ns: 110_000, maxNs: 400_000, meanNs: 65_000)
        var buf = [UInt8](repeating: 0xEE, count: cap)
        let n = gdh_status2_pack(&buf, cap, &s, &hop, &hr, 9, &k2d, nil)
        return Array(buf.prefix(n))
    }

    func testPackedStatus2DecodesFieldByField() throws {
        let bytes = packed()
        XCTAssertEqual(bytes.count, DextStatus2.size)
        let s = try XCTUnwrap(DextStatus2.decode(bytes))
        XCTAssertEqual(s.version, 1); XCTAssertEqual(s.declaredSize, 676)
        XCTAssertEqual(s.build, 18); XCTAssertEqual(s.instanceNonce, 0x0102030405060708); XCTAssertEqual(s.rootPid, 777)
        XCTAssertEqual(s.desiredState, 0); XCTAssertEqual(s.source, .userClient)
        XCTAssertTrue(s.padLive); XCTAssertTrue(s.ownerPresent)
        XCTAssertEqual(s.ucPosts, 1_000_000_000_001); XCTAssertEqual(s.ucRejected, 2); XCTAssertEqual(s.neutralPosts, 3)
        XCTAssertEqual(s.postErrors, 4); XCTAssertEqual(s.syncViolations, 5); XCTAssertEqual(s.padCreates, 6)
        XCTAssertEqual(s.padDestroys, 7); XCTAssertEqual(s.createFails, 8); XCTAssertEqual(s.outputsSeen, 9)
        XCTAssertEqual(s.outputsNoOwner, 10); XCTAssertEqual(s.createEarly, 11); XCTAssertEqual(s.syncInline, 12)
        XCTAssertEqual(s.topology, 0x77); XCTAssertEqual(s.probeExt, 0x83); XCTAssertEqual(s.probeSubmit, 0x85)
        XCTAssertEqual(s.padSpecCRC, 0xCAFEBABE); XCTAssertEqual(s.meterWindows, 9)
        XCTAssertEqual(s.hop, DextMeterSummary(count: 220, p50Ns: 25_000, p99Ns: 75_000, maxNs: 120_000, meanNs: 31_000))
        XCTAssertEqual(s.hr, DextMeterSummary(count: 220, p50Ns: 50_000, p99Ns: 100_000, maxNs: 140_000, meanNs: 42_000))
        XCTAssertEqual(s.meterLogText, "dext: hop p50/p99/max/mean 25/75/120/31.0 us hr 50/100/140/42.0 us n=220 win=9 dext topo: uc=root:1 pad=root:1 pad=uc:1 syncViolations=5 syncInline=12")
    }

    func testTopologyTextShowsUnknownAsAQuestionMark() {
        var s = DextStatus2(); XCTAssertNil(s.topologyText); XCTAssertNil(s.meterLogText)
        s.topology = 0x10 | 0x01                                   // uc==root known and true
        XCTAssertEqual(s.topologyText, "dext topo: uc=root:1 pad=root:? pad=uc:?")
        s.topology = 0x70 | 0x04                                   // all known, only pad==uc
        XCTAssertEqual(s.topologyText, "dext topo: uc=root:0 pad=root:0 pad=uc:1")
        XCTAssertEqual(s.meterLogText, "dext topo: uc=root:0 pad=root:0 pad=uc:1")
        s.syncInline = 3
        XCTAssertTrue(s.meterLogText!.hasSuffix("syncInline=3"))
    }

    func testStatus2WithoutPadOrWindowHasNoMeterText() throws {
        var s = snapshot(); s.padState = UInt32(GDHR_PAD_NONE); s.padSource = UInt32(GDHR_SRC_NONE); s.ownerPresent = 0
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = gdh_status2_pack(&buf, 1024, &s, nil, nil, 0, nil, nil)
        let d = try XCTUnwrap(DextStatus2.decode(Array(buf.prefix(n))))
        XCTAssertFalse(d.padLive); XCTAssertEqual(d.source, DextProtocol.PadSource.none); XCTAssertFalse(d.ownerPresent)
        XCTAssertEqual(d.hop, DextMeterSummary())
    }

    func testShortBuffersDecodeWhatFits() throws {
        // The dext writes min(size, caller maximum) bytes.
        let full = packed()
        let short = try XCTUnwrap(DextStatus2.decode(Array(full.prefix(28))))
        XCTAssertEqual(short.declaredSize, 676, "size says what the dext has; the buffer is what arrived")
        XCTAssertEqual(short.build, 18); XCTAssertEqual(short.rootPid, 777); XCTAssertEqual(short.source, .userClient)
        XCTAssertEqual(short.ucPosts, 0, "beyond the buffer reads as zero"); XCTAssertEqual(short.hop, DextMeterSummary())
        let tight = try XCTUnwrap(DextStatus2.decode(Array(full.prefix(8))))
        XCTAssertEqual(tight.build, 18); XCTAssertEqual(tight.instanceNonce, 0)
        // a field cut in the middle is not half-read
        let cut = try XCTUnwrap(DextStatus2.decode(Array(full.prefix(DextStatus2.Offset.ucPosts + 5))))
        XCTAssertEqual(cut.ucPosts, 0)
        XCTAssertNil(DextStatus2.decode(Array(full.prefix(7))), "less than version, size and build")
        XCTAssertNil(DextStatus2.decode([]))
        // the packer itself, with a small capacity
        var s = snapshot(); var buf = [UInt8](repeating: 0xEE, count: 40)
        XCTAssertEqual(gdh_status2_pack(&buf, 12, &s, nil, nil, 0, nil, nil), 12)
        XCTAssertEqual(buf[12], 0xEE, "nothing is written past the capacity")
        XCTAssertEqual(gdh_status2_pack(&buf, 7, &s, nil, nil, 0, nil, nil), 0)
    }

    func testLongBuffersAndNewerVersionsDecodeTheKnownPrefix() throws {
        var longer = packed() + [UInt8](repeating: 0x5A, count: 64)      // a newer dext appended fields
        longer[DextStatus2.Offset.size] = UInt8((676 + 64) & 0xFF); longer[DextStatus2.Offset.size + 1] = UInt8((676 + 64) >> 8)
        longer[DextStatus2.Offset.version] = 3                           // and bumped the version
        let s = try XCTUnwrap(DextStatus2.decode(longer))
        XCTAssertEqual(s.version, 3); XCTAssertEqual(s.declaredSize, 740)
        XCTAssertEqual(s.ucPosts, 1_000_000_000_001); XCTAssertEqual(s.hr.p99Ns, 100_000)
        // garbage that claims a tiny size, or version 0, is refused
        var bad = packed(); bad[DextStatus2.Offset.size] = 4; bad[DextStatus2.Offset.size + 1] = 0
        XCTAssertNil(DextStatus2.decode(bad))
        var zero = packed(); zero[DextStatus2.Offset.version] = 0
        XCTAssertNil(DextStatus2.decode(zero))
    }

    func testStatus2StaysInsideItsMaximum() {
        XCTAssertLessThanOrEqual(DextStatus2.size, DextStatus2.maxSize)
        XCTAssertEqual(DextStatus2.Offset.submitMean + 4, DextStatus2.size, "the layout ends exactly at the declared size")
        XCTAssertEqual(DextStatus2.Offset.probeSubmit + 2, DextStatus2.Offset.tapPresent, "one reserved byte (171) between the T3 and T4 parts")
    }
}

final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var v = 0
    var value: Int { l.lock(); defer { l.unlock() }; return v }
    func add() { l.lock(); v += 1; l.unlock() }
}

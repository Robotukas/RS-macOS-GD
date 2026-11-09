import XCTest
import GDHubXlate
@testable import GDHub

/// `gdx_validate` against truncated, oversized, forged and hostile blobs. A rejected blob never touches the output.
final class GDHubXlateBlobTests: XCTestCase {
    typealias F = XlateFixtures

    private var factoryTable: GDHMTable { try! MapBlobEncoder.table(.default, identity: F.identity, spec: F.spec, revision: 7) }
    private var factoryBlob: [UInt8] { factoryTable.serialize() }

    private func code(_ t: GDHMTable, spec: [UInt8] = F.spec) -> Int32 { F.validate(t.serialize(), spec: spec) }
    private func edited(_ f: (inout GDHMTable) -> Void) -> Int32 { var t = factoryTable; f(&t); return code(t) }
    private func patched(_ blob: [UInt8], _ f: (inout [UInt8]) -> Void) -> Int32 { var b = blob; f(&b); return F.validate(F.reseal(b)) }

    func testFactoryBlobIsValidAndSmall() {
        let b = factoryBlob
        XCTAssertEqual(F.validate(b), GDX_OK)
        XCTAssertLessThanOrEqual(b.count, 1024)
        XCTAssertEqual(b.count % 8, 0)
        XCTAssertEqual(Array(b[0..<4]), Array("GDHM".utf8))
        XCTAssertEqual(b[4], 1); XCTAssertEqual(b[5], 0)
        XCTAssertEqual(Int(b[6]) | Int(b[7]) << 8, b.count, "length field")
        XCTAssertEqual(b[20], 250, "silenceNeutralMs")
    }

    func testEveryTruncationIsRejected() {
        let b = factoryBlob
        for n in 0..<b.count {
            let rc = F.validate(Array(b[0..<n]))
            XCTAssertNotEqual(rc, GDX_OK, "prefix of \(n) bytes")
            XCTAssertEqual(rc, n < 64 ? GDX_E_SHORT : GDX_E_LENGTH, "prefix of \(n)")
            // Even with the length field and checksum repaired to match, the sections do not fit.
            if n >= 64 {
                var t = Array(b[0..<n]); t[6] = UInt8(n & 0xff); t[7] = UInt8(n >> 8)
                XCTAssertNotEqual(F.validate(F.reseal(t)), GDX_OK, "resealed prefix of \(n)")
            }
        }
        XCTAssertEqual(F.validate([]), GDX_E_SHORT)
    }

    func testOversizeAndTrailingBytesAreRejected() {
        let b = factoryBlob
        XCTAssertEqual(F.validate(b + [0]), GDX_E_LENGTH)
        XCTAssertEqual(F.validate(F.reseal(b + [0, 0, 0, 0, 0, 0, 0, 0])), GDX_E_LENGTH, "length field still says the old size")
        XCTAssertEqual(F.validate([UInt8](repeating: 0, count: 1025)), GDX_E_TOO_BIG)
        XCTAssertEqual(F.validate([UInt8](repeating: 0x47, count: 100_000)), GDX_E_TOO_BIG)
        // A length field that claims more than the 1024 maximum, with a body to match.
        var big = b + [UInt8](repeating: 0, count: 1032 - b.count)
        big[6] = UInt8(1032 & 0xff); big[7] = UInt8(1032 >> 8)
        XCTAssertEqual(F.validate(F.reseal(big)), GDX_E_TOO_BIG)
    }

    func testHeaderFieldRejections() {
        let b = factoryBlob
        XCTAssertEqual(patched(b) { $0[0] = 0x58 }, GDX_E_MAGIC)
        XCTAssertEqual(patched(b) { $0[3] = 0 }, GDX_E_MAGIC)
        XCTAssertEqual(patched(b) { $0[4] = 2 }, GDX_E_VERSION)
        XCTAssertEqual(patched(b) { $0[4] = 0 }, GDX_E_VERSION)
        XCTAssertEqual(patched(b) { $0[5] = 1 }, GDX_E_VERSION)
        XCTAssertEqual(patched(b) { $0[6] = $0[6] &+ 8 }, GDX_E_LENGTH)
        XCTAssertEqual(F.validate({ var x = b; x[40] ^= 1; return x }()), GDX_E_CRC, "body change without reseal")
        XCTAssertEqual(F.validate({ var x = b; x[28] ^= 0xFF; return x }()), GDX_E_CRC, "checksum field itself")
        XCTAssertEqual(F.validate({ var x = b; x[b.count - 1] ^= 1; return x }()), GDX_E_CRC, "last byte")
        XCTAssertEqual(patched(b) { $0[16] = 2 }, GDX_E_SOURCE)
        XCTAssertEqual(patched(b) { $0[16] = 0 }, GDX_E_SOURCE)
        XCTAssertEqual(patched(b) { $0[18] = 1 }, GDX_E_FLAGS)
        XCTAssertEqual(patched(b) { $0[19] = 0x80 }, GDX_E_FLAGS)
        XCTAssertEqual(patched(b) { $0[27] = 1 }, GDX_E_COUNTS, "nEcho must be 0 in v1")
        XCTAssertEqual(patched(b) { $0[22] = 0 }, GDX_E_COUNTS, "no reports")
        XCTAssertEqual(patched(b) { $0[22] = 5 }, GDX_E_COUNTS)
        XCTAssertEqual(patched(b) { $0[23] = 33 }, GDX_E_COUNTS)
        XCTAssertEqual(patched(b) { $0[24] = 5 }, GDX_E_COUNTS)
        XCTAssertEqual(patched(b) { $0[25] = 3 }, GDX_E_COUNTS)
        XCTAssertEqual(patched(b) { $0[26] = 33 }, GDX_E_COUNTS)
        XCTAssertEqual(patched(b) { $0[26] = 255 }, GDX_E_COUNTS)
        XCTAssertEqual(patched(b) { $0[23] = 14 }, GDX_E_LENGTH, "a count that leaves bytes unaccounted")
    }

    func testParameterRejections() {
        func f64(_ v: Double, at: Int, _ b: inout [UInt8]) { for i in 0..<8 { b[at + i] = UInt8((v.bitPattern >> UInt64(8 * i)) & 0xff) } }
        let b = factoryBlob
        for bad in [Double.nan, .infinity, -0.001, 1.0, 2.0, -.infinity] {
            XCTAssertEqual(patched(b) { f64(bad, at: 32, &$0) }, GDX_E_PARAM, "deadband \(bad)")
            XCTAssertEqual(patched(b) { f64(bad, at: 40, &$0) }, GDX_E_PARAM, "hysteresis \(bad)")
        }
        for bad in [Double.nan, 0.0, -0.5, 1.5, .infinity] {
            XCTAssertEqual(patched(b) { f64(bad, at: 48, &$0) }, GDX_E_PARAM, "stickActive \(bad)")
        }
        XCTAssertEqual(patched(b) { f64(0.0, at: 32, &$0) }, GDX_OK, "deadband 0 is legal")
        XCTAssertEqual(patched(b) { $0[56] = 0xFF; $0[57] = 0x03; $0[58] = 0; $0[59] = 0 }, GDX_OK, "trigger threshold 1023")
        XCTAssertEqual(patched(b) { $0[57] = 0x04 }, GDX_E_PARAM, "trigger threshold 1124")
        XCTAssertEqual(patched(b) { $0[59] = 0x80 }, GDX_E_PARAM, "negative trigger threshold")
        XCTAssertEqual(patched(b) { $0[62] = 1 }, GDX_E_PARAM, "axis threshold 16000 + 65536")
    }

    func testOutOfRangeIndicesAndEnumerations() {
        XCTAssertEqual(edited { _ in }, GDX_OK)
        // Reports
        XCTAssertEqual(edited { $0.reports[0].length = 0 }, GDX_E_REPORT)
        XCTAssertEqual(edited { $0.reports[0].length = 65 }, GDX_E_REPORT)
        XCTAssertEqual(edited { $0.reports[1].id = 3 }, GDX_E_SPEC_REPORT, "an input report the spec does not declare")
        XCTAssertEqual(edited { $0.reports[0].length = 17 }, GDX_E_SPEC_REPORT, "wrong length for 0x01")
        // Buttons
        XCTAssertEqual(edited { $0.buttons[0].item = 15 }, GDX_E_ITEM, "Share is reserved")
        XCTAssertEqual(edited { $0.buttons[0].item = 255 }, GDX_E_ITEM)
        XCTAssertEqual(edited { $0.buttons[0].item = 16 }, GDX_E_ITEM, "an axis item")
        XCTAssertEqual(edited { $0.buttons[0].kind = 6 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[0].kind = 255 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[0].outSlot = 1 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[0].arg = 19 }, GDX_E_KIND, "button bit 19")
        XCTAssertEqual(edited { $0.buttons[0].arg = 255 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[0].sign = 1 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[0].stickRef = 1 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[11].kind = UInt8(GDX_KIND_TRIGGER_GT); $0.buttons[11].arg = 2 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[11].kind = UInt8(GDX_KIND_AXIS_GT); $0.buttons[11].arg = 4 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[11].kind = UInt8(GDX_KIND_STICK_MAG); $0.buttons[11].arg = 0; $0.buttons[11].stickRef = 2 }, GDX_E_KIND)
        XCTAssertEqual(edited { $0.buttons[11].kind = UInt8(GDX_KIND_NONE); $0.buttons[11].arg = 3 }, GDX_E_KIND)
        // Rules per item: 0 < n <= 2
        XCTAssertEqual(edited { $0.buttons.append($0.buttons[0]) }, GDX_OK, "2 OR'ed sources")
        XCTAssertEqual(edited { $0.buttons.append($0.buttons[0]); $0.buttons.append($0.buttons[0]) }, GDX_E_ITEM, "3 sources")
        XCTAssertEqual(edited { $0.buttons.removeAll { $0.item == 3 } }, GDX_OK, "an unbound item never fires")
        XCTAssertEqual(edited { for _ in 0..<18 { $0.buttons.append($0.buttons[0]) } }, GDX_E_COUNTS, "more than 32 rules")
        // Axes
        XCTAssertEqual(edited { $0.axes[0].stick = 2 }, GDX_E_AXIS)
        XCTAssertEqual(edited { $0.axes[0].component = 2 }, GDX_E_AXIS)
        XCTAssertEqual(edited { $0.axes[0].field = 4 }, GDX_E_AXIS)
        XCTAssertEqual(edited { $0.axes[1] = $0.axes[0] }, GDX_E_AXIS, "the same axis item twice")
        XCTAssertEqual(edited { $0.axes[0].field = UInt8(GDX_FIELD_NONE); $0.axes[0].sign = 1 }, GDX_E_AXIS)
        XCTAssertEqual(edited { $0.axes[0].min = -5 }, GDX_E_AXIS, "a range value without hasRange")
        // Triggers
        XCTAssertEqual(edited { $0.triggers[0].item = 19 }, GDX_E_TRIGGER)
        XCTAssertEqual(edited { $0.triggers[1].item = 20 }, GDX_E_TRIGGER, "LT twice")
        XCTAssertEqual(edited { $0.triggers[0].field = 2 }, GDX_E_TRIGGER)
        XCTAssertEqual(edited { $0.triggers[0].field = UInt8(GDX_FIELD_NONE) }, GDX_OK)
        // Placements
        XCTAssertEqual(edited { $0.placements[0].encoding = 0 }, GDX_E_ENCODING)
        XCTAssertEqual(edited { $0.placements[0].encoding = 6 }, GDX_E_ENCODING)
        XCTAssertEqual(edited { $0.placements[0].item = 20 }, GDX_E_ENCODING, "a trigger item with an axis encoding")
        XCTAssertEqual(edited { $0.placements[0].bits = 15 }, GDX_E_ENCODING)
        XCTAssertEqual(edited { $0.placements[6].item = 12 }, GDX_E_ENCODING, "HAT8 must name the D-pad base item")
        XCTAssertEqual(edited { $0.placements[7].item = 15 }, GDX_E_ENCODING, "BIT of the reserved Share item")
        XCTAssertEqual(edited { $0.placements[0].reportIndex = 2 }, GDX_E_PLACEMENT)
        XCTAssertEqual(edited { $0.placements[0].reportIndex = 255 }, GDX_E_PLACEMENT)
        XCTAssertEqual(edited { $0.placements[0].bitOffset = 120 }, GDX_E_PLACEMENT, "16 bits at 120 overflow 16 bytes")
        XCTAssertEqual(edited { $0.placements[0].bitOffset = 65535 }, GDX_E_PLACEMENT)
        XCTAssertEqual(edited { $0.placements[0].bitOffset = 0 }, GDX_E_PLACEMENT, "overlaps the report ID byte")
        XCTAssertEqual(edited { $0.placements[17].bitOffset = 16 }, GDX_E_PLACEMENT, "Guide bit outside the 2-byte report")
    }

    func testReservedAndPaddingBytesMustBeZero() {
        let b = factoryBlob
        XCTAssertEqual(patched(b) { $0[64 + 2] = 1 }, GDX_E_FLAGS, "reserved half of a report entry")
        XCTAssertEqual(patched(b) { $0[64 + 6] = 1 }, GDX_E_FLAGS, "reserved half of the second report entry")
        // One report and one trigger: both sections end in 4 bytes of padding, which must be zero.
        var t = factoryTable
        t.reports.removeLast(); t.placements.removeLast(); t.triggers.removeLast()
        let one = t.serialize()
        XCTAssertEqual(F.validate(one), GDX_OK)
        XCTAssertEqual(patched(one) { $0[64 + 5] = 1 }, GDX_E_FLAGS, "padding after the report entries")
        let trOff = 64 + 8 + 15 * 8 + 4 * 16
        XCTAssertEqual(patched(one) { $0[trOff + 5] = 1 }, GDX_E_FLAGS, "padding after the trigger entries")
        XCTAssertEqual(patched(one) { $0[trOff + 2] = 1 }, GDX_E_FLAGS, "reserved half of a trigger entry")
        // Axis entry: bytes 5...7 are reserved.
        let axOff = 64 + 8 + 15 * 8
        XCTAssertEqual(patched(one) { $0[axOff + 6] = 1 }, GDX_E_AXIS)
        XCTAssertEqual(patched(one) { $0[axOff + 4] = 2 }, GDX_E_AXIS, "hasRange is 0 or 1")
        // Placement entry: the last two bytes are reserved.
        let plOff = trOff + 8
        XCTAssertEqual(patched(one) { $0[plOff + 6] = 1 }, GDX_E_FLAGS)
    }

    func testSpecMismatches() {
        XCTAssertEqual(code(factoryTable, spec: F.spec.dropLast().map { $0 }), GDX_E_SPEC_CRC, "a spec that is not the one targeted")
        var other = F.spec; other[200] ^= 1
        XCTAssertEqual(code(factoryTable, spec: other), GDX_E_SPEC_CRC)
        XCTAssertEqual(edited { $0.specCRC32 ^= 1 }, GDX_E_SPEC_CRC)
        XCTAssertEqual(code(factoryTable, spec: [UInt8](repeating: 0, count: 300)), GDX_E_SPEC_FORMAT)
        XCTAssertEqual(code(factoryTable, spec: Array(F.spec[0..<100])), GDX_E_SPEC_FORMAT)
        XCTAssertNotEqual(code(factoryTable, spec: []), GDX_OK)
        var noInputs = F.spec; noInputs[10] = 0
        XCTAssertEqual(code(factoryTable, spec: noInputs), GDX_E_SPEC_FORMAT)
        // A different (but valid) spec with the matching CRC and the same reports passes: only (id, length) and the CRC matter.
        var idProduct = F.spec; idProduct[16] ^= 1
        var t = factoryTable; t.specCRC32 = GDHMTable.crc32(idProduct)
        XCTAssertEqual(code(t, spec: idProduct), GDX_OK)
        // Report IDs: a spec with a padded send length for 0x01 no longer declares length 16.
        var padded = F.spec; padded[49] = 25
        t.specCRC32 = GDHMTable.crc32(padded)
        XCTAssertEqual(code(t, spec: padded), GDX_E_SPEC_REPORT)
    }

    func testNullArgumentsAndUntouchedOutput() {
        let b = factoryBlob
        var out = gdx_map()
        out.revision = 0xDEAD_BEEF
        b.withUnsafeBufferPointer { bp in F.spec.withUnsafeBufferPointer { sp in
            XCTAssertEqual(gdx_validate(nil, 0, sp.baseAddress, sp.count, &out), GDX_E_ARG)
            XCTAssertEqual(gdx_validate(bp.baseAddress, bp.count, nil, 0, &out), GDX_E_ARG)
            XCTAssertEqual(gdx_validate(bp.baseAddress, bp.count, sp.baseAddress, sp.count, nil), GDX_E_ARG)
            XCTAssertEqual(gdx_validate(bp.baseAddress, bp.count - 8, sp.baseAddress, sp.count, &out), GDX_E_LENGTH)
            XCTAssertEqual(out.revision, 0xDEAD_BEEF, "a rejected blob leaves the old table alone")
            XCTAssertEqual(gdx_validate(bp.baseAddress, bp.count, sp.baseAddress, sp.count, &out), GDX_OK)
            XCTAssertEqual(out.revision, 7)
        } }
        XCTAssertEqual(String(cString: gdx_reason(GDX_E_CRC)), "checksum mismatch")
        XCTAssertFalse(String(cString: gdx_reason(9999)).isEmpty)
        XCTAssertEqual(gdx_crc32(nil, 0), 0)
        XCTAssertEqual("123456789".utf8.map { $0 }.withUnsafeBufferPointer { gdx_crc32($0.baseAddress, $0.count) }, 0xCBF4_3926, "CRC-32/IEEE check value")
    }

    /// 300,000 mutated blobs: nothing crashes, a blob that validates also evaluates, and the output is untouched on rejection.
    func testHostileBlobFuzz() {
        var rng = SplitMix64(seed: 0xF0221)
        let base = factoryBlob
        var accepted = 0, rejected = 0
        let raw = F.randomRaw(&rng)
        for i in 0..<300_000 {
            var b = base
            switch i % 5 {
            case 0: b[rng.int(0...(b.count - 1))] = UInt8(truncatingIfNeeded: rng.next())
            case 1: for _ in 0..<rng.int(2...8) { b[rng.int(0...(b.count - 1))] ^= UInt8(1 << rng.int(0...7)) }
            case 2: b = Array(b.prefix(rng.int(0...b.count)))
            case 3: b += (0..<rng.int(1...40)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            default: for k in 0..<b.count where rng.chance(8) { b[k] = UInt8(truncatingIfNeeded: rng.next()) }
            }
            if rng.chance(70) && b.count >= 32 { b = F.reseal(b) }                         // let some past the checksum
            if rng.chance(50) && b.count >= 8 { let n = b.count; b[6] = UInt8(n & 0xff); b[7] = UInt8((n >> 8) & 0xff); b = F.reseal(b) }
            var out = gdx_map(); out.revision = 0x1234
            let rc = b.withUnsafeBufferPointer { bp in F.spec.withUnsafeBufferPointer { sp in
                gdx_validate(bp.baseAddress, bp.count, sp.baseAddress, sp.count, &out) } }
            if rc == GDX_OK {
                accepted += 1
                var m = out; var pad = gdx_pad(); var o = gdx_out(); var st = gdx_state()
                raw.withUnsafeBufferPointer {
                    XCTAssertEqual(gdx_eval(&m, $0.baseAddress, 16, &pad), 0)
                    gdx_build(&m, &pad, &o)
                    _ = gdx_step(&st, &m, $0.baseAddress, 16, &o)
                }
            } else {
                rejected += 1
                if out.revision != 0x1234 { XCTFail("rejected blob changed the output (case \(i))"); return }
            }
        }
        XCTAssertGreaterThan(rejected, 250_000)
        print("fuzz: \(accepted) accepted, \(rejected) rejected")
    }
}

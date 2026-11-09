import XCTest
@testable import GDHub

/// Deterministic generator so a failing random state can be reproduced.
struct DevTestRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class PadReportDecoderTests: XCTestCase {
    private let decoder = PadReportDecoder.xboxBT16

    private func decode(_ reports: [PadReport], into s: PadDecodedState = .neutral) -> PadDecodedState {
        var state = s
        for r in reports { decoder.apply(reportID: r.id, bytes: r.bytes, to: &state) }
        return state
    }

    private func randomState(_ g: inout DevTestRNG) -> PadState {
        var s = PadState()
        func axis() -> Double { Double.random(in: -1...1, using: &g) }
        s.lx = axis(); s.ly = axis(); s.rx = axis(); s.ry = axis()
        s.lt = Double.random(in: 0...1, using: &g); s.rt = Double.random(in: 0...1, using: &g)
        let all: [PadButtons] = [.a, .b, .x, .y, .lb, .rb, .view, .menu, .ls, .rs, .guide, .dpadUp, .dpadDown, .dpadLeft, .dpadRight]
        for b in all where Bool.random(using: &g) { s.buttons.insert(b) }
        return s
    }

    private func items(of b: PadButtons) -> Set<PadItem> {
        var s: Set<PadItem> = []
        let pairs: [(PadButtons, PadItem)] = [(.a, .a), (.b, .b), (.x, .x), (.y, .y), (.lb, .lb), (.rb, .rb), (.view, .view),
                                              (.menu, .menu), (.ls, .ls), (.rs, .rs), (.guide, .guide)]
        for (f, i) in pairs where b.contains(f) { s.insert(i) }
        s.formUnion(PadHat.items(PadReportBuilders.hat(b)))
        return s
    }

    func testDecodesWhatTheBuilderWritesForRandomStates() {
        var g = DevTestRNG(state: 20261109)
        for n in 0..<200 {
            let s = randomState(&g)
            let d = decode(PadReportBuilders.xboxBT16(s))
            // Quantisation: 16 bits for sticks (half a step is 1.6e-5), 10 bits for triggers (half a step is 4.9e-4).
            XCTAssertEqual(d.lx, s.lx, accuracy: 4e-5, "state \(n)")
            XCTAssertEqual(d.ly, s.ly, accuracy: 4e-5, "state \(n): Y has the sign of PadState (up is positive)")
            XCTAssertEqual(d.rx, s.rx, accuracy: 4e-5, "state \(n)")
            XCTAssertEqual(d.ry, s.ry, accuracy: 4e-5, "state \(n)")
            XCTAssertEqual(d.lt, s.lt, accuracy: 6e-4, "state \(n)")
            XCTAssertEqual(d.rt, s.rt, accuracy: 6e-4, "state \(n)")
            XCTAssertEqual(d.items, items(of: s.buttons), "state \(n)")
        }
    }

    func testYIsNegatedOnTheWire() {
        var s = PadState(); s.ly = 1; s.ry = -1
        let r = PadReportBuilders.xboxBT16(s)[0].bytes
        XCTAssertEqual(UInt16(r[3]) | UInt16(r[4]) << 8, 0, "stick up is the smallest value on the wire")
        let d = decode(PadReportBuilders.xboxBT16(s))
        XCTAssertEqual(d.ly, 1, accuracy: 1e-4)
        XCTAssertEqual(d.ry, -1, accuracy: 1e-4)
    }

    func testTriggerFieldIgnoresItsPaddingBits() {
        var bytes = PadReportBuilders.xboxBT16(PadState())[0].bytes
        bytes[9] = 0xFF; bytes[10] = 0xFF      // 0xFFFF: 10 bits all set, six padding bits above
        bytes[11] = 0x00; bytes[12] = 0xFC     // 0xFC00: only padding
        var s = PadDecodedState.neutral
        XCTAssertTrue(decoder.apply(reportID: 1, bytes: bytes, to: &s))
        XCTAssertEqual(s.lt, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.rt, 0.0, accuracy: 1e-9)
    }

    func testHatValuesZeroToEightGiveTheDpadItems() {
        let expect: [UInt8: Set<PadItem>] = [
            0: [], 1: [.dpadUp], 2: [.dpadUp, .dpadRight], 3: [.dpadRight], 4: [.dpadRight, .dpadDown],
            5: [.dpadDown], 6: [.dpadDown, .dpadLeft], 7: [.dpadLeft], 8: [.dpadLeft, .dpadUp],
        ]
        for (hat, items) in expect {
            var bytes = PadReportBuilders.xboxBT16(PadState())[0].bytes
            bytes[13] = hat
            var s = PadDecodedState.neutral
            decoder.apply(reportID: 1, bytes: bytes, to: &s)
            XCTAssertEqual(s.hat, hat)
            XCTAssertEqual(s.items, items, "hat \(hat)")
        }
        var bytes = PadReportBuilders.xboxBT16(PadState())[0].bytes
        bytes[13] = 15       // outside the descriptor's range: the null state
        var s = PadDecodedState.neutral
        decoder.apply(reportID: 1, bytes: bytes, to: &s)
        XCTAssertEqual(s.hat, 0)
    }

    func testALoneGuideReportMergesIntoTheHeldState() {
        var s = decode(PadReportBuilders.xboxBT16({ var p = PadState(); p.buttons = [.a, .dpadUp]; return p }()))
        XCTAssertTrue(s.buttons.contains(.a))
        XCTAssertFalse(s.guide)
        XCTAssertTrue(decoder.apply(reportID: 2, bytes: [0x02, 0x01], to: &s), "a lone 0x02 changes the state")
        XCTAssertTrue(s.guide)
        XCTAssertEqual(s.items, [.a, .dpadUp, .guide], "report 0x01's state is kept")
        XCTAssertFalse(decoder.apply(reportID: 2, bytes: [0x02, 0x01], to: &s), "the same report again changes nothing")
        XCTAssertTrue(decoder.apply(reportID: 2, bytes: [0x02, 0x00], to: &s))
        XCTAssertEqual(s.items, [.a, .dpadUp])
    }

    func testGoldenLineFromACaptureDecodesToCentredSticksAndHatEast() {
        let hex = "01 00 80 00 80 00 80 00 80 00 00 00 00 03 00 00"
        let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        var s = PadDecodedState.neutral
        XCTAssertTrue(decoder.apply(reportID: 1, bytes: bytes, to: &s))
        for v in [s.lx, s.ly, s.rx, s.ry] { XCTAssertEqual(v, 0, accuracy: 1e-4) }
        XCTAssertEqual(s.lt, 0); XCTAssertEqual(s.rt, 0)
        XCTAssertEqual(s.hat, 3)
        XCTAssertEqual(PadHat.name(s.hat), "E")
        XCTAssertEqual(s.items, [.dpadRight])
        XCTAssertTrue(s.sticksInside(deadZone: 0.12))
    }

    func testWrongIDOrShortBytesChangeNothing() {
        var s = PadDecodedState.neutral
        XCTAssertFalse(decoder.apply(reportID: 9, bytes: [9, 1, 2], to: &s))
        XCTAssertFalse(decoder.apply(reportID: 1, bytes: [1, 0, 0], to: &s), "shorter than the table's 16 bytes")
        XCTAssertFalse(decoder.apply(reportID: 1, bytes: [2] + [UInt8](repeating: 0xFF, count: 15), to: &s), "ID byte disagrees")
        XCTAssertEqual(s, .neutral)
    }

    func testToleranceHelpers() {
        var s = PadDecodedState.neutral
        XCTAssertTrue(s.isNeutral(deadZone: 0.12, triggerMax: 0.05))
        s.lx = 0.08; s.ly = 0.08       // radius 0.113
        XCTAssertTrue(s.sticksInside(deadZone: 0.12))
        s.lx = 0.10; s.ly = 0.10       // radius 0.141
        XCTAssertFalse(s.sticksInside(deadZone: 0.12))
        s = .neutral; s.rt = 0.06
        XCTAssertFalse(s.isNeutral(deadZone: 0.12, triggerMax: 0.05))
        s = .neutral; s.hat = 1
        XCTAssertFalse(s.isNeutral(deadZone: 0.12, triggerMax: 0.05), "the hat is exact")
        s = .neutral; s.guide = true
        XCTAssertFalse(s.isNeutral(deadZone: 0.12, triggerMax: 0.05), "Guide is exact")
    }

    func testPadItemNamesRoundTripAndLinkToLayoutControls() {
        for item in PadItem.allCases { XCTAssertEqual(PadItem(name: item.name), item) }
        XCTAssertEqual(PadItem.ls.layoutControlID, "l3")
        XCTAssertEqual(PadItem.dpadLeft.layoutControlID, "dpad_left")
        XCTAssertNil(PadItem.guide.layoutControlID)
    }
}

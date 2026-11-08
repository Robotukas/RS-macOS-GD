import XCTest
@testable import GDHub

final class PadReportBuilderTests: XCTestCase {
    private func r1(_ s: PadState) -> [UInt8] { PadReportBuilders.xboxBT16(s)[0].bytes }
    private func r2(_ s: PadState) -> [UInt8] { PadReportBuilders.xboxBT16(s)[1].bytes }

    func testNeutralVectors() {
        XCTAssertEqual(r1(.neutral), [UInt8](hex: "01 00 80 00 80 00 80 00 80 00 00 00 00 00 00 00"))
        XCTAssertEqual(r2(.neutral), [0x02, 0x00])
        XCTAssertEqual(PadReportBuilders.xboxBT16(.neutral).map(\.id), [1, 2])
    }

    func testButtons() {
        func b14(_ b: PadButtons) -> UInt8 { r1(PadState(buttons: b))[14] }
        func b15(_ b: PadButtons) -> UInt8 { r1(PadState(buttons: b))[15] }
        XCTAssertEqual(b14(.a), 0x01); XCTAssertEqual(b14(.b), 0x02); XCTAssertEqual(b14(.x), 0x04)
        XCTAssertEqual(b14(.y), 0x08); XCTAssertEqual(b14(.lb), 0x10); XCTAssertEqual(b14(.rb), 0x20)
        XCTAssertEqual(b14(.view), 0x40); XCTAssertEqual(b14(.menu), 0x80)
        XCTAssertEqual(b14([.a, .menu]), 0x81)
        XCTAssertEqual(b15(.ls), 0x01); XCTAssertEqual(b15(.rs), 0x02)
        XCTAssertEqual(r2(PadState(buttons: .guide)), [0x02, 0x01])
        XCTAssertEqual(r1(PadState(buttons: .guide)), r1(.neutral), "Guide only appears in report 0x02")
    }

    func testAxesAndTriggers() {
        XCTAssertEqual(Array(r1(PadState(lx: -1))[1...2]), [0x00, 0x00])
        XCTAssertEqual(Array(r1(PadState(lx: 1))[1...2]), [0xFF, 0xFF])
        XCTAssertEqual(Array(r1(PadState(ly: 1))[3...4]), [0x00, 0x00], "y up is 0")
        XCTAssertEqual(Array(r1(PadState(ly: -1))[3...4]), [0xFF, 0xFF])
        XCTAssertEqual(Array(r1(PadState(rx: 1))[5...6]), [0xFF, 0xFF])
        XCTAssertEqual(Array(r1(PadState(ry: 1))[7...8]), [0x00, 0x00])
        XCTAssertEqual(Array(r1(PadState(lt: 1))[9...10]), [0xFF, 0x03])
        XCTAssertEqual(Array(r1(PadState(rt: 0.5))[11...12]), [0x00, 0x02])
        XCTAssertEqual(Array(r1(PadState(lx: 5, lt: 9))[1...2]), [0xFF, 0xFF], "clamped")
    }

    func testHat() {
        func hat(_ b: PadButtons) -> UInt8 { r1(PadState(buttons: b))[13] }
        XCTAssertEqual(hat([]), 0)
        XCTAssertEqual(hat(.dpadUp), 1)
        XCTAssertEqual(hat([.dpadUp, .dpadRight]), 2)
        XCTAssertEqual(hat(.dpadRight), 3)
        XCTAssertEqual(hat([.dpadDown, .dpadRight]), 4)
        XCTAssertEqual(hat(.dpadDown), 5)
        XCTAssertEqual(hat([.dpadDown, .dpadLeft]), 6)
        XCTAssertEqual(hat(.dpadLeft), 7)
        XCTAssertEqual(hat([.dpadUp, .dpadLeft]), 8)
        XCTAssertEqual(hat([.dpadUp, .dpadDown]), 0, "opposite directions cancel")
        XCTAssertEqual(hat([.dpadUp, .dpadDown, .dpadRight]), 3)
    }

    func testKnownState() {
        let s = PadState(buttons: [.a, .rb, .ls, .dpadLeft], lx: 0.5, ly: -0.5, rx: 0, ry: 1, lt: 1, rt: 0)
        // lx 0.5 -> 49151.25 -> 0xBFFF; -ly = 0.5 -> 0xBFFF; rx 0 -> 0x8000; -ry = -1 -> 0x0000
        XCTAssertEqual(r1(s), [UInt8](hex: "01 FF BF FF BF 00 80 00 00 FF 03 00 00 07 21 01"))
    }

    func testEveryReportMatchesTheDescriptorSizes() throws {
        let sizes = try HIDReportSizer.inputs(PadDescriptors.xboxBT16)
        for state in [PadState.neutral, PadState(buttons: [.a, .guide], lx: 1, ly: 1, lt: 1)] {
            for (r, size) in zip(PadReportBuilders.xboxBT16(state), sizes) {
                XCTAssertEqual(r.id, size.id)
                XCTAssertEqual(r.bytes.count, size.length)
                XCTAssertEqual(r.bytes.first, size.id)
            }
        }
    }

    func testIdentity02E0ReportsEqualBT16() {
        let s = PadState(buttons: [.x, .menu, .dpadUp], lx: -0.3, ly: 0.7, rx: 0.1, ry: -0.9, lt: 0.2, rt: 0.8)
        XCTAssertEqual(PadIdentity.xboxBT16_02E0.reports(for: s), PadIdentity.xboxBT16.reports(for: s))
        XCTAssertEqual(PadIdentity.xboxBT16_02E0.reports(for: s), PadReportBuilders.xboxBT16(s))
        XCTAssertEqual(PadIdentity.xboxBT16_02E0.productID, 0x02E0)
        XCTAssertEqual(PadIdentity.xboxBT16.productID, 0x0B13)
        XCTAssertEqual(PadIdentity.default.id, "xbox-bt16-02e0")
    }

    func testTestPatternCoversEveryControlInOrder() {
        var seen: [PadButtons] = []
        var ms = 0
        var sawLT = false, sawRT = false, sawLeftStick = false, sawRightStick = false
        while let s = VirtualPadSink.testPatternState(atMs: ms) {
            if !s.buttons.isEmpty, seen.last != s.buttons { seen.append(s.buttons) }
            if s.lt > 0.9 { sawLT = true }
            if s.rt > 0.9 { sawRT = true }
            if s.lx > 0.9 { sawLeftStick = true }
            if s.rx > 0.9 { sawRightStick = true }
            ms += 10
        }
        XCTAssertEqual(seen, [.a, .b, .x, .y, .lb, .rb, .view, .menu, .ls, .rs, .guide,
                              .dpadUp, .dpadRight, .dpadDown, .dpadLeft])
        XCTAssertTrue(sawLT && sawRT && sawLeftStick && sawRightStick)
        XCTAssertEqual(ms, VirtualPadSink.testPatternDurationMs)
        XCTAssertNil(VirtualPadSink.testPatternState(atMs: ms))
    }
}

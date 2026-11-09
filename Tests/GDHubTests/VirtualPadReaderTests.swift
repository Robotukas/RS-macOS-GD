import XCTest
@testable import GDHub

/// The reader's buffer and held state, fed the way the HID callback feeds them (no IOKit device needed).
final class VirtualPadReaderTests: XCTestCase {
    private func reports(_ s: PadState) -> [PadReport] { PadReportBuilders.xboxBT16(s) }

    func testHeldStateStartsUnknownAndFollowsEveryReport() {
        let reader = VirtualPadReader(capacity: 128)
        XCTAssertEqual(reader.heldSnapshot(), .init(state: nil, everSeen: false, seq: 0))
        var s = PadState(); s.buttons = [.a]; s.lx = 0.5
        for r in reports(s) { reader.record(id: r.id, bytes: r.bytes, tNs: 1_000) }
        let held = reader.heldSnapshot()
        XCTAssertTrue(held.everSeen)
        XCTAssertEqual(held.state?.buttons, [.a])
        XCTAssertEqual(held.state?.lx ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(held.seq, UInt64(reports(s).count))
    }

    func testDrainContinuesFromACursorWithoutGapsOrRepeats() {
        let reader = VirtualPadReader(capacity: 128)
        for i in 0..<10 { reader.record(id: 1, bytes: reports(PadState())[0].bytes, tNs: UInt64(i)) }
        let first = reader.drain(after: 0)
        XCTAssertEqual(first.reports.count, 10)
        XCTAssertEqual(first.reports.map(\.tNs), (0..<10).map(UInt64.init))
        XCTAssertFalse(first.lost)
        for i in 10..<15 { reader.record(id: 1, bytes: reports(PadState())[0].bytes, tNs: UInt64(i)) }
        let second = reader.drain(after: first.lastSeq)
        XCTAssertEqual(second.reports.map(\.tNs), (10..<15).map(UInt64.init))
        XCTAssertTrue(reader.drain(after: second.lastSeq).reports.isEmpty)
    }

    func testTheRingKeepsTheNewestAndSaysWhenItLostSome() {
        let reader = VirtualPadReader(capacity: 64)
        for i in 0..<200 { reader.record(id: 1, bytes: reports(PadState())[0].bytes, tNs: UInt64(i)) }
        let d = reader.drain(after: 0)
        XCTAssertTrue(d.lost)
        XCTAssertEqual(d.reports.count, 64)
        XCTAssertEqual(d.reports.last?.tNs, 199)
        XCTAssertEqual(reader.snapshot(since: 190).count, 10)
    }

    func testTheDefaultCapacityHoldsTwentyThousandReports() {
        XCTAssertGreaterThanOrEqual(VirtualPadReader.defaultCapacity, 20_000)
    }
}

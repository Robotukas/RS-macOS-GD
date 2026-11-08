import XCTest
@testable import GDHub

/// Descriptor lengths and report sizes (design §7.1). The other identities' descriptors are transcribed from the
/// design here only to check the parser; the app carries them from D6.
final class HIDReportSizerTests: XCTestCase {
    private typealias R = HIDReportSizer.ReportSize

    // Parts shared by the Xbox descriptors.
    private static let head = """
        05 01 09 05 A1 01 85 01
        09 01 A1 00 09 30 09 31 15 00 27 FF FF 00 00 95 02 75 10 81 02 C0
        09 01 A1 00 09 33 09 34 15 00 27 FF FF 00 00 95 02 75 10 81 02 C0
        05 01 09 32 15 00 26 FF 03 95 01 75 0A 81 02 15 00 25 00 75 06 95 01 81 03
        05 01 09 35 15 00 26 FF 03 95 01 75 0A 81 02 15 00 25 00 75 06 95 01 81 03
        05 01 09 39 15 01 25 08 35 00 46 3B 01 66 14 00 75 04 95 01 81 42
        75 04 95 01 15 00 25 00 35 00 45 00 65 00 81 03
        """
    private static let rumble = """
        05 0F 09 21 85 03 A1 02
        09 97 15 00 25 01 75 04 95 01 91 02 15 00 25 00 75 04 95 01 91 03
        09 70 15 00 25 64 75 08 95 04 91 02
        09 50 66 01 10 55 0E 15 00 26 FF 00 75 08 95 01 91 02
        09 A7 15 00 26 FF 00 75 08 95 01 91 02
        65 00 55 00 09 7C 15 00 26 FF 00 75 08 95 01 91 02 C0
        C0
        """
    private static let gip = "06 00 FF 09 01 A1 01 15 00 26 FF 00 75 08 85 20 95 18 81 02 85 09 95 0C 91 02 C0"

    private static let bt17 = [UInt8](hex: head + """
        05 09 15 00 25 01 75 01 95 02 19 01 29 02 81 02 95 01 81 03 95 02 19 03 29 04 81 02
        95 01 81 03 95 02 19 05 29 06 81 02 95 02 81 03 95 02 19 07 29 08 81 02
        95 01 09 0B 81 02 95 02 19 09 29 0A 81 02 95 01 81 03
        05 0C 0A B2 00 95 01 81 02 95 07 81 03
        """ + rumble)

    private static let dual = PadDescriptors.xboxBT16 + [UInt8](hex: gip)

    private static let pr208 = [UInt8](hex: head + """
        05 09 19 01 29 0F 15 00 25 01 75 01 95 0F 81 02
        15 00 25 00 75 01 95 01 81 03
        05 0C 0A B2 00 15 00 25 01 95 01 75 01 81 02
        15 00 25 00 75 07 95 01 81 03
        """ + rumble + gip)

    private static let x360 = [UInt8](hex: """
        05 01 09 05 A1 01 75 08 95 02 81 01
        05 09 15 00 25 01 75 01 95 04 19 0C 29 0F 81 02
        95 04 09 09 09 0A 09 07 09 08 81 02
        95 03 09 05 09 06 09 0B 81 02 95 01 81 01
        95 04 19 01 29 04 81 02
        05 01 15 00 26 FF 00 75 08 95 02 09 32 09 35 81 02
        16 00 80 26 FF 7F 75 10 95 04 09 30 09 31 09 33 09 34 81 02
        75 08 95 06 81 01
        06 00 FF 09 01 15 00 26 FF 00 75 08 95 04 91 02 C0
        """)

    private static let keyboard = [UInt8](hex: """
        05 01 09 06 A1 01 85 01 05 07 19 E0 29 E7 15 00 25 01 75 01 95 08 81 02 95 01 75 08 81 01
        05 07 19 00 29 DF 15 00 25 01 75 01 95 E0 81 02 05 08 19 01 29 05 95 05 75 01 91 02 95 01 75 03 91 01 C0
        05 0C 09 01 A1 01 85 02 15 00 26 FF 03 19 00 2A FF 03 75 10 95 01 81 00 C0
        """)

    private static let pointer = [UInt8](hex: """
        05 01 09 02 A1 01 85 01 09 01 A1 00 05 09 19 01 29 08 15 00 25 01 75 01 95 08 81 02
        05 01 09 30 09 31 16 01 80 26 FF 7F 75 10 95 02 81 06 09 38 15 81 25 7F 75 08 95 01 81 06
        05 0C 0A 38 02 15 81 25 7F 75 08 95 01 81 06 C0 C0
        """)

    func testBT16() throws {
        let d = PadDescriptors.xboxBT16
        XCTAssertEqual(d.count, 285)
        let r = try HIDReportSizer.parse(d)
        XCTAssertEqual(r.inputs, [R(1, 16), R(2, 2)])
        XCTAssertEqual(r.outputs, [R(3, 9)])
        XCTAssertTrue(r.features.isEmpty)
    }

    func testBT17() throws {
        XCTAssertEqual(Self.bt17.count, 315)
        let r = try HIDReportSizer.parse(Self.bt17)
        XCTAssertEqual(r.inputs, [R(1, 17)])
        XCTAssertEqual(r.outputs, [R(3, 9)])
    }

    func testDual() throws {
        XCTAssertEqual(Self.dual.count, 312)
        let r = try HIDReportSizer.parse(Self.dual)
        XCTAssertEqual(r.inputs, [R(1, 16), R(2, 2), R(0x20, 25)])
        XCTAssertEqual(r.outputs, [R(3, 9), R(9, 13)])
    }

    func testPR208() throws {
        XCTAssertEqual(Self.pr208.count, 310)
        let r = try HIDReportSizer.parse(Self.pr208)
        XCTAssertEqual(r.inputs, [R(1, 17), R(0x20, 25)])
        XCTAssertEqual(r.outputs, [R(3, 9), R(9, 13)])
    }

    func testX360() throws {
        XCTAssertEqual(Self.x360.count, 122)
        let r = try HIDReportSizer.parse(Self.x360)
        XCTAssertEqual(r.inputs, [R(0, 20)])
        XCTAssertEqual(r.outputs, [R(0, 4)])
    }

    func testKeyboard() throws {
        XCTAssertEqual(Self.keyboard.count, 90)
        let r = try HIDReportSizer.parse(Self.keyboard)
        XCTAssertEqual(r.inputs, [R(1, 31), R(2, 3)])
        XCTAssertEqual(r.outputs, [R(1, 2)])
    }

    func testPointer() throws {
        XCTAssertEqual(Self.pointer.count, 75)
        let r = try HIDReportSizer.parse(Self.pointer)
        XCTAssertEqual(r.inputs, [R(1, 8)])
        XCTAssertTrue(r.outputs.isEmpty)
    }

    func testNotByteAlignedThrows() {
        // Report ID 1, one 4-bit input.
        XCTAssertThrowsError(try HIDReportSizer.parse([UInt8](hex: "85 01 75 04 95 01 81 02"))) {
            XCTAssertEqual($0 as? HIDReportSizer.SizerError, .notByteAligned(type: "input", id: 1, bits: 4))
        }
    }

    func testPushPopRestoresGlobals() throws {
        // Push, change size, pop: the following input uses the original 8-bit size.
        let r = try HIDReportSizer.parse([UInt8](hex: "75 08 95 02 A4 75 10 B4 81 02"))
        XCTAssertEqual(r.inputs, [R(0, 2)])
    }

    func testTruncatedItemThrows() {
        XCTAssertThrowsError(try HIDReportSizer.parse([0x75]))
    }
}

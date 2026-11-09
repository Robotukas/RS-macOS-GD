import XCTest
@testable import GDHub

/// Keeps `Dext/GDHubVirtualHID/GDHubProtocol.h` and `DextProtocol.swift` in step (design §7.1).
final class DextProtocolTests: XCTestCase {
    private func headerDefines() throws -> [String: UInt64] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Dext/GDHubVirtualHID/GDHubProtocol.h")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3, parts[0] == "#define", parts[1].hasPrefix("GDHUB_") else { continue }
            var tok = String(parts[2])
            if tok.hasSuffix("u") || tok.hasSuffix("U") { tok.removeLast() }
            let value: UInt64?
            if tok.hasPrefix("0x") || tok.hasPrefix("0X") { value = UInt64(tok.dropFirst(2), radix: 16) }
            else { value = UInt64(tok) }
            if let value { out[String(parts[1])] = value }
        }
        return out
    }

    /// Every numeric `#define` in the header and its Swift mirror.
    private var mirror: [String: UInt64] {
        typealias P = DextProtocol
        return [
            "GDHUB_PROTOCOL_VERSION": UInt64(P.version),
            "GDHUB_USERCLIENT_TYPE": UInt64(P.userClientType),
            "GDHUB_SEL_HELLO": UInt64(P.Selector.hello),
            "GDHUB_SEL_CREATE_DEVICE": UInt64(P.Selector.createDevice),
            "GDHUB_SEL_DESTROY_DEVICE": UInt64(P.Selector.destroyDevice),
            "GDHUB_SEL_POST_REPORT": UInt64(P.Selector.postReport),
            "GDHUB_SEL_POST_NEUTRAL": UInt64(P.Selector.postNeutral),
            "GDHUB_SEL_HEARTBEAT": UInt64(P.Selector.heartbeat),
            "GDHUB_SEL_REGISTER_OUTPUT": UInt64(P.Selector.registerOutput),
            "GDHUB_SEL_GET_STATUS": UInt64(P.Selector.getStatus),
            "GDHUB_SEL_DEV_TERMINATE": UInt64(P.Selector.devTerminate),
            "GDHUB_SEL_COUNT": UInt64(P.Selector.count),
            "GDHUB_SLOT_PAD": UInt64(P.Slot.pad.rawValue),
            "GDHUB_SLOT_KEYBOARD": UInt64(P.Slot.keyboard.rawValue),
            "GDHUB_SLOT_POINTER": UInt64(P.Slot.pointer.rawValue),
            "GDHUB_SLOT_COUNT": UInt64(P.Slot.count),
            "GDHUB_CAP_PAD": P.Capability.pad,
            "GDHUB_CAP_KEYBOARD": P.Capability.keyboard,
            "GDHUB_CAP_POINTER": P.Capability.pointer,
            "GDHUB_MAX_DESCRIPTOR": UInt64(P.Limit.maxDescriptor),
            "GDHUB_MAX_REPORT": UInt64(P.Limit.maxReport),
            "GDHUB_MAX_INPUT_REPORTS": UInt64(P.Limit.maxInputReports),
            "GDHUB_MAX_NEUTRAL": UInt64(P.Limit.maxNeutral),
            "GDHUB_SPEC_MAGIC": UInt64(P.Spec.magic),
            "GDHUB_SPEC_HEADER_SIZE": UInt64(P.Spec.headerSize),
            "GDHUB_SPEC_OFF_MAGIC": UInt64(P.Offset.magic),
            "GDHUB_SPEC_OFF_VERSION": UInt64(P.Offset.version),
            "GDHUB_SPEC_OFF_HEADER_SIZE": UInt64(P.Offset.headerSize),
            "GDHUB_SPEC_OFF_SLOT": UInt64(P.Offset.slot),
            "GDHUB_SPEC_OFF_FLAGS": UInt64(P.Offset.flags),
            "GDHUB_SPEC_OFF_INPUT_COUNT": UInt64(P.Offset.inputCount),
            "GDHUB_SPEC_OFF_VENDOR": UInt64(P.Offset.vendor),
            "GDHUB_SPEC_OFF_PRODUCT": UInt64(P.Offset.product),
            "GDHUB_SPEC_OFF_VERSION_NUMBER": UInt64(P.Offset.versionNumber),
            "GDHUB_SPEC_OFF_COUNTRY": UInt64(P.Offset.country),
            "GDHUB_SPEC_OFF_LOCATION": UInt64(P.Offset.location),
            "GDHUB_SPEC_OFF_INTERVAL_US": UInt64(P.Offset.intervalUs),
            "GDHUB_SPEC_OFF_USAGE_PAGE": UInt64(P.Offset.usagePage),
            "GDHUB_SPEC_OFF_USAGE": UInt64(P.Offset.usage),
            "GDHUB_SPEC_OFF_DESC_LEN": UInt64(P.Offset.descLen),
            "GDHUB_SPEC_OFF_NEUTRAL_LEN": UInt64(P.Offset.neutralLen),
            "GDHUB_SPEC_OFF_INPUT_TABLE": UInt64(P.Offset.inputTable),
            "GDHUB_SPEC_OFF_TRANSPORT": UInt64(P.Offset.transport),
            "GDHUB_SPEC_LEN_TRANSPORT": UInt64(P.Length.transport),
            "GDHUB_SPEC_OFF_MANUFACTURER": UInt64(P.Offset.manufacturer),
            "GDHUB_SPEC_LEN_MANUFACTURER": UInt64(P.Length.manufacturer),
            "GDHUB_SPEC_OFF_PRODUCT_NAME": UInt64(P.Offset.productName),
            "GDHUB_SPEC_LEN_PRODUCT_NAME": UInt64(P.Length.productName),
            "GDHUB_SPEC_OFF_SERIAL": UInt64(P.Offset.serial),
            "GDHUB_SPEC_LEN_SERIAL": UInt64(P.Length.serial),
            "GDHUB_SPEC_FLAG_HID_DEFAULT_BEHAVIOR": UInt64(P.Spec.flagHIDDefaultBehavior),
            "GDHUB_OUTPUT_ARG_COUNT": UInt64(P.outputArgCount),
        ]
    }

    func testEveryHeaderDefineMatchesSwift() throws {
        let header = try headerDefines()
        XCTAssertGreaterThan(header.count, 40, "header parsed")
        for (name, value) in header.sorted(by: { $0.key < $1.key }) {
            guard let swift = mirror[name] else { XCTFail("\(name) has no Swift mirror"); continue }
            XCTAssertEqual(swift, value, name)
        }
        for name in mirror.keys where header[name] == nil { XCTFail("\(name) is mirrored but not in the header") }
    }

    func testSpecHeaderLayoutIsContiguous() {
        typealias O = DextProtocol.Offset
        typealias L = DextProtocol.Length
        XCTAssertEqual(O.inputTable + DextProtocol.Limit.maxInputReports * L.inputTableEntry, O.transport)
        XCTAssertEqual(O.transport + L.transport, O.manufacturer)
        XCTAssertEqual(O.manufacturer + L.manufacturer, O.productName)
        XCTAssertEqual(O.productName + L.productName, O.serial)
        XCTAssertLessThanOrEqual(O.serial + L.serial, DextProtocol.Spec.headerSize, "224..255 are reserved")
        XCTAssertEqual(O.neutralLen + 2, O.inputTable)
        let magic = DextProtocol.Spec.magic
        XCTAssertEqual((0..<4).map { UInt8((magic >> UInt32(8 * $0)) & 0xFF) }, [0x47, 0x44, 0x48, 0x53],
                       "'G' 'D' 'H' 'S' on the wire")
    }

    func testOutputReportDecodesPackedWords() throws {
        var w = [UInt64](repeating: 0, count: DextProtocol.outputArgCount)
        // slot 0, type 2 (output), report ID 3, length 9, not truncated; payload 03 0F 10 20 30 40 FF 00 EB
        w[0] = 0 | (2 << 8) | (3 << 16) | (9 << 24)
        w[1] = 0x00FF_4030_2010_0F03
        w[2] = 0xEB
        w[9] = 41
        let r = try XCTUnwrap(OutputReport(words: w))
        XCTAssertEqual(r.slot, 0); XCTAssertEqual(r.type, 2); XCTAssertEqual(r.reportID, 3)
        XCTAssertEqual(r.bytes, [0x03, 0x0F, 0x10, 0x20, 0x30, 0x40, 0xFF, 0x00, 0xEB])
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.sequence, 41)
        XCTAssertNil(OutputReport(words: [0, 1, 2]), "too few words")
    }

    func testErrorCodesRoundTrip() {
        XCTAssertEqual(DextProtocol.krNotPermitted, kern_return_t(bitPattern: 0xE00002E2))
        XCTAssertEqual(DextError(DextProtocol.krExclusiveAccess), .exclusiveAccess)
        XCTAssertEqual(DextError(DextProtocol.krNotPermitted).code, DextProtocol.krNotPermitted)
        XCTAssertEqual(DextError(5), .other(5))
        XCTAssertEqual(DextStatus(words: [3, 100, 2, 7, 1]).watchdogFires, 2)
    }

    // MARK: DeviceSpec encoding (design §7.1)

    private func bt16Spec(_ identity: PadIdentity) throws -> [UInt8] { try identity.spec().encoded() }

    func testDevTerminateIsTheNextSelector() {
        XCTAssertEqual(DextProtocol.Selector.devTerminate, DextProtocol.Selector.getStatus + 1)
        XCTAssertEqual(DextProtocol.Selector.count, DextProtocol.Selector.devTerminate + 1)
    }

    func testBT16SpecEncoding() throws {
        typealias O = DextProtocol.Offset
        let b = try bt16Spec(.xboxBT16)
        XCTAssertEqual(b.count, 256 + 285 + 18)
        XCTAssertEqual(Array(b[0..<4]), [0x47, 0x44, 0x48, 0x53])
        XCTAssertEqual(Array(b[O.version..<O.version + 2]), [1, 0])
        XCTAssertEqual(Array(b[O.headerSize..<O.headerSize + 2]), [0x00, 0x01])
        XCTAssertEqual(b[O.slot], 0); XCTAssertEqual(b[O.flags], 0); XCTAssertEqual(b[O.inputCount], 2)
        XCTAssertEqual(Array(b[O.vendor..<O.vendor + 4]), [0x5E, 0x04, 0x00, 0x00])
        XCTAssertEqual(Array(b[O.product..<O.product + 4]), [0x13, 0x0B, 0x00, 0x00])
        XCTAssertEqual(Array(b[O.versionNumber..<O.versionNumber + 4]), [0x13, 0x05, 0x00, 0x00])
        XCTAssertEqual(Array(b[O.location..<O.location + 4]), [0x01, 0x48, 0x44, 0x47])
        XCTAssertEqual(Array(b[O.intervalUs..<O.intervalUs + 4]), [0xE8, 0x03, 0x00, 0x00])      // 1000 µs (fix #6)
        XCTAssertEqual(Array(b[O.usagePage..<O.usagePage + 4]), [1, 0, 0, 0])
        XCTAssertEqual(Array(b[O.usage..<O.usage + 4]), [5, 0, 0, 0])
        XCTAssertEqual(Array(b[O.descLen..<O.descLen + 2]), [0x1D, 0x01])      // 285
        XCTAssertEqual(Array(b[O.neutralLen..<O.neutralLen + 2]), [18, 0])
        XCTAssertEqual(Array(b[O.inputTable..<O.inputTable + 8]), [0x01, 0x00, 0x10, 0x00, 0x02, 0x00, 0x02, 0x00])
        XCTAssertEqual(Array(b[O.transport..<O.transport + 21]), Array("Bluetooth Low Energy".utf8) + [0])
        XCTAssertEqual(Array(b[O.manufacturer..<O.manufacturer + 10]), Array("Microsoft".utf8) + [0])
        XCTAssertEqual(Array(b[O.productName..<O.productName + 25]), Array("Xbox Wireless Controller".utf8) + [0])
        XCTAssertEqual(Array(b[O.serial..<O.serial + 8]), Array("GDHub-1".utf8) + [0])
        XCTAssertEqual(Array(b[224..<256]), [UInt8](repeating: 0, count: 32), "reserved bytes are zero")
        XCTAssertEqual(Array(b[256..<256 + 285]), PadDescriptors.xboxBT16)
        XCTAssertEqual(Array(b[(256 + 285)...]), [UInt8](hex: "01 00 80 00 80 00 80 00 80 00 00 00 00 00 00 00 02 00"))
    }

    func test02E0SpecDiffersOnlyInProductID() throws {
        typealias O = DextProtocol.Offset
        let a = try bt16Spec(.xboxBT16_02E0), b = try bt16Spec(.xboxBT16)
        XCTAssertEqual(Array(a[O.product..<O.product + 4]), [0xE0, 0x02, 0x00, 0x00])
        var patched = b
        for i in 0..<4 { patched[O.product + i] = a[O.product + i] }
        XCTAssertEqual(a, patched)
    }

    func testSendLengthSpec() throws {
        // A 17-byte report 0x01 sent as 25 bytes (xbox-pr208 shape), built from a hand-made descriptor.
        let desc = [UInt8](hex: "05 01 09 05 A1 01 85 01 75 08 95 10 81 02 85 20 95 18 81 02 C0")
        func spec(send: Int, neutral0: Int? = nil) -> DeviceSpec {
            DeviceSpec(slot: .pad, vendorID: 1, productID: 2, versionNumber: 3, transport: "Virtual", manufacturer: "m",
                       product: "p", serialNumber: "s", descriptor: desc, sendLengths: [0x01: send],
                       neutralReports: [[0x01] + [UInt8](repeating: 0, count: (neutral0 ?? send) - 1),
                                        [0x20] + [UInt8](repeating: 0, count: 24)])
        }
        let b = try spec(send: 25).encoded()
        XCTAssertEqual(Array(b[DextProtocol.Offset.inputTable..<DextProtocol.Offset.inputTable + 8]),
                       [0x01, 0x19, 0x11, 0x00, 0x20, 0x00, 0x19, 0x00])
        XCTAssertEqual(Array(b[DextProtocol.Offset.transport..<DextProtocol.Offset.transport + 8]),
                       [0x56, 0x69, 0x72, 0x74, 0x75, 0x61, 0x6C, 0x00])
        XCTAssertEqual(b.count, 256 + desc.count + 50)
        XCTAssertThrowsError(try spec(send: 16).encoded(), "below the declared length")
        XCTAssertThrowsError(try spec(send: 26).encoded(), "above the largest input report")
        XCTAssertThrowsError(try spec(send: 25, neutral0: 24).encoded(), "neutral length is not its send length")
    }

    func testSpecValidationRules() throws {
        var s = try PadIdentity.xboxBT16.spec()
        s.product = String(repeating: "x", count: 64)
        XCTAssertThrowsError(try s.encoded(), "overlong product string")
        s.product = String(repeating: "x", count: 63)
        XCTAssertNoThrow(try s.encoded())
        s = try PadIdentity.xboxBT16.spec(); s.transport = ""
        XCTAssertThrowsError(try s.encoded(), "empty transport")
        s = try PadIdentity.xboxBT16.spec(); s.neutralReports[0][0] = 0x09
        XCTAssertThrowsError(try s.encoded(), "neutral must start with its report ID")
        s = try PadIdentity.xboxBT16.spec(); s.neutralReports.removeLast()
        XCTAssertThrowsError(try s.encoded(), "one neutral report per input")
        s = try PadIdentity.xboxBT16.spec(); s.sendLengths = [0x07: 16]
        XCTAssertThrowsError(try s.encoded(), "send length for a non-input report")
        s = try PadIdentity.xboxBT16.spec(); s.descriptor = []
        XCTAssertThrowsError(try s.encoded())
    }
}

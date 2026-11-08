import Foundation
import IOKit

/// Swift mirror of `Dext/GDHubVirtualHID/GDHubProtocol.h` (design §3.5, §5.3). Little-endian wire format.
/// `DextProtocolTests` parses the header text and compares every `#define` number with the constants below.
enum DextProtocol {
    static let version = 1
    static let userClientType: UInt32 = 0

    enum Selector {
        static let hello: UInt32 = 0
        static let createDevice: UInt32 = 1
        static let destroyDevice: UInt32 = 2
        static let postReport: UInt32 = 3
        static let postNeutral: UInt32 = 4
        static let heartbeat: UInt32 = 5
        static let registerOutput: UInt32 = 6
        static let getStatus: UInt32 = 7
        /// DEBUG-ONLY dev experiment (not in the design): the dext calls Terminate(0) on its root service.
        static let devTerminate: UInt32 = 8
        static let count: UInt32 = 9
    }

    enum Slot: UInt8 {
        case pad = 0, keyboard = 1, pointer = 2
        static let count = 3
    }

    /// `hello` output[2] bits, `1 << slot`.
    enum Capability {
        static let pad: UInt64 = 1
        static let keyboard: UInt64 = 2
        static let pointer: UInt64 = 4
    }

    enum Limit {
        static let maxDescriptor = 1024
        static let maxReport = 64
        static let maxInputReports = 4
        static let maxNeutral = 256
    }

    /// DeviceSpec blob layout (header 256 bytes, then descriptor, then neutral reports).
    enum Spec {
        static let magic: UInt32 = 0x5348_4447          // bytes 'G' 'D' 'H' 'S'
        static let headerSize = 256
        static let flagHIDDefaultBehavior: UInt8 = 1
    }

    enum Offset {
        static let magic = 0
        static let version = 4
        static let headerSize = 6
        static let slot = 8
        static let flags = 9
        static let inputCount = 10
        static let vendor = 12
        static let product = 16
        static let versionNumber = 20
        static let country = 24
        static let location = 28
        static let intervalUs = 32
        static let usagePage = 36
        static let usage = 40
        static let descLen = 44
        static let neutralLen = 46
        static let inputTable = 48          // 4 x { u8 reportID, u8 sendLength, u16 lengthInclID }
        static let transport = 64
        static let manufacturer = 96
        static let productName = 128
        static let serial = 192
    }

    enum Length {
        static let inputTableEntry = 4
        static let transport = 32
        static let manufacturer = 32
        static let productName = 64
        static let serial = 32
    }

    /// Async output notification: `outputArgCount` words, see `OutputReport.init(words:)`.
    static let outputArgCount = 10

    // IOReturn codes the protocol uses (IOKit's iokit_common_err values).
    static let krNotPermitted: kern_return_t = kern_return_t(bitPattern: 0xE000_02E2)
    static let krExclusiveAccess: kern_return_t = kern_return_t(bitPattern: 0xE000_02C5)
    static let krBadArgument: kern_return_t = kern_return_t(bitPattern: 0xE000_02C2)
    static let krBusy: kern_return_t = kern_return_t(bitPattern: 0xE000_02D5)
    static let krUnsupported: kern_return_t = kern_return_t(bitPattern: 0xE000_02C7)
    static let krNotReady: kern_return_t = kern_return_t(bitPattern: 0xE000_02D8)
}

/// Error codes the dext returns, as Swift cases.
enum DextError: Error, Equatable, CustomStringConvertible {
    case notPermitted           // 0xE00002E2: caller is not team 79XF6HYX8A
    case exclusiveAccess        // 0xE00002C5: another client owns the dext
    case badArgument            // 0xE00002C2
    case busy                   // 0xE00002D5
    case unsupported            // 0xE00002C7
    case notReady               // 0xE00002D8
    case other(kern_return_t)

    init(_ kr: kern_return_t) {
        switch kr {
        case DextProtocol.krNotPermitted: self = .notPermitted
        case DextProtocol.krExclusiveAccess: self = .exclusiveAccess
        case DextProtocol.krBadArgument: self = .badArgument
        case DextProtocol.krBusy: self = .busy
        case DextProtocol.krUnsupported: self = .unsupported
        case DextProtocol.krNotReady: self = .notReady
        default: self = .other(kr)
        }
    }

    var code: kern_return_t {
        switch self {
        case .notPermitted: return DextProtocol.krNotPermitted
        case .exclusiveAccess: return DextProtocol.krExclusiveAccess
        case .badArgument: return DextProtocol.krBadArgument
        case .busy: return DextProtocol.krBusy
        case .unsupported: return DextProtocol.krUnsupported
        case .notReady: return DextProtocol.krNotReady
        case .other(let kr): return kr
        }
    }

    var description: String {
        let hex = "0x" + String(UInt32(bitPattern: code), radix: 16, uppercase: true)
        switch self {
        case .notPermitted: return "not permitted (\(hex))"
        case .exclusiveAccess: return "already owned by another client (\(hex))"
        case .badArgument: return "bad argument (\(hex))"
        case .busy: return "busy (\(hex))"
        case .unsupported: return "unsupported (\(hex))"
        case .notReady: return "not ready (\(hex))"
        case .other: return "error \(hex)"
        }
    }
}

/// `getStatus` scalar outputs.
struct DextStatus: Equatable {
    var deviceMask: UInt64
    var postCount: UInt64
    var watchdogFires: UInt64
    var outputCount: UInt64
    var outputDrops: UInt64
    static let scalarCount = 5

    init(words: [UInt64]) {
        let w = words + [UInt64](repeating: 0, count: Self.scalarCount)
        deviceMask = w[0]; postCount = w[1]; watchdogFires = w[2]; outputCount = w[3]; outputDrops = w[4]
    }
}

/// `hello` scalar outputs.
struct DextHello: Equatable {
    var protocolVersion: UInt64
    var dextBuild: UInt64
    var capabilities: UInt64
    static let scalarCount = 3
}

/// One output report delivered through the `registerOutput` completion (design §3.8).
/// args[0] = slot | type<<8 | reportID<<16 | length<<24 | truncated<<40, args[1...8] = payload (8 bytes per word,
/// little-endian, max 64), args[9] = sequence.
struct OutputReport: Equatable {
    var slot: UInt8
    var type: UInt8
    var reportID: UInt8
    var truncated: Bool
    var bytes: [UInt8]
    var sequence: UInt64

    init?(words w: [UInt64]) {
        guard w.count >= DextProtocol.outputArgCount else { return nil }
        slot = UInt8(w[0] & 0xFF)
        type = UInt8((w[0] >> 8) & 0xFF)
        reportID = UInt8((w[0] >> 16) & 0xFF)
        let len = min(Int((w[0] >> 24) & 0xFFFF), DextProtocol.Limit.maxReport)
        truncated = (w[0] >> 40) & 1 != 0
        var out = [UInt8](); out.reserveCapacity(len)
        for i in 0..<len { out.append(UInt8((w[1 + i / 8] >> UInt64(8 * (i % 8))) & 0xFF)) }
        bytes = out
        sequence = w[9]
    }
}

// MARK: - DeviceSpec (design §5.3)

enum DeviceSpecError: Error, Equatable, CustomStringConvertible {
    case descriptorSize(Int)
    case inputReports(Int)
    case reportLength(id: UInt8, length: Int)
    case sendLengthNotInput(UInt8)
    case sendLengthOutOfRange(id: UInt8, send: Int)
    case reportIDZeroWithMultipleInputs
    case neutralCount(expected: Int, got: Int)
    case neutralLength(id: UInt8, expected: Int, got: Int)
    case neutralMissingID(UInt8)
    case neutralTotal(Int)
    case stringTooLong(field: String, max: Int)
    case emptyTransport

    var description: String {
        switch self {
        case .descriptorSize(let n): return "descriptor size \(n) not in 1...\(DextProtocol.Limit.maxDescriptor)"
        case .inputReports(let n): return "\(n) input reports (need 1...\(DextProtocol.Limit.maxInputReports))"
        case .reportLength(let id, let l): return "input report 0x\(String(id, radix: 16)) length \(l) not in 1...\(DextProtocol.Limit.maxReport)"
        case .sendLengthNotInput(let id): return "send length for 0x\(String(id, radix: 16)), which is not an input report"
        case .sendLengthOutOfRange(let id, let s): return "send length \(s) for 0x\(String(id, radix: 16)) outside its declared length...largest input"
        case .reportIDZeroWithMultipleInputs: return "report ID 0 with more than one input report"
        case .neutralCount(let e, let g): return "\(g) neutral reports, expected \(e)"
        case .neutralLength(let id, let e, let g): return "neutral report 0x\(String(id, radix: 16)) is \(g) bytes, expected its send length \(e)"
        case .neutralMissingID(let id): return "neutral report does not start with 0x\(String(id, radix: 16))"
        case .neutralTotal(let n): return "neutral blob \(n) bytes exceeds \(DextProtocol.Limit.maxNeutral)"
        case .stringTooLong(let f, let m): return "\(f) must be shorter than \(m) bytes"
        case .emptyTransport: return "Transport must not be empty"
        }
    }
}

/// Everything the dext needs to publish one HID device. `encoded()` produces the createDevice blob and enforces
/// the same rules as `GDHubSpecValidate` (design §3.6).
struct DeviceSpec: Equatable {
    var slot: DextProtocol.Slot
    var flags: UInt8 = 0
    var vendorID: UInt32, productID: UInt32, versionNumber: UInt32
    var countryCode: UInt32 = 0, locationID: UInt32 = 0, reportIntervalUs: UInt32 = 4000
    var primaryUsagePage: UInt32 = 1, primaryUsage: UInt32 = 5
    var transport: String, manufacturer: String, product: String, serialNumber: String
    var descriptor: [UInt8]
    /// reportID → padded send length; only `xbox-pr208` ([0x01: 25]).
    var sendLengths: [UInt8: Int] = [:]
    /// One per `HIDReportSizer` input report, same order, each at its send length.
    var neutralReports: [[UInt8]]

    func encoded() throws -> [UInt8] {
        typealias O = DextProtocol.Offset
        typealias L = DextProtocol.Length
        guard (1...DextProtocol.Limit.maxDescriptor).contains(descriptor.count) else {
            throw DeviceSpecError.descriptorSize(descriptor.count)
        }
        let inputs = try HIDReportSizer.inputs(descriptor)
        guard (1...DextProtocol.Limit.maxInputReports).contains(inputs.count) else {
            throw DeviceSpecError.inputReports(inputs.count)
        }
        for r in inputs where !(1...DextProtocol.Limit.maxReport).contains(r.length) {
            throw DeviceSpecError.reportLength(id: r.id, length: r.length)
        }
        if inputs.contains(where: { $0.id == 0 }) && inputs.count != 1 { throw DeviceSpecError.reportIDZeroWithMultipleInputs }
        let maxLen = inputs.map(\.length).max() ?? 0
        for (id, send) in sendLengths {
            guard let r = inputs.first(where: { $0.id == id }) else { throw DeviceSpecError.sendLengthNotInput(id) }
            guard send >= r.length, send <= maxLen, send <= 255 else { throw DeviceSpecError.sendLengthOutOfRange(id: id, send: send) }
        }
        func send(_ r: HIDReportSizer.ReportSize) -> Int { sendLengths[r.id] ?? r.length }
        guard neutralReports.count == inputs.count else {
            throw DeviceSpecError.neutralCount(expected: inputs.count, got: neutralReports.count)
        }
        var neutralBlob: [UInt8] = []
        for (r, n) in zip(inputs, neutralReports) {
            guard n.count == send(r) else { throw DeviceSpecError.neutralLength(id: r.id, expected: send(r), got: n.count) }
            if r.id != 0 && n.first != r.id { throw DeviceSpecError.neutralMissingID(r.id) }
            neutralBlob += n
        }
        guard neutralBlob.count <= DextProtocol.Limit.maxNeutral else { throw DeviceSpecError.neutralTotal(neutralBlob.count) }
        guard !transport.isEmpty else { throw DeviceSpecError.emptyTransport }

        var out = [UInt8](repeating: 0, count: DextProtocol.Spec.headerSize)
        func put32(_ off: Int, _ v: UInt32) { for i in 0..<4 { out[off + i] = UInt8((v >> UInt32(8 * i)) & 0xFF) } }
        func put16(_ off: Int, _ v: Int) { out[off] = UInt8(v & 0xFF); out[off + 1] = UInt8((v >> 8) & 0xFF) }
        func putString(_ off: Int, _ len: Int, _ s: String, _ field: String) throws {
            let u = Array(s.utf8)
            guard u.count < len else { throw DeviceSpecError.stringTooLong(field: field, max: len) }
            for (i, b) in u.enumerated() { out[off + i] = b }
        }
        put32(O.magic, DextProtocol.Spec.magic)
        put16(O.version, DextProtocol.version)
        put16(O.headerSize, DextProtocol.Spec.headerSize)
        out[O.slot] = slot.rawValue
        out[O.flags] = flags
        out[O.inputCount] = UInt8(inputs.count)
        put32(O.vendor, vendorID); put32(O.product, productID); put32(O.versionNumber, versionNumber)
        put32(O.country, countryCode); put32(O.location, locationID); put32(O.intervalUs, reportIntervalUs)
        put32(O.usagePage, primaryUsagePage); put32(O.usage, primaryUsage)
        put16(O.descLen, descriptor.count)
        put16(O.neutralLen, neutralBlob.count)
        for (i, r) in inputs.enumerated() {
            let base = O.inputTable + i * L.inputTableEntry
            out[base] = r.id
            out[base + 1] = UInt8(sendLengths[r.id] ?? 0)
            put16(base + 2, r.length)
        }
        try putString(O.transport, L.transport, transport, "Transport")
        try putString(O.manufacturer, L.manufacturer, manufacturer, "Manufacturer")
        try putString(O.productName, L.productName, product, "Product")
        try putString(O.serial, L.serial, serialNumber, "SerialNumber")
        return out + descriptor + neutralBlob
    }
}

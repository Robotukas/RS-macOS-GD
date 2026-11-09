import Foundation
import IOKit

/// Swift mirror of `Dext/GDHubVirtualHID/GDHubProtocol.h` (design §3.5, §5.3). Little-endian wire format.
/// `DextProtocolTests` parses the header text and compares every `#define` number with the constants below.
enum DextProtocol {
    static let version = 1
    /// Version of the DeviceSpec blob. Checked by the dext's spec validation instead of `version` (T3); both are 1.
    static let specVersion = 1
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
        /// T3, behind `Capability.rootPad`. Scalars in: state, flags, argMs. Scalars out: appliedState, tapPresent, padSource, lastError.
        static let setForwarding: UInt32 = 9
        /// 10 is reserved (set mapping, T5) and 12 too (create device 2, T7).
        static let getStatus2: UInt32 = 11
        static let count: UInt32 = 12
    }

    enum Slot: UInt8 {
        case pad = 0, keyboard = 1, pointer = 2
        static let count = 3
    }

    /// `hello` output[2] bits. Bits 0-2 are `1 << slot`; higher bits are features, only ever added (the additive rule in
    /// GDHubProtocol.h). A dext that does not set a bit does not have the selectors behind it: the app must not call them.
    enum Capability {
        static let pad: UInt64 = 1
        static let keyboard: UInt64 = 2
        static let pointer: UInt64 = 4
        /// T3: the root service owns the pad; selectors `setForwarding` (9) and `getStatus2` (11) exist.
        static let rootPad: UInt64 = 1 << 8
    }

    /// Forwarding state of `setForwarding`. T3 knows INERT only.
    enum Forwarding {
        static let inert: UInt64 = 0
    }

    /// Who may post to the pad (`padSource` in status2 and in `setForwarding`'s output).
    enum PadSource: UInt8 {
        case none = 0, userClient = 1, tap = 2
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

    /// Where the app's `DextClient` finds the dext's root service: a service of class IOUserService that has both of these
    /// properties. `IOUserServerName` alone is not enough from T4 on, when a second service of the same dext (the receiver
    /// tap) carries the same server name.
    static let rootUserClass = "GDHubVirtualHID"

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

// MARK: - GDHubStatus2 (T3 subset)

/// Summary of one dext histogram over its last completed 10 s window, in nanoseconds (bucket upper edges, clamped to the max).
struct DextMeterSummary: Equatable {
    var count: UInt32 = 0, p50Ns: UInt32 = 0, p99Ns: UInt32 = 0, maxNs: UInt32 = 0, meanNs: UInt32 = 0

    /// "p50/p99/max/mean" in microseconds: the percentiles and the maximum in whole microseconds (rounded to nearest; the
    /// dext's smallest bucket edge is 1 us), the mean exact to a tenth, truncated.
    var microsecondsText: String {
        func us(_ ns: UInt32) -> Int { Int((Double(ns) / 1000).rounded()) }
        return "\(us(p50Ns))/\(us(p99Ns))/\(us(maxNs))/\(meanNs / 1000).\((meanNs % 1000) / 100)"
    }
}

/// `getStatus2` (selector 11), mirror of GDHUB_ST2_* in GDHubProtocol.h. Decoded by offset; a buffer shorter than the
/// dext wrote, or longer than this app knows, both decode: fields beyond min(declared size, bytes received) read as 0.
struct DextStatus2: Equatable {
    enum Offset {
        static let version = 0, size = 2, build = 4, nonce = 8, rootPid = 16
        static let desiredState = 20, padSource = 21, padLive = 22, ownerPresent = 23
        static let ucPosts = 24, ucRejected = 32, neutralPosts = 40, postErrors = 48, syncViolations = 56
        static let padCreates = 64, padDestroys = 72, createFails = 80, outputsSeen = 88, outputsNoOwner = 96, createEarly = 104
        static let padSpecCRC = 112, meterWindows = 116
        static let hopCount = 120, hopP50 = 124, hopP99 = 128, hopMax = 132, hopMean = 136
        static let hrCount = 140, hrP50 = 144, hrP99 = 148, hrMax = 152, hrMean = 156
    }
    static let version = 1
    static let size = 160
    static let maxSize = 512
    /// version, size and build: the least a reader needs.
    static let minimumBytes = 8

    var version: UInt16 = 0
    var declaredSize: UInt16 = 0
    var build: UInt32 = 0
    var instanceNonce: UInt64 = 0
    var rootPid: UInt32 = 0
    var desiredState: UInt8 = 0
    var padSource: UInt8 = 0
    var padLive = false
    var ownerPresent = false
    var ucPosts: UInt64 = 0, ucRejected: UInt64 = 0, neutralPosts: UInt64 = 0, postErrors: UInt64 = 0
    var syncViolations: UInt64 = 0, padCreates: UInt64 = 0, padDestroys: UInt64 = 0, createFails: UInt64 = 0
    var outputsSeen: UInt64 = 0, outputsNoOwner: UInt64 = 0, createEarly: UInt64 = 0
    var padSpecCRC: UInt32 = 0
    var meterWindows: UInt32 = 0
    var hop = DextMeterSummary()
    var hr = DextMeterSummary()

    var source: DextProtocol.PadSource? { DextProtocol.PadSource(rawValue: padSource) }

    /// nil if fewer than `minimumBytes` arrived or the structure claims a size or version this reader cannot use.
    static func decode(_ bytes: [UInt8]) -> DextStatus2? {
        guard bytes.count >= minimumBytes else { return nil }
        func le(_ off: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<n { v |= UInt64(bytes[off + i]) << UInt64(8 * i) }
            return v
        }
        let ver = UInt16(le(Offset.version, 2)), declared = UInt16(le(Offset.size, 2))
        guard ver >= 1, Int(declared) >= minimumBytes else { return nil }
        let valid = min(Int(declared), bytes.count)
        func u(_ off: Int, _ n: Int) -> UInt64 { off + n <= valid ? le(off, n) : 0 }
        var s = DextStatus2()
        s.version = ver; s.declaredSize = declared
        s.build = UInt32(u(Offset.build, 4)); s.instanceNonce = u(Offset.nonce, 8); s.rootPid = UInt32(u(Offset.rootPid, 4))
        s.desiredState = UInt8(u(Offset.desiredState, 1)); s.padSource = UInt8(u(Offset.padSource, 1))
        s.padLive = u(Offset.padLive, 1) != 0; s.ownerPresent = u(Offset.ownerPresent, 1) != 0
        s.ucPosts = u(Offset.ucPosts, 8); s.ucRejected = u(Offset.ucRejected, 8); s.neutralPosts = u(Offset.neutralPosts, 8)
        s.postErrors = u(Offset.postErrors, 8); s.syncViolations = u(Offset.syncViolations, 8)
        s.padCreates = u(Offset.padCreates, 8); s.padDestroys = u(Offset.padDestroys, 8); s.createFails = u(Offset.createFails, 8)
        s.outputsSeen = u(Offset.outputsSeen, 8); s.outputsNoOwner = u(Offset.outputsNoOwner, 8); s.createEarly = u(Offset.createEarly, 8)
        s.padSpecCRC = UInt32(u(Offset.padSpecCRC, 4)); s.meterWindows = UInt32(u(Offset.meterWindows, 4))
        s.hop = DextMeterSummary(count: UInt32(u(Offset.hopCount, 4)), p50Ns: UInt32(u(Offset.hopP50, 4)),
                                 p99Ns: UInt32(u(Offset.hopP99, 4)), maxNs: UInt32(u(Offset.hopMax, 4)),
                                 meanNs: UInt32(u(Offset.hopMean, 4)))
        s.hr = DextMeterSummary(count: UInt32(u(Offset.hrCount, 4)), p50Ns: UInt32(u(Offset.hrP50, 4)),
                                p99Ns: UInt32(u(Offset.hrP99, 4)), maxNs: UInt32(u(Offset.hrMax, 4)),
                                meanNs: UInt32(u(Offset.hrMean, 4)))
        return s
    }

    /// The part of the engine's meter line that comes from the dext; nil until the dext has closed a 10 s window with posts.
    var meterLogText: String? {
        guard hr.count > 0 else { return nil }
        return "dext: hop p50/p99/max/mean \(hop.microsecondsText) us hr \(hr.microsecondsText) us n=\(hr.count) win=\(meterWindows)"
            + (syncViolations > 0 ? " syncViolations=\(syncViolations)" : "")
    }
}

/// Outputs of `setForwarding`.
struct DextForwardingResult: Equatable {
    var appliedState: UInt64 = 0, tapPresent: UInt64 = 0, padSource: UInt64 = 0, lastError: UInt64 = 0
    static let scalarCount = 4
    init(words: [UInt64]) {
        let w = words + [UInt64](repeating: 0, count: Self.scalarCount)
        appliedState = w[0]; tapPresent = w[1]; padSource = w[2]; lastError = w[3]
    }
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

    var hasRootPad: Bool { capabilities & DextProtocol.Capability.rootPad != 0 }
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
        put16(O.version, DextProtocol.specVersion)
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

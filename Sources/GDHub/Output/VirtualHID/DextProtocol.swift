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
        static let count: UInt32 = 8
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

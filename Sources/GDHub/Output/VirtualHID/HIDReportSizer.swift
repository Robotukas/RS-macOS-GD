import Foundation

/// Minimal HID report descriptor parser: report IDs and byte lengths per report type (design §5.3).
/// Feeds the DeviceSpec input table and the tests.
enum HIDReportSizer {
    struct ReportSize: Equatable {
        var id: UInt8
        /// Bytes on the wire, including the report-ID byte when `id != 0`.
        var length: Int
        init(_ id: UInt8, _ length: Int) { self.id = id; self.length = length }
    }

    struct Result: Equatable {
        var inputs: [ReportSize] = []
        var outputs: [ReportSize] = []
        var features: [ReportSize] = []
    }

    enum SizerError: Error, Equatable {
        case truncated
        case notByteAligned(type: String, id: UInt8, bits: Int)
    }

    /// Handles short items: Report Size (0x74), Report Count (0x94), Report ID (0x84), Push/Pop (0xA4/0xB4) and
    /// Input/Output/Feature (0x80/0x90/0xB0); long items (0xFE) are skipped. Bit totals are summed per (type, id) in
    /// first-seen order. Throws if a report's bit total is not a multiple of 8.
    static func parse(_ d: [UInt8]) throws -> Result {
        struct Globals { var size = 0, count = 0, id: UInt8 = 0 }
        var g = Globals()
        var stack: [Globals] = []
        // (type 0 input, 1 output, 2 feature) -> ordered ids with bit totals
        var order: [[UInt8]] = [[], [], []]
        var bits: [[UInt8: Int]] = [[:], [:], [:]]

        var i = 0
        while i < d.count {
            let prefix = d[i]
            if prefix == 0xFE {                       // long item: 0xFE, bDataSize, bLongItemTag, data...
                guard i + 1 < d.count else { throw SizerError.truncated }
                i += 3 + Int(d[i + 1])
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let dataLen = sizeCode == 3 ? 4 : sizeCode
            guard i + 1 + dataLen <= d.count else { throw SizerError.truncated }
            var value = 0
            for b in 0..<dataLen { value |= Int(d[i + 1 + b]) << (8 * b) }
            switch prefix & 0xFC {
            case 0x74: g.size = value
            case 0x94: g.count = value
            case 0x84: g.id = UInt8(truncatingIfNeeded: value)
            case 0xA4: stack.append(g)
            case 0xB4: if let top = stack.popLast() { g = top }
            case 0x80, 0x90, 0xB0:
                let t = (prefix & 0xFC) == 0x80 ? 0 : ((prefix & 0xFC) == 0x90 ? 1 : 2)
                if bits[t][g.id] == nil { order[t].append(g.id); bits[t][g.id] = 0 }
                bits[t][g.id]! += g.size * g.count
            default: break
            }
            i += 1 + dataLen
        }

        func sizes(_ t: Int, _ name: String) throws -> [ReportSize] {
            try order[t].map { id in
                let total = bits[t][id] ?? 0
                guard total % 8 == 0 else { throw SizerError.notByteAligned(type: name, id: id, bits: total) }
                return ReportSize(id, total / 8 + (id != 0 ? 1 : 0))
            }
        }
        return Result(inputs: try sizes(0, "input"), outputs: try sizes(1, "output"), features: try sizes(2, "feature"))
    }

    static func inputs(_ d: [UInt8]) throws -> [ReportSize] { try parse(d).inputs }
}

extension Array where Element == UInt8 {
    /// Parses hex text such as "05 01 09 05" (whitespace ignored). Crashes on malformed input: descriptors are literals.
    init(hex: String) {
        let cleaned = hex.filter { $0.isHexDigit }
        precondition(cleaned.count % 2 == 0, "odd number of hex digits")
        var out: [UInt8] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            out.append(UInt8(cleaned[idx..<next], radix: 16)!)
            idx = next
        }
        self = out
    }
}

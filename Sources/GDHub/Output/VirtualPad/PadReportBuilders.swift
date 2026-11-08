import Foundation

/// One input report: its ID and the bytes to post (ID byte first when the descriptor uses IDs).
struct PadReport: Equatable {
    var id: UInt8
    var bytes: [UInt8]
}

/// Pure builders from `PadState` to input reports (design §4.3). D3 has the compact 16-byte Xbox report only.
enum PadReportBuilders {
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    /// Stick axis → u16, centre 0x8000: `u16(v) = ((clamp(v, -1, 1) + 1) * 32767.5)` rounded half away from zero.
    static func axis16(_ v: Double) -> UInt16 {
        UInt16(((clamp(v, -1, 1) + 1) * 32767.5).rounded(.toNearestOrAwayFromZero))
    }

    /// Trigger 0...1 → 10 bits.
    static func trigger10(_ t: Double) -> UInt16 {
        UInt16((clamp(t, 0, 1) * 1023).rounded(.toNearestOrAwayFromZero))
    }

    /// 0 none, 1 N, 2 NE, 3 E, 4 SE, 5 S, 6 SW, 7 W, 8 NW; opposite directions cancel.
    static func hat(_ b: PadButtons) -> UInt8 {
        var dx = 0, dy = 0
        if b.contains(.dpadRight) { dx += 1 }
        if b.contains(.dpadLeft) { dx -= 1 }
        if b.contains(.dpadUp) { dy += 1 }
        if b.contains(.dpadDown) { dy -= 1 }
        switch (dx, dy) {
        case (0, 1): return 1
        case (1, 1): return 2
        case (1, 0): return 3
        case (1, -1): return 4
        case (0, -1): return 5
        case (-1, -1): return 6
        case (-1, 0): return 7
        case (-1, 1): return 8
        default: return 0
        }
    }

    /// `xbox-bt16` / `xbox-bt16-02e0`: report 0x01 (16 B) and report 0x02 (2 B, Guide).
    static func xboxBT16(_ s: PadState) -> [PadReport] {
        var r = [UInt8](repeating: 0, count: 16)
        r[0] = 0x01
        func put(_ at: Int, _ v: UInt16) { r[at] = UInt8(v & 0xFF); r[at + 1] = UInt8(v >> 8) }
        put(1, axis16(s.lx)); put(3, axis16(-s.ly))
        put(5, axis16(s.rx)); put(7, axis16(-s.ry))
        put(9, trigger10(s.lt)); put(11, trigger10(s.rt))
        r[13] = hat(s.buttons)
        let b = s.buttons
        var b14: UInt8 = 0
        if b.contains(.a) { b14 |= 0x01 }
        if b.contains(.b) { b14 |= 0x02 }
        if b.contains(.x) { b14 |= 0x04 }
        if b.contains(.y) { b14 |= 0x08 }
        if b.contains(.lb) { b14 |= 0x10 }
        if b.contains(.rb) { b14 |= 0x20 }
        if b.contains(.view) { b14 |= 0x40 }
        if b.contains(.menu) { b14 |= 0x80 }
        r[14] = b14
        var b15: UInt8 = 0
        if b.contains(.ls) { b15 |= 0x01 }
        if b.contains(.rs) { b15 |= 0x02 }
        r[15] = b15
        return [PadReport(id: 0x01, bytes: r), PadReport(id: 0x02, bytes: [0x02, b.contains(.guide) ? 0x01 : 0x00])]
    }
}

import Foundation
#if canImport(GDHubXlate)
import GDHubXlate       // SwiftPM: the C target. The Xcode app target gets the same symbols from the bridging header.
#endif

/// Which frame-to-report translator the engine runs. `defaults write com.interlinked.gdhub xlateCore -string swift`
/// selects the original Swift mapper and builder; anything else (including no value) is the shared C core.
enum XlateCoreChoice: String, Equatable {
    case c
    case swift
}

/// `gdx_validate` refused a GDHM blob.
struct XlateError: Error, Equatable, CustomStringConvertible {
    let code: Int32
    var description: String { "GDHM rejected: \(String(cString: gdx_reason(code))) (\(code))" }
}

/// Thin wrapper over `GDHubXlate` (Shared/GDHubXlate.c): owns one validated `gdx_map` and calls the C functions.
///
/// Thread confinement: the map is written once, in `init`, and only read afterwards, so any number of queues may use
/// the same instance for `eval`/`unchanged`/`build`. A `gdx_state` (`step`) belongs to exactly one owner at a time; the
/// engine's sink does not use one (it keeps its own rate-cap and hysteresis state), the tests and, from T5, the
/// driver do.
final class XlateCore {
    private let mapPtr: UnsafeMutablePointer<gdx_map>

    /// Validates `blob` against `spec` (the encoded DeviceSpec of the pad it targets).
    init(blob: [UInt8], spec: [UInt8]) throws {
        mapPtr = UnsafeMutablePointer<gdx_map>.allocate(capacity: 1)
        mapPtr.initialize(to: gdx_map())
        let rc = blob.withUnsafeBufferPointer { b in
            spec.withUnsafeBufferPointer { s in
                gdx_validate(b.baseAddress, b.count, s.baseAddress, s.count, mapPtr)
            }
        }
        // A throw after every stored property is set still runs `deinit`, which frees the map: deallocating here as well would
        // free it twice (the abort the local blob check hit the first time a blob was rejected).
        if rc != 0 { throw XlateError(code: rc) }
    }

    deinit { mapPtr.deallocate() }

    var revision: UInt32 { mapPtr.pointee.revision }
    var silenceNeutralMs: UInt16 { mapPtr.pointee.silenceNeutralMs }
    var map: gdx_map { mapPtr.pointee }

    // MARK: Per-frame calls

    /// Parse + map + snap of a raw report 0x06 (16 bytes with the ID byte). Nil for a frame the Swift parser rejects too.
    func eval(raw: UnsafeBufferPointer<UInt8>) -> gdx_pad? {
        var p = gdx_pad()
        return gdx_eval(mapPtr, raw.baseAddress, raw.count, &p) == 0 ? p : nil
    }

    func eval(raw: [UInt8]) -> gdx_pad? {
        raw.withUnsafeBufferPointer { eval(raw: $0) }
    }

    /// The engine hands the sink a parsed `GamepadFrame`; it is turned back into the 16 report bytes on the stack
    /// (lossless: every bit of report 0x06 lives in a `GamepadFrame` field) and evaluated by the C core.
    func eval(_ frame: GamepadFrame) -> gdx_pad {
        frame.withRawReport { raw in
            var p = gdx_pad()
            let rc = gdx_eval(mapPtr, raw.baseAddress, raw.count, &p)
            precondition(rc == 0, "a GamepadFrame always serialises to a valid report 0x06")
            return p
        }
    }

    func unchanged(_ now: gdx_pad, _ last: gdx_pad) -> Bool {
        var a = now, b = last
        return gdx_unchanged(mapPtr, &a, &b) != 0
    }

    func build(_ pad: gdx_pad) -> gdx_out {
        var p = pad
        var o = gdx_out()
        gdx_build(mapPtr, &p, &o)
        return o
    }

    /// The reports of `pad` as the sink posts them, in the map's report order.
    func reports(_ pad: gdx_pad) -> [PadReport] {
        XlateCore.reports(build(pad))
    }

    static func reports(_ out: gdx_out) -> [PadReport] {
        var o = out
        let count = Int(o.count)
        return withUnsafeBytes(of: &o) { raw in
            let base = MemoryLayout<gdx_out>.offset(of: \gdx_out.r)!
            let stride = MemoryLayout<gdx_report>.stride
            return (0..<count).map { i in
                let at = base + i * stride
                let len = Int(raw[at + 1])
                return PadReport(id: raw[at], bytes: Array(raw[(at + 2)..<(at + 2 + len)]))
            }
        }
    }

    /// One uncapped step (tests, the future driver). Returns the mask of reports to post and fills `out`.
    func step(_ state: inout gdx_state, raw: UnsafeBufferPointer<UInt8>, out: inout gdx_out) -> UInt32 {
        gdx_step(&state, mapPtr, raw.baseAddress, raw.count, &out)
    }

    // MARK: PadState <-> gdx_pad (exact)

    /// `gdx_pad.buttons` numbers its bits by output item (A…Guide 0…10, D-pad up/right/down/left 11…14, Share 15);
    /// `PadButtons` keeps Share at 11 and the D-pad at 12…15 as up/down/left/right.
    static func itemBits(_ b: PadButtons) -> UInt32 {
        var r = UInt32(b.rawValue) & 0x7FF
        if b.contains(.dpadUp) { r |= 1 << 11 }
        if b.contains(.dpadRight) { r |= 1 << 12 }
        if b.contains(.dpadDown) { r |= 1 << 13 }
        if b.contains(.dpadLeft) { r |= 1 << 14 }
        if b.contains(.share) { r |= 1 << 15 }
        return r
    }

    static func padButtons(_ bits: UInt32) -> PadButtons {
        var b = PadButtons(rawValue: UInt16(bits & 0x7FF))
        if bits & (1 << 11) != 0 { b.insert(.dpadUp) }
        if bits & (1 << 12) != 0 { b.insert(.dpadRight) }
        if bits & (1 << 13) != 0 { b.insert(.dpadDown) }
        if bits & (1 << 14) != 0 { b.insert(.dpadLeft) }
        if bits & (1 << 15) != 0 { b.insert(.share) }
        return b
    }

    static func pad(from s: PadState) -> gdx_pad {
        var p = gdx_pad()
        p.buttons = itemBits(s.buttons)
        p.v.0 = s.lx; p.v.1 = s.ly; p.v.2 = s.rx; p.v.3 = s.ry; p.v.4 = s.lt; p.v.5 = s.rt
        return p
    }

    static func state(from p: gdx_pad) -> PadState {
        PadState(buttons: padButtons(p.buttons), lx: p.v.0, ly: p.v.1, rx: p.v.2, ry: p.v.3, lt: p.v.4, rt: p.v.5)
    }
}

extension GamepadFrame {
    /// The 16 bytes of report 0x06 this frame was parsed from (see docs/protocol/envision-pro-receiver.md), in stack
    /// storage that lives for the duration of `body`.
    @inline(__always)
    func withRawReport<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { buf in
            let x = UInt16(bitPattern: self.x), y = UInt16(bitPattern: self.y)
            let z = UInt16(bitPattern: self.z), rz = UInt16(bitPattern: self.rz)
            let t = UInt32(lt & 0x3ff) | UInt32(rt & 0x3ff) << 10 | UInt32(hat & 0xf) << 20
            let btn = (buttons & 0x7ffff) | UInt32(extra & 0x1fff) << 19
            buf[0] = 6
            buf[1] = UInt8(x & 0xff); buf[2] = UInt8(x >> 8)
            buf[3] = UInt8(y & 0xff); buf[4] = UInt8(y >> 8)
            buf[5] = UInt8(z & 0xff); buf[6] = UInt8(z >> 8)
            buf[7] = UInt8(rz & 0xff); buf[8] = UInt8(rz >> 8)
            buf[9] = UInt8(t & 0xff); buf[10] = UInt8((t >> 8) & 0xff); buf[11] = UInt8((t >> 16) & 0xff)
            buf[12] = UInt8(btn & 0xff); buf[13] = UInt8((btn >> 8) & 0xff)
            buf[14] = UInt8((btn >> 16) & 0xff); buf[15] = UInt8((btn >> 24) & 0xff)
            return body(UnsafeBufferPointer(buf))
        }
    }

    var rawReport: [UInt8] { withRawReport { Array($0) } }
}

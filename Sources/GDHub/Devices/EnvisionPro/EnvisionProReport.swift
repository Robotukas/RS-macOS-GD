import Foundation

/// One decoded input report 0x06 from the Envision Pro receiver.
/// Byte layout: docs/protocol/envision-pro-receiver.md
struct GamepadFrame: Equatable {
    var x: Int16 = 0
    var y: Int16 = 0
    var z: Int16 = 0
    var rz: Int16 = 0
    /// 0...1023
    var lt: UInt16 = 0
    /// 0...1023
    var rt: UInt16 = 0
    /// 0 = N, 1 = NE ... 7 = NW, 8 = centred
    var hat: UInt8 = 8
    /// 19 bits, bit 0 = button 1
    var buttons: UInt32 = 0
    /// 13 "vendor padding" bits that carry physical identity of some inputs
    var extra: UInt16 = 0

    static let idle = GamepadFrame()

    static let axisNames = ["x", "y", "z", "rz"]
    static let triggerNames = ["lt", "rt"]

    static func parse(_ bytes: [UInt8]) -> GamepadFrame? {
        bytes.withUnsafeBufferPointer { parse($0) }
    }

    /// Parses straight from the IOKit report buffer: no copy, and nothing is kept after it returns.
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> GamepadFrame? {
        guard bytes.count == 16, bytes[0] == 6 else { return nil }
        func s16(_ lo: UInt8, _ hi: UInt8) -> Int16 {
            Int16(bitPattern: UInt16(lo) | UInt16(hi) << 8)
        }
        var f = GamepadFrame()
        f.x = s16(bytes[1], bytes[2])
        f.y = s16(bytes[3], bytes[4])
        f.z = s16(bytes[5], bytes[6])
        f.rz = s16(bytes[7], bytes[8])
        let t = UInt32(bytes[9]) | UInt32(bytes[10]) << 8 | UInt32(bytes[11]) << 16
        f.lt = UInt16(t & 0x3ff)
        f.rt = UInt16((t >> 10) & 0x3ff)
        f.hat = UInt8((t >> 20) & 0xf)
        let btn = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        f.buttons = btn & 0x7ffff
        f.extra = UInt16(btn >> 19)
        return f
    }

    /// Value of a named int16 axis ("x", "y", "z", "rz").
    func axis(_ name: String) -> Int? {
        switch name {
        case "x": return Int(x)
        case "y": return Int(y)
        case "z": return Int(z)
        case "rz": return Int(rz)
        default: return nil
        }
    }

    /// Value of a named trigger ("lt", "rt"), 0...1023.
    func trigger(_ name: String) -> Int? {
        switch name {
        case "lt": return Int(lt)
        case "rt": return Int(rt)
        default: return nil
        }
    }

    func isButtonDown(_ n: Int) -> Bool {
        n >= 1 && n <= 19 && (buttons >> UInt32(n - 1)) & 1 == 1
    }

    /// Events describing what changed from `previous` to `self`.
    func diff(from previous: GamepadFrame) -> [InputEvent] {
        if self == previous { return [] }       // ≈1 kHz of identical reports at rest: no work, no allocation
        var events: [InputEvent] = []
        let changed = buttons ^ previous.buttons
        if changed != 0 {
            for bit in 0..<19 where (changed >> UInt32(bit)) & 1 == 1 {
                if (buttons >> UInt32(bit)) & 1 == 1 {
                    events.append(.buttonDown(bit + 1))
                } else {
                    events.append(.buttonUp(bit + 1))
                }
            }
        }
        if hat != previous.hat { events.append(.hat(hat)) }
        if extra != previous.extra { events.append(.extraBits(extra)) }
        for name in GamepadFrame.axisNames {
            guard let new = axis(name), let old = previous.axis(name) else { continue }
            if abs(new - old) > 2000 { events.append(.axis(name: name, value: new)) }
        }
        for name in GamepadFrame.triggerNames {
            guard let new = trigger(name), let old = previous.trigger(name) else { continue }
            if new - old > 40 { events.append(.trigger(name: name, value: new)) }
        }
        return events
    }
}

enum InputEvent: Equatable {
    case buttonDown(Int)
    case buttonUp(Int)
    case hat(UInt8)
    case extraBits(UInt16)
    case axis(name: String, value: Int)
    case trigger(name: String, value: Int)

    static let hatNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    var text: String {
        switch self {
        case .buttonDown(let n): return "button \(n) down"
        case .buttonUp(let n): return "button \(n) up"
        case .hat(let h):
            let name = Int(h) < InputEvent.hatNames.count ? InputEvent.hatNames[Int(h)] : "centre"
            return "hat \(h) (\(name))"
        case .extraBits(let e):
            let bits = (0..<13).filter { (e >> UInt16($0)) & 1 == 1 }.map { "\($0)" }.joined(separator: ",")
            return "extra bits \(String(e, radix: 2).leftPadded(to: 13)) [\(bits.isEmpty ? "-" : bits)]"
        case .axis(let name, let value): return "axis \(name) \(value)"
        case .trigger(let name, let value): return "trigger \(name) \(value)"
        }
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}

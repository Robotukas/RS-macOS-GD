import XCTest
import GDHubXlate
@testable import GDHub

/// Deterministic generator (SplitMix64). Never `random()`, never the system generator.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { Int(truncatingIfNeeded: Int64(r.lowerBound) &+ Int64(next() % UInt64(r.upperBound - r.lowerBound + 1))) }
    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }
}

/// Collects mismatches so a million-frame test reports the first few instead of a million assertions.
final class MismatchLog {
    private(set) var count = 0
    private(set) var first: [String] = []
    func note(_ describe: @autoclosure () -> String) {
        count += 1
        if first.count < 6 { first.append(describe()) }
    }
    func assertNone(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(count, 0, "\(what): \(count) mismatches. First: \(first.joined(separator: " | "))", file: file, line: line)
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

enum XlateFixtures {
    /// The encoded spec of the default pad identity (without the cosmetic product override).
    static let spec: [UInt8] = try! PadIdentity.default.spec(productOverride: nil).encoded()
    static let identity = PadIdentity.default

    /// Factory layout plus the full-int16 learned ranges the owner's live file carries (generic values, nothing copied).
    static var liveShaped: ControlMapping {
        var m = ControlMapping.default
        let full = AxisRange(min: -32768, max: 32767)
        m.sticks["left_stick"]?.ranges = ["x": full, "y": full]
        m.sticks["right_stick"]?.ranges = ["z": full, "rz": full]
        return m
    }

    static func core(_ m: ControlMapping, revision: UInt32 = 1, identity: PadIdentity = XlateFixtures.identity) throws -> XlateCore {
        switch MapBlobEncoder.encode(m, identity: identity, spec: spec, revision: revision) {
        case .blob(let blob): return try XlateCore(blob: blob, spec: spec)
        case .unsupported(let why): throw XCTSkip("mapping unsupported: \(why)")
        }
    }

    /// Re-computes the blob checksum after a test edited bytes.
    static func reseal(_ blob: [UInt8]) -> [UInt8] {
        var b = blob
        guard b.count >= 32 else { return b }
        for i in 28..<32 { b[i] = 0 }
        let c = b.withUnsafeBufferPointer { gdx_crc32($0.baseAddress, $0.count) }
        for i in 0..<4 { b[28 + i] = UInt8((c >> UInt32(8 * i)) & 0xff) }
        return b
    }

    static func validate(_ blob: [UInt8], spec: [UInt8] = XlateFixtures.spec) -> Int32 {
        var out = gdx_map()
        return blob.withUnsafeBufferPointer { b in spec.withUnsafeBufferPointer { s in
            gdx_validate(b.baseAddress, b.count, s.baseAddress, s.count, &out) } }
    }

    // MARK: Random learned mappings (always expressible in GDHM v1)

    static func randomMapping(_ rng: inout SplitMix64) -> ControlMapping {
        var m = ControlMapping.default
        let items = MapBlobEncoder.buttonControls
        func binding() -> Binding? {
            switch rng.int(0...9) {
            case 0: return nil
            case 1, 2, 3, 4: return .button(rng.int(0...21))                  // 0, 20, 21: out of range, never active
            case 5, 6: return .hat(UInt8(rng.int(0...10)))
            case 7: return .trigger(rng.pick(["lt", "rt", "lt", "rt", "zz"]))
            default: return .axis(rng.pick(["x", "y", "z", "rz", "w"]), sign: rng.pick([1, -1, 1, -1, 2, -3, 0, 127, -128]))
            }
        }
        for cid in items {
            if let b = binding() { m.buttons[cid] = b } else { m.buttons[cid] = nil }
            if rng.chance(25) {
                var mask = UInt16(1) << UInt16(rng.int(0...12))
                if rng.chance(50) { mask |= UInt16(1) << UInt16(rng.int(0...12)) }
                if rng.chance(5) { mask = 0x8000 | mask }                       // a bit `extra` can never have
                m.physicalBits[cid] = mask
            } else if rng.chance(10) {
                m.physicalBits[cid] = 0
            }
        }
        for cid in ["lt", "rt"] {
            switch rng.int(0...5) {
            case 0: m.buttons[cid] = .trigger(cid == "lt" ? "rt" : "lt")       // swapped
            case 1: m.buttons[cid] = nil
            case 2: m.buttons[cid] = .button(rng.int(1...19))
            default: m.buttons[cid] = .trigger(cid)
            }
        }
        for sid in ["left_stick", "right_stick"] {
            func component() -> Binding? {
                switch rng.int(0...7) {
                case 0: return nil
                case 1: return .button(3)
                default: return .axis(rng.pick(["x", "y", "z", "rz", "q"]), sign: rng.pick([1, -1, 1, -1, 2, -3, 0, 100]))
                }
            }
            var s = StickBinding(horizontal: component(), vertical: component(), ranges: nil)
            if rng.chance(70) {
                var r: [String: AxisRange] = [:]
                for f in ["x", "y", "z", "rz"] where rng.chance(60) {
                    switch rng.int(0...5) {
                    case 0: r[f] = AxisRange(min: -32768, max: 32767)
                    case 1: r[f] = AxisRange(min: rng.int(-32768...(-1)), max: rng.int(1...32767))
                    case 2: r[f] = AxisRange(min: 0, max: 0)                    // degenerate: both clamp to 1
                    case 3: r[f] = AxisRange(min: 100, max: -100)               // inverted: clamp to 1
                    case 4: r[f] = AxisRange(min: -1, max: 1)
                    default: r[f] = AxisRange(min: rng.int(-70000...70000), max: rng.int(-70000...70000))
                    }
                }
                s.ranges = r
            }
            m.sticks[sid] = s
        }
        if rng.chance(20) { m.sticks["a"] = m.sticks["left_stick"]; m.buttons["a"] = nil }          // STICK_MAG
        if rng.chance(20) { m.sticks["y"] = m.sticks["right_stick"]; m.buttons["y"] = nil }
        if rng.chance(10) { m.sticks["x"] = StickBinding(horizontal: nil, vertical: nil, ranges: nil); m.buttons["x"] = nil }
        return m
    }

    // MARK: Random remaps (outputs)

    /// The 23 remappable controls of remap step 1, in the order `ControlMapping.remappableIDs` had then. `randomOutputs`
    /// draws from this list, not from the live one, so a seed keeps giving the same mapping when the model grows more
    /// remappable controls (remap step 2 appends six). The S1 pins (`GDHMv1PinTests`) depend on it.
    static let frozenRemappableIDs: [String] = [
        "a", "b", "x", "y", "lb", "rb", "lt", "rt", "view", "menu", "l3", "r3",
        "dpad_up", "dpad_right", "dpad_down", "dpad_left", "start", "profile", "g1", "g2", "g3", "g4", "g5",
    ]

    /// `m` plus stray learned bits on the two analog triggers, as an old learn can leave them: lt mostly 1 and rt mostly
    /// 0x20 (the paddle outer right and SAX right table bits), sometimes another bit or both bits. Drawn from its own
    /// generator, so no existing seeded mapping changes. A trigger's bits matter only while it is a source of a remapped
    /// button; the encoder and the Swift mapper both read them then.
    static func withStrayTriggerBits(_ m: ControlMapping, _ seed: UInt64) -> ControlMapping {
        var rng = SplitMix64(seed: seed)
        var out = m
        for (id, usual) in [("lt", UInt16(1)), ("rt", UInt16(0x20))] where rng.chance(70) {
            switch rng.int(0...9) {
            case 0: out.physicalBits[id] = UInt16(1) << UInt16(rng.int(0...12))
            case 1: out.physicalBits[id] = usual | (UInt16(1) << UInt16(rng.int(0...12)))
            default: out.physicalBits[id] = usual
            }
        }
        return out
    }

    /// `m` plus a few random remaps, drawn from ITS OWN generator (`seed`), never from the stream `randomMapping` uses, so
    /// the existing seeded mappings stay what they were. With `expressibleOnly` (the default) a pick that GDHM v1 could not
    /// say (`MapBlobEncoder.remapLimit`) is dropped, so every result encodes; without it the result can be anything.
    /// About a third of the picks involve a trigger, and now and then a swap of two controls is made.
    static func randomOutputs(_ m: ControlMapping, _ seed: UInt64, expressibleOnly: Bool = true) -> ControlMapping {
        var rng = SplitMix64(seed: seed)
        var out = m
        let ids = frozenRemappableIDs
        func output(for id: String) -> ControlOutput {
            switch rng.int(0...9) {
            case 0: return .nothing
            case 1 where id == "g2" || id == "g3" || id == "g4": return .builtIn
            case 2, 3, 4: return .pad(rng.pick([.lt, .rt]))
            default: return .pad(rng.pick(PadOutput.allCases))
            }
        }
        func apply(_ picks: [(String, ControlOutput)]) {
            var candidate = out
            for (id, o) in picks { candidate.setOutput(o, for: id) }
            if !expressibleOnly || MapBlobEncoder.remapLimit(candidate) == nil { out = candidate }
        }
        for _ in 0..<rng.int(1...6) {
            switch rng.int(0...9) {
            case 0:                                                      // a swap
                let a = rng.pick(ids), b = rng.pick(ids)
                if a != b, case .pad(let pa) = out.effectiveOutput(a), case .pad(let pb) = out.effectiveOutput(b) {
                    apply([(a, .pad(pb)), (b, .pad(pa))])
                }
            case 1, 2, 3:                                                // a trigger control, or a trigger output
                let id = rng.chance(50) ? rng.pick(["lt", "rt"]) : rng.pick(ids)
                apply([(id, output(for: id))])
            case 4 where rng.chance(50):                                 // the LT/RT swap, or one trigger moved to the other
                apply(rng.chance(50) ? [("lt", .pad(.rt)), ("rt", .pad(.lt))] : [("lt", .pad(.rt)), ("rt", .nothing)])
            default:
                let id = rng.pick(ids)
                apply([(id, output(for: id))])
            }
        }
        return out
    }

    // MARK: Random frames

    static func randomRaw(_ rng: inout SplitMix64) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 16)
        b[0] = 6
        func put16(_ at: Int, _ v: Int) { let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v)); b[at] = UInt8(u & 0xff); b[at + 1] = UInt8(u >> 8) }
        switch rng.int(0...3) {
        case 0:                                                   // anything
            for i in 1..<16 { b[i] = UInt8(truncatingIfNeeded: rng.next()) }
        case 1:                                                   // rest: small deflections, sparse bits
            for a in 0..<4 { put16(1 + 2 * a, rng.int(-300...300)) }
            setTriggers(&b, rng.int(0...6), rng.int(0...6), hat: rng.chance(90) ? 8 : rng.int(0...15))
            setButtons(&b, rng.chance(70) ? 0 : 1 << rng.int(0...18), extra: rng.chance(70) ? 0 : 1 << rng.int(0...12))
        case 2:                                                   // extremes and thresholds
            let ax = [-32768, -32767, -16001, -16000, -15999, -66, -65, -64, -1, 0, 1, 64, 65, 66, 15999, 16000, 16001, 32766, 32767]
            for a in 0..<4 { put16(1 + 2 * a, rng.pick(ax)) }
            let tr = [0, 1, 2, 3, 99, 100, 101, 511, 512, 1021, 1022, 1023]
            setTriggers(&b, rng.pick(tr), rng.pick(tr), hat: rng.int(0...15))
            setButtons(&b, rng.int(0...0x7ffff), extra: rng.int(0...0x1fff))
        default:                                                  // everything moving
            for a in 0..<4 { put16(1 + 2 * a, rng.int(-32768...32767)) }
            setTriggers(&b, rng.int(0...1023), rng.int(0...1023), hat: rng.int(0...15))
            setButtons(&b, rng.int(0...0x7ffff), extra: rng.chance(50) ? 0 : rng.int(0...0x1fff))
        }
        return b
    }

    static func setTriggers(_ b: inout [UInt8], _ lt: Int, _ rt: Int, hat: Int) {
        let t = UInt32(lt) | UInt32(rt) << 10 | UInt32(hat) << 20
        b[9] = UInt8(t & 0xff); b[10] = UInt8((t >> 8) & 0xff); b[11] = UInt8((t >> 16) & 0xff)
    }

    static func setButtons(_ b: inout [UInt8], _ buttons: Int, extra: Int) {
        let v = UInt32(buttons) | UInt32(extra) << 19
        b[12] = UInt8(v & 0xff); b[13] = UInt8((v >> 8) & 0xff); b[14] = UInt8((v >> 16) & 0xff); b[15] = UInt8((v >> 24) & 0xff)
    }
}

/// The Swift pipeline the C core replaces: GamepadFrame.parse -> PassthroughPadMapper -> snapped -> PadReportBuilders.
struct SwiftOracle {
    var mapping: ControlMapping
    var identity = PadIdentity.default
    var axisDeadband = 0.002, triggerDeadband = 0.002

    func state(_ raw: [UInt8]) -> PadState? {
        guard let f = GamepadFrame.parse(raw) else { return nil }
        return VirtualPadSink.snapped(PassthroughPadMapper.padState(f, mapping), axisDeadband: axisDeadband, triggerDeadband: triggerDeadband)
    }

    func reports(_ s: PadState) -> [PadReport] { identity.reports(for: s) }
}

import Foundation
#if canImport(GDHubXlate)
import GDHubXlate
#endif

/// One GDHM v1 mapping blob, as tables (docs/plans/receiver-takeover-plan.md section 5.3). `serialize()` writes the
/// little-endian bytes `gdx_validate` reads. Tests build and edit tables directly.
struct GDHMTable: Equatable {
    struct Report: Equatable { var id: UInt8, length: UInt8 }
    struct Button: Equatable {
        var item: UInt8, kind: UInt8, arg: UInt8 = 0, sign: Int8 = 0
        var physMask: UInt16 = 0, stickRef: UInt8 = 0, outSlot: UInt8 = 0
    }
    struct Axis: Equatable {
        var stick: UInt8, component: UInt8, field: UInt8, sign: Int8 = 0
        var hasRange = false, min: Int32 = 0, max: Int32 = 0
    }
    struct Trigger: Equatable { var item: UInt8, field: UInt8 }
    struct Placement: Equatable {
        var reportIndex: UInt8, item: UInt8, bitOffset: UInt16, bits: UInt8, encoding: UInt8
    }

    var revision: UInt32 = 0
    var specCRC32: UInt32 = 0
    var sourceKind: UInt16 = 1
    var flags: UInt16 = 0
    var silenceNeutralMs: UInt16 = 250
    var deadband = 0.002, hysteresis = 0.002, stickActive = 0.5
    var triggerActiveRaw: Int32 = 100, axisActiveRaw: Int32 = 16000
    var reports: [Report] = []
    var buttons: [Button] = []
    var axes: [Axis] = []
    var triggers: [Trigger] = []
    var placements: [Placement] = []

    /// Writes the blob, header checksum included. No range checks: the table may be deliberately invalid in tests.
    func serialize() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        func put16(_ at: Int, _ v: UInt16) { b[at] = UInt8(v & 0xff); b[at + 1] = UInt8(v >> 8) }
        func put32(_ at: Int, _ v: UInt32) { for i in 0..<4 { b[at + i] = UInt8((v >> UInt32(8 * i)) & 0xff) } }
        func putF64(_ at: Int, _ v: Double) {
            let u = v.bitPattern
            for i in 0..<8 { b[at + i] = UInt8((u >> UInt64(8 * i)) & 0xff) }
        }
        func align8() { while b.count % 8 != 0 { b.append(0) } }
        func app16(_ v: UInt16) { b.append(UInt8(v & 0xff)); b.append(UInt8(v >> 8)) }
        func app32(_ v: UInt32) { for i in 0..<4 { b.append(UInt8((v >> UInt32(8 * i)) & 0xff)) } }

        put32(0, UInt32(GDX_BLOB_MAGIC))
        put16(4, UInt16(GDX_BLOB_VERSION))
        put32(8, revision)
        put32(12, specCRC32)
        put16(16, sourceKind)
        put16(18, flags)
        put16(20, silenceNeutralMs)
        b[22] = UInt8(truncatingIfNeeded: reports.count)
        b[23] = UInt8(truncatingIfNeeded: buttons.count)
        b[24] = UInt8(truncatingIfNeeded: axes.count)
        b[25] = UInt8(truncatingIfNeeded: triggers.count)
        b[26] = UInt8(truncatingIfNeeded: placements.count)
        b[27] = 0
        putF64(32, deadband); putF64(40, hysteresis); putF64(48, stickActive)
        put32(56, UInt32(bitPattern: triggerActiveRaw)); put32(60, UInt32(bitPattern: axisActiveRaw))

        for r in reports { b.append(r.id); b.append(r.length); app16(0) }
        align8()
        for x in buttons {
            b.append(x.item); b.append(x.kind); b.append(x.arg); b.append(UInt8(bitPattern: x.sign))
            app16(x.physMask); b.append(x.stickRef); b.append(x.outSlot)
        }
        align8()
        for a in axes {
            b.append(a.stick); b.append(a.component); b.append(a.field); b.append(UInt8(bitPattern: a.sign))
            b.append(a.hasRange ? 1 : 0); b.append(0); b.append(0); b.append(0)
            app32(UInt32(bitPattern: a.min)); app32(UInt32(bitPattern: a.max))
        }
        align8()
        for t in triggers { b.append(t.item); b.append(t.field); app16(0) }
        align8()
        for p in placements {
            b.append(p.reportIndex); b.append(p.item); app16(p.bitOffset); b.append(p.bits); b.append(p.encoding); app16(0)
        }
        align8()
        put16(6, UInt16(truncatingIfNeeded: b.count))
        put32(28, 0)
        put32(28, Self.crc32(b))       // computed with the checksum field zero
        return b
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { gdx_crc32($0.baseAddress, $0.count) }
    }
}

/// Compiles the current mapping model (`ControlMapping` + the pad identity) into a GDHM v1 blob (plan sections 5.3 and
/// 2.4). The blob expresses exactly what `PassthroughPadMapper`, `VirtualPadSink.snapped`/`unchanged` and
/// `PadReportBuilders.xboxBT16` do today. Anything v1 cannot express makes `encode` return `.unsupported(reason)`;
/// the engine then keeps the Swift path.
enum MapBlobEncoder {
    enum Result: Equatable {
        case blob([UInt8])
        case unsupported(String)
    }

    /// Output item of each button control the mapper reads, in item order (0 A … 10 Guide, 11…14 D-pad U/R/D/L).
    /// "start" feeds Guide, "l3"/"r3" feed LS/RS (PassthroughPadMapper).
    static let buttonControls = ["a", "b", "x", "y", "lb", "rb", "view", "menu", "l3", "r3", "start",
                                 "dpad_up", "dpad_right", "dpad_down", "dpad_left"]
    /// The pad output of each item above, same order (`buttonControls` names the control that sends it by default).
    static let buttonOutputs: [PadOutput] = [.a, .b, .x, .y, .lb, .rb, .view, .menu, .l3, .r3, .guide,
                                             .dpad_up, .dpad_right, .dpad_down, .dpad_left]
    static let stickControls = ["left_stick", "right_stick"]
    static let triggerOutputs: [PadOutput] = [.lt, .rt]
    static let axisFields = GamepadFrame.axisNames
    static let triggerFields = GamepadFrame.triggerNames

    /// Pad layouts the placements below describe. Both Xbox identities use `PadReportBuilders.xboxBT16`.
    static func supportsLayout(of identity: PadIdentity) -> Bool { identity.id.hasPrefix("xbox-bt16") }

    /// Report 0x01 (16 B) and 0x02 (2 B), exactly `PadReportBuilders.xboxBT16`.
    static let xboxBT16Reports: [GDHMTable.Report] = [.init(id: 0x01, length: 16), .init(id: 0x02, length: 2)]
    static let xboxBT16Placements: [GDHMTable.Placement] = {
        typealias P = GDHMTable.Placement
        let axis = UInt8(GDX_ENC_AXIS16), neg = UInt8(GDX_ENC_AXIS16_NEG), trig = UInt8(GDX_ENC_TRIG10_U16)
        let hat = UInt8(GDX_ENC_HAT8), bit = UInt8(GDX_ENC_BIT)
        var p: [P] = [
            P(reportIndex: 0, item: UInt8(GDX_ITEM_LX), bitOffset: 8, bits: 16, encoding: axis),
            P(reportIndex: 0, item: UInt8(GDX_ITEM_LY), bitOffset: 24, bits: 16, encoding: neg),
            P(reportIndex: 0, item: UInt8(GDX_ITEM_RX), bitOffset: 40, bits: 16, encoding: axis),
            P(reportIndex: 0, item: UInt8(GDX_ITEM_RY), bitOffset: 56, bits: 16, encoding: neg),
            P(reportIndex: 0, item: UInt8(GDX_ITEM_LT), bitOffset: 72, bits: 16, encoding: trig),
            P(reportIndex: 0, item: UInt8(GDX_ITEM_RT), bitOffset: 88, bits: 16, encoding: trig),
            P(reportIndex: 0, item: UInt8(GDX_ITEM_DPAD_UP), bitOffset: 104, bits: 8, encoding: hat),
        ]
        for item in 0..<8 {      // A B X Y LB RB View Menu: byte 14
            p.append(P(reportIndex: 0, item: UInt8(item), bitOffset: UInt16(112 + item), bits: 1, encoding: bit))
        }
        p.append(P(reportIndex: 0, item: UInt8(GDX_ITEM_LS), bitOffset: 120, bits: 1, encoding: bit))
        p.append(P(reportIndex: 0, item: UInt8(GDX_ITEM_RS), bitOffset: 121, bits: 1, encoding: bit))
        p.append(P(reportIndex: 1, item: UInt8(GDX_ITEM_GUIDE), bitOffset: 8, bits: 1, encoding: bit))
        return p
    }()

    enum Failure: Error { case unsupported(String) }

    static func encode(_ mapping: ControlMapping, identity: PadIdentity, spec: [UInt8], revision: UInt32,
                       axisDeadband: Double = 0.002, triggerDeadband: Double = 0.002) -> Result {
        do {
            return .blob(try table(mapping, identity: identity, spec: spec, revision: revision,
                                   axisDeadband: axisDeadband, triggerDeadband: triggerDeadband).serialize())
        } catch Failure.unsupported(let reason) {
            return .unsupported(reason)
        } catch {
            return .unsupported("\(error)")
        }
    }

    /// What GDHM v1 cannot say about the mapping's remaps (`outputs`), in the owner's words, or nil. v1 takes 0, 1 or 2
    /// OR-ed rules per pad button and exactly one field per pad trigger, so it cannot send one pad button from three
    /// controls, a button to a trigger, or two controls to one trigger; and it has no echo entry, so it cannot hide the
    /// button the controller adds for a remapped paddle or SAX key. This is the level-1 answer (a driver that takes GDHM
    /// v1 only, build 24). Never non-nil for a mapping with empty `outputs`. Pure; the menu uses it to mark picks the
    /// driver cannot do yet (the App drives the pad then).
    static func remapLimit(_ mapping: ControlMapping) -> String? { limit(mapping, inWords: false) }

    /// The same limit as `remapLimit`, said in the words the screen uses: the layout's labels for the controls ("three
    /// buttons send A: A, X, G5") and the menu's names for the pad items ("View", not "VIEW"). This is what the owner reads
    /// (the Mapping hint, the menu marks, the engine's note that the Driver menu and the Developer prompt show); the
    /// engine reports it as its reason. `remapLimit` keeps the step-1 text byte for byte, because the GDHM v1 pin
    /// (`GDHMv1PinTests`) pins it.
    static func remapLimitInWords(_ mapping: ControlMapping) -> String? { limit(mapping, inWords: true) }

    private static func limit(_ mapping: ControlMapping, inWords words: Bool) -> String? {
        guard !mapping.outputs.isEmpty else { return nil }
        func control(_ id: String) -> String { words ? (controlWords[id] ?? id) : id }
        func item(_ o: PadOutput) -> String { words ? o.shortName : label(o) }
        // A remapped paddle or SAX key first, so that no message below can name one of them by its raw id.
        for id in ControlMapping.echoKeyIDs {
            let output = mapping.effectiveOutput(id)
            if output != .builtIn {
                let sent: String
                if case .pad(let p) = output { sent = p.shortName } else { sent = label(output) }
                return "\(controlWords[id] ?? id) sends \(sent): this driver version cannot hide the controller's own press"
            }
        }
        for output in PadOutput.allCases {
            let sources = mapping.sources(of: output)
            if output.isTrigger {
                for source in sources where mapping.triggerFeed(from: source, into: output) == .fullScale {
                    return "\(control(source)) sends \(item(output)): a button cannot pull a trigger in this driver version"
                }
                if sources.count > 1 {
                    return "\(count(sources.count)) controls send \(item(output)): \(sources.map(control).joined(separator: ", "))"
                }
            } else if sources.count > 2 {
                return "\(count(sources.count)) buttons send \(item(output)): \(sources.map(control).joined(separator: ", "))"
            }
        }
        return nil
    }

    /// The owner's words for every control a pick can name: the layout labels (a test holds the table to the layout file).
    static let controlWords: [String: String] = [
        "a": "A", "b": "B", "x": "X", "y": "Y", "lb": "LB", "rb": "RB", "lt": "LT", "rt": "RT",
        "view": "View", "menu": "Menu", "start": "Start", "l3": "L3", "r3": "R3", "profile": "Profile",
        "dpad_up": "D-pad up", "dpad_right": "D-pad right", "dpad_down": "D-pad down", "dpad_left": "D-pad left",
        "g1": "G1", "g2": "G2", "g3": "G3", "g4": "G4", "g5": "G5",
        "left_stick": "Left stick", "right_stick": "Right stick",
        "paddle_outer_right": "Paddle outer right", "paddle_inner_right": "Paddle inner right",
        "paddle_inner_left": "Paddle inner left", "paddle_outer_left": "Paddle outer left",
        "sax_left": "SAX left", "sax_right": "SAX right",
    ]

    private static func label(_ o: ControlOutput) -> String {
        switch o {
        case .pad(let p): return label(p)
        case .nothing: return "Nothing"
        case .builtIn: return "its built-in function"
        }
    }

    private static func label(_ o: PadOutput) -> String {
        switch o {
        case .dpad_up: return "D-pad up"
        case .dpad_right: return "D-pad right"
        case .dpad_down: return "D-pad down"
        case .dpad_left: return "D-pad left"
        case .guide: return "Guide"
        default: return o.rawValue.uppercased()
        }
    }

    private static func count(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight"]
        return n < words.count ? words[n] : String(n)
    }

    static func table(_ m: ControlMapping, identity: PadIdentity, spec: [UInt8], revision: UInt32,
                      axisDeadband: Double = 0.002, triggerDeadband: Double = 0.002) throws -> GDHMTable {
        if let why = remapLimitInWords(m) { throw Failure.unsupported(why) }
        guard supportsLayout(of: identity) else {
            throw Failure.unsupported("pad layout \(identity.id) has no GDHM placements")
        }
        guard axisDeadband == triggerDeadband else {
            throw Failure.unsupported("axis deadband \(axisDeadband) differs from trigger deadband \(triggerDeadband)")
        }
        guard axisDeadband >= 0, axisDeadband < 1 else { throw Failure.unsupported("deadband \(axisDeadband) outside 0..<1") }

        var t = GDHMTable()
        t.revision = revision
        t.specCRC32 = GDHMTable.crc32(spec)
        t.deadband = axisDeadband
        t.hysteresis = axisDeadband
        t.reports = xboxBT16Reports
        t.placements = xboxBT16Placements

        // Per item: one rule per source, the default owner first (so an un-remapped mapping gives exactly one rule per item).
        for (item, output) in buttonOutputs.enumerated() {
            for cid in m.sources(of: output) {
                t.buttons.append(try buttonRule(item: UInt8(item), control: cid, m))
            }
        }
        for (stickIndex, sid) in stickControls.enumerated() {
            let s = m.sticks[sid]
            for (component, binding) in [s?.horizontal, s?.vertical].enumerated() {
                t.axes.append(try axisRule(stick: UInt8(stickIndex), component: UInt8(component), binding, in: s, control: sid))
            }
        }
        for (i, output) in triggerOutputs.enumerated() {
            var field = UInt8(GDX_FIELD_NONE)
            let sources = m.sources(of: output)
            if sources.count > 1 { throw Failure.unsupported("\(sources.joined(separator: ", ")) all send \(label(output))") }
            if let source = sources.first {
                switch m.triggerFeed(from: source, into: output) {
                case .nothing:
                    break
                case .analog(let name):
                    if let f = triggerFields.firstIndex(of: name) { field = UInt8(f) }
                case .fullScale:
                    throw Failure.unsupported("\(source) sends \(label(output)): a button cannot pull a trigger in this driver version")
                }
            }
            t.triggers.append(.init(item: UInt8(GDX_ITEM_LT) + UInt8(i), field: field))
        }
        return t
    }

    /// `ControlMapping.isActive` for one button control, as a single GDHM rule.
    private static func buttonRule(item: UInt8, control cid: String, _ m: ControlMapping) throws -> GDHMTable.Button {
        var r = GDHMTable.Button(item: item, kind: UInt8(GDX_KIND_NONE))
        // The six paddle and SAX keys are known by the fixed table, never by what a learn stored (`identityBits`).
        r.physMask = m.identityBits(cid) != 0 ? m.identityBits(cid) : (m.physicalBits[cid] ?? 0)
        var inexpressible: String?
        if let b = m.buttons[cid] {
            switch b {
            case .button(let n):
                if (1...19).contains(n) { r.kind = UInt8(GDX_KIND_BUTTON); r.arg = UInt8(n - 1) }       // else never active
            case .hat(let d):
                r.kind = UInt8(GDX_KIND_HAT); r.arg = d
            case .trigger(let name):
                if let f = triggerFields.firstIndex(of: name) { r.kind = UInt8(GDX_KIND_TRIGGER_GT); r.arg = UInt8(f) }
            case .axis(let name, let sign):
                if let f = axisFields.firstIndex(of: name) {
                    if let s = Int8(exactly: sign) { r.kind = UInt8(GDX_KIND_AXIS_GT); r.arg = UInt8(f); r.sign = s }
                    else { inexpressible = "\(cid): axis sign \(sign) does not fit GDHM v1" }
                }
            }
        } else if let s = m.sticks[cid], !s.isEmpty {
            if s == m.sticks[stickControls[0]] { r.kind = UInt8(GDX_KIND_STICK_MAG); r.stickRef = 0 }
            else if s == m.sticks[stickControls[1]] { r.kind = UInt8(GDX_KIND_STICK_MAG); r.stickRef = 1 }
            else { inexpressible = "\(cid): a stick binding other than the left or right stick on a button control" }
        }
        // A physical-identity mask replaces the binding altogether (ControlMapping.isActive), so what the binding
        // would have needed does not matter then.
        if let why = inexpressible {
            if r.physMask == 0 { throw Failure.unsupported(why) }
            r.kind = UInt8(GDX_KIND_NONE); r.arg = 0; r.sign = 0; r.stickRef = 0
        }
        return r
    }

    /// `ControlMapping.stickPosition.norm` for one component of a stick.
    private static func axisRule(stick: UInt8, component: UInt8, _ b: Binding?, in s: StickBinding?, control: String) throws -> GDHMTable.Axis {
        var a = GDHMTable.Axis(stick: stick, component: component, field: UInt8(GDX_FIELD_NONE))
        guard case .axis(let name, let sign)? = b, let f = axisFields.firstIndex(of: name) else { return a }
        guard let sign8 = Int8(exactly: sign) else {
            throw Failure.unsupported("\(control): axis sign \(sign) does not fit GDHM v1")
        }
        a.field = UInt8(f); a.sign = sign8
        if let range = s?.ranges?[name] {
            guard let lo = Int32(exactly: range.min), let hi = Int32(exactly: range.max) else {
                throw Failure.unsupported("\(control): learned range \(range.min)...\(range.max) of \(name) does not fit 32 bits")
            }
            a.hasRange = true; a.min = lo; a.max = hi
        }
        return a
    }
}

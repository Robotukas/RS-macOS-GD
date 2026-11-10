import Foundation
import CoreGraphics

enum Binding: Codable, Equatable, Hashable {
    /// 1-based button index into `GamepadFrame.buttons`.
    case button(Int)
    /// Hat value 0...7.
    case hat(UInt8)
    /// "lt" or "rt".
    case trigger(String)
    /// "x", "y", "z" or "rz"; `sign` is +1 or -1 so that sign * value grows in the learned direction
    /// (right for horizontal, down for vertical).
    case axis(String, sign: Int)

    var summary: String {
        switch self {
        case .button(let n): return "button \(n)"
        case .hat(let h): return "hat \(h)"
        case .trigger(let f): return "trigger \(f)"
        case .axis(let f, let s): return "axis \(s < 0 ? "-" : "+")\(f)"
        }
    }
}

/// Observed extremes of one axis while the stick was rotated through a full circle.
struct AxisRange: Codable, Equatable {
    var min: Int
    var max: Int
}

struct StickBinding: Codable, Equatable {
    var horizontal: Binding?
    var vertical: Binding?
    /// Per-axis extremes ("x", "y", ...) from the circle capture; used to scale the position to -1...1.
    var ranges: [String: AxisRange]?

    var isEmpty: Bool { horizontal == nil && vertical == nil }
}

/// Which part of a control a learned binding applies to.
enum LearnTarget: Equatable {
    case whole
    case stickHorizontal
    case stickVertical
    /// One full rotation of a stick: both axes and their extremes in one step.
    case stickCircle
}

/// Result of one learn step.
struct LearnAssignment {
    var controlId: String
    var target: LearnTarget
    var binding: Binding?
    var physicalBits: UInt16
    /// Set for `.stickCircle`: the complete stick binding including axis ranges.
    var stick: StickBinding? = nil
}

/// One output item of the virtual pad, named by its control id ("guide" for Guide). Everything but the triggers maps
/// onto the existing `PadItem` (the GDX-numbered item), so there is no second hand-numbered table.
enum PadOutput: String, CaseIterable {
    case a, b, x, y, lb, rb, lt, rt, view, menu, l3, r3, guide
    case dpad_up, dpad_right, dpad_down, dpad_left

    var padItem: PadItem? {
        switch self {
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .lb: return .lb
        case .rb: return .rb
        case .view: return .view
        case .menu: return .menu
        case .l3: return .ls
        case .r3: return .rs
        case .guide: return .guide
        case .dpad_up: return .dpadUp
        case .dpad_right: return .dpadRight
        case .dpad_down: return .dpadDown
        case .dpad_left: return .dpadLeft
        case .lt, .rt: return nil
        }
    }

    /// Reverse of `padItem`.
    init(_ item: PadItem) {
        // Total over PadItem; a new PadItem case without a PadOutput fails the build here.
        switch item {
        case .a: self = .a
        case .b: self = .b
        case .x: self = .x
        case .y: self = .y
        case .lb: self = .lb
        case .rb: self = .rb
        case .view: self = .view
        case .menu: self = .menu
        case .ls: self = .l3
        case .rs: self = .r3
        case .guide: self = .guide
        case .dpadUp: self = .dpad_up
        case .dpadRight: self = .dpad_right
        case .dpadDown: self = .dpad_down
        case .dpadLeft: self = .dpad_left
        }
    }

    var isTrigger: Bool { self == .lt || self == .rt }
}

/// What a remappable control sends to the virtual pad.
enum ControlOutput: Hashable {
    case pad(PadOutput)
    case nothing
    /// The controller's own function (the volume keys on G2-G4); valid only there.
    case builtIn

    /// On-disk form: the pad control id ("y"), "nothing" or "built_in".
    var string: String {
        switch self {
        case .pad(let p): return p.rawValue
        case .nothing: return "nothing"
        case .builtIn: return "built_in"
        }
    }

    init?(string: String) {
        switch string {
        case "nothing": self = .nothing
        case "built_in": self = .builtIn
        default:
            guard let p = PadOutput(rawValue: string) else { return nil }
            self = .pad(p)
        }
    }
}

struct ControlMapping: Equatable {
    var buttons: [String: Binding] = [:]
    var sticks: [String: StickBinding] = [:]
    /// "Extra" bit (13-bit field) that identifies the physical paddle / SAX button. When present it
    /// takes precedence over `buttons`, because the standard field only carries the function the
    /// on-controller profile maps the paddle to (D-pad, A, B ...).
    var physicalBits: [String: UInt16] = [:]
    /// Remaps: control id -> what it sends to the pad. Absent = the control's default output. Never holds an entry
    /// equal to the default (see `setOutput`).
    var outputs: [String: ControlOutput] = [:]

    /// Factory layout of the SCUF Envision Pro as learned on real hardware (docs/protocol).
    static var `default`: ControlMapping {
        var m = ControlMapping()
        let buttons: [(String, Int)] = [
            ("a", 1), ("b", 2), ("x", 3), ("y", 4), ("lb", 5), ("rb", 6), ("view", 7), ("menu", 8),
            ("l3", 9), ("r3", 10), ("start", 11), ("g1", 12), ("g2", 13), ("g3", 14), ("g4", 15), ("g5", 16),
            ("profile", 17),
        ]
        for (id, n) in buttons { m.buttons[id] = .button(n) }
        m.buttons["lt"] = .trigger("lt")
        m.buttons["rt"] = .trigger("rt")
        m.buttons["dpad_up"] = .hat(0)
        m.buttons["dpad_right"] = .hat(2)
        m.buttons["dpad_down"] = .hat(4)
        m.buttons["dpad_left"] = .hat(6)
        m.sticks["left_stick"] = StickBinding(horizontal: .axis("x", sign: 1), vertical: .axis("y", sign: 1))
        m.sticks["right_stick"] = StickBinding(horizontal: .axis("z", sign: 1), vertical: .axis("rz", sign: 1))
        // Factory profile: paddles act as the D-pad, SAX buttons as A / B.
        m.buttons["paddle_outer_right"] = .hat(2)
        m.buttons["paddle_inner_right"] = .hat(4)
        m.buttons["paddle_inner_left"] = .hat(0)
        m.buttons["paddle_outer_left"] = .hat(6)
        m.buttons["sax_left"] = .button(1)
        m.buttons["sax_right"] = .button(2)
        m.physicalBits = ["paddle_outer_right": 1, "paddle_inner_right": 2, "paddle_inner_left": 4,
                          "paddle_outer_left": 8, "sax_left": 16, "sax_right": 32]
        return m
    }

    // MARK: Queries

    func isMapped(_ controlId: String) -> Bool {
        if buttons[controlId] != nil { return true }
        if let s = sticks[controlId], !s.isEmpty { return true }
        if let p = physicalBits[controlId], p != 0 { return true }
        return false
    }

    func isActive(_ controlId: String, _ frame: GamepadFrame) -> Bool {
        // Physical identity wins: a paddle lights only when that paddle is pressed, not when the
        // button it is mapped to is pressed on the face.
        if let bits = physicalBits[controlId], bits != 0 {
            return frame.extra & bits == bits
        }
        if let b = buttons[controlId] {
            switch b {
            case .button(let n):
                return frame.isButtonDown(n)
            case .hat(let d):
                let h = Int(frame.hat)
                guard h < 8 else { return false }
                if h == Int(d) { return true }
                // A cardinal direction is also active on the two adjacent diagonals.
                if d % 2 == 0 { return (h + 1) % 8 == Int(d) || (h + 7) % 8 == Int(d) }
                return false
            case .trigger(let f):
                return (frame.trigger(f) ?? 0) > 100
            case .axis(let f, let sign):
                return sign * (frame.axis(f) ?? 0) > 16000
            }
        }
        if let s = sticks[controlId] {
            if let p = stickPosition(controlId, frame, binding: s) { return abs(p.x) > 0.5 || abs(p.y) > 0.5 }
            return false
        }
        return false
    }

    /// Stick position in -1...1; x grows to the right, y grows downward. Nil if the stick has no axis bound.
    func stickPosition(_ controlId: String, _ frame: GamepadFrame) -> CGPoint? {
        guard let s = sticks[controlId] else { return nil }
        return stickPosition(controlId, frame, binding: s)
    }

    private func stickPosition(_ controlId: String, _ frame: GamepadFrame, binding s: StickBinding) -> CGPoint? {
        func norm(_ b: Binding?) -> Double? {
            guard case .axis(let f, let sign)? = b, let v = frame.axis(f) else { return nil }
            // Scale by the learned extremes when we have them, so the dot reaches the ring edge
            // exactly where the stick physically stops; otherwise assume the full int16 range.
            var scaled: Double
            if let r = s.ranges?[f] {
                scaled = v >= 0 ? Double(v) / Double(Swift.max(r.max, 1)) : Double(v) / Double(Swift.max(-r.min, 1))
            } else {
                scaled = Double(v) / 32767.0
            }
            scaled *= Double(sign)
            return Swift.max(-1, Swift.min(1, scaled))
        }
        let h = norm(s.horizontal)
        let v = norm(s.vertical)
        if h == nil && v == nil { return nil }
        return CGPoint(x: h ?? 0, y: v ?? 0)
    }

    /// Trigger fill in 0...1, or nil if the control is not bound to a trigger field.
    func triggerValue(_ controlId: String, _ frame: GamepadFrame) -> Double? {
        guard case .trigger(let f)? = buttons[controlId], let v = frame.trigger(f) else { return nil }
        return max(0, min(1, Double(v) / 1023.0))
    }

    // MARK: Mutation

    mutating func apply(_ a: LearnAssignment) {
        if a.target == .stickCircle {
            if let s = a.stick { sticks[a.controlId] = s }
            return
        }
        if let binding = a.binding {
            switch a.target {
            case .whole:
                buttons[a.controlId] = binding
            case .stickCircle:
                break
            case .stickHorizontal:
                var s = sticks[a.controlId] ?? StickBinding()
                s.horizontal = binding
                sticks[a.controlId] = s
            case .stickVertical:
                var s = sticks[a.controlId] ?? StickBinding()
                s.vertical = binding
                sticks[a.controlId] = s
            }
        }
        // Replace rather than merge so re-learning clears a stale bit.
        if a.physicalBits != 0 {
            physicalBits[a.controlId] = a.physicalBits
        } else if a.target == .whole {
            physicalBits[a.controlId] = nil
        }
    }
}

// MARK: Remaps

extension ControlMapping {
    /// The controls whose output can be changed, in the order the UI and `sources(of:)` use.
    static let remappableIDs: [String] = [
        "a", "b", "x", "y", "lb", "rb", "lt", "rt", "view", "menu", "l3", "r3",
        "dpad_up", "dpad_right", "dpad_down", "dpad_left", "start", "profile", "g1", "g2", "g3", "g4", "g5",
    ]

    private static let remappableSet = Set(remappableIDs)

    /// Controls on which `ControlOutput.builtIn` (the volume function) is valid.
    static let builtInIDs: Set<String> = ["g2", "g3", "g4"]

    func defaultOutput(_ id: String) -> ControlOutput {
        switch id {
        case "start": return .pad(.guide)
        case "g2", "g3", "g4": return .builtIn
        case "guide": return .nothing
        default:
            if Self.remappableSet.contains(id), let p = PadOutput(rawValue: id) { return .pad(p) }
            return .nothing
        }
    }

    func effectiveOutput(_ id: String) -> ControlOutput {
        if let o = outputs[id], Self.remappableSet.contains(id) { return o }
        return defaultOutput(id)
    }

    func isRemapped(_ id: String) -> Bool { outputs[id] != nil }

    mutating func setOutput(_ output: ControlOutput, for id: String) {
        guard Self.remappableIDs.contains(id) else { return }
        if output == .builtIn && !Self.builtInIDs.contains(id) { return }
        outputs[id] = output == defaultOutput(id) ? nil : output
    }

    mutating func resetAllOutputs() { outputs = [:] }

    /// Controls that currently send `item`: the default owner first (for Guide that is "start"), then the rest in
    /// `remappableIDs` order. The single source of truth for the mapper, the encoder, the menu and the lighting.
    func sources(of item: PadOutput) -> [String] { sourcesByOutput()[item] ?? [] }

    /// `sources(of:)` for every pad output in one pass (the mapper needs all of them for every frame). Outputs nobody
    /// sends are absent.
    func sourcesByOutput() -> [PadOutput: [String]] {
        // No remaps (the common case): the default owners alone.
        if outputs.isEmpty { return Self.defaultSources }
        var all: [PadOutput: [String]] = [:]
        for id in Self.remappableIDs {
            guard case .pad(let p) = effectiveOutput(id) else { continue }
            if defaultOutput(id) == .pad(p) { all[p, default: []].insert(id, at: 0) }     // the default owner goes first
            else { all[p, default: []].append(id) }
        }
        return all
    }

    /// Each pad output with the control whose default output it is, derived from `defaultOutput` (not a second table).
    private static let defaultSources: [PadOutput: [String]] = {
        let m = ControlMapping()
        var owners: [PadOutput: [String]] = [:]
        for id in remappableIDs {
            if case .pad(let p) = m.defaultOutput(id), owners[p] == nil { owners[p] = [id] }
        }
        return owners
    }()

    /// What one source adds to a trigger output (`lt` / `rt`). The single rule the mapper, the encoder and the menu share.
    enum TriggerFeed: Equatable {
        /// Adds nothing: the default owner of this trigger while its learned binding is not a trigger field (an
        /// un-remapped `lt` learned as a button sends nothing, as before remaps existed).
        case nothing
        /// Adds the analog value of this physical trigger field ("lt" or "rt"): the source's learned binding is a trigger.
        case analog(String)
        /// Adds full scale while the source is held (`isActive`): an explicitly remapped button.
        case fullScale
    }

    /// How `source` feeds the pad trigger `trigger` (`.lt` or `.rt`). Judged by the learned binding, not by the control id.
    /// The default owner contributes exactly what it did before remaps (`triggerValue ?? 0`).
    func triggerFeed(from source: String, into trigger: PadOutput) -> TriggerFeed {
        if case .trigger(let field)? = buttons[source] { return .analog(field) }
        return defaultOutput(source) == .pad(trigger) ? .nothing : .fullScale
    }

    /// Learn guard (remap plan): in a single-control learn, an assignment of a whole control with a binding and no
    /// physical bits is refused when another control already has that binding and no physical bits of its own
    /// (paddles and SAX carry bits, so they never count as owners). Returns the lowest such control id.
    /// Guided "Learn all" simply does not call this.
    func learnConflict(_ a: LearnAssignment) -> String? {
        guard a.target == .whole, let binding = a.binding, a.physicalBits == 0 else { return nil }
        return buttons.filter { id, b in
            id != a.controlId && b == binding && (physicalBits[id] ?? 0) == 0
        }.keys.min()
    }
}

// MARK: Codable

extension ControlMapping: Codable {
    private enum CodingKeys: String, CodingKey { case buttons, sticks, physicalBits, outputs }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `buttons` is required, as it always was: a file without it (`{}`, a truncated edit) is unreadable, not an
        // empty mapping that would leave the pad dead.
        buttons = try c.decode([String: Binding].self, forKey: .buttons)
        sticks = try c.decodeIfPresent([String: StickBinding].self, forKey: .sticks) ?? [:]
        physicalBits = try c.decodeIfPresent([String: UInt16].self, forKey: .physicalBits) ?? [:]
        guard c.contains(.outputs), (try? c.decodeNil(forKey: .outputs)) == false else { return }
        guard let o = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .outputs) else {
            print("ControlMapping: \"outputs\" is not an object; ignoring it.")
            return
        }
        for key in o.allKeys {
            guard Self.remappableIDs.contains(key.stringValue) else {
                print("ControlMapping: dropped output for unknown control \"\(key.stringValue)\".")
                continue
            }
            guard let text = try? o.decode(String.self, forKey: key), let value = ControlOutput(string: text) else {
                print("ControlMapping: dropped output for \"\(key.stringValue)\": not a known value.")
                continue
            }
            if value == .builtIn && !Self.builtInIDs.contains(key.stringValue) {
                print("ControlMapping: dropped built_in for \"\(key.stringValue)\": only valid on g2, g3, g4.")
                continue
            }
            setOutput(value, for: key.stringValue)   // also drops entries equal to the default
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(buttons, forKey: .buttons)
        try c.encode(sticks, forKey: .sticks)
        try c.encode(physicalBits, forKey: .physicalBits)
        if !outputs.isEmpty {
            try c.encode(outputs.mapValues(\.string), forKey: .outputs)
        }
    }
}

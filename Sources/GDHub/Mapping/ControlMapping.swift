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

struct ControlMapping: Codable, Equatable {
    var buttons: [String: Binding] = [:]
    var sticks: [String: StickBinding] = [:]
    /// "Extra" bit (13-bit field) that identifies the physical paddle / SAX button. When present it
    /// takes precedence over `buttons`, because the standard field only carries the function the
    /// on-controller profile maps the paddle to (D-pad, A, B ...).
    var physicalBits: [String: UInt16] = [:]

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

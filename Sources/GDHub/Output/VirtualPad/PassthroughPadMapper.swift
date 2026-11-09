import Foundation

/// `GamepadFrame` + learned `ControlMapping` → `PadState` (design §5.5), until the P3 engine replaces it.
///
/// Pure and stateless, so it can run on any queue. The SCUF's extra controls have no XInput equivalent and are not
/// forwarded as themselves:
/// - G1…G5 and Profile (buttons 12…17) are dropped. "Profile" stays unbound (output-layer plan §3.5).
/// - Paddles and SAX buttons reach the pad only through the controller's own factory echo: paddles arrive as hat
///   directions (D-pad), SAX left / right as buttons 1 / 2 (A / B). The mapper never reads `physicalBits`
///   itself (`ControlMapping.isActive` gives them precedence only for the paddle / SAX controls), so the echo
///   is counted once.
enum PassthroughPadMapper {
    static func padState(_ f: GamepadFrame, _ m: ControlMapping) -> PadState {
        var s = PadState()
        var b: PadButtons = []
        if m.isActive("a", f) { b.insert(.a) }
        if m.isActive("b", f) { b.insert(.b) }
        if m.isActive("x", f) { b.insert(.x) }
        if m.isActive("y", f) { b.insert(.y) }
        if m.isActive("lb", f) { b.insert(.lb) }
        if m.isActive("rb", f) { b.insert(.rb) }
        if m.isActive("view", f) { b.insert(.view) }
        if m.isActive("menu", f) { b.insert(.menu) }
        if m.isActive("l3", f) { b.insert(.ls) }
        if m.isActive("r3", f) { b.insert(.rs) }
        if m.isActive("start", f) { b.insert(.guide) }            // centre button → Guide
        if m.isActive("dpad_up", f) { b.insert(.dpadUp) }
        if m.isActive("dpad_right", f) { b.insert(.dpadRight) }
        if m.isActive("dpad_down", f) { b.insert(.dpadDown) }
        if m.isActive("dpad_left", f) { b.insert(.dpadLeft) }
        s.buttons = b
        // The mapping's y grows downward; PadState's y grows upward.
        if let p = m.stickPosition("left_stick", f) { s.lx = Double(p.x); s.ly = -Double(p.y) }
        if let p = m.stickPosition("right_stick", f) { s.rx = Double(p.x); s.ry = -Double(p.y) }
        s.lt = m.triggerValue("lt", f) ?? 0
        s.rt = m.triggerValue("rt", f) ?? 0
        return s
    }
}

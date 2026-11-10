import Foundation

/// `GamepadFrame` + learned `ControlMapping` → `PadState` (design §5.5), until the P3 engine replaces it.
///
/// Pure and stateless, so it can run on any queue. The SCUF's extra controls have no XInput equivalent and are not
/// forwarded as themselves unless the mapping's `outputs` say so (remap plan):
/// - What each control sends is `mapping.effectiveOutput`. A pad button is held when any of `sources(of:)` is active
///   (`isActive`); `.nothing` and `.builtIn` feed nothing. By default G1…G5 and Profile (buttons 12…17) send nothing,
///   and "Profile" stays unbound (output-layer plan §3.5).
/// - Paddles and SAX buttons reach the pad only through the controller's own factory echo: paddles arrive as hat
///   directions (D-pad), SAX left / right as buttons 1 / 2 (A / B). The mapper never reads `physicalBits`
///   itself (`ControlMapping.isActive` gives them precedence only for the paddle / SAX controls), so the echo
///   is counted once.
/// - Opposite D-pad directions are both reported here; the report builders cancel them (`GDX_ENC_HAT8`).
enum PassthroughPadMapper {
    static func padState(_ f: GamepadFrame, _ m: ControlMapping) -> PadState {
        var s = PadState()
        var b: PadButtons = []
        let sources = m.sourcesByOutput()
        for output in PadOutput.allCases {
            guard let bit = buttons(of: output) else { continue }
            if sources[output]?.contains(where: { m.isActive($0, f) }) == true { b.insert(bit) }
        }
        s.buttons = b
        // The mapping's y grows downward; PadState's y grows upward.
        if let p = m.stickPosition("left_stick", f) { s.lx = Double(p.x); s.ly = -Double(p.y) }
        if let p = m.stickPosition("right_stick", f) { s.rx = Double(p.x); s.ry = -Double(p.y) }
        s.lt = triggerLevel(.lt, sources[.lt] ?? [], f, m)
        s.rt = triggerLevel(.rt, sources[.rt] ?? [], f, m)
        return s
    }

    /// LT / RT value 0...1: the maximum over the sources of that trigger (see `ControlMapping.triggerFeed`).
    private static func triggerLevel(_ trigger: PadOutput, _ sources: [String], _ f: GamepadFrame, _ m: ControlMapping) -> Double {
        var level = 0.0
        for source in sources {
            let v: Double
            switch m.triggerFeed(from: source, into: trigger) {
            case .nothing: v = 0
            case .analog: v = m.triggerValue(source, f) ?? 0
            case .fullScale: v = m.isActive(source, f) ? 1 : 0
            }
            level = max(level, v)
        }
        return level
    }

    /// The `PadButtons` bit of a digital pad output (nil for LT / RT, which are analog). Total over `PadOutput`.
    private static func buttons(of o: PadOutput) -> PadButtons? {
        switch o {
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
}

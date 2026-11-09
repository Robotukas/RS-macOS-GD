import Foundation

/// What the virtual pad should show for one pressed control, worked out by running the real mapper instead of keeping
/// a table. `ControlMapping.isMapped` is true for G keys although the mapper drops them, and paddles and SAX buttons
/// reach the pad only as the factory echo (hat directions, A / B); simulating the press covers all of that, and keeps
/// covering it when the owner remaps something.
enum DevExpectation {
    /// The receiver frame the controller would send while `controlID` is held: the control's binding made true, plus
    /// its physical-identity bit. nil when the mapping has nothing for the control or the binding cannot be pressed.
    static func pressedFrame(for controlID: String, mapping: ControlMapping) -> GamepadFrame? {
        var f = GamepadFrame.idle
        var touched = false
        if let bits = mapping.physicalBits[controlID], bits != 0 {
            f.extra |= bits
            touched = true
        }
        if let b = mapping.buttons[controlID] {
            switch b {
            case .button(let n):
                if (1...19).contains(n) { f.buttons |= UInt32(1) << UInt32(n - 1); touched = true }
            case .hat(let d):
                f.hat = d; touched = true
            case .trigger(let name):
                if name == "lt" { f.lt = 1023; touched = true } else if name == "rt" { f.rt = 1023; touched = true }
            case .axis(let name, let sign):
                let v = Int16(sign < 0 ? -32767 : 32767)
                switch name {
                case "x": f.x = v
                case "y": f.y = v
                case "z": f.z = v
                case "rz": f.rz = v
                default: return touched ? f : nil
                }
                touched = true
            }
        }
        return touched ? f : nil
    }

    /// The pad items `controlID` produces when pressed, as the diff of the mapper's output against an idle frame.
    /// Sticks and triggers are not digital and give an empty set (their own judge rules look at the axes). G keys and
    /// Profile give an empty set unless the mapping routes them to something the mapper forwards.
    static func expected(for controlID: String, mapping: ControlMapping, layout: ControlLayout) -> DevExpectedItems {
        DevExpectedItems(items: expectedItems(for: controlID, mapping: mapping, layout: layout))
    }

    static func expectedItems(for controlID: String, mapping: ControlMapping, layout: ControlLayout) -> Set<PadItem> {
        if let control = layout.control(id: controlID), control.kind != .button { return [] }
        guard let frame = pressedFrame(for: controlID, mapping: mapping) else { return [] }
        let idle = pad(from: PassthroughPadMapper.padState(.idle, mapping))
        return pad(from: PassthroughPadMapper.padState(frame, mapping)).subtracting(idle)
    }

    /// What a digital step expects: its `expect.items` when the template sets them, otherwise the union over the
    /// step's controls.
    static func resolve(step: DevStep, mapping: ControlMapping, layout: ControlLayout) -> DevExpectedItems {
        if let override = step.expect?.items { return override }
        var all: Set<PadItem> = []
        for cid in step.controls { all.formUnion(expectedItems(for: cid, mapping: mapping, layout: layout)) }
        return DevExpectedItems(items: all)
    }

    /// The layout controls that draw the expected output, in item order: A → `a`, hat W → `dpad_left`, hat NE →
    /// `dpad_up` and `dpad_right`, Guide → none (the Start control feeds it, but nothing draws "Guide").
    static func linkedOutputControls(for expected: DevExpectedItems) -> [String] {
        expected.items.sorted().compactMap(\.layoutControlID)
    }

    /// The one control the UI lights dimmer while `controlID` is wanted: the first output control of the expectation.
    /// It equals `controlID` when the control is its own output (A); the UI then shows nothing extra.
    static func linkedOutputControl(for controlID: String, mapping: ControlMapping, layout: ControlLayout) -> String? {
        linkedOutputControls(for: expected(for: controlID, mapping: mapping, layout: layout)).first
    }

    /// The items of a mapper output that a digital control can produce.
    private static func pad(from state: PadState) -> Set<PadItem> {
        let b = state.buttons
        var s: Set<PadItem> = []
        let pairs: [(PadButtons, PadItem)] = [(.a, .a), (.b, .b), (.x, .x), (.y, .y), (.lb, .lb), (.rb, .rb), (.view, .view),
                                              (.menu, .menu), (.ls, .ls), (.rs, .rs), (.guide, .guide)]
        for (flag, item) in pairs where b.contains(flag) { s.insert(item) }
        s.formUnion(PadHat.items(PadReportBuilders.hat(b)))
        return s
    }
}

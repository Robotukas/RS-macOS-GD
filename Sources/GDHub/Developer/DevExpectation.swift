import Foundation

/// What the virtual pad should show for one pressed control, worked out by running the real mapper instead of keeping
/// a table. `ControlMapping.isMapped` is true for G keys although the mapper drops them; simulating the press covers all
/// of that, and keeps covering it when the owner remaps something.
///
/// The six paddle and SAX keys: one that is remapped expects its pick whatever echo is stored (its press is simulated
/// by its identity bit alone, never by the stored binding). One left on Controller's profile expects whatever the
/// controller's profile gives, which the Mac cannot know (row 1 presses Profile): it resolves to the `builtInEcho` rule,
/// one pad item per press, in every template.
enum DevExpectation {
    /// One of the six paddle and SAX keys, left on Controller's profile (`.builtIn`): its press shows the button the
    /// controller adds, so the step takes the `builtInEcho` rule.
    static func isBuiltInEcho(_ controlID: String, mapping: ControlMapping) -> Bool {
        mapping.identityBits(controlID) != 0 && mapping.effectiveOutput(controlID) == .builtIn
    }

    /// One of the six whose own button is hidden (any pick, Nothing included).
    static func isHiddenKey(_ controlID: String, mapping: ControlMapping) -> Bool {
        mapping.identityBits(controlID) != 0 && mapping.effectiveOutput(controlID) != .builtIn
    }

    /// Whether the step takes the `builtInEcho` rule: it says so, or it is a digital step on one paddle or SAX key left
    /// on Controller's profile that writes no expectation of its own.
    static func usesBuiltInEcho(step: DevStep, mapping: ControlMapping) -> Bool {
        guard step.devKind == .digital else { return false }
        if step.expect?.builtInEcho == true { return true }
        if step.expect?.items != nil || step.expect?.builtInEcho == false { return false }
        return step.controls.count == 1 && isBuiltInEcho(step.controls[0], mapping: mapping)
    }

    /// The receiver frame the controller would send while `controlID` is held: the control's binding made true, plus
    /// its physical-identity bit. nil when the mapping has nothing for the control or the binding cannot be pressed. A
    /// remapped paddle or SAX key sets only its identity bits.
    static func pressedFrame(for controlID: String, mapping: ControlMapping) -> GamepadFrame? {
        var f = GamepadFrame.idle
        var touched = false
        if isHiddenKey(controlID, mapping: mapping) {
            f.extra = mapping.identityBits(controlID)
            return f
        }
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
        if let control = layout.control(id: controlID), control.kind == .stick { return [] }
        if isBuiltInEcho(controlID, mapping: mapping) { return [] }
        guard let frame = pressedFrame(for: controlID, mapping: mapping) else { return [] }
        let idle = pad(from: PassthroughPadMapper.padState(.idle, mapping))
        return pad(from: PassthroughPadMapper.padState(frame, mapping)).subtracting(idle)
    }

    /// The pad's triggers that pressing (or fully pulling) `controlID` pulls all the way, under the mapping: LT sent to
    /// RT pulls RT, G1 sent to LT pulls LT.
    static func expectedTriggers(for controlID: String, mapping: ControlMapping, layout: ControlLayout) -> (lt: Bool, rt: Bool) {
        if let control = layout.control(id: controlID), control.kind == .stick { return (false, false) }
        if isBuiltInEcho(controlID, mapping: mapping) { return (false, false) }
        guard let frame = pressedFrame(for: controlID, mapping: mapping) else { return (false, false) }
        let pad = PassthroughPadMapper.padState(frame, mapping)
        return (pad.lt > 0.5, pad.rt > 0.5)
    }

    /// The pad items that the step's `background` controls send (they stay held while the others are pressed).
    static func backgroundItems(step: DevStep, mapping: ControlMapping, layout: ControlLayout) -> Set<PadItem> {
        var all: Set<PadItem> = []
        for cid in step.expect?.background ?? [] { all.formUnion(expectedItems(for: cid, mapping: mapping, layout: layout)) }
        return all
    }

    /// What a digital, trigger or held step expects: its `expect.items` when the template sets them, otherwise the union
    /// over the step's controls other than its `background` ones (what they send is held, not pressed). Triggers are
    /// worked out the same way.
    static func resolve(step: DevStep, mapping: ControlMapping, layout: ControlLayout) -> DevExpectedItems {
        if let override = step.expect?.items { return override }
        // A held step that names its item expects exactly that (a trigger has no place in the item list).
        if step.devKind == .held, let name = step.expect?.item, let held = DevHeldItem(name: name) {
            return DevExpectedItems(items: held.padItems)
        }
        var all: Set<PadItem> = []
        var lt = false, rt = false
        let background = Set(step.expect?.background ?? [])
        for cid in step.controls where !background.contains(cid) {
            all.formUnion(expectedItems(for: cid, mapping: mapping, layout: layout))
            let t = expectedTriggers(for: cid, mapping: mapping, layout: layout)
            lt = lt || t.lt; rt = rt || t.rt
        }
        return DevExpectedItems(items: all, lt: lt, rt: rt)
    }

    /// What a held step watches: its `expect.item` when it names one, otherwise the trigger of an `lt` / `rt` control and
    /// the items the pad shows for the step's button controls. nil when `expect.item` is not a name this build knows.
    static func heldTargets(step: DevStep, expected: DevExpectedItems) -> [DevHeldItem]? {
        if let name = step.expect?.item { return DevHeldItem(name: name).map { [$0] } }
        var out: [DevHeldItem] = []
        if expected.lt || expected.rt {
            // The pad trigger the control is mapped to (LT sent to RT holds RT).
            out += expected.triggers.map { DevHeldItem.trigger($0) }
        } else if expected.items.isEmpty {
            // Nothing worked out: the control's own trigger, as before remaps could move it.
            for cid in step.controls {
                if cid == "lt" { out.append(.trigger(.left)) } else if cid == "rt" { out.append(.trigger(.right)) }
            }
        }
        out += expected.items.sorted().map { DevHeldItem.item($0) }
        return out
    }

    /// The layout controls that draw the expected output, in item order: A → `a`, hat W → `dpad_left`, hat NE →
    /// `dpad_up` and `dpad_right`, Guide → none (the Start control feeds it, but nothing draws "Guide"); then the
    /// trigger controls the step pulls (`lt`, `rt`).
    static func linkedOutputControls(for expected: DevExpectedItems) -> [String] {
        expected.items.sorted().compactMap(\.layoutControlID) + (expected.lt ? ["lt"] : []) + (expected.rt ? ["rt"] : [])
    }

    /// The one control the UI lights dimmer while `controlID` is wanted: the first output control of the expectation.
    /// It equals `controlID` when the control is its own output (A); the UI then shows nothing extra.
    static func linkedOutputControl(for controlID: String, mapping: ControlMapping, layout: ControlLayout) -> String? {
        linkedOutputControls(for: expected(for: controlID, mapping: mapping, layout: layout)).first
    }

    /// The items of a mapper output that a digital control can produce.
    static func pad(from state: PadState) -> Set<PadItem> {
        let b = state.buttons
        var s: Set<PadItem> = []
        let pairs: [(PadButtons, PadItem)] = [(.a, .a), (.b, .b), (.x, .x), (.y, .y), (.lb, .lb), (.rb, .rb), (.view, .view),
                                              (.menu, .menu), (.ls, .ls), (.rs, .rs), (.guide, .guide)]
        for (flag, item) in pairs where b.contains(flag) { s.insert(item) }
        s.formUnion(PadHat.items(PadReportBuilders.hat(b)))
        return s
    }
}

/// One output of the virtual pad that a held step requires to stay held.
enum DevHeldItem: Equatable {
    case trigger(PadTrigger)
    /// A button, a D-pad direction (the hat presses it) or Guide.
    case item(PadItem)
    /// Exactly this hat value, 1 (N) … 8 (NW).
    case hat(UInt8)

    /// "RT", "LT", a `PadItem` name ("A", "D-pad left", "Guide") or a hat direction ("N" … "NW").
    init?(name: String) {
        switch name.uppercased() {
        case "RT": self = .trigger(.right); return
        case "LT": self = .trigger(.left); return
        default: break
        }
        if let item = PadItem(name: name) { self = .item(item); return }
        if let v = PadHat.value(named: name.uppercased()), v != 0 { self = .hat(v); return }
        return nil
    }

    var name: String {
        switch self {
        case .trigger(let t): return t == .left ? "LT" : "RT"
        case .item(let i): return i.name
        case .hat(let v): return "hat " + PadHat.name(v)
        }
    }

    var isTrigger: Bool { if case .trigger = self { return true } else { return false } }

    /// The pad items it presses (a trigger presses none).
    var padItems: Set<PadItem> {
        switch self {
        case .trigger: return []
        case .item(let i): return [i]
        case .hat(let v): return PadHat.items(v)
        }
    }

    /// Triggers count as held from `minLevel` up; everything else is a bit or the hat.
    func isHeld(_ s: PadDecodedState, minLevel: Double) -> Bool {
        switch self {
        case .trigger(let t): return s.value(of: t) >= minLevel
        case .item(let i): return s.items.contains(i)
        case .hat(let v): return s.hat == v
        }
    }
}

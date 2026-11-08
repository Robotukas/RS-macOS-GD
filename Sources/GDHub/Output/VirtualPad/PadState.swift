import Foundation

/// Gamepad buttons in XInput terms (design §5.4). The Xbox "Menu" button is Start, "View" is Back.
struct PadButtons: OptionSet, Equatable {
    let rawValue: UInt16
    static let a = PadButtons(rawValue: 1 << 0)
    static let b = PadButtons(rawValue: 1 << 1)
    static let x = PadButtons(rawValue: 1 << 2)
    static let y = PadButtons(rawValue: 1 << 3)
    static let lb = PadButtons(rawValue: 1 << 4)
    static let rb = PadButtons(rawValue: 1 << 5)
    static let view = PadButtons(rawValue: 1 << 6)
    static let menu = PadButtons(rawValue: 1 << 7)
    static let ls = PadButtons(rawValue: 1 << 8)
    static let rs = PadButtons(rawValue: 1 << 9)
    static let guide = PadButtons(rawValue: 1 << 10)
    static let share = PadButtons(rawValue: 1 << 11)
    static let dpadUp = PadButtons(rawValue: 1 << 12)
    static let dpadDown = PadButtons(rawValue: 1 << 13)
    static let dpadLeft = PadButtons(rawValue: 1 << 14)
    static let dpadRight = PadButtons(rawValue: 1 << 15)
}

/// Device-independent pad state. Sticks -1...1 with y up = +1, triggers 0...1.
struct PadState: Equatable {
    var buttons: PadButtons = []
    var lx = 0.0, ly = 0.0, rx = 0.0, ry = 0.0
    var lt = 0.0, rt = 0.0
    static let neutral = PadState()
}

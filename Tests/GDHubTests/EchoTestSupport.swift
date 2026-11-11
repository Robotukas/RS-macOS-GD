import Foundation
@testable import GDHub

/// A small model of the controller for the echo tests (docs/plans/remap-step2-plan.md, "Tests", V1-V27): the real
/// inputs and the six keys go in, the controller adds each held key's echo to the real items (buttons ORed, each D-pad
/// axis combined with opposite directions cancelling) and sends one report; `EchoState` cleans it. Mirrors `simulate` in
/// `scripts/tools/echo_rule.py`.
enum EchoSim {
    static let keyNames = ["OR", "IR", "IL", "OL", "SL", "SR"]
    static let up: UInt16 = 1 << 10, right: UInt16 = 1 << 11, down: UInt16 = 1 << 12, left: UInt16 = 1 << 13
    /// What the controller adds for each key in the factory profile.
    static let factoryEchoes: [UInt16] = [right, down, up, left, 1 << 0, 1 << 1]
    static let itemTokens: [String: UInt16] = ["A": 1 << 0, "B": 1 << 1, "X": 1 << 2, "Y": 1 << 3, "LB": 1 << 4, "RB": 1 << 5,
                                               "View": 1 << 6, "Menu": 1 << 7, "L3": 1 << 8, "R3": 1 << 9,
                                               "up": up, "right": right, "down": down, "left": left]
    static let buttonNames = ["A", "B", "X", "Y", "LB", "RB", "View", "Menu", "L3", "R3"]

    struct Row {
        let rep: String
        let real: UInt16, keys: UInt8
        let buttons: UInt32, hat: UInt8, extra: UInt16
        let word: UInt32
        let pad: UInt16, ideal: UInt16, hold: UInt16
        let state: [UInt8]
        /// A pad item outside the union of the ideal items since the report before the hold began.
        var ghost: Bool { keys != 0 && pad & ~hold != 0 }
    }

    /// The hat as the pad shows it for an item word: opposite directions cancelled.
    static func padItems(_ items: UInt16) -> UInt16 {
        (items & 0x3FF) | EchoFilter.hatItems[Int(EchoFilter.itemsHat[Int((items >> 10) & 15)])] << 10
    }

    static func hatOf(_ items: UInt16) -> UInt8 { UInt8(EchoFilter.itemsHat[Int((items >> 10) & 15)]) }

    /// "A+X+hat:UL", "hat:." : the buttons, then the hat as letters.
    static func text(_ items: UInt16) -> String {
        let names = (0..<10).filter { items >> UInt16($0) & 1 == 1 }.map { buttonNames[$0] }
        let h = Int(hatOf(items))
        let hat = h >= 8 ? "." : ["U", "UR", "R", "DR", "D", "DL", "L", "UL"][h]
        return (names + ["hat:" + hat]).joined(separator: "+")
    }

    static func hatText(_ items: UInt16) -> String { String(text(items).split(separator: ":").last ?? "") }

    static func controller(real: UInt16, keys: UInt8, echoes: [UInt16]) -> (buttons: UInt32, hat: UInt8, extra: UInt16) {
        var s = real
        for k in 0..<6 where keys >> UInt8(k) & 1 == 1 { s |= echoes[k] }
        return (UInt32(s & 0x3FF), hatOf(s), UInt16(keys))
    }

    /// Runs a script: each string is a report of tokens, '+A' / '-A' real items, '+OR' / '-OR' keys, 'reset' (a full reset of
    /// the state before that report), 'E=OR:Y' (the controller now adds Y for that key), '.' nothing. A rest report comes first.
    /// `hidden` names the keys in the hide mask, `stored` the stored item codes.
    static func run(_ script: [String], hidden: [String], stored: [UInt8] = EchoParams.factoryItems,
                    echoes: [UInt16] = factoryEchoes, keepResets: Bool = false) -> [Row] {
        var mask: UInt8 = 0
        for h in hidden { mask |= 1 << UInt8(keyNames.firstIndex(of: h)!) }
        return run(script, params: EchoParams(hideMask: mask, items: stored), echoes: echoes, keepResets: keepResets)
    }

    static func run(_ script: [String], params: EchoParams, echoes: [UInt16] = factoryEchoes, keepResets: Bool = false) -> [Row] {
        var state = EchoState()
        var echoes = echoes
        var real: UInt16 = 0, keys: UInt8 = 0, hold: UInt16 = 0, prevIdeal: UInt16 = 0
        var rows: [Row] = []
        for rep in ["rest"] + script {
            for t in rep.split(separator: " ").map(String.init) {
                if t == "." || t == "rest" { continue }
                if t == "reset" { if !keepResets { state.reset() }; continue }
                if t.hasPrefix("E=") {
                    let parts = t.dropFirst(2).split(separator: ":").map(String.init)
                    echoes[keyNames.firstIndex(of: parts[0])!] = itemTokens[parts[1]]!
                    continue
                }
                let on = t.hasPrefix("+"), name = String(t.dropFirst())
                if let k = keyNames.firstIndex(of: name) {
                    if on { keys |= 1 << UInt8(k) } else { keys &= ~(1 << UInt8(k)) }
                } else if let m = itemTokens[name] {
                    if on { real |= m } else { real &= ~m }
                } else { fatalError("unknown token \(t)") }
            }
            let c = controller(real: real, keys: keys, echoes: echoes)
            let w = state.step(params, buttons: c.buttons, hat: c.hat, extra: c.extra)
            let pad = padItems(EchoFilter.items(word: w, buttons: c.buttons, hat: c.hat))
            var idealRaw = real
            for k in 0..<6 where keys >> UInt8(k) & 1 == 1 && params.hideMask >> UInt8(k) & 1 == 0 { idealRaw |= echoes[k] }
            if keys & params.hideMask == 0 { hold = idealRaw }
            else if let last = rows.last, last.keys & params.hideMask == 0 { hold = prevIdeal | idealRaw }
            else { hold |= idealRaw }
            prevIdeal = idealRaw
            rows.append(Row(rep: rep, real: real, keys: keys & params.hideMask, buttons: c.buttons, hat: c.hat, extra: c.extra, word: w,
                            pad: pad, ideal: padItems(idealRaw), hold: hold, state: state.bytes))
        }
        return rows
    }

    /// The pad of every report after the rest.
    static func pads(_ rows: [Row]) -> [String] { rows.dropFirst().map { text($0.pad) } }
    static func hats(_ rows: [Row]) -> [String] { rows.dropFirst().map { hatText($0.pad) } }

    /// A 16-byte report 0x06 with the given buttons, hat, extra bits and a marker in every field the rule never touches.
    static func report(buttons: UInt32, hat: UInt8, extra: UInt16, sticks: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8],
                       triggers: UInt32 = 0) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 16)
        r[0] = 6
        for (i, v) in sticks.enumerated() where i < 8 { r[1 + i] = v }
        let trig = (triggers & 0xFFFFF) | UInt32(hat & 15) << 20
        r[9] = UInt8(trig & 0xFF); r[10] = UInt8((trig >> 8) & 0xFF); r[11] = UInt8((trig >> 16) & 0xFF)
        let word = (buttons & 0x7FFFF) | UInt32(extra & 0x1FFF) << 19
        r[12] = UInt8(word & 0xFF); r[13] = UInt8((word >> 8) & 0xFF); r[14] = UInt8((word >> 16) & 0xFF); r[15] = UInt8((word >> 24) & 0xFF)
        return r
    }

    /// 16 hex bytes ("06 00 ...") to a report.
    static func bytes(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }
}

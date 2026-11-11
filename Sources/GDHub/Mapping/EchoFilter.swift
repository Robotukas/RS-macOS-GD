import Foundation

/// The rule that hides the controller's own button for a remapped paddle or SAX key (the "echo"), remap step 2
/// (docs/plans/remap-step2-plan.md, "Translators: hiding the echo"). The Python oracle `scripts/tools/echo_rule.py` is
/// the reference of this file; the tests replay both over the same sequences and over the survey fixture.
///
/// Pure: integer work only, no allocation per report, no AppKit, no dependence on `ControlMapping` (tests build
/// `EchoParams` directly; `ControlMapping.echoParams` will return the same value). Not wired into anything yet.
///
/// Items, a 14-bit word: bits 0..9 are receiver buttons 1..10 (A B X Y LB RB View Menu L3 R3), bits 10..13 are
/// D-pad up, right, down, left. An item code c in 1...14 names bit c - 1; 0 is none. Keys, by their extra bit: 0 paddle
/// outer right, 1 inner right, 2 inner left, 3 outer left, 4 SAX left, 5 SAX right.

/// The hide mask and the stored item of each key in it: the only input of the rule.
struct EchoParams: Equatable {
    /// Bit k set: extra bit k (a paddle or SAX key) is remapped, so the button the controller adds for it is hidden.
    let hideMask: UInt8
    /// The stored item (a code, 1...14) of each of the six keys: never 0 for a key in `hideMask`, 0 for a key outside it.
    let items: [UInt8]

    /// The codes of the factory bindings: paddle outer right D-pad right, inner right down, inner left up, outer left
    /// left, SAX left A, SAX right B.
    static let factoryItems: [UInt8] = [12, 13, 11, 14, 1, 2]

    /// `items` shorter than six are padded with 0. A key in the mask whose code is 0 or above 14 gets its factory item,
    /// a key outside the mask gets 0, so equal parameters compare equal and a key in the mask always covers something.
    init(hideMask: UInt8, items: [UInt8] = EchoParams.factoryItems) {
        let mask = hideMask & 0x3F
        var out = [UInt8](repeating: 0, count: 6)
        for k in 0..<6 where (mask >> UInt8(k)) & 1 == 1 {
            let c = k < items.count ? items[k] : 0
            out[k] = (1...14).contains(c) ? c : EchoParams.factoryItems[k]
        }
        self.hideMask = mask
        self.items = out
    }

    /// Nothing hidden: every report passes unchanged.
    static let none = EchoParams(hideMask: 0)
    /// The factory stored items with the given keys hidden.
    static func factory(hideMask: UInt8) -> EchoParams { EchoParams(hideMask: hideMask) }
}

/// 16 bytes of state, all zero when fresh. It matters only while a remapped key is held: with none held, the state is
/// exactly what a fresh one gets from the report (`cur` cleared on the report a hold ends).
struct EchoState: Equatable {
    /// The cleaned items of the last report (both directions of an axis may be set).
    var est: UInt16 = 0
    /// The raw items of the last report.
    var prev: UInt16 = 0
    /// The remapped keys down in the last report.
    var held: UInt8 = 0
    /// All six key bits of the last report.
    var six: UInt8 = 0
    /// The held keys whose stored item was seen or confirmed at their press.
    var known: UInt8 = 0
    /// Bit 0 VALID (`prev` and `six` hold a report), bit 1 ARMED (a report with no remapped key held was seen since the reset).
    var flags: UInt8 = 0
    /// The item code read for each held key, one byte each (the stored item, or the other item its press showed):
    /// bytes 0..5 of this word are `cur[0]...cur[5]`, bytes 6 and 7 are the two zero pad bytes.
    var cur: UInt64 = 0

    static let valid: UInt8 = 1
    static let armed: UInt8 = 2

    /// Back to the fresh state (what a full `gdx_reset` does to the echo state).
    mutating func reset() { self = EchoState() }

    /// The 16 bytes: est, prev (little endian), held, six, known, flags, cur[6], pad[2].
    var bytes: [UInt8] {
        var b: [UInt8] = [UInt8(est & 0xFF), UInt8(est >> 8), UInt8(prev & 0xFF), UInt8(prev >> 8), held, six, known, flags]
        for i in 0..<8 { b.append(UInt8((cur >> UInt64(8 * i)) & 0xFF)) }
        return b
    }

    fileprivate func code(_ k: Int) -> UInt16 { UInt16((cur >> UInt64(8 * k)) & 0xFF) }
    fileprivate mutating func setCode(_ k: Int, _ c: UInt16) {
        let shift = UInt64(8 * k)
        cur = (cur & ~(0xFF << shift)) | (UInt64(c) << shift)
    }

    /// One report through the rule. `buttons` holds the receiver buttons (bits 0..9 are buttons 1..10), `hat` the hat
    /// value (0 up ... 7 up-left, 8..15 none), `extra` the extra bits (bits 0..5 the six keys). Returns the word
    /// (see `EchoFilter`): 0 means the report passes unchanged.
    mutating func step(_ params: EchoParams, buttons: UInt32, hat: UInt8, extra: UInt16) -> UInt32 {
        let obs = UInt16(buttons & 0x3FF) | EchoFilter.hatItems[Int(hat & 15)] << 10
        let six = UInt8(extra & 0x3F)
        let heldNow = six & params.hideMask
        if heldNow == 0 {                                                           // unchanged
            if held != 0 { cur = 0 }                                                // a hold ended
            est = obs; prev = obs
            self.six = six; held = 0; known = 0
            flags = EchoState.valid | EchoState.armed
            return 0
        }
        var word: UInt32 = 0
        let pressed = heldNow & ~held
        if pressed != 0 {
            var mp: UInt16 = 0                                                       // what the keys add, as stored
            let carried = heldNow & ~pressed & known
            for j in 0..<6 where ((carried | pressed) >> UInt8(j)) & 1 == 1 { mp |= EchoFilter.mask(params.items[j]) }
            let single = flags & EchoState.valid != 0 && (six ^ self.six).nonzeroBitCount == 1
            let c: UInt16 = single ? EchoFilter.changed(prev, obs) : 0
            for k in 0..<6 where (pressed >> UInt8(k)) & 1 == 1 {
                let s = EchoFilter.mask(params.items[k])
                if !EchoFilter.on(s, in: prev) && c.nonzeroBitCount == 1 {           // the press shows one item
                    setCode(k, UInt16(c.trailingZeroBitCount + 1))
                    if c == s { known |= 1 << UInt8(k) } else { word |= EchoFilter.wordOther }
                    continue
                }
                setCode(k, UInt16(params.items[k]))                                  // the stored item stands
                var ok = obs & s != 0
                if !ok && s & 0x3FF == 0 {
                    let (p, n) = EchoFilter.axis(of: s)
                    ok = EchoFilter.axisValue(obs, p, n) == EchoFilter.axisValue(est | mp, p, n)
                }
                if ok { known |= 1 << UInt8(k) } else { word |= EchoFilter.wordUnconfirmed }
            }
        }
        known &= heldNow
        var covered: UInt16 = 0, sure: UInt16 = 0                                    // M and MI
        for k in 0..<6 where (heldNow >> UInt8(k)) & 1 == 1 {
            let s = EchoFilter.mask(params.items[k])
            covered |= s | EchoFilter.mask(UInt8(code(k)))
            if (known >> UInt8(k)) & 1 == 1 { sure |= s }
        }
        var out = (obs & 0x3FF & ~covered) | (est & 0x3FF & covered)                  // a covered button keeps its value
        for (p, n) in EchoFilter.axes {
            let pm = UInt16(1) << p, nm = UInt16(1) << n
            let hp = covered & pm != 0, hn = covered & nm != 0
            if !hp && !hn {
                out |= obs & (pm | nm)                                                // nothing covered: as reported
            } else if hp && hn {
                out |= est & (pm | nm)                                                // the axis is frozen
            } else {
                let a = hp ? pm : nm, b = hp ? nm : pm                                // a covered, b the other
                out |= est & a                                                        // a keeps its value
                if obs & b != 0 || (obs & a == 0 && sure & a != 0) {                  // "none" under a seen or confirmed a
                    out |= b
                    if obs & b == 0 { word |= EchoFilter.wordRecovered }
                }
            }
        }
        est = out; prev = obs; held = heldNow; self.six = six
        flags |= EchoState.valid
        let armedBit: UInt32 = flags & EchoState.armed != 0 ? EchoFilter.wordArmed : 0
        return word | EchoFilter.wordApplied | armedBit | UInt32(heldNow) << 16
            | EchoFilter.itemsHat[Int((out >> 10) & 15)] << 10 | UInt32(out & 0x3FF)
    }

    /// One 16-byte report 0x06 through the rule; anything else (a bad frame) passes unchanged: word 0, state untouched.
    mutating func step(_ params: EchoParams, report: [UInt8]) -> UInt32 {
        guard let f = EchoFilter.fields(report) else { return 0 }
        return step(params, buttons: f.buttons, hat: f.hat, extra: f.extra)
    }
}

/// Words, tables and the pure parts of the rule.
///
/// The word (u32): bits 0..9 the cleaned receiver buttons 1..10; bits 10..13 the cleaned hat (0..8); bits 16..21 the
/// remapped keys held; bit 24 RECOVERED (the pad shows a direction the report does not); bit 25 OTHER (a press showed
/// another item than the stored one; both are covered); bit 26 UNCONFIRMED (a press whose stored item was neither seen
/// nor agreed with by the report); bit 27 ARMED; bit 31 APPLIED. Bits 25 and 26 mark the press report only. A word of 0
/// means the report passes unchanged.
enum EchoFilter {
    static let wordRecovered: UInt32 = 1 << 24
    static let wordOther: UInt32 = 1 << 25
    static let wordUnconfirmed: UInt32 = 1 << 26
    static let wordArmed: UInt32 = 1 << 27
    static let wordApplied: UInt32 = 1 << 31
    /// What a repeated report may differ in: the press flags mark the press report only.
    static let pressFlags: UInt32 = wordOther | wordUnconfirmed

    /// Receiver hat -> direction bits (up 1, right 2, down 4, left 8 in the high four bits of the item word).
    static let hatItems: [UInt16] = [1, 3, 2, 6, 4, 12, 8, 9, 0, 0, 0, 0, 0, 0, 0, 0]
    /// Direction bits -> receiver hat, opposite directions cancelling as the controller does.
    static let itemsHat: [UInt32] = [8, 0, 2, 1, 4, 8, 3, 2, 6, 7, 8, 0, 5, 6, 4, 8]
    /// (positive, negative) item bit of the two axes: up/down, right/left.
    static let axes: [(UInt16, UInt16)] = [(10, 12), (11, 13)]

    /// The one-item mask of an item code (0 for none).
    static func mask(_ code: UInt8) -> UInt16 { code == 0 || code > 14 ? 0 : UInt16(1) << UInt16(code - 1) }

    static func axisValue(_ items: UInt16, _ p: UInt16, _ n: UInt16) -> Int {
        (items >> p & 1 == 1 ? 1 : 0) - (items >> n & 1 == 1 ? 1 : 0)
    }

    /// The axis a direction item belongs to.
    static func axis(of s: UInt16) -> (UInt16, UInt16) { s & (1 << 10 | 1 << 12) != 0 ? axes[0] : axes[1] }

    /// Item s (one item) is on in a raw report: a button by its bit, a direction when the axis reads s's direction.
    static func on(_ s: UInt16, in items: UInt16) -> Bool {
        if s & 0x3FF != 0 { return items & s != 0 }
        let (p, n) = axis(of: s)
        return axisValue(items, p, n) == (s == 1 << p ? 1 : -1)
    }

    /// What one press changed: the buttons 1..10 that came on, plus per axis the direction p when the axis went from 0
    /// to p, from n to 0 or straight from n to p, and n when it went from 0 to n, from p to 0 or straight from p to n.
    /// A release is read backwards: `changed(report, reportBefore)`.
    static func changed(_ prev: UInt16, _ obs: UInt16) -> UInt16 {
        var c = obs & ~prev & 0x3FF
        for (p, n) in axes {
            let v0 = axisValue(prev, p, n), v1 = axisValue(obs, p, n)
            if (v0 == 0 && v1 == 1) || (v0 == -1 && v1 == 0) || (v0 == -1 && v1 == 1) { c |= 1 << p }
            else if (v0 == 0 && v1 == -1) || (v0 == 1 && v1 == 0) || (v0 == 1 && v1 == -1) { c |= 1 << n }
        }
        return c
    }

    /// buttons (19 bits), hat and the 13 extra bits of a 16-byte report 0x06; nil for anything else.
    static func fields(_ r: [UInt8]) -> (buttons: UInt32, hat: UInt8, extra: UInt16)? {
        guard r.count == 16, r[0] == 6 else { return nil }
        let word = UInt32(r[12]) | UInt32(r[13]) << 8 | UInt32(r[14]) << 16 | UInt32(r[15]) << 24
        return (word & 0x7FFFF, r[11] >> 4, UInt16((word >> 19) & 0x1FFF))
    }

    /// The items a word gives for a report (the report's own when the word is 0).
    static func items(word: UInt32, buttons: UInt32, hat: UInt8) -> UInt16 {
        if word == 0 { return UInt16(buttons & 0x3FF) | hatItems[Int(hat & 15)] << 10 }
        return UInt16(word & 0x3FF) | hatItems[Int((word >> 10) & 15)] << 10
    }

    /// With bit 31 set: receiver buttons 1..10 (byte 12 and bits 0-1 of byte 13) := word bits 0..9 and the hat nibble (the
    /// high nibble of byte 11) := word bits 10..13. Nothing else changes: the extra bits stay (the remapped key's own rule
    /// still fires), triggers, sticks, Start, G1-G5, Profile and buttons 18-19 are never touched. A word of 0, or a report
    /// that is not 16 bytes, gives the bytes unchanged.
    static func apply(_ word: UInt32, to report: [UInt8]) -> [UInt8] {
        guard word & wordApplied != 0, report.count == 16 else { return report }
        var out = report
        out[12] = UInt8(word & 0xFF)
        out[13] = (report[13] & 0xFC) | UInt8((word >> 8) & 3)
        out[11] = (report[11] & 0x0F) | UInt8(((word >> 10) & 0xF) << 4)
        return out
    }
}

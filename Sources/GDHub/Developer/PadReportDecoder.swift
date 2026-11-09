import Foundation
#if canImport(GDHubXlate)
import GDHubXlate
#endif

/// One named output item of the virtual pad, numbered exactly like the `GDX_ITEM_*` constants (0 A … 10 Guide,
/// 11…14 D-pad U/R/D/L). The decoder, the expectation and the judge all speak in these, so a pad state can be compared
/// with an expectation without caring which report carried what.
enum PadItem: Int, CaseIterable, Codable, Comparable {
    case a, b, x, y, lb, rb, view, menu, ls, rs, guide, dpadUp, dpadRight, dpadDown, dpadLeft

    static func < (l: PadItem, r: PadItem) -> Bool { l.rawValue < r.rawValue }

    /// The face, shoulder and stick-click buttons: the items that are a plain bit of report 0x01.
    static let buttonItems: [PadItem] = [.a, .b, .x, .y, .lb, .rb, .view, .menu, .ls, .rs]
    static let dpadItems: [PadItem] = [.dpadUp, .dpadRight, .dpadDown, .dpadLeft]

    /// Names as they appear in templates, reports and the UI.
    var name: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .lb: return "LB"
        case .rb: return "RB"
        case .view: return "View"
        case .menu: return "Menu"
        case .ls: return "LS"
        case .rs: return "RS"
        case .guide: return "Guide"
        case .dpadUp: return "D-pad up"
        case .dpadRight: return "D-pad right"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        }
    }

    init?(name: String) {
        guard let item = PadItem.allCases.first(where: { $0.name == name }) else { return nil }
        self = item
    }

    /// The layout control that draws this output item (`MapBlobEncoder.buttonControls` is in item order), or nil for
    /// Guide: the Start control feeds it, but no control is "the Guide button".
    var layoutControlID: String? {
        self == .guide ? nil : MapBlobEncoder.buttonControls[rawValue]
    }
}

/// The hat switch of report 0x01: 0 none, 1 N, 2 NE … 8 NW (`PadReportBuilders.hat`).
enum PadHat {
    static let names = ["none", "N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    private static let directions: [Set<PadItem>] = [
        [], [.dpadUp], [.dpadUp, .dpadRight], [.dpadRight], [.dpadRight, .dpadDown],
        [.dpadDown], [.dpadDown, .dpadLeft], [.dpadLeft], [.dpadLeft, .dpadUp],
    ]

    /// The D-pad items a hat value presses. Values outside 0…8 are what the descriptor calls "null state": none.
    static func items(_ hat: UInt8) -> Set<PadItem> { Int(hat) < directions.count ? directions[Int(hat)] : [] }

    /// The hat value for a set of D-pad items, or nil when no direction presses exactly those (opposites cancel in the
    /// builder, so they never come out of it).
    static func value(for items: Set<PadItem>) -> UInt8? {
        let dpad = items.intersection(PadItem.dpadItems)
        return directions.firstIndex(of: dpad).map { UInt8($0) }
    }

    static func name(_ hat: UInt8) -> String { Int(hat) < names.count ? names[Int(hat)] : "none" }
    static func value(named name: String) -> UInt8? { names.firstIndex(of: name).map { UInt8($0) } }
}

enum PadStick: String, Codable { case left, right }
enum PadTrigger: String, Codable { case left, right }

/// What the virtual pad currently holds, merged across report 0x01 and report 0x02. Sticks are in `PadState`'s
/// convention (right and up are positive), so a decoded builder output compares with the state that made it.
struct PadDecodedState: Equatable, Codable {
    var lx = 0.0, ly = 0.0, rx = 0.0, ry = 0.0
    var lt = 0.0, rt = 0.0
    /// A…RS only; Guide and the D-pad have their own fields.
    var buttons: Set<PadItem> = []
    /// 0 none, 1 N … 8 NW.
    var hat: UInt8 = 0
    var guide = false

    static let neutral = PadDecodedState()

    /// Every pressed item: the buttons, the D-pad directions the hat presses, and Guide.
    var items: Set<PadItem> {
        var s = buttons
        s.formUnion(PadHat.items(hat))
        if guide { s.insert(.guide) }
        return s
    }

    func position(of stick: PadStick) -> (x: Double, y: Double) {
        stick == .left ? (lx, ly) : (rx, ry)
    }

    func value(of trigger: PadTrigger) -> Double { trigger == .left ? lt : rt }

    /// Radial dead zone, like a game would apply it: a stick is inside when its deflection is at most `deadZone`.
    func isInside(_ stick: PadStick, deadZone: Double) -> Bool {
        let p = position(of: stick)
        return (p.x * p.x + p.y * p.y).squareRoot() <= deadZone
    }

    func sticksInside(deadZone: Double) -> Bool {
        isInside(.left, deadZone: deadZone) && isInside(.right, deadZone: deadZone)
    }

    func triggersBelow(_ triggerMax: Double) -> Bool { lt <= triggerMax && rt <= triggerMax }

    /// Nothing pressed and everything at rest within the tolerances. Buttons, the hat and Guide are exact.
    func isNeutral(deadZone: Double, triggerMax: Double) -> Bool {
        buttons.isEmpty && hat == 0 && !guide && sticksInside(deadZone: deadZone) && triggersBelow(triggerMax)
    }
}

/// Reads input reports of the virtual pad back into a `PadDecodedState`. Built from the same tables the C core and the
/// dext are built from (`MapBlobEncoder.xboxBT16Reports` / `xboxBT16Placements`), so there is no second table of
/// offsets that could drift from the first. The Swift builder `PadReportBuilders.xboxBT16` is independent of those
/// tables, which is what makes decoding its output a real test of them.
struct PadReportDecoder {
    let reports: [GDHMTable.Report]
    let placements: [GDHMTable.Placement]

    /// The decoder for both Xbox identities.
    static let xboxBT16 = PadReportDecoder(reports: MapBlobEncoder.xboxBT16Reports,
                                           placements: MapBlobEncoder.xboxBT16Placements)

    init(reports: [GDHMTable.Report], placements: [GDHMTable.Placement]) {
        self.reports = reports
        self.placements = placements
    }

    /// Folds one input report into `state`. `bytes` is the report as IOKit delivers it, ID byte first, which is also
    /// how the placements count their bit offsets. Returns whether anything in `state` changed; a report of another ID,
    /// or a short one, changes nothing.
    @discardableResult
    func apply(reportID: UInt8, bytes: [UInt8], to state: inout PadDecodedState) -> Bool {
        guard let index = reports.firstIndex(where: { $0.id == reportID }),
              bytes.count >= Int(reports[index].length), bytes.first == reportID else { return false }
        let before = state
        for p in placements where Int(p.reportIndex) == index {
            let raw = Self.bits(bytes, offset: Int(p.bitOffset), count: Int(p.bits))
            switch Int(p.encoding) {
            case Int(GDX_ENC_AXIS16), Int(GDX_ENC_AXIS16_NEG):
                let top = Double((UInt64(1) << UInt64(p.bits)) - 1)
                let v = Double(raw) / (top / 2) - 1
                let signed = Int(p.encoding) == Int(GDX_ENC_AXIS16_NEG) ? -v : v
                switch Int(p.item) {
                case Int(GDX_ITEM_LX): state.lx = signed
                case Int(GDX_ITEM_LY): state.ly = signed
                case Int(GDX_ITEM_RX): state.rx = signed
                case Int(GDX_ITEM_RY): state.ry = signed
                default: break
                }
            case Int(GDX_ENC_TRIG10_U16):
                // 10 significant bits in a 16-bit field: the high bits are padding and must not count.
                let v = min(Double(raw & 0x3FF) / 1023, 1)
                if Int(p.item) == Int(GDX_ITEM_LT) { state.lt = v } else if Int(p.item) == Int(GDX_ITEM_RT) { state.rt = v }
            case Int(GDX_ENC_HAT8):
                state.hat = raw <= 8 ? UInt8(raw) : 0
            case Int(GDX_ENC_BIT):
                guard let item = PadItem(rawValue: Int(p.item)) else { break }
                switch item {
                case .guide: state.guide = raw != 0
                case .dpadUp, .dpadRight, .dpadDown, .dpadLeft: break       // the hat carries these
                default:
                    if raw != 0 { state.buttons.insert(item) } else { state.buttons.remove(item) }
                }
            default:
                break
            }
        }
        return state != before
    }

    /// Little-endian bit field, bit 0 = least significant bit of byte 0 (the HID order).
    static func bits(_ bytes: [UInt8], offset: Int, count: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<count {
            let at = offset + i
            guard at / 8 < bytes.count else { break }
            if (bytes[at / 8] >> UInt8(at % 8)) & 1 == 1 { v |= UInt64(1) << UInt64(i) }
        }
        return v
    }
}

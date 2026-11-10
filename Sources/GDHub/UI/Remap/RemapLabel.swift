import Foundation

/// What a label pill shows: the control's label and, for a remapped control, an arrow and what it sends now ("G1 → Y").
struct RemapLabel: Equatable {
    /// How the layout is being shown.
    enum Mode: Equatable {
        case live
        case mapping
        /// Edit layout: always the plain label, so stored label geometry never depends on remaps.
        case editLayout
    }

    enum SuffixStyle: Equatable {
        /// Remapped to a pad button: orange.
        case remapped
        /// Remapped to Nothing: grey.
        case nothing
    }

    struct Suffix: Equatable {
        /// "→ Y"
        var text: String
        var style: SuffixStyle
    }

    /// The control's own label.
    var text: String
    var suffix: Suffix?

    /// "G1 → Y", or just the label; for accessibility.
    var fullText: String { suffix.map { "\(text) \($0.text)" } ?? text }

    var isRemapped: Bool { suffix != nil }

    init(label: String, id: String, mapping: ControlMapping, mode: Mode) {
        text = label
        suffix = nil
        guard mode != .editLayout, mapping.isRemapped(id) else { return }
        switch mapping.effectiveOutput(id) {
        case .pad(let p): suffix = Suffix(text: "→ \(p.shortName)", style: .remapped)
        case .nothing: suffix = Suffix(text: "→ Nothing", style: .nothing)
        case .builtIn: break      // the factory function of g2-g4: never stored as a remap
        }
    }
}

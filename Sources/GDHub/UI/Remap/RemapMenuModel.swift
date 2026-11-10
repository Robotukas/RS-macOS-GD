import Foundation

extension PadOutput {
    /// The name in the Mapping menu.
    var menuTitle: String {
        switch self {
        case .guide: return "Guide (Xbox button)"
        default: return shortName
        }
    }

    /// The short name after the arrow in a label ("G1 → Y"), as in the approved mockup.
    var shortName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .lb: return "LB"
        case .rb: return "RB"
        case .lt: return "LT"
        case .rt: return "RT"
        case .view: return "View"
        case .menu: return "Menu"
        case .l3: return "L3"
        case .r3: return "R3"
        case .guide: return "Guide"
        case .dpad_up: return "D-pad up"
        case .dpad_down: return "D-pad down"
        case .dpad_left: return "D-pad left"
        case .dpad_right: return "D-pad right"
        }
    }
}

/// What the click menu of one control shows (remap plan, "UI (R2)"; mockup v6). Pure: the native `NSMenu` is built from it
/// top to bottom as: header, note, the groups with a separator between them, the footnote, a separator, "Reset to
/// default", a separator, the re-learn item. Sticks and the controls that are not remappable yet get header, note, a
/// separator and the re-learn item only.
struct RemapMenuModel: Equatable {
    enum Kind: Equatable {
        /// One of `ControlMapping.remappableIDs`: the full menu.
        case remappable
        /// A stick: not remappable in this feature.
        case stick
        /// Paddles and SAX (step 2): they follow the pad button the controller's profile gives them.
        case deferred
    }

    struct Entry: Equatable, Identifiable {
        /// `output.string`: "y", "nothing", "built_in", "guide" (stable, for accessibility ids).
        var id: String { output.string }
        var title: String
        /// What picking this entry sets (`ControlMapping.setOutput`).
        var output: ControlOutput
        /// The tick: this is what the control sends now.
        var isCurrent: Bool
        /// The "default" tag: this is what the control sends if never touched.
        var isDefault: Bool
        /// Non-nil when picking this entry would make the mapping something the driver cannot do yet (the App drives the
        /// controller instead); the text is `MapBlobEncoder.remapLimit` of the result. Always nil when the current
        /// mapping already has such a limit (the footnote would say nothing new).
        var limit: String?
    }

    struct Reset: Equatable {
        var title: String
        var isEnabled: Bool
    }

    static let defaultTag = "default"
    /// The mark on an entry with a `limit`.
    static let limitTag = "App drives *"
    static let footnoteText = "* With this pick the App drives the controller until the next driver update."
    static let stickNote = "Sticks are not remappable in this feature."
    static let deferredNote = "Remapping paddles and SAX comes next. Until then this key sends the button the controller's profile gives it, and follows that button's remap."
    static let resetTitle = "Reset to default"

    var controlID: String
    var kind: Kind
    /// "<Label> sends"
    var header: String
    var note: String?
    /// Groups of entries; a separator between groups. Empty unless `kind == .remappable`.
    var groups: [[Entry]]
    /// Present when any entry has a `limit`.
    var footnote: String?
    /// nil for a control that has no remap.
    var reset: Reset?
    /// "Re-learn button…" or "Re-learn stick…".
    var relearnTitle: String

    var entries: [Entry] { groups.flatMap { $0 } }

    private static let padGroups: [[PadOutput]] = [
        [.a, .b, .x, .y],
        [.lb, .rb, .lt, .rt],
        [.view, .menu, .l3, .r3],
        [.dpad_up, .dpad_down, .dpad_left, .dpad_right],
        [.guide],
    ]

    private static let builtInTitles: [String: String] = [
        "g2": "Volume down (built in)", "g3": "Volume up (built in)", "g4": "Mute (built in)",
    ]

    private static let notes: [String: String] = [
        "g2": "Mapped: G2 no longer changes the volume.",
        "g3": "Mapped: G3 no longer changes the volume.",
        "g4": "Mapped: G4 no longer changes the volume.",
        "start": "Holding Start still switches the controller off.",
        "profile": "Each press also switches the controller's own profile, which changes what the paddles and SAX keys send.",
    ]

    /// - Parameters:
    ///   - label: the control's label as the layout shows it ("G1").
    ///   - kind: the control's layout kind; only `.stick` changes the wording ("Re-learn stick…").
    init(controlID id: String, label: String, kind layoutKind: ControlLayout.Kind, mapping: ControlMapping) {
        controlID = id
        header = "\(label) sends"
        relearnTitle = layoutKind == .stick ? "Re-learn stick…" : "Re-learn button…"
        guard ControlMapping.remappableIDs.contains(id) else {
            let isStick = layoutKind == .stick
            kind = isStick ? .stick : .deferred
            note = isStick ? Self.stickNote : Self.deferredNote
            groups = []
            footnote = nil
            reset = nil
            return
        }
        kind = .remappable
        note = Self.notes[id]
        let current = mapping.effectiveOutput(id)
        let fallback = mapping.defaultOutput(id)
        // The mockup marks a pick only while the mapping has no limit yet.
        let alreadyLimited = MapBlobEncoder.remapLimit(mapping) != nil

        func entry(_ title: String, _ output: ControlOutput) -> Entry {
            var limit: String?
            if !alreadyLimited, output != current {
                limit = MapBlobEncoder.remapLimit(Self.mapping(mapping, picking: output, for: id))
            }
            return Entry(title: title, output: output, isCurrent: output == current, isDefault: output == fallback, limit: limit)
        }

        var built: [[Entry]] = []
        if let title = Self.builtInTitles[id] { built.append([entry(title, .builtIn)]) }
        for group in Self.padGroups { built.append(group.map { entry($0.menuTitle, .pad($0)) }) }
        built.append([entry("Nothing", .nothing)])
        groups = built
        footnote = built.joined().contains { $0.limit != nil } ? Self.footnoteText : nil
        reset = Reset(title: Self.resetTitle, isEnabled: mapping.isRemapped(id))
    }

    /// The mapping after the pick (the same value `ControlMapping.setOutput` makes; a pick equal to the default clears the remap).
    static func mapping(_ mapping: ControlMapping, picking output: ControlOutput, for id: String) -> ControlMapping {
        var m = mapping
        m.setOutput(output, for: id)
        return m
    }

    /// The mapping after "Reset to default" for this control.
    static func mappingAfterReset(_ mapping: ControlMapping, for id: String) -> ControlMapping {
        var m = mapping
        m.outputs[id] = nil
        return m
    }
}

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

/// What the click menu of one control shows (remap plan, "UI (R2)"; mockups v6, v7 and v7b). Pure: the native `NSMenu` is
/// built from it top to bottom as: header, note, the conflict note, the groups with a separator between them, the
/// footnote, a separator, "Reset to default" (only while remapped) and a separator, the re-learn item. A stick gets header, note, a separator and
/// the re-learn item only.
struct RemapMenuModel: Equatable {
    enum Kind: Equatable {
        /// One of `ControlMapping.remappableIDs` (paddles and SAX keys included): the full menu.
        case remappable
        /// A stick: not remappable in this feature.
        case stick
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
        /// controller instead); the text is `MapBlobEncoder.remapLimitInWords` of the result. Always nil when the current
        /// mapping already has such a limit (the footnote would say nothing new).
        var limit: String?
    }

    /// The "Reset to default" item: present only while the control is remapped (nothing to reset, nothing shown).
    struct Reset: Equatable {
        var title: String
    }

    static let defaultTag = "default"
    /// The mark on an entry with a `limit`.
    static let limitTag = "App drives *"
    static let footnoteText = "* With this pick the App drives the controller until the next driver update."
    static let stickNote = "Sticks are not remappable in this feature."
    /// A paddle or SAX key left on "Controller's profile (built in)": mockup v7 (and v7b), word for word.
    static let controllersProfileNote = "Sends the button the controller's profile gives it, and follows that button's remap."
    /// A remapped paddle or SAX key: mockup v7b (`NOTE_RM`), word for word, approved on 11 November.
    static let remappedKeyNote = "Sends only your pick. The controller's own button for this key is hidden while you hold it, so pressing that same button yourself shows only when you let go."
    static let controllersProfileTitle = "Controller's profile (built in)"
    /// What a `built_in` requirement says about a control, next to the menu's own labels: a paddle or SAX key is "on
    /// Controller's profile" (the menu's "Controller's profile (built in)"), G2-G4 are "at their built-in function".
    static func builtInRequirement(for controlID: String) -> String {
        ControlMapping.echoKeyIDs.contains(controlID) ? "on Controller's profile" : "at its built-in function"
    }
    /// The Profile key's note, word for word (mockup v7b); the Developer-mode texts for the Profile step repeat it.
    static let profileNote = "Each press also switches the controller's own profile. Paddles and SAX keys left on Controller's profile change with it; remapped ones keep sending only your pick."
    static let resetTitle = "Reset to default"

    var controlID: String
    var kind: Kind
    /// "<Label> sends"
    var header: String
    var note: String?
    /// A remapped paddle or SAX key whose signal an old learn also gave to another control: "<Other> was learned with
    /// <Key>'s signal: re-learn <Other>." (a second note under the first, in the warning colour); nil otherwise.
    var conflictNote: String?
    /// Groups of entries; a separator between groups. Empty unless `kind == .remappable`.
    var groups: [[Entry]]
    /// Present when any entry has a `limit`.
    var footnote: String?
    /// nil unless the control is remapped.
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

    private static let builtInTitles: [String: String] = {
        var t = ["g2": "Volume down (built in)", "g3": "Volume up (built in)", "g4": "Mute (built in)"]
        for id in ControlMapping.echoKeyIDs { t[id] = controllersProfileTitle }
        return t
    }()

    private static let notes: [String: String] = [
        "g2": "Mapped: G2 no longer changes the volume.",
        "g3": "Mapped: G3 no longer changes the volume.",
        "g4": "Mapped: G4 no longer changes the volume.",
        "start": "Holding Start still switches the controller off.",
        "profile": profileNote,
    ]

    /// - Parameters:
    ///   - label: the control's label as the layout shows it ("G1").
    ///   - kind: the control's layout kind; only `.stick` changes the wording ("Re-learn stick…").
    ///   - labelOf: the layout label of any control, for the signal-conflict note (it names a control in words; the raw id
    ///     is only the fallback for a control the layout does not draw).
    init(controlID id: String, label: String, kind layoutKind: ControlLayout.Kind, mapping: ControlMapping,
         labelOf: (String) -> String = { $0 }) {
        controlID = id
        conflictNote = nil
        header = "\(label) sends"
        relearnTitle = layoutKind == .stick ? "Re-learn stick…" : "Re-learn button…"
        guard ControlMapping.remappableIDs.contains(id) else {
            // Only the sticks are left (every button is remappable); any other control that is not gets no menu text.
            kind = .stick
            note = layoutKind == .stick ? Self.stickNote : nil
            groups = []
            footnote = nil
            reset = nil
            return
        }
        kind = .remappable
        let current = mapping.effectiveOutput(id)
        let fallback = mapping.defaultOutput(id)
        // A paddle or SAX key: its note follows its pick; every other control has one fixed note, or none.
        note = ControlMapping.identityBits(id) != 0
            ? (current == .builtIn ? Self.controllersProfileNote : Self.remappedKeyNote)
            : Self.notes[id]
        conflictNote = mapping.signalConflict(forKey: id, label: labelOf)
        // The mockup marks a pick only while the mapping has no limit yet.
        let alreadyLimited = MapBlobEncoder.remapLimit(mapping) != nil

        func entry(_ title: String, _ output: ControlOutput) -> Entry {
            var limit: String?
            if !alreadyLimited, output != current {
                limit = MapBlobEncoder.remapLimitInWords(Self.mapping(mapping, picking: output, for: id))
            }
            return Entry(title: title, output: output, isCurrent: output == current, isDefault: output == fallback, limit: limit)
        }

        var built: [[Entry]] = []
        if let title = Self.builtInTitles[id] { built.append([entry(title, .builtIn)]) }
        for group in Self.padGroups { built.append(group.map { entry($0.menuTitle, .pad($0)) }) }
        built.append([entry("Nothing", .nothing)])
        groups = built
        footnote = built.joined().contains { $0.limit != nil } ? Self.footnoteText : nil
        reset = mapping.isRemapped(id) ? Reset(title: Self.resetTitle) : nil
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

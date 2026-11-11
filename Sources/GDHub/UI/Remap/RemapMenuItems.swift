import Foundation

/// What picking a menu item does.
enum RemapPick: Equatable {
    /// Make the control send this (`EnvisionProDevice.setOutput`).
    case output(ControlOutput)
    /// "Reset to default" for this control.
    case reset
    /// "Re-learn button…" / "Re-learn stick…": today's single-control learn.
    case relearn
}

/// One row of the native Mapping menu, in the order it is shown. Pure: `RemapMenuModel.itemSpecs` makes the list and
/// `RemapNSMenuBuilder` turns it into an `NSMenu`, so the order, the ticks, the tags and the enabled flags are tested
/// without a window.
struct RemapMenuItemSpec: Equatable {
    enum Kind: Equatable {
        /// "<Label> sends": a disabled item.
        case header
        /// A disabled, wrapped line of explanation under the header.
        case note
        /// A disabled, wrapped line in the warning colour under the note: an old learn gave another control this key's signal.
        case conflict
        /// A choice: `pick` is `.output`.
        case entry
        case separator
        /// "* With this pick the App drives the controller…": a disabled, wrapped line.
        case footnote
        case reset
        case relearn
    }

    var kind: Kind
    var title: String = ""
    /// Secondary text after the title: "default", "App drives *".
    var tags: [String] = []
    /// The tick (`NSMenuItem.state == .on`).
    var isOn = false
    var isEnabled = true
    var pick: RemapPick?
}

extension RemapMenuModel {
    /// The rows top to bottom: header, note, the conflict note, the groups with a separator between them, the footnote,
    /// then for a remappable control a separator, "Reset to default" (only while remapped) and a separator, then the
    /// re-learn item. A stick or a control that is not remappable yet gets header, note, a separator and the re-learn item.
    /// - Parameter relearnEnabled: `ModeGate.canLearn`.
    func itemSpecs(relearnEnabled: Bool = true) -> [RemapMenuItemSpec] {
        var out: [RemapMenuItemSpec] = [RemapMenuItemSpec(kind: .header, title: header, isEnabled: false)]
        if let note { out.append(RemapMenuItemSpec(kind: .note, title: note, isEnabled: false)) }
        if let conflictNote { out.append(RemapMenuItemSpec(kind: .conflict, title: conflictNote, isEnabled: false)) }
        for (i, group) in groups.enumerated() {
            if i > 0 { out.append(RemapMenuItemSpec(kind: .separator)) }
            for e in group {
                var tags: [String] = []
                if e.isDefault { tags.append(Self.defaultTag) }
                if e.limit != nil { tags.append(Self.limitTag) }
                out.append(RemapMenuItemSpec(kind: .entry, title: e.title, tags: tags, isOn: e.isCurrent, isEnabled: true,
                                             pick: .output(e.output)))
            }
        }
        if let footnote { out.append(RemapMenuItemSpec(kind: .footnote, title: footnote, isEnabled: false)) }
        out.append(RemapMenuItemSpec(kind: .separator))
        if let reset {
            out.append(RemapMenuItemSpec(kind: .reset, title: reset.title, pick: .reset))
            out.append(RemapMenuItemSpec(kind: .separator))
        }
        out.append(RemapMenuItemSpec(kind: .relearn, title: relearnTitle, isEnabled: relearnEnabled, pick: .relearn))
        return out
    }
}

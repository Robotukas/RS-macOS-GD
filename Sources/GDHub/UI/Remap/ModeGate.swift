import Foundation

/// Which modes may start and what a click on the drawing does (remap plan, "UI (R2)"). Pure: the device and the views
/// build one from their current state and ask it, so the rules live in one place and are tested as a table.
///
/// The rules, all of them "as today" except those that mention Mapping:
/// - **Mapping** is refused while the layout is being edited, while Developer mode is on, and in a display-only copy.
/// - **Edit layout** is refused while Developer mode is on (today's `beginEditingLayout`) and while Mapping is on.
///   A display-only copy may edit its layout (it did before).
/// - **Developer** is refused while the layout is being edited (today's `beginDeveloper`), while it is already on, and
///   while Mapping is on. A display-only copy can still open it (the session says why it cannot run).
/// - **Learn** (guided or single) is refused only while Developer mode is on (today's `beginLearn`) and in a display-only
///   copy. Editing, Mapping and a running learn do not matter: a learn that is running **keeps going** when Mapping begins
///   or ends (the device must not cancel it there); beginning Developer mode still cancels it, as today.
struct ModeGate: Equatable {
    enum Learning: Equatable { case none, single, guided }

    /// What was clicked.
    enum ClickTarget: Equatable { case label, hotspot }

    /// What the click does.
    enum ClickAction: Equatable {
        case none
        /// Edit layout: the label becomes (part of) the selection.
        case selectLabel
        /// Mapping: open the menu for the control, anchored at the thing that was clicked.
        case openMenu
        /// Live view: no learn and no menu; the toolbar hint flashes `RemapHint.flash`.
        case flashHint
    }

    var isEditing = false
    var devOn = false
    var remapping = false
    var learning: Learning = .none
    /// A display-only copy of the app (the engine belongs to another copy): it may not change what a button sends.
    var displayOnly = false

    // MARK: Which mode may begin

    var canBeginRemapping: Bool { !isEditing && !devOn && !displayOnly }

    /// Enabled state of the toolbar's Mapping button: it must stay usable to switch Mapping off ("Mapping ✓ Done").
    var mappingButtonEnabled: Bool { remapping || canBeginRemapping }

    var canBeginEditing: Bool { !devOn && !remapping }

    var canBeginDeveloper: Bool { !devOn && !isEditing && !remapping }

    /// A guided or single learn may start (and "Re-learn…" in the menu is enabled).
    var canLearn: Bool { !devOn && !displayOnly }

    /// Enabled state of "Learn all (guided)": today it is disabled only while a guided learn is running.
    var learnAllEnabled: Bool { canLearn && learning != .guided }

    // MARK: Clicks

    func clickAction(on target: ClickTarget) -> ClickAction {
        if devOn { return .none }
        if isEditing { return target == .label ? .selectLabel : .none }
        // A display-only copy can neither map nor learn: the "switch Mapping on" hint would send the user nowhere.
        if displayOnly { return .none }
        return remapping ? .openMenu : .flashHint
    }

    /// The callout layer takes clicks exactly when a click on a label does something (today: only while editing).
    var labelsHitTestable: Bool { clickAction(on: .label) != .none }
}

/// The toolbar hint line next to the Mapping button (the "Driven by: App (mapping needs a driver update: …)" line is
/// built by the caller from `limit(of:)`).
enum RemapHint {
    static let flash = "Switch Mapping on first (button on the left)."
    static let mappingOn = "Mapping: click a label or a button to choose what it sends."
    static let live = "Live view. Switch Mapping on to change what a button sends."

    /// `flashing`: a click in the live view happened a moment ago (only meaningful while Mapping is off).
    static func text(remapping: Bool, flashing: Bool) -> String {
        if remapping { return mappingOn }
        return flashing ? flash : live
    }

    /// What the driver cannot do for this mapping yet, or nil (`MapBlobEncoder.remapLimit`).
    static func limit(of mapping: ControlMapping) -> String? { MapBlobEncoder.remapLimit(mapping) }
}

import Foundation

/// The view tabs of the drawing: All / Front / Back / Sides. Raw values are what `@AppStorage` stores.
enum ViewTab: String, CaseIterable, Equatable {
    case all, front, back, sides

    var title: String {
        switch self {
        case .all: return "All"
        case .front: return "Front"
        case .back: return "Back"
        case .sides: return "Sides"
        }
    }

    /// Whether something other than the tab decides which views are shown: Edit layout (always All), a Developer run
    /// (its focused views, or All) and a guided Learn all (All). While true the picker is disabled; the saved tab is
    /// untouched and comes back afterwards.
    static func tabPickerEnabled(editing: Bool, devRunning: Bool, guidedLearn: Bool) -> Bool {
        !editing && !devRunning && !guidedLearn
    }

    /// The columns of views to draw, each column listing its views top to bottom (the type `ControlLayout.columns` has).
    /// - Edit layout: all views, in `allColumns` (the user's arrangement).
    /// - A Developer run: its focused views (`DevFocus.sides`), one column each; All when the focus is empty. Never the tab.
    /// - Guided Learn all: all views.
    /// - Otherwise the tab: All = `allColumns`, Front, Back, Sides = left side then right side.
    static func visibleColumns(tab: ViewTab, editing: Bool, devRunning: Bool, devFocus: [ControlLayout.Side],
                               guidedLearn: Bool,
                               allColumns: [[ControlLayout.Side]] = ControlLayout.defaultViewColumns) -> [[ControlLayout.Side]] {
        if editing || guidedLearn { return allColumns }
        if devRunning { return devFocus.isEmpty ? allColumns : devFocus.map { [$0] } }
        switch tab {
        case .all: return allColumns
        case .front: return [[.front]]
        case .back: return [[.back]]
        case .sides: return [[.sideLeft], [.sideRight]]
        }
    }
}

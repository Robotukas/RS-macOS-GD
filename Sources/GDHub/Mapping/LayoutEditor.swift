import SwiftUI

/// Edit-mode state for the callout layout: selection, measured pill sizes, drag origins and the
/// align actions the toolbar can trigger. Each view's callout layer registers an aligner for itself.
@MainActor
final class LayoutEditor: ObservableObject {
    enum AlignAction { case leftEdges, rightEdges, sameRow, distributeVertically }

    @Published var isEditing = false
    @Published var selection: Set<String> = []
    @Published var pillSizes: [String: CGSize] = [:]
    /// Magnification of the controller row while editing (1 = fit to window).
    @Published var zoom: Double = 1
    /// Keep leader segments horizontal / vertical while dragging corners.
    @Published var orthogonal = true
    /// Last pointer position per view (frame coordinates), for "Add corner here".
    var hoverPoint: [String: CGPoint] = [:]

    var dragOrigin: [String: CGPoint] = [:]
    var aligners: [String: (AlignAction) -> Void] = [:]

    func toggleSelection(_ id: String, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    func perform(_ action: AlignAction) {
        for aligner in aligners.values { aligner(action) }
    }
}

/// Collects the rendered size of every label pill so alignment can use real edges.
struct PillSizeKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}

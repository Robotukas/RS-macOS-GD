import SwiftUI

/// Edit-mode state for the callout layout: selection, measured pill sizes, drag origins and the
/// align actions the toolbar can trigger. Each view's callout layer registers an aligner for itself.
@MainActor
final class LayoutEditor: ObservableObject {
    enum AlignAction: CaseIterable {
        case leftEdges, rightEdges, centersHorizontal, topEdges, bottomEdges, sameRow, distributeVertically, distributeHorizontally

        var title: String {
            switch self {
            case .leftEdges: return "Left edges"
            case .rightEdges: return "Right edges"
            case .centersHorizontal: return "Centres (vertical line)"
            case .topEdges: return "Top edges"
            case .bottomEdges: return "Bottom edges"
            case .sameRow: return "Centres (same row)"
            case .distributeVertically: return "Distribute vertically"
            case .distributeHorizontally: return "Distribute horizontally"
            }
        }

        /// Cmd-Option-1 ... 8, in menu order (letters would collide with system shortcuts).
        var shortcutKey: KeyEquivalent {
            switch self {
            case .leftEdges: return "1"
            case .rightEdges: return "2"
            case .centersHorizontal: return "3"
            case .topEdges: return "4"
            case .bottomEdges: return "5"
            case .sameRow: return "6"
            case .distributeVertically: return "7"
            case .distributeHorizontally: return "8"
            }
        }

        /// Minimum number of selected labels the action makes sense for.
        var minimumSelection: Int {
            switch self {
            case .distributeVertically, .distributeHorizontally: return 3
            default: return 2
            }
        }
    }

    @Published var isEditing = false
    @Published var selection: Set<String> = []
    @Published var pillSizes: [String: CGSize] = [:]
    /// Every label pill's frame in the shared "grid" coordinate space (all views), for cross-view alignment.
    var pillFrames: [String: CGRect] = [:]
    /// Magnification of the controller row while editing (1 = fit to window).
    @Published var zoom: Double = 1
    /// Keep leader segments horizontal / vertical while dragging corners.
    @Published var orthogonal = true
    /// Last pointer position per view (frame coordinates), for "Add corner here".
    var hoverPoint: [String: CGPoint] = [:]

    var dragOrigin: [String: CGPoint] = [:]
    /// Label anchors while a drag is in progress (frame coordinates); committed to the layout on release.
    @Published var liveAnchors: [String: CGPoint] = [:]

    /// An align action to carry out. Each view's callout layer observes this and runs the action with
    /// its *current* geometry (a closure captured at registration would use stale sizes after zooming).
    struct AlignRequest: Equatable {
        let id: UUID
        let action: AlignAction
    }
    @Published var alignRequest: AlignRequest?
    /// Rubber-band selection in progress: which view it belongs to and its rectangle (frame coordinates).
    @Published var marquee: (view: String, rect: CGRect)?
    var marqueeStart: CGPoint?
    func toggleSelection(_ id: String, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    func perform(_ action: AlignAction) {
        alignRequest = AlignRequest(id: UUID(), action: action)
    }

    /// Align the selection, making sure the label the user right-clicked is part of it.
    func perform(_ action: AlignAction, including id: String) {
        selection.insert(id)
        perform(action)
    }
}

/// Collects the rendered frame (in the shared "grid" space) of every label pill so alignment can
/// use real edges, across views.
struct PillSizeKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

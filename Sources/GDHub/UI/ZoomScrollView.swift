import SwiftUI
import AppKit

/// Scrollable container for the controller row in edit mode. Mouse-wheel scrolling (and pinch, and
/// Cmd + any scroll) zooms toward the pointer so the point under the cursor stays where it is;
/// trackpad two-finger scrolling pans as usual.
struct ZoomScrollView<Content: View>: NSViewRepresentable {
    @ObservedObject var editor: LayoutEditor
    let contentSize: CGSize
    let content: Content

    static var zoomRange: ClosedRange<Double> { 1...4 }

    final class Coordinator {
        /// Set when a zoom was requested from the wheel; consumed on the next layout to keep the anchor fixed.
        var pending: (docPoint: CGPoint, offsetInView: CGPoint, oldZoom: Double)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WheelZoomScrollView {
        let sv = WheelZoomScrollView()
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.allowsMagnification = false
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: contentSize)
        sv.documentView = host
        sv.onZoom = { [weak sv] factor, locationInWindow in
            guard let sv else { return }
            let old = editor.zoom
            let new = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, old * factor))
            guard new != old else { return }
            let clip = sv.contentView
            let docPoint = clip.convert(locationInWindow, from: nil)
            let offset = CGPoint(x: docPoint.x - clip.bounds.origin.x, y: docPoint.y - clip.bounds.origin.y)
            context.coordinator.pending = (docPoint, offset, old)
            editor.zoom = new
        }
        return sv
    }

    func updateNSView(_ sv: WheelZoomScrollView, context: Context) {
        guard let host = sv.documentView as? NSHostingView<Content> else { return }
        host.rootView = content
        if host.frame.size != contentSize { host.frame.size = contentSize }
        if let p = context.coordinator.pending {
            context.coordinator.pending = nil
            let ratio = editor.zoom / p.oldZoom
            let clip = sv.contentView
            var origin = CGPoint(x: p.docPoint.x * ratio - p.offsetInView.x, y: p.docPoint.y * ratio - p.offsetInView.y)
            origin.x = max(0, min(origin.x, contentSize.width - clip.bounds.width))
            origin.y = max(0, min(origin.y, contentSize.height - clip.bounds.height))
            clip.scroll(to: origin)
            sv.reflectScrolledClipView(clip)
        }
    }
}

final class WheelZoomScrollView: NSScrollView {
    /// (zoom factor to multiply by, pointer location in window coordinates)
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let wantsZoom = !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.command)
        guard wantsZoom, let onZoom else { super.scrollWheel(with: event); return }
        // Mouse wheel notches are coarse; trackpad (with Cmd) deltas are fine-grained.
        let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.12
        let factor = exp(event.scrollingDeltaY * step)
        onZoom(factor, event.locationInWindow)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification, event.locationInWindow)
    }
}

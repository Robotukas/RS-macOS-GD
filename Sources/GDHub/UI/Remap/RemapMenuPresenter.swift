import SwiftUI
import AppKit
import os

/// Colours of the Mapping UI, from the approved mockup (v6).
enum RemapColors {
    /// `--accent`: a remapped label's border and "→ Y".
    static let accent = Color(red: 1.0, green: 138.0 / 255, blue: 31.0 / 255)
    /// `--accent-soft`: the fill of a remapped label.
    static let accentSoft = Color(red: 58.0 / 255, green: 42.0 / 255, blue: 23.0 / 255)
    /// `--off`: the arrow of "→ Nothing".
    static let off = Color(red: 138.0 / 255, green: 138.0 / 255, blue: 148.0 / 255)
    /// The dashed border every label gets while Mapping is on.
    static let mappingBorder = Color(red: 109.0 / 255, green: 143.0 / 255, blue: 196.0 / 255)
    /// `--warn`: the conflict note in a menu and the conflict hint line in the toolbar (mockup v7b).
    static let warning = Color(red: 232.0 / 255, green: 179.0 / 255, blue: 57.0 / 255)
    /// `--new`: the outline on the label and button whose menu is open.
    static let selection = Color(red: 76.0 / 255, green: 157.0 / 255, blue: 1.0)
    /// `.hint.flash`.
    static let flash = Color(red: 1.0, green: 217.0 / 255, blue: 138.0 / 255)
}

/// A small invisible `NSView` placed in each drawn view. The menu pops up from it, so it opens AT the clicked button or
/// label (decision 3). It is flipped (its coordinates run down like SwiftUI's) and never takes a click.
final class RemapAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}

private final class WeakAnchor {
    weak var view: RemapAnchorView?
    init(_ view: RemapAnchorView) { self.view = view }
}

/// The anchor of one drawn view, as SwiftUI sees it.
struct RemapAnchor: NSViewRepresentable {
    let presenter: RemapMenuPresenter
    let side: ControlLayout.Side

    func makeNSView(context: Context) -> RemapAnchorView {
        let v = RemapAnchorView()
        presenter.register(v, side: side)
        return v
    }

    func updateNSView(_ nsView: RemapAnchorView, context: Context) {
        presenter.register(nsView, side: side)
    }
}

/// Target of every item of one popped menu. Kept alive by the presenter until `popUp` returns.
@MainActor
final class RemapMenuTarget: NSObject {
    private let handler: (RemapPick) -> Void
    init(_ handler: @escaping (RemapPick) -> Void) { self.handler = handler }

    @objc func choose(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RemapPickBox else { return }
        handler(box.pick)
    }
}

/// What a menu item carries: its pick.
final class RemapPickBox: NSObject {
    let pick: RemapPick
    init(_ pick: RemapPick) { self.pick = pick }
}

/// Makes the native `NSMenu` of the Mapping mode from the pure item list.
@MainActor
enum RemapNSMenuBuilder {
    static let noteWidth: CGFloat = 250
    /// The warning amber of the conflict note (`RemapColors.warning`).
    static let warningColor = NSColor(srgbRed: 232.0 / 255, green: 179.0 / 255, blue: 57.0 / 255, alpha: 1)

    static func menu(for specs: [RemapMenuItemSpec], target: RemapMenuTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false           // the enabled flags are ours (header, notes, Reset)
        menu.minimumWidth = 220
        for spec in specs { menu.addItem(item(for: spec, target: target)) }
        return menu
    }

    private static func item(for spec: RemapMenuItemSpec, target: RemapMenuTarget) -> NSMenuItem {
        switch spec.kind {
        case .separator:
            return .separator()
        case .header:
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(string: spec.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            return item
        case .note, .footnote, .conflict:
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            switch spec.kind {
            case .note: item.view = wrappedLabel(spec.title, color: .systemOrange)
            case .conflict: item.view = wrappedLabel(spec.title, color: warningColor, weight: .semibold)
            default: item.view = wrappedLabel(spec.title, color: .secondaryLabelColor)
            }
            return item
        case .entry, .reset, .relearn:
            let item = NSMenuItem(title: spec.title, action: #selector(RemapMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = target
            item.isEnabled = spec.isEnabled
            item.state = spec.isOn ? .on : .off
            if let pick = spec.pick { item.representedObject = RemapPickBox(pick) }
            if !spec.tags.isEmpty {
                let s = NSMutableAttributedString(string: spec.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                s.append(NSAttributedString(string: "   " + spec.tags.joined(separator: "   "), attributes: [
                    .font: NSFont.menuFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                item.attributedTitle = s
            }
            return item
        }
    }

    /// A disabled item cannot wrap its title, so a long note is a small wrapping label in a custom view.
    private static func wrappedLabel(_ text: String, color: NSColor, weight: NSFont.Weight = .regular) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: weight)
        label.textColor = color
        label.preferredMaxLayoutWidth = noteWidth - 28
        let size = label.sizeThatFits(NSSize(width: noteWidth - 28, height: .greatestFiniteMagnitude))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: noteWidth, height: size.height + 6))
        label.frame = NSRect(x: 14, y: 3, width: noteWidth - 28, height: size.height)
        container.addSubview(label)
        container.setAccessibilityLabel(text)
        return container
    }
}

/// Opens the Mapping menu for a control. Held by the controller view as a `@StateObject`; it has no published state, so a
/// pop never re-renders the screen by itself (the device's `remapMenuControl` does that, for the selection outline).
@MainActor
final class RemapMenuPresenter: ObservableObject {
    private static let log = Logger(subsystem: GDHubID.subsystem, category: "mapping-menu")
    /// Every live anchor of a side, oldest first. The same side can be drawn by more than one view over time (the
    /// normal drawing, the focused one of Developer mode, another view tab); SwiftUI does not call `updateNSView` on
    /// a view whose inputs did not change, so a single slot was left pointing at a view that had gone away.
    private var anchors: [ControlLayout.Side: [WeakAnchor]] = [:]
    private var pending = false
    private(set) var isOpen = false

    func register(_ view: RemapAnchorView, side: ControlLayout.Side) {
        var list = (anchors[side] ?? []).filter { $0.view != nil && $0.view !== view }
        list.append(WeakAnchor(view))                // the newest registration is tried first
        anchors[side] = list
    }

    /// The anchor view of a drawn view: the newest one that is in a window, else the newest one alive, else nil.
    func anchor(for side: ControlLayout.Side) -> RemapAnchorView? {
        let alive = (anchors[side] ?? []).compactMap(\.view)
        return alive.last { $0.window != nil } ?? alive.last
    }

    /// Called from a click (or an accessibility action). The menu is popped on the next run-loop turn, in the common
    /// modes, so the tap returns first and the click that opened it is finished; a menu opened inside the click's own
    /// block would also hold back everything else that runs on the main queue while it is open.
    /// - Parameter point: where the menu's top left goes, in the coordinates of the drawn view's anchor (SwiftUI's, y down).
    func present(controlID: String, side: ControlLayout.Side, at point: CGPoint, device: EnvisionProDevice) {
        guard device.modeGate.clickAction(on: .label) == .openMenu, !pending, !isOpen else { return }
        pending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self, weak device] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                guard let device else { return }
                self.pop(controlID: controlID, side: side, at: point, device: device)
            }
        }
    }

    private func pop(controlID: String, side: ControlLayout.Side, at point: CGPoint, device: EnvisionProDevice) {
        guard device.isRemapping, !isOpen, let anchor = anchor(for: side), anchor.window != nil,
              let control = device.layout?.control(id: controlID) else {
            let found = self.anchor(for: side)
            Self.log.error("no menu for \(controlID, privacy: .public): mapping=\(device.isRemapping) open=\(self.isOpen) anchor=\(found != nil) inWindow=\(found?.window != nil)")
            return
        }
        let model = RemapMenuModel(controlID: controlID, label: control.label, kind: control.kind, mapping: device.mapping,
                                   labelOf: { device.layout?.control(id: $0)?.label ?? $0 })
        let specs = model.itemSpecs(relearnEnabled: device.modeGate.canLearn)
        let target = RemapMenuTarget { [weak device] pick in
            guard let device else { return }
            switch pick {
            case .output(let output): device.setOutput(output, for: controlID)
            case .reset: device.resetOutput(for: controlID)
            case .relearn: device.startLearn(controlId: controlID)
            }
        }
        let menu = RemapNSMenuBuilder.menu(for: specs, target: target)
        isOpen = true
        device.setRemapMenuControl(controlID)
        // Returns when the menu closes; the pick (if any) was delivered to `target` before that.
        menu.popUp(positioning: nil, at: point, in: anchor)
        device.setRemapMenuControl(nil)
        isOpen = false
        withExtendedLifetime(target) {}
    }
}

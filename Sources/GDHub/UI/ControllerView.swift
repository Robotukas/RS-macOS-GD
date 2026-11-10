import SwiftUI
import AppKit

@MainActor
private enum ControllerImages {
    private static var cache: [String: NSImage] = [:]

    static func image(file: String) -> NSImage? {
        if let img = cache[file] { return img }
        let ns = file as NSString
        guard let url = Bundle.module.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[file] = img
        return img
    }
}

struct ControllerView: View {
    @ObservedObject var device: EnvisionProDevice
    @ObservedObject var control: EnvisionProControl
    @StateObject private var menuPresenter = RemapMenuPresenter()
    @AppStorage("controllerViewTab") private var savedTab = ViewTab.all.rawValue

    var body: some View {
        if let layout = device.layout {
            // Which drawings light this frame, computed once for all views (pressed = as before remaps, linked = fed by a
            // remap). Developer mode keeps its own overlay and draws no linked.
            let levels = lightLevels(layout: layout)
            // Pinned to the top: when the content is taller than the window the bottom is what gets cut off,
            // never the Developer panel (a plain VStack inside `frame(maxHeight: .infinity)` is centred, which
            // pushed the top of an overflowing run above the window edge).
            VStack(alignment: .leading, spacing: 12) {
                if let dev = device.dev {
                    DevPanel(session: dev)
                        .layoutPriority(2)
                }
                // One scale factor for all four views: each gets a width proportional to its image,
                // so resizing the window grows or shrinks every view by the same amount.
                DevObserved(session: device.dev) { dev in
                VStack(spacing: 6) {
                viewTabPicker(dev: dev)
                GeometryReader { geo in
                    let focus = device.editor.isEditing ? [] : DevFocus.sides(overlay: dev, layout: layout)
                    let columns = ViewTab.visibleColumns(
                        tab: ViewTab(rawValue: savedTab) ?? .all, editing: device.editor.isEditing,
                        devRunning: dev?.isRunning ?? false, devFocus: focus,
                        guidedLearn: device.learn?.mode == .guided, allColumns: layout.columns)
                    let spacing: CGFloat = 16
                    // Title above each view, plus the sliders / arrows while the layout is being edited.
                    let titleHeight: CGFloat = 18 + (device.editor.isEditing ? 50 : 0)
                    // Natural size of the arrangement in image pixels (titles added in points below).
                    let colWidths = columns.map { col in col.map { layout.framedWidth(for: $0) }.max() ?? 1 }
                    let totalWidth = colWidths.reduce(0, +)
                    let colHeights = columns.map { col in col.reduce(0.0) { $0 + layout.images.info(for: $1).height } }
                    let maxRows = columns.map(\.count).max() ?? 1
                    let totalHeight = colHeights.max() ?? 1
                    let availWidth = max(geo.size.width - spacing * CGFloat(columns.count - 1), 1)
                    let availHeight = max(geo.size.height - CGFloat(maxRows) * titleHeight - spacing * CGFloat(maxRows - 1), 1)
                    let zoom = device.editor.isEditing ? CGFloat(device.editor.zoom) : 1
                    let scale = min(availWidth / totalWidth, availHeight / totalHeight) * zoom
                    Group {
                    if !focus.isEmpty {
                        focusedViews(focus, layout: layout, dev: dev, levels: levels, size: geo.size)
                            .transition(.opacity)
                    } else {
                        let grid = HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(0..<columns.count, id: \.self) { ci in
                                VStack(spacing: spacing) {
                                    ForEach(columns[ci], id: \.self) { side in
                                        let info = layout.images.info(for: side)
                                        ControllerSideView(device: device, layout: layout, side: side, dev: dev,
                                                           levels: levels, presenter: menuPresenter)
                                            .frame(width: layout.framedWidth(for: side) * scale, height: info.height * scale + titleHeight)
                                    }
                                }
                            }
                        }
                        .coordinateSpace(name: "grid")
                        if device.editor.isEditing {
                            // Editing: the grid lives in a scroll view that zooms toward the pointer on mouse wheel.
                            let padding: CGFloat = 8
                            let contentSize = CGSize(
                                width: max(totalWidth * scale + spacing * CGFloat(columns.count - 1) + padding * 2, geo.size.width),
                                height: max(totalHeight * scale + CGFloat(maxRows) * titleHeight + spacing * CGFloat(maxRows - 1) + padding * 2, geo.size.height))
                            ZoomScrollView(editor: device.editor, contentSize: contentSize,
                                           content: grid.padding(padding).frame(width: contentSize.width, height: contentSize.height, alignment: .center))
                                .frame(width: geo.size.width, height: geo.size.height)
                        } else {
                            grid.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    }
                    .animation(.easeInOut(duration: 0.2), value: focus)
                }
                .padding(.horizontal)
                }
                .frame(minHeight: device.dev == nil ? 0 : 140, maxHeight: .infinity)
                }
                if let dev = device.dev, dev.finishedWithResults || !dev.rows.isEmpty {
                    DevResultTable(session: dev)
                        .layoutPriority(1)
                }
                if !device.editor.isEditing && device.learn == nil && device.dev == nil {
                    ControllerStatusStrip(device: device, control: control)
                }
                LayoutToolbar(device: device, editor: device.editor)
                if device.dev == nil {
                    HStack(alignment: .top, spacing: 16) {
                        LearnToolbar(device: device)
                        if let current = device.learn?.currentControl {
                            MagnifierView(device: device, layout: layout, control: current)
                                .padding(.trailing)
                        }
                    }
                }
                // Developer mode: no loupe. A step with a wanted control shows that view large (focused layout).
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("Could not load envision-pro-layout.json from the app bundle.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ControllerView {
    /// `RemapLighting.levels` for every control, once per frame; the sources table is cached on the device.
    fileprivate func lightLevels(layout: ControlLayout) -> [String: RemapLighting.Level] {
        let all = RemapLighting.levels(frame: device.frame, mapping: device.mapping, controls: layout.controls,
                                       sources: device.remapSources)
        // While Developer mode is on its own overlay says what is linked.
        return device.dev == nil ? all : all.filter { $0.value == .pressed }
    }

    /// The tabs above the drawing: All / Front / Back / Sides. Disabled while something else decides the views (Edit layout
    /// and a guided Learn all show All, a Developer run shows its focus); the saved tab comes back afterwards.
    @ViewBuilder
    fileprivate func viewTabPicker(dev: DevOverlay?) -> some View {
        let guided = device.learn?.mode == .guided
        let editing = device.editor.isEditing
        let enabled = ViewTab.tabPickerEnabled(editing: editing, devRunning: dev?.isRunning ?? false, guidedLearn: guided)
        let shown: ViewTab = (editing || guided) ? .all : (ViewTab(rawValue: savedTab) ?? .all)
        Picker("Views", selection: SwiftUI.Binding<ViewTab>(get: { shown }, set: { savedTab = $0.rawValue })) {
            ForEach(ViewTab.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!enabled)
        .accessibilityIdentifier("viewTabs")
        .help(enabled ? "Which views of the controller to draw" : "Edit layout, Learn all and Developer runs choose the views")
        .frame(maxWidth: .infinity)
    }

    /// Developer mode, active step: only the view(s) holding the wanted control, as large as the area allows.
    /// One view fills the area (capped at 900 pt wide); two views (wanted + its linked output) share the width
    /// 62 / 38. Each view gets its own scale.
    @ViewBuilder
    fileprivate func focusedViews(_ sides: [ControlLayout.Side], layout: ControlLayout, dev: DevOverlay?,
                                  levels: [String: RemapLighting.Level], size: CGSize) -> some View {
        let spacing: CGFloat = 16
        let titleHeight: CGFloat = 18
        let share: [CGFloat] = sides.count == 1 ? [1] : [0.62, 0.38]
        let usable = max(size.width - spacing * CGFloat(sides.count - 1), 1)
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(sides.enumerated()), id: \.element) { i, side in
                let info = layout.images.info(for: side)
                let fw = layout.framedWidth(for: side)
                let w = min(usable * share[i], 900)
                let scale = max(min(w / fw, (size.height - titleHeight) / info.height), 0.01)
                ControllerSideView(device: device, layout: layout, side: side, dev: dev,
                                   levels: levels, presenter: menuPresenter)
                    .frame(width: fw * scale, height: info.height * scale + titleHeight)
            }
        }
        .coordinateSpace(name: "grid")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ControllerSideView: View {
    @ObservedObject var device: EnvisionProDevice
    let layout: ControlLayout
    let side: ControlLayout.Side
    let dev: DevOverlay?
    let levels: [String: RemapLighting.Level]
    let presenter: RemapMenuPresenter

    /// A click (or an accessibility press) on a drawn button. `point` is where the menu's top left goes.
    private func hotspotClick(_ c: ControlLayout.Control, at point: CGPoint) {
        device.handleClick(on: .hotspot, controlID: c.id) {
            presenter.present(controlID: c.id, side: side, at: point, device: device)
        }
    }

    private func hotspotHelp(_ c: ControlLayout.Control) -> String {
        if device.dev != nil || device.editor.isEditing { return c.label }
        return device.isRemapping ? "Click to choose what \(c.label) sends" : "Switch Mapping on to change what \(c.label) sends"
    }

    var body: some View {
        let info = layout.images.info(for: side)
        let labelMode: RemapLabel.Mode = device.editor.isEditing ? .editLayout : (device.isRemapping ? .mapping : .live)
        // Larger hotspots first so small ones on top of them (L3 over the left stick) stay clickable.
        let controls = layout.controls
            .filter { $0.view == side }
            .sorted { layout.radius(of: $0) > layout.radius(of: $1) }
        let learningId = device.learn?.currentControl?.id
        let gutters = layout.gutters(for: side)
        let framedFraction = 1 + gutters.left + gutters.right
        VStack(spacing: 4) {
            Text(side.title).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let imgW = geo.size.width / framedFraction
                let imgH = imgW / info.aspectRatio
                let originX = gutters.left * imgW
                let imgSize = CGSize(width: imgW, height: imgH)
                ZStack(alignment: .topLeading) {
                    // The menu pops up from here: one invisible view over the whole drawn view, never takes a click.
                    RemapAnchor(presenter: presenter, side: side)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if let img = ControllerImages.image(file: info.file) {
                        Image(nsImage: img).resizable().frame(width: imgW, height: imgH).offset(x: originX)
                    } else {
                        Rectangle().fill(.quaternary).frame(width: imgW, height: imgH).offset(x: originX)
                    }
                    ForEach(controls) { c in
                        let d = 2 * layout.radius(of: c) * imgW
                        let hotspotW = c.isPill ? d * 2 : d
                        let centre = CGPoint(x: originX + c.x * imgW, y: c.y * imgH)
                        HotspotView(
                            control: c,
                            diameter: d,
                            level: levels[c.id],
                            selected: device.remapMenuControl == c.id,
                            mapped: device.mapping.isMapped(c.id),
                            learning: learningId == c.id,
                            stick: c.kind == .stick ? device.mapping.stickPosition(c.id, device.frame) : nil,
                            trigger: c.kind == .trigger ? device.mapping.triggerValue(c.id, device.frame) : nil,
                            coverage: learningId == c.id ? device.learn?.circleCovered : nil,
                            dev: dev?.control(c),
                            help: hotspotHelp(c),
                            accessibilityText: RemapLabel(label: c.label, id: c.id, mapping: device.mapping, mode: labelMode).fullText,
                            accessibilityID: "remap.hotspot.\(c.id)",
                            onTap: { hotspotClick(c, at: CGPoint(x: centre.x - hotspotW / 2, y: centre.y + d / 2 + 4)) }
                        )
                        .allowsHitTesting(device.dev == nil)
                        .position(x: centre.x, y: centre.y)
                    }
                    CalloutLayer(controls: controls, layout: layout, size: imgSize, origin: CGPoint(x: originX, y: 0),
                                 frameSize: geo.size, device: device, editor: device.editor, learningId: learningId, dev: dev,
                                 presenter: presenter)
                        .allowsHitTesting(device.modeGate.labelsHitTestable)
                }
            }
            .aspectRatio(info.aspectRatio * framedFraction, contentMode: .fit)
            if device.editor.isEditing {
                GutterSliders(device: device, side: side, gutters: gutters)
                HStack(spacing: 4) {
                    Button { device.moveView(side, dx: -1, dy: 0) } label: { Image(systemName: "arrow.left") }
                    Button { device.moveView(side, dx: 0, dy: -1) } label: { Image(systemName: "arrow.up") }
                    Button { device.moveView(side, dx: 0, dy: 1) } label: { Image(systemName: "arrow.down") }
                    Button { device.moveView(side, dx: 1, dy: 0) } label: { Image(systemName: "arrow.right") }
                }
                .controlSize(.mini)
                .help("Move this view between and within columns")
            }
        }
    }
}

/// Loupe: a zoomed crop of the view that holds the control being learned, with the live hotspot on top.
private struct MagnifierView: View {
    @ObservedObject var device: EnvisionProDevice
    let layout: ControlLayout
    let control: ControlLayout.Control
    var dev: DevOverlay?

    private let size: CGFloat = 200
    private let zoom: CGFloat = 3.2

    var body: some View {
        let info = layout.images.info(for: control.view)
        // The crop is `zoom` times wider than the loupe; the hotspot is scaled with it.
        let dw = size * zoom
        let dh = dw / info.aspectRatio
        let diameter = 2 * layout.radius(of: control) * dw
        VStack(spacing: 4) {
            ZStack {
                if let img = ControllerImages.image(file: info.file) {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: dw, height: dh)
                        .offset(x: size / 2 - control.x * dw, y: size / 2 - control.y * dh)
                } else {
                    Color.gray
                }
                HotspotView(
                    control: control,
                    diameter: diameter,
                    level: device.mapping.isActive(control.id, device.frame) ? .pressed : nil,
                    selected: false,
                    mapped: device.mapping.isMapped(control.id),
                    learning: dev == nil,
                    stick: control.kind == .stick ? device.mapping.stickPosition(control.id, device.frame) : nil,
                    trigger: control.kind == .trigger ? device.mapping.triggerValue(control.id, device.frame) : nil,
                    coverage: dev == nil ? device.learn?.circleCovered : nil,
                    dev: dev?.control(control),
                    help: control.label,
                    accessibilityText: control.label,
                    accessibilityID: nil,
                    onTap: {}
                )
                .allowsHitTesting(false)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
            .shadow(radius: 6)
            Text("\(control.view.title): \(control.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HotspotView: View {
    let control: ControlLayout.Control
    let diameter: CGFloat
    /// Pressed: orange as before remaps. Linked: a dimmer orange (the pad is sending the item this drawing stands for).
    let level: RemapLighting.Level?
    /// The menu of this control is open: outline.
    let selected: Bool
    let mapped: Bool
    let learning: Bool
    let stick: CGPoint?
    let trigger: Double?
    /// Circle-capture sectors while this stick is being learned (nil otherwise).
    let coverage: [Bool]?
    var dev: DevControlOverlay?
    let help: String
    let accessibilityText: String
    /// nil for the loupe, which is a copy of a button that already has its element.
    let accessibilityID: String?
    let onTap: () -> Void

    private var active: Bool { level == .pressed }

    private var width: CGFloat { control.isPill ? diameter * 2 : diameter }
    private var shape: AnyShape { control.isPill ? AnyShape(Capsule()) : AnyShape(Circle()) }

    var body: some View {
        ZStack {
            if level == .linked {
                shape.fill(Color.orange.opacity(0.2))
                shape.stroke(Color.orange.opacity(0.55), lineWidth: 1)
            }
            if control.kind == .trigger, let t = trigger {
                if t > 0.02 {
                    ZStack(alignment: .bottom) {
                        Color.clear
                        Rectangle().fill(Color.orange.opacity(0.7)).frame(height: diameter * t)
                    }
                    .clipShape(shape)
                    shape.stroke(Color.orange.opacity(0.8), lineWidth: 1)
                }
            } else if active {
                shape.fill(Color.orange.opacity(control.kind == .stick ? 0.3 : 0.6))
                shape.stroke(Color.orange, lineWidth: 1.5)
            }

            if control.kind == .stick, let p = stick {
                let travel = diameter / 2 * 0.65
                Circle()
                    .fill(Color.orange)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                    .frame(width: diameter * 0.22, height: diameter * 0.22)
                    .offset(x: p.x * travel, y: p.y * travel)
            }

            if learning {
                LearningPulse(shape: shape)
            }

            if let dev {
                devOverlay(dev)
            }

            if let cov = coverage, !cov.isEmpty {
                CoverageRing(covered: cov)
                    .frame(width: diameter * 1.25, height: diameter * 1.25)
                    .allowsHitTesting(false)
            }

            if selected {
                shape.stroke(RemapColors.selection, lineWidth: 2).padding(-2)
            }
        }
        .frame(width: width, height: diameter)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .help(help)
        .modifier(HotspotAccessibility(text: accessibilityText, id: accessibilityID, action: onTap))
    }

    /// Developer mode: the purple pad state, then the ring that says what the step wants or how it ended.
    @ViewBuilder private func devOverlay(_ d: DevControlOverlay) -> some View {
        let purple = DevPalette.purple
        if let pad = d.pad {
            if pad.pressed {
                shape.fill(purple.opacity(0.55))
            }
            if let t = pad.trigger, t > 0.02 {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    Rectangle().fill(purple.opacity(0.85)).frame(width: width * 0.4, height: diameter * t)
                }
                .clipShape(shape)
            }
            if let p = pad.stick {
                let travel = diameter / 2 * 0.65
                Circle()
                    .fill(purple)
                    .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 0.75))
                    .frame(width: diameter * 0.18, height: diameter * 0.18)
                    .offset(x: p.x * travel, y: p.y * travel)
            }
        }
        switch d.highlight {
        case .wanted?:
            if d.paused {
                shape.fill(purple.opacity(0.2))
                shape.stroke(purple, lineWidth: 3)
                Text("❚❚").font(.system(size: max(diameter * 0.35, 9), weight: .heavy)).foregroundStyle(purple)
            } else {
                DevPulse(shape: shape)
            }
        case .linked?:
            shape.stroke(purple.opacity(0.55), lineWidth: 2)
        case .passed?:
            shape.stroke(DevPalette.pass, lineWidth: 2.5)
        case .failed?:
            shape.stroke(DevPalette.fail, lineWidth: 2.5)
        case .inconclusive?:
            shape.stroke(DevPalette.inconclusive, lineWidth: 2.5)
        case .skipped?:
            shape.stroke(DevPalette.skipped, lineWidth: 2)
            Path { p in
                p.move(to: CGPoint(x: width * 0.15, y: diameter * 0.85))
                p.addLine(to: CGPoint(x: width * 0.85, y: diameter * 0.15))
            }
            .stroke(DevPalette.skipped, lineWidth: 1.5)
            .frame(width: width, height: diameter)
        case .restOutline?:
            shape.stroke(purple.opacity(0.25), lineWidth: 1)
        case nil:
            EmptyView()
        }
    }
}

/// A hotspot has no element of its own by default: give it one (a button that does what a click does).
private struct HotspotAccessibility: ViewModifier {
    let text: String
    let id: String?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let id {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(id)
                .accessibilityAction(.default, action)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// The purple pulse of the control a step asks for.
private struct DevPulse: View {
    let shape: AnyShape

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = 0.5 + 0.5 * sin(t * 2 * .pi / 1.1)
            ZStack {
                shape.fill(DevPalette.purple.opacity(0.25))
                shape.stroke(DevPalette.purple, lineWidth: 3)
            }
            .scaleEffect(1 + 0.12 * phase)
            .shadow(color: DevPalette.purple.opacity(0.4 + 0.3 * phase), radius: 8)
        }
    }
}

/// Callout labels beside each control with a thin leader line to it. Orange while the control is
/// active, blue while it is being learned, dimmed when it has no mapping yet.
private struct CalloutLayer: View {
    let controls: [ControlLayout.Control]
    let layout: ControlLayout
    /// Size of the controller image; `origin` is where it sits inside the framed area of `frameSize`.
    let size: CGSize
    let origin: CGPoint
    let frameSize: CGSize
    @ObservedObject var device: EnvisionProDevice
    @ObservedObject var editor: LayoutEditor
    let learningId: String?
    var dev: DevOverlay?
    let presenter: RemapMenuPresenter

    /// Where a label's anchor point is (frame coordinates) and which pill edge the anchor refers to.
    struct Placed {
        var anchor: CGPoint
        var kind: ControlLayout.LabelAnchor
    }

    private var viewKey: String { controls.first?.view.rawValue ?? "" }

    /// Label font for this view: fixed, or scaled by how large the image is drawn versus its pixel size.
    private var fontSize: CGFloat {
        guard let side = controls.first?.view else { return 10 }
        let natural = layout.images.info(for: side).width
        return CGFloat(layout.font.pointSize(viewScale: natural > 0 ? size.width / natural : 1))
    }

    private func point(_ c: ControlLayout.Control) -> CGPoint {
        CGPoint(x: origin.x + c.x * size.width, y: origin.y + c.y * size.height)
    }

    private func toFrame(_ fx: Double, _ fy: Double) -> CGPoint {
        CGPoint(x: origin.x + fx * size.width, y: origin.y + fy * size.height)
    }

    private func toFraction(_ p: CGPoint) -> (Double, Double) {
        ((p.x - origin.x) / size.width, (p.y - origin.y) / size.height)
    }

    private func freePoint(_ c: ControlLayout.Control) -> CGPoint {
        let r = layout.radius(of: c)
        let dx = c.labelDx ?? 0
        let dy = c.labelDy ?? (r * size.width / size.height + 0.06)
        return toFrame(c.x + dx, c.y + dy)
    }

    /// Placements as stored in the layout, ignoring an in-progress drag.
    private var basePlacements: [String: Placed] { computePlacements(includeLive: false) }

    /// User positions win; then column labels (stacked and pushed apart); then per-control offsets.
    private var placements: [String: Placed] { computePlacements(includeLive: true) }

    private func computePlacements(includeLive: Bool) -> [String: Placed] {
        var out: [String: Placed] = [:]
        for c in controls {
            if let lx = c.labelX, let ly = c.labelY {
                out[c.id] = Placed(anchor: toFrame(lx, ly), kind: c.labelAnchor ?? .center)
            }
        }
        let gap: CGFloat = fontSize * 2
        let cols = layout.labelColumns?[viewKey]
        for side in ["left", "right"] {
            let members = controls.filter { $0.labelSide == side && out[$0.id] == nil }.sorted { $0.y < $1.y }
            guard !members.isEmpty, let cols else { continue }
            var ys = members.map { origin.y + $0.y * size.height }
            for i in 1..<ys.count where ys[i] < ys[i - 1] + gap { ys[i] = ys[i - 1] + gap }
            let bottom = origin.y + size.height - 10
            if let last = ys.last, last > bottom {
                ys[ys.count - 1] = bottom
                for i in stride(from: ys.count - 2, through: 0, by: -1) where ys[i] > ys[i + 1] - gap { ys[i] = ys[i + 1] - gap }
            }
            for (i, c) in members.enumerated() {
                let x = origin.x + (side == "left" ? cols.left : cols.right) * size.width
                out[c.id] = Placed(anchor: CGPoint(x: x, y: max(ys[i], 10)), kind: side == "left" ? .trailing : .leading)
            }
        }
        for c in controls where out[c.id] == nil { out[c.id] = Placed(anchor: freePoint(c), kind: .center) }
        if includeLive {
            for (id, live) in editor.liveAnchors where out[id] != nil { out[id]!.anchor = live }
        }
        return out
    }

    /// Where the leader meets the label: a side edge, or the bottom / top centre of the pill.
    private func leaderEnd(_ c: ControlLayout.Control, _ p: Placed) -> CGPoint {
        let rect = pillRect(c.id, p)
        if let dx = c.leaderEndDx, let dy = c.leaderEndDy {
            return CGPoint(x: rect.midX + dx * rect.width, y: rect.midY + dy * rect.height)
        }
        let ctr = point(c)
        var attach = c.leaderAttach ?? "auto"
        if attach == "auto" {
            let dx = ctr.x - rect.midX, dy = ctr.y - rect.midY
            attach = abs(dy) > abs(dx) ? (dy > 0 ? "below" : "above") : "side"
        }
        switch attach {
        case "below": return CGPoint(x: rect.midX, y: rect.maxY + 2)
        case "above": return CGPoint(x: rect.midX, y: rect.minY - 2)
        default:
            return ctr.x < rect.midX ? CGPoint(x: rect.minX - 2, y: rect.midY) : CGPoint(x: rect.maxX + 2, y: rect.midY)
        }
    }

    /// Where the leader meets the control: the hand-set target, or the control centre (trimmed to the
    /// hotspot edge in `leaderPoints`).
    private func targetPoint(_ c: ControlLayout.Control) -> CGPoint? {
        guard let dx = c.leaderTargetDx, let dy = c.leaderTargetDy else { return nil }
        return toFrame(c.x + dx, c.y + dy)
    }

    private func corners(_ c: ControlLayout.Control, _ p: Placed) -> [CGPoint] {
        if let l = c.leader { return l.compactMap { $0.count == 2 ? toFrame($0[0], $0[1]) : nil } }
        return presetCorners(c, p)
    }

    /// Orthogonal presets: horizontal from the label, vertical into the control (or the other way round
    /// when the label is mostly above / below the control). Two corners put a vertical middle segment in.
    private func presetCorners(_ c: ControlLayout.Control, _ p: Placed) -> [CGPoint] {
        guard let preset = c.leaderPreset else { return [] }
        let e = leaderEnd(c, p), ctr = targetPoint(c) ?? point(c)
        let byGeometry = abs(e.x - ctr.x) >= abs(e.y - ctr.y)
        let horizontal: Bool
        switch c.leaderOrientation {
        case "hFirst": horizontal = true
        case "vFirst": horizontal = false
        case "flip": horizontal = !byGeometry
        default: horizontal = byGeometry
        }
        switch preset {
        case "oneCorner":
            return [horizontal ? CGPoint(x: ctr.x, y: e.y) : CGPoint(x: e.x, y: ctr.y)]
        case "twoCorners":
            if horizontal {
                let m = (e.x + ctr.x) / 2
                return [CGPoint(x: m, y: e.y), CGPoint(x: m, y: ctr.y)]
            } else {
                let m = (e.y + ctr.y) / 2
                return [CGPoint(x: e.x, y: m), CGPoint(x: ctr.x, y: m)]
            }
        default:
            return []
        }
    }

    /// Turn a preset into explicit corners so they can be edited individually.
    private func materializeCorners(_ c: ControlLayout.Control, _ p: Placed) {
        guard c.leader == nil else { return }
        let cs = corners(c, p).map { pt -> [Double] in let (fx, fy) = toFraction(pt); return [fx, fy] }
        device.updateControl(c.id) { $0.leader = cs.isEmpty ? [] : cs; $0.leaderPreset = nil }
    }

    /// Points of the leader polyline: control edge, corners, label.
    private func leaderPoints(_ c: ControlLayout.Control, _ p: Placed) -> [CGPoint] {
        let cs = corners(c, p)
        let end = leaderEnd(c, p)
        if let t = targetPoint(c) { return [t] + cs + [end] }
        let centre = point(c)
        let first = cs.first ?? end
        let r = layout.radius(of: c) * size.width
        let v = CGVector(dx: first.x - centre.x, dy: first.y - centre.y)
        let len = max((v.dx * v.dx + v.dy * v.dy).squareRoot(), 1)
        let start = CGPoint(x: centre.x + v.dx / len * r * 0.9, y: centre.y + v.dy / len * r * 0.9)
        return [start] + cs + [end]
    }

    /// Drag the point where the leader meets the label; stored relative to the pill so it survives resizes.
    private func moveEnd(_ c: ControlLayout.Control, _ p: Placed, to pt: CGPoint) {
        let rect = pillRect(c.id, p)
        let dx = max(-0.5, min(0.5, (pt.x - rect.midX) / max(rect.width, 1)))
        let dy = max(-0.5, min(0.5, (pt.y - rect.midY) / max(rect.height, 1)))
        device.updateControl(c.id) { $0.leaderEndDx = dx; $0.leaderEndDy = dy }
    }

    /// Drag the point where the leader meets the control.
    private func moveTarget(_ c: ControlLayout.Control, to pt: CGPoint) {
        let (fx, fy) = toFraction(pt)
        device.updateControl(c.id) { $0.leaderTargetDx = fx - c.x; $0.leaderTargetDy = fy - c.y }
    }

    private func color(_ c: ControlLayout.Control) -> Color {
        if editor.isEditing && editor.selection.contains(c.id) { return .yellow }
        if learningId == c.id { return .blue }
        if let h = dev?.highlights[c.id], h != .restOutline { return DevPalette.color(for: h) }
        if device.mapping.isActive(c.id, device.frame) { return .orange }
        return device.mapping.isMapped(c.id) ? .white : .gray
    }

    /// ✓ / ✗ after the label once a step has a verdict.
    private func devMark(_ c: ControlLayout.Control) -> String {
        switch dev?.highlights[c.id] {
        case .passed?: return " ✓"
        case .failed?: return " ✗"
        case .inconclusive?: return " ?"
        default: return ""
        }
    }

    // MARK: Editing

    /// Rendered rectangle of a label pill (frame coordinates).
    private func pillRect(_ id: String, _ p: Placed) -> CGRect {
        let sz = editor.pillSizes[id] ?? CGSize(width: 40, height: 16)
        let x: CGFloat
        switch p.kind { case .center: x = p.anchor.x - sz.width / 2; case .leading: x = p.anchor.x; case .trailing: x = p.anchor.x - sz.width }
        return CGRect(x: x, y: p.anchor.y - sz.height / 2, width: sz.width, height: sz.height)
    }

    private func leftEdge(_ id: String, _ p: Placed) -> CGFloat {
        let w = editor.pillSizes[id]?.width ?? 40
        switch p.kind { case .center: return p.anchor.x - w / 2; case .leading: return p.anchor.x; case .trailing: return p.anchor.x - w }
    }

    private func rightEdge(_ id: String, _ p: Placed) -> CGFloat {
        let w = editor.pillSizes[id]?.width ?? 40
        switch p.kind { case .center: return p.anchor.x + w / 2; case .leading: return p.anchor.x + w; case .trailing: return p.anchor.x }
    }

    /// Store a label position. When `oldCenter` (the pill centre before the move) is given, hand-placed
    /// leader corners are carried along by the same offset so the leader keeps its shape.
    private func setLabel(_ id: String, anchor: CGPoint, kind: ControlLayout.LabelAnchor, oldCenter: CGPoint? = nil) {
        let (fx, fy) = toFraction(anchor)
        var shift: (Double, Double)? = nil
        if let old = oldCenter {
            let newRect = pillRect(id, Placed(anchor: anchor, kind: kind))
            shift = (Double(newRect.midX - old.x) / Double(size.width), Double(newRect.midY - old.y) / Double(size.height))
        }
        device.updateControl(id) {
            $0.labelX = fx; $0.labelY = fy; $0.labelAnchor = kind
            if let (dx, dy) = shift, let l = $0.leader {
                $0.leader = l.map { $0.count == 2 ? [$0[0] + dx, $0[1] + dy] : $0 }
            }
        }
    }

    private func pillCenter(_ id: String, _ placed: [String: Placed]) -> CGPoint? {
        placed[id].map { let r = pillRect(id, $0); return CGPoint(x: r.midX, y: r.midY) }
    }

    /// Snap to other labels' anchor x (same edge kind) or y when within a few points.
    private func snapped(_ p: CGPoint, kind: ControlLayout.LabelAnchor, excluding id: String, in placed: [String: Placed]) -> CGPoint {
        var out = p
        let tol: CGFloat = 6
        for (oid, o) in placed where oid != id {
            if o.kind == kind && abs(o.anchor.x - p.x) < tol { out.x = o.anchor.x }
            if abs(o.anchor.y - p.y) < tol { out.y = o.anchor.y }
        }
        return out
    }

    /// Align the selected labels. Targets are computed from every selected label's frame in the shared
    /// grid space (so labels in different views line up); this layer then moves only its own members.
    /// All views share one scale, so a grid-space offset equals a layer-space offset.
    private func align(_ action: LayoutEditor.AlignAction) {
        let placed = placements
        let frames = editor.pillFrames
        let all = editor.selection.filter { frames[$0] != nil }
        guard all.count >= action.minimumSelection else { return }
        let mine = controls.map(\.id).filter { all.contains($0) }
        guard !mine.isEmpty else { return }
        func f(_ id: String) -> CGRect { frames[id]! }
        func local(_ id: String) -> CGRect { pillRect(id, placed[id]!) }
        func move(_ id: String, dx: CGFloat, dy: CGFloat, kind: ControlLayout.LabelAnchor? = nil) {
            guard let p = placed[id] else { return }
            let k = kind ?? p.kind
            let r = local(id)
            // Anchor x for the (possibly new) edge kind, shifted by dx.
            let x: CGFloat
            switch k { case .leading: x = r.minX + dx; case .trailing: x = r.maxX + dx; case .center: x = r.midX + dx }
            setLabel(id, anchor: CGPoint(x: x, y: p.anchor.y + dy), kind: k, oldCenter: pillCenter(id, placed))
        }
        switch action {
        case .leftEdges:
            let target = all.map { f($0).minX }.min()!
            for id in mine { move(id, dx: target - f(id).minX, dy: 0, kind: .leading) }
        case .rightEdges:
            let target = all.map { f($0).maxX }.max()!
            for id in mine { move(id, dx: target - f(id).maxX, dy: 0, kind: .trailing) }
        case .centersHorizontal:
            let target = all.map { f($0).midX }.reduce(0, +) / CGFloat(all.count)
            for id in mine { move(id, dx: target - f(id).midX, dy: 0, kind: .center) }
        case .topEdges:
            let target = all.map { f($0).minY }.min()!
            for id in mine { move(id, dx: 0, dy: target - f(id).minY) }
        case .bottomEdges:
            let target = all.map { f($0).maxY }.max()!
            for id in mine { move(id, dx: 0, dy: target - f(id).maxY) }
        case .sameRow:
            let target = all.map { f($0).midY }.reduce(0, +) / CGFloat(all.count)
            for id in mine { move(id, dx: 0, dy: target - f(id).midY) }
        case .distributeVertically:
            let sorted = all.sorted { f($0).midY < f($1).midY }
            guard sorted.count > 2 else { return }
            let top = f(sorted.first!).midY, bottom = f(sorted.last!).midY
            let step = (bottom - top) / CGFloat(sorted.count - 1)
            for (i, id) in sorted.enumerated() where mine.contains(id) {
                move(id, dx: 0, dy: (top + step * CGFloat(i)) - f(id).midY)
            }
        case .distributeHorizontally:
            let sorted = all.sorted { f($0).midX < f($1).midX }
            guard sorted.count > 2 else { return }
            let left = f(sorted.first!).midX, right = f(sorted.last!).midX
            let step = (right - left) / CGFloat(sorted.count - 1)
            for (i, id) in sorted.enumerated() where mine.contains(id) {
                move(id, dx: (left + step * CGFloat(i)) - f(id).midX, dy: 0)
            }
        }
    }

    private func addCorner(_ c: ControlLayout.Control, segment: Int, at p: CGPoint) {
        if let pl = placements[c.id] { materializeCorners(c, pl) }
        let (fx, fy) = toFraction(p)
        device.updateControl(c.id) {
            var l = $0.leader ?? []
            l.insert([fx, fy], at: min(segment, l.count))
            $0.leader = l
        }
    }

    private func removeCorner(_ c: ControlLayout.Control, index: Int) {
        device.updateControl(c.id) {
            guard var l = $0.leader, l.indices.contains(index) else { return }
            l.remove(at: index)
            $0.leader = l.isEmpty ? nil : l
        }
    }

    private func moveCorner(_ c: ControlLayout.Control, index: Int, to raw: CGPoint) {
        guard let pl = placements[c.id] else { return }
        materializeCorners(c, pl)
        var p = raw
        if editor.orthogonal {
            // Snap to the neighbouring points so the adjacent segments become horizontal / vertical.
            let pts = leaderPoints(c, pl)          // [start] + corners + [end]
            let prev = pts[index], next = pts[index + 2]
            let tol: CGFloat = 10
            if abs(p.x - prev.x) < tol { p.x = prev.x } else if abs(p.x - next.x) < tol { p.x = next.x }
            if abs(p.y - prev.y) < tol { p.y = prev.y } else if abs(p.y - next.y) < tol { p.y = next.y }
        }
        let (fx, fy) = toFraction(p)
        device.updateControl(c.id) {
            guard var l = $0.leader, l.indices.contains(index) else { return }
            l[index] = [fx, fy]
            $0.leader = l
        }
    }

    // MARK: Body

    var body: some View {
        // Hide the callouts entirely when the view is too small for 10pt text to be useful.
        if size.width >= 110 {
            let placed = placements
            ZStack(alignment: .topLeading) {
                if editor.isEditing {
                    marqueeBackground(placed)
                }
                ForEach(controls) { c in
                    if let pl = placed[c.id] {
                        let pts = leaderPoints(c, pl)
                        let col = color(c)
                        leaderView(c, pts, col)
                        if editor.isEditing {
                            cornerHandles(c, pts)
                        }
                    }
                }
                ForEach(controls) { c in
                    if let pl = placed[c.id] {
                        // A label with "→ Y" is longer than its neighbours (the G1…G5 row): it draws above them, nothing moves.
                        labelView(c, pl, placed)
                            .zIndex(device.remapMenuControl == c.id ? 2 : (device.mapping.isRemapped(c.id) && !editor.isEditing ? 1 : 0))
                    }
                }
                if let m = editor.marquee, m.view == viewKey {
                    Rectangle()
                        .fill(Color.blue.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.blue, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: m.rect.width, height: m.rect.height)
                        .position(x: m.rect.midX, y: m.rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: frameSize.width, height: frameSize.height)
            .coordinateSpace(name: "callouts")
            .onContinuousHover { phase in
                if editor.isEditing, case .active(let loc) = phase { editor.hoverPoint[viewKey] = loc }
            }
            .onPreferenceChange(PillSizeKey.self) { frames in
                editor.pillFrames.merge(frames) { $1 }
                let changed = frames.filter { editor.pillSizes[$0.key] != $0.value.size }
                if !changed.isEmpty { editor.pillSizes.merge(changed.mapValues(\.size)) { $1 } }
            }
            .onChange(of: editor.alignRequest) { _, request in
                if let request { align(request.action) }
            }
        }
    }

    /// Empty-space gestures: drag draws a selection box (Shift adds to the selection), click clears it.
    private func marqueeBackground(_ placed: [String: Placed]) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { if !NSEvent.modifierFlags.contains(.shift) { editor.selection = [] } }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("callouts"))
                .onChanged { v in
                    let start = editor.marqueeStart ?? v.startLocation
                    editor.marqueeStart = start
                    let rect = CGRect(x: min(start.x, v.location.x), y: min(start.y, v.location.y),
                                      width: abs(v.location.x - start.x), height: abs(v.location.y - start.y))
                    editor.marquee = (viewKey, rect)
                }
                .onEnded { _ in
                    defer { editor.marquee = nil; editor.marqueeStart = nil }
                    guard let m = editor.marquee, m.view == viewKey else { return }
                    let hit = Set(controls.compactMap { c -> String? in
                        guard let p = placed[c.id] else { return nil }
                        return pillRect(c.id, p).intersects(m.rect) ? c.id : nil
                    })
                    if NSEvent.modifierFlags.contains(.shift) { editor.selection.formUnion(hit) } else { editor.selection = hit }
                })
    }

    /// Move the dragged label (snapped) and carry every other selected label in this view by the same delta.
    private func dragLabels(_ c: ControlLayout.Control, _ pl: Placed, _ placed: [String: Placed], translation: CGSize) {
        let origin = editor.dragOrigin[c.id] ?? pl.anchor
        editor.dragOrigin[c.id] = origin
        // No snapping while the pointer moves (it reads as jitter); the release snaps instead.
        let raw = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
        DragLog.record("drag \(c.id) origin=\(Int(origin.x)),\(Int(origin.y)) t=\(Int(translation.width)),\(Int(translation.height)) -> \(Int(raw.x)),\(Int(raw.y)) plAnchor=\(Int(pl.anchor.x)),\(Int(pl.anchor.y))")
        let group = editor.selection.contains(c.id) && editor.selection.count > 1
        var live = editor.liveAnchors
        live[c.id] = raw
        if group {
            let delta = CGSize(width: raw.x - origin.x, height: raw.y - origin.y)
            for other in controls where other.id != c.id && editor.selection.contains(other.id) {
                guard let op = placed[other.id] else { continue }
                let o = editor.dragOrigin[other.id] ?? op.anchor
                editor.dragOrigin[other.id] = o
                live[other.id] = CGPoint(x: o.x + delta.width, y: o.y + delta.height)
            }
        }
        editor.liveAnchors = live
    }

    /// Write the dragged positions into the layout (one change, one autosave) and clear the live state.
    /// A single dragged label is stored by its centre: an edge anchor keeps that edge fixed, so with a
    /// fixed-size font the pill's centre (and a Below / Above leader) would drift as the view zooms.
    /// Group drags keep their anchors so aligned edges stay aligned.
    private func commitDrag(_ placed: [String: Placed]) {
        var live = editor.liveAnchors
        let origins = editor.dragOrigin
        editor.liveAnchors = [:]
        editor.dragOrigin = [:]
        let single = live.count == 1
        let before = basePlacements
        // Snap once on release: the primary dragged label snaps to neighbours, the rest follow its shift.
        if let primary = live.keys.sorted().first(where: { origins[$0] != nil }) ?? live.keys.first,
           let p = live[primary], let kind = placed[primary]?.kind {
            let others = placed.filter { !live.keys.contains($0.key) }
            let snappedPoint = snapped(p, kind: kind, excluding: primary, in: others)
            let shift = CGSize(width: snappedPoint.x - p.x, height: snappedPoint.y - p.y)
            for (id, a) in live { live[id] = CGPoint(x: a.x + shift.width, y: a.y + shift.height) }
        }
        for (id, anchor) in live {
            guard let kind = placed[id]?.kind else { continue }
            let old = pillCenter(id, before)
            if single && kind != .center {
                let rect = pillRect(id, Placed(anchor: anchor, kind: kind))
                setLabel(id, anchor: CGPoint(x: rect.midX, y: rect.midY), kind: .center, oldCenter: old)
            } else {
                setLabel(id, anchor: anchor, kind: kind, oldCenter: old)
            }
        }
    }

    @ViewBuilder
    private func leaderView(_ c: ControlLayout.Control, _ pts: [CGPoint], _ col: Color) -> some View {
        Path { path in
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
        }
        .stroke(col.opacity(0.75), lineWidth: 0.75)
        Circle().fill(col.opacity(0.95)).frame(width: 3, height: 3).position(pts[0])
        if editor.isEditing {
            // One wide invisible hit strip per segment: double-click adds a corner there.
            ForEach(0..<(pts.count - 1), id: \.self) { i in
                let seg = Path { $0.move(to: pts[i]); $0.addLine(to: pts[i + 1]) }
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                seg.stroke(Color.clear, lineWidth: 12)
                    .contentShape(seg.strokedPath(StrokeStyle(lineWidth: 12)))
                    .onTapGesture(count: 2, coordinateSpace: .local) { loc in addCorner(c, segment: i, at: loc) }
                    .contextMenu {
                        Button("Add corner here") { addCorner(c, segment: i, at: editor.hoverPoint[viewKey] ?? mid) }
                    }
            }
        }
    }

    @ViewBuilder
    private func cornerHandles(_ c: ControlLayout.Control, _ pts: [CGPoint]) -> some View {
        // Target handle (green) where the line meets the control, end handle (yellow square) at the label.
        if let pl = placements[c.id] {
            Circle()
                .fill(Color.green)
                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                .frame(width: 9, height: 9)
                .position(pts[0])
                .contextMenu { Button("Reset leader target") { device.updateControl(c.id) { $0.leaderTargetDx = nil; $0.leaderTargetDy = nil } } }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("callouts"))
                    .onChanged { v in
                        let key = "\(c.id)#target"
                        let o = editor.dragOrigin[key] ?? pts[0]
                        editor.dragOrigin[key] = o
                        moveTarget(c, to: CGPoint(x: o.x + v.translation.width, y: o.y + v.translation.height))
                    }
                    .onEnded { _ in editor.dragOrigin["\(c.id)#target"] = nil })
            Rectangle()
                .fill(Color.yellow)
                .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                .frame(width: 8, height: 8)
                .position(pts[pts.count - 1])
                .contextMenu { Button("Reset leader end") { device.updateControl(c.id) { $0.leaderEndDx = nil; $0.leaderEndDy = nil } } }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("callouts"))
                    .onChanged { v in
                        let key = "\(c.id)#end"
                        let o = editor.dragOrigin[key] ?? pts[pts.count - 1]
                        editor.dragOrigin[key] = o
                        moveEnd(c, pl, to: CGPoint(x: o.x + v.translation.width, y: o.y + v.translation.height))
                    }
                    .onEnded { _ in editor.dragOrigin["\(c.id)#end"] = nil })
        }
        // pts = [start] + corners + [end]
        let n = max(pts.count - 2, 0)
        ForEach(0..<n, id: \.self) { i in
            let key = "\(c.id)#\(i)"
            Circle()
                .fill(Color.blue)
                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                .frame(width: 9, height: 9)
                .position(pts[i + 1])
                .onTapGesture(count: 2) { removeCorner(c, index: i) }
                .contextMenu { Button("Remove corner") { removeCorner(c, index: i) } }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("callouts"))
                    .onChanged { v in
                        let o = editor.dragOrigin[key] ?? pts[i + 1]
                        editor.dragOrigin[key] = o
                        moveCorner(c, index: i, to: CGPoint(x: o.x + v.translation.width, y: o.y + v.translation.height))
                    }
                    .onEnded { _ in editor.dragOrigin[key] = nil })
        }
    }

    /// The label, then (once remapped) the arrow and what it sends: orange, or grey for Nothing.
    private func labelText(_ rl: RemapLabel, mark: String, color: Color) -> Text {
        var t = Text(rl.text).foregroundColor(color)
        if let s = rl.suffix {
            t = t + Text(" " + s.text).foregroundColor(s.style == .nothing ? RemapColors.off : RemapColors.accent)
        }
        return t + Text(mark).foregroundColor(color)
    }

    /// Edit layout: dashed in the label's colour. Remapped: 1 pt orange. Mapping: dashed blue-grey. Otherwise as before.
    @ViewBuilder
    private func labelBorder(col: Color, remapped: Bool, mapping: Bool) -> some View {
        if editor.isEditing {
            Capsule().stroke(col.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        } else if remapped {
            Capsule().stroke(RemapColors.accent, lineWidth: 1)
        } else if mapping {
            Capsule().stroke(RemapColors.mappingBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        } else {
            Capsule().stroke(col.opacity(0.5), lineWidth: 0.5)
        }
    }

    /// A click or accessibility press on a label: select it (Edit layout), open its menu (Mapping) or flash the hint (live view).
    private func labelClick(_ c: ControlLayout.Control, _ pl: Placed) {
        device.handleClick(on: .label, controlID: c.id, extendSelection: NSEvent.modifierFlags.contains(.shift)) {
            let r = pillRect(c.id, pl)
            presenter.present(controlID: c.id, side: c.view, at: CGPoint(x: r.minX, y: r.maxY + 4), device: device)
        }
    }

    @ViewBuilder
    private func labelView(_ c: ControlLayout.Control, _ pl: Placed, _ placed: [String: Placed]) -> some View {
        let col = color(c)
        let fs = fontSize
        let mark = devMark(c)
        let dimmed = dev.map { $0.isRunning && $0.highlights[c.id] == nil } ?? false
        let mode: RemapLabel.Mode = editor.isEditing ? .editLayout : (device.isRemapping ? .mapping : .live)
        let rl = RemapLabel(label: c.label, id: c.id, mapping: device.mapping, mode: mode)
        let remapped = rl.isRemapped
        let selected = device.remapMenuControl == c.id
        let pill = labelText(rl, mark: mark, color: col)
            .font(.system(size: fs, weight: .medium))
            .padding(.horizontal, fs * 0.5)
            .padding(.vertical, fs * 0.2)
            .background(remapped ? RemapColors.accentSoft.opacity(0.95) : Color.black.opacity(0.6), in: Capsule())
            .overlay(labelBorder(col: col, remapped: remapped, mapping: mode == .mapping))
            .overlay {
                if selected { Capsule().inset(by: -2).stroke(RemapColors.selection, lineWidth: 2) }
            }
            .opacity(dimmed ? 0.45 : 1)
            .fixedSize()
            .background(GeometryReader { g in Color.clear.preference(key: PillSizeKey.self, value: [c.id: g.frame(in: .named("grid"))]) })
            .onTapGesture { labelClick(c, pl) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rl.fullText)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("remap.label.\(c.id)")
            .accessibilityAction(.default) { labelClick(c, pl) }
            .contextMenu {
                if editor.isEditing {
                    Menu("Align") {
                        ForEach(LayoutEditor.AlignAction.allCases, id: \.self) { action in
                            Button(action.title) { editor.perform(action, including: c.id) }
                                .disabled(editor.selection.union([c.id]).count < action.minimumSelection)
                        }
                    }
                    Menu("Leader") {
                        Button("Straight") { device.setLeaderPreset(nil, for: [c.id]) }
                        Button("L shape (one corner)") { device.setLeaderPreset("oneCorner", for: [c.id]) }
                        Button("Z shape (two corners)") { device.setLeaderPreset("twoCorners", for: [c.id]) }
                        Button("Flip corner direction") { device.flipLeaderOrientation(for: [c.id]) }
                        Divider()
                        Button("Leaves label: automatic") { device.setLeaderAttach(nil, for: [c.id]) }
                        Button("Leaves label: side") { device.setLeaderAttach("side", for: [c.id]) }
                        Button("Leaves label: below") { device.setLeaderAttach("below", for: [c.id]) }
                        Button("Leaves label: above") { device.setLeaderAttach("above", for: [c.id]) }
                        Divider()
                        Button("Reset leader end and target") {
                            device.updateControl(c.id) { $0.leaderEndDx = nil; $0.leaderEndDy = nil; $0.leaderTargetDx = nil; $0.leaderTargetDy = nil }
                        }
                    }
                    Button("Reset label position") {
                        device.updateControl(c.id) { $0.labelX = nil; $0.labelY = nil; $0.labelAnchor = nil }
                    }
                }
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("callouts"))
                .onChanged { v in
                    guard editor.isEditing else { return }
                    dragLabels(c, pl, placed, translation: v.translation)
                }
                .onEnded { _ in if editor.isEditing { commitDrag(placed) } })
        switch pl.kind {
        case .center:
            if rl.suffix != nil {
                // A centred pill that grew by " → Y" would shift its own name sideways. The plain pill keeps the place and
                // the size; the remapped one is laid over it from the same left edge, so "G1" stays exactly where it was.
                let plain = RemapLabel(label: c.label, id: c.id, mapping: device.mapping, mode: .editLayout)
                labelText(plain, mark: mark, color: col)
                    .font(.system(size: fs, weight: .medium))
                    .padding(.horizontal, fs * 0.5)
                    .padding(.vertical, fs * 0.2)
                    .fixedSize()
                    .hidden()
                    .overlay(alignment: .leading) { pill }
                    .position(pl.anchor).transaction { $0.animation = nil }
            } else {
                pill.position(pl.anchor).transaction { $0.animation = nil }
            }
        case .trailing:
            // Right-aligned: the pill ends on the anchor x.
            let w = max(pl.anchor.x, 1)
            pill.frame(width: w, alignment: .trailing).position(x: w / 2, y: pl.anchor.y)
        case .leading:
            let w = max(frameSize.width - pl.anchor.x, 1)
            pill.frame(width: w, alignment: .leading).position(x: pl.anchor.x + w / 2, y: pl.anchor.y)
        }
    }
}

/// Ring of sectors around a stick: green where the circle capture has been, red where it is still missing.
/// Sector 0 starts at 9 o'clock and sectors run clockwise, matching LearnSession.trackCircle.
private struct CoverageRing: View {
    let covered: [Bool]

    var body: some View {
        let n = covered.count
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let start = (Double(i) / Double(n) + 0.5).truncatingRemainder(dividingBy: 1)
                Circle()
                    .trim(from: start, to: start + 1 / Double(n) - 0.004)
                    .stroke(covered[i] ? Color.green : Color.red.opacity(0.8),
                            style: StrokeStyle(lineWidth: 4, lineCap: .butt))
            }
        }
    }
}

private struct LearningPulse: View {
    let shape: AnyShape

    var body: some View {
        // TimelineView instead of @State: the SwiftUI @State macro plugin is missing from
        // the Command Line Tools toolchain.
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = 0.5 + 0.5 * sin(t * 2 * .pi / 1.2)
            ZStack {
                shape.fill(Color.blue.opacity(0.35))
                shape.stroke(Color.blue, lineWidth: 3)
            }
            .opacity(0.25 + 0.75 * phase)
        }
    }
}

private struct LearnToolbar: View {
    @ObservedObject var device: EnvisionProDevice

    var body: some View {
        let learn = device.learn
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Back") { device.backLearn() }.disabled(learn?.canGoBack != true)
                Button("Skip") { device.skipLearn() }.disabled(learn == nil)
                Button("Cancel") { device.cancelLearn() }.disabled(learn == nil)
                Spacer()
                if let learn {
                    Text("Control \(learn.progress.text)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let learn {
                ProgressView(value: Double(learn.progress.current - 1), total: Double(max(learn.progress.total, 1)))
                Text(learn.instruction).font(.title3.weight(.semibold))
                if !learn.lastResult.isEmpty {
                    Text("Last: \(learn.lastResult)").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Use Learn all (guided) to teach every control, or switch Mapping on and choose Re-learn… in a control's menu to teach just that one. Keep the controller untouched until prompted.")
                    .font(.callout).foregroundStyle(.secondary)
                if !device.lastLearnResult.isEmpty {
                    Text("Last: \(device.lastLearnResult)").font(.callout).foregroundStyle(.secondary)
                }
            }
            if device.status != .active {
                Text(statusHint)
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var statusHint: String {
        switch device.status {
        case .asleep: return "Controller is asleep - press a button to wake it before learning."
        case .receiverIdle: return "Receiver is idle - turn the controller on (Start) to link it."
        case .disconnected: return "Receiver not found - plug it in."
        case .active: return ""
        }
    }
}

/// Edit-mode controls: unlock/lock the callout layout, align selected labels, reset.
private struct LayoutToolbar: View {
    @ObservedObject var device: EnvisionProDevice
    @ObservedObject var editor: LayoutEditor

    var body: some View {
        HStack(spacing: 10) {
            if editor.isEditing {
                Button("Done (lock layout)") { device.lockLayout() }.buttonStyle(.borderedProminent)
                Button("Cancel") { device.cancelEditingLayout() }
                Divider().frame(height: 16)
                Menu("Align") {
                    ForEach(LayoutEditor.AlignAction.allCases, id: \.self) { action in
                        Button(action.title) { editor.perform(action) }
                            .disabled(editor.selection.count < action.minimumSelection)
                    }
                }
                .fixedSize()
                .disabled(editor.selection.count < 2)
                Menu("Leader") {
                    Button("Straight") { device.setLeaderPreset(nil, for: editor.selection) }
                    Button("L shape (one corner)") { device.setLeaderPreset("oneCorner", for: editor.selection) }
                    Button("Z shape (two corners)") { device.setLeaderPreset("twoCorners", for: editor.selection) }
                    Button("Horizontal first") { device.setLeaderOrientation("hFirst", for: editor.selection) }
                    Button("Vertical first") { device.setLeaderOrientation("vFirst", for: editor.selection) }
                    Button("Flip corner direction") { device.flipLeaderOrientation(for: editor.selection) }
                    Divider()
                    Button("Leaves label: automatic") { device.setLeaderAttach(nil, for: editor.selection) }
                    Button("Leaves label: side") { device.setLeaderAttach("side", for: editor.selection) }
                    Button("Leaves label: below") { device.setLeaderAttach("below", for: editor.selection) }
                    Button("Leaves label: above") { device.setLeaderAttach("above", for: editor.selection) }
                }
                .fixedSize()
                .disabled(editor.selection.isEmpty)
                Toggle("Orthogonal", isOn: $editor.orthogonal).toggleStyle(.checkbox)
                Menu("Views") {
                    Button("Row: left, front, back, right") { device.setViewColumns([[.sideLeft], [.front], [.back], [.sideRight]]) }
                    Button("Front over back, sides beside") { device.setViewColumns([[.sideLeft], [.front, .back], [.sideRight]]) }
                    Button("Front over back, sides stacked") { device.setViewColumns([[.sideLeft, .sideRight], [.front, .back]]) }
                    Button("Two by two") { device.setViewColumns([[.front, .sideLeft], [.back, .sideRight]]) }
                }
                .fixedSize()
                Divider().frame(height: 16)
                Button("Reset layout") { device.resetLayout() }
                Divider().frame(height: 16)
                Text("Zoom").font(.caption).foregroundStyle(.secondary)
                Slider(value: $editor.zoom, in: 1...4).frame(width: 120)
                Text(String(format: "%.1fx", editor.zoom)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text("Drag labels, or drag a box on empty space to select several (Shift adds); selected labels move together. Double-click or right-click a leader to add a corner; double-click or right-click a corner to remove it. Sliders under each view set the label space. Leader menu sets shape and corner direction; drag the yellow square to move where the line meets the label and the green dot to move where it meets the control. Mouse wheel zooms toward the pointer.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                let gate = device.modeGate
                Button("Edit layout") { device.beginEditingLayout() }
                    .disabled(!gate.canBeginEditing)
                Button(device.isRemapping ? "Mapping ✓ Done" : "Mapping") {
                    if device.isRemapping { device.endRemapping() } else { _ = device.beginRemapping() }
                }
                .disabled(!gate.mappingButtonEnabled)
                .help("Choose what a button sends: click a label or a button")
                .accessibilityIdentifier("toolbar.mapping")
                Button("Learn all (guided)") { device.startGuidedLearn() }
                    .disabled(!gate.learnAllEnabled)
                Button(device.dev == nil ? "Developer" : "Developer ✓ Done") {
                    if let dev = device.dev {
                        if dev.isRunning { dev.stop() }
                        device.endDeveloper()
                    } else {
                        _ = device.beginDeveloper()
                    }
                }
                .disabled(device.dev == nil && !gate.canBeginDeveloper)
                .help("Record what the virtual pad sends while the app tells you what to press")
                if device.isRemapping {
                    Button("Reset all remaps") { device.resetAllRemaps() }
                        .disabled(device.mapping.outputs.isEmpty)
                        .help("Every button sends what it did before; learned buttons stay")
                        .accessibilityIdentifier("toolbar.resetAllRemaps")
                }
                if let dev = device.dev {
                    DevToolbarHint(session: dev)
                } else {
                    RemapHintLine(device: device)
                }
                Spacer()
            }
        }
        .padding(.horizontal)
        if editor.isEditing {
            FontToolbar(device: device)
                .padding(.horizontal)
        }
    }
}

/// The line next to the Mapping button: what a click does now, who drives the controller when the driver cannot do the
/// mapping yet, and the flash after a click in the live view.
private struct RemapHintLine: View {
    @ObservedObject var device: EnvisionProDevice

    var body: some View {
        let flashing = !device.isRemapping && device.remapHintFlashing
        if flashing {
            Text(RemapHint.flash).font(.caption).foregroundStyle(RemapColors.flash).lineLimit(1).truncationMode(.tail)
        } else if let limit = device.remapLimit {
            Text("Driven by: App (mapping needs a driver update: \(limit))")
                .font(.caption).foregroundStyle(RemapColors.flash).lineLimit(1).truncationMode(.tail)
                .help("Driven by: App (mapping needs a driver update: \(limit))")
        } else {
            Text(RemapHint.text(remapping: device.isRemapping, flashing: false))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// The line next to the Developer button: what to do in the current state.
private struct DevToolbarHint: View {
    @ObservedObject var session: DevSession

    var body: some View {
        Text(text).font(.caption).foregroundStyle(DevPalette.purple).lineLimit(2)
    }

    private var text: String {
        if session.isPaused { return "Paused. Space resumes, Esc stops." }
        if session.isRunning { return "Follow the purple control. Space pauses, ← back, → skip, Esc stops." }
        if session.finishedWithResults { return "Run finished. Click a red or amber chip to run that step again, or press Start for a new run." }
        return "Pick where to record and a template, then press Start. Press Developer ✓ Done to leave."
    }
}

/// Label font controls: point size, fixed or scaled with the view, and the lock range for scaled.
private struct FontToolbar: View {
    @ObservedObject var device: EnvisionProDevice

    private var font: ControlLayout.LabelFont { device.layout?.font ?? .standard }

    private func update(_ change: (inout ControlLayout.LabelFont) -> Void) {
        guard var l = device.layout else { return }
        var f = l.font
        change(&f)
        if f.minSize > f.maxSize { f.minSize = f.maxSize }
        l.labelFont = f
        device.layout = l
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Label font").font(.caption).foregroundStyle(.secondary)
            Slider(value: SwiftUI.Binding<Double>(get: { font.size }, set: { v in update { $0.size = v } }), in: 6...20, step: 0.5)
                .frame(width: 140)
            Text(String(format: "%.1f pt", font.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Picker("", selection: SwiftUI.Binding<Bool>(get: { font.scaled }, set: { v in update { $0.scaled = v } })) {
                Text("Fixed size").tag(false)
                Text("Scales with view").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if font.scaled {
                Text("lock between").font(.caption).foregroundStyle(.secondary)
                Stepper(String(format: "%.0f pt", font.minSize),
                        value: SwiftUI.Binding<Double>(get: { font.minSize }, set: { v in update { $0.minSize = v } }), in: 4...30)
                Text("and").font(.caption).foregroundStyle(.secondary)
                Stepper(String(format: "%.0f pt", font.maxSize),
                        value: SwiftUI.Binding<Double>(get: { font.maxSize }, set: { v in update { $0.maxSize = max(v, $0.minSize) } }), in: 4...40)
            }
            Spacer()
        }
        .controlSize(.small)
    }
}

/// Left / right label-space sliders shown under a view while editing the layout.
private struct GutterSliders: View {
    @ObservedObject var device: EnvisionProDevice
    let side: ControlLayout.Side
    let gutters: ControlLayout.LabelGutters

    private func set(left: Double? = nil, right: Double? = nil) {
        guard var l = device.layout else { return }
        var g = l.gutters(for: side)
        if let left { g.left = left }
        if let right { g.right = right }
        var all = l.labelGutters ?? [:]
        all[side.rawValue] = g
        l.labelGutters = all
        device.layout = l
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("space").font(.caption2).foregroundStyle(.secondary)
            Slider(value: SwiftUI.Binding<Double>(get: { gutters.left }, set: { set(left: $0) }), in: 0...1.2)
                .frame(maxWidth: 110)
            Text("|").font(.caption2).foregroundStyle(.secondary)
            Slider(value: SwiftUI.Binding<Double>(get: { gutters.right }, set: { set(right: $0) }), in: 0...1.2)
                .frame(maxWidth: 110)
        }
        .controlSize(.mini)
    }
}


/// Debug aid: set GDHUB_DRAG_LOG=1 in the environment (or create ~/Library/Application Support/GDHub/drag.log)
/// to append one line per drag update.
enum DragLog {
    private static let url: URL? = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GDHub", isDirectory: true)
        let u = dir.appendingPathComponent("drag.log")
        let enabled = ProcessInfo.processInfo.environment["GDHUB_DRAG_LOG"] != nil || FileManager.default.fileExists(atPath: u.path)
        return enabled ? u : nil
    }()

    static func record(_ line: String) {
        guard let url else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSinceReferenceDate)
        let data = (stamp + " " + line + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}


/// Battery and sleep-timer strip under the controller views.
private struct ControllerStatusStrip: View {
    @ObservedObject var device: EnvisionProDevice
    @ObservedObject var control: EnvisionProControl

    private var active: Bool { device.status == .active }

    private var batteryIcon: String {
        guard let p = control.batteryPercent else { return "battery.0percent" }
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Label(control.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "--", systemImage: batteryIcon)
                .monospacedDigit()
                .help("Controller battery")
            Divider().frame(height: 18)
            Text("Sleep after")
            Picker("Sleep after", selection: SwiftUI.Binding<SleepSetting?>(
                get: { control.sleepSetting.flatMap { $0.isPreset ? $0 : nil } },
                set: { if let v = $0 { control.apply(v) } })) {
                ForEach(SleepSetting.presets, id: \.self) { Text($0.presetLabel).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .disabled(!active || control.sleepSetting == nil || control.isBusy)
            if control.isBusy { ProgressView().controlSize(.small) }
            if let s = control.sleepSetting, !s.isPreset {
                Text(s.displayText).foregroundStyle(.secondary)
            }
            if !active {
                Text("Turn the controller on to change this").font(.callout).foregroundStyle(.secondary)
            } else if let e = control.lastError {
                Text(e).font(.callout).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
}

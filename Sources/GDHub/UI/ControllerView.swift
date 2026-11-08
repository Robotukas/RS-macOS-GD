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

    var body: some View {
        if let layout = device.layout {
            VStack(spacing: 12) {
                // One scale factor for all four views: each gets a width proportional to its image,
                // so resizing the window grows or shrinks every view by the same amount.
                GeometryReader { geo in
                    let columns = layout.columns
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
                    let grid = HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(0..<columns.count, id: \.self) { ci in
                            VStack(spacing: spacing) {
                                ForEach(columns[ci], id: \.self) { side in
                                    let info = layout.images.info(for: side)
                                    ControllerSideView(device: device, layout: layout, side: side)
                                        .frame(width: layout.framedWidth(for: side) * scale, height: info.height * scale + titleHeight)
                                }
                            }
                        }
                    }
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
                .padding(.horizontal)
                LayoutToolbar(device: device, editor: device.editor)
                HStack(alignment: .top, spacing: 16) {
                    LearnToolbar(device: device)
                    if let current = device.learn?.currentControl {
                        MagnifierView(device: device, layout: layout, control: current)
                            .padding(.trailing)
                    }
                }
            }
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

private struct ControllerSideView: View {
    @ObservedObject var device: EnvisionProDevice
    let layout: ControlLayout
    let side: ControlLayout.Side

    var body: some View {
        let info = layout.images.info(for: side)
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
                    if let img = ControllerImages.image(file: info.file) {
                        Image(nsImage: img).resizable().frame(width: imgW, height: imgH).offset(x: originX)
                    } else {
                        Rectangle().fill(.quaternary).frame(width: imgW, height: imgH).offset(x: originX)
                    }
                    ForEach(controls) { c in
                        let d = 2 * layout.radius(of: c) * imgW
                        HotspotView(
                            control: c,
                            diameter: d,
                            active: device.mapping.isActive(c.id, device.frame),
                            mapped: device.mapping.isMapped(c.id),
                            learning: learningId == c.id,
                            stick: c.kind == .stick ? device.mapping.stickPosition(c.id, device.frame) : nil,
                            trigger: c.kind == .trigger ? device.mapping.triggerValue(c.id, device.frame) : nil,
                            coverage: learningId == c.id ? device.learn?.circleCovered : nil,
                            onTap: { if !device.editor.isEditing { device.startLearn(controlId: c.id) } }
                        )
                        .position(x: originX + c.x * imgW, y: c.y * imgH)
                    }
                    CalloutLayer(controls: controls, layout: layout, size: imgSize, origin: CGPoint(x: originX, y: 0),
                                 frameSize: geo.size, device: device, editor: device.editor, learningId: learningId)
                        .allowsHitTesting(device.editor.isEditing)
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
                    active: device.mapping.isActive(control.id, device.frame),
                    mapped: device.mapping.isMapped(control.id),
                    learning: true,
                    stick: control.kind == .stick ? device.mapping.stickPosition(control.id, device.frame) : nil,
                    trigger: control.kind == .trigger ? device.mapping.triggerValue(control.id, device.frame) : nil,
                    coverage: device.learn?.circleCovered,
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
    let active: Bool
    let mapped: Bool
    let learning: Bool
    let stick: CGPoint?
    let trigger: Double?
    /// Circle-capture sectors while this stick is being learned (nil otherwise).
    let coverage: [Bool]?
    let onTap: () -> Void

    private var width: CGFloat { control.isPill ? diameter * 2 : diameter }
    private var shape: AnyShape { control.isPill ? AnyShape(Capsule()) : AnyShape(Circle()) }

    var body: some View {
        ZStack {
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

            if let cov = coverage, !cov.isEmpty {
                CoverageRing(covered: cov)
                    .frame(width: diameter * 1.25, height: diameter * 1.25)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: diameter)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .help("Click to learn \(control.label)")
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

    /// User positions win; then column labels (stacked and pushed apart); then per-control offsets.
    private var placements: [String: Placed] {
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
        for (id, live) in editor.liveAnchors where out[id] != nil { out[id]!.anchor = live }
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
        if device.mapping.isActive(c.id, device.frame) { return .orange }
        return device.mapping.isMapped(c.id) ? .white : .gray
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

    private func setLabel(_ id: String, anchor: CGPoint, kind: ControlLayout.LabelAnchor) {
        let (fx, fy) = toFraction(anchor)
        device.updateControl(id) { $0.labelX = fx; $0.labelY = fy; $0.labelAnchor = kind }
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

    private func align(_ action: LayoutEditor.AlignAction) {
        let placed = placements
        let ids = controls.map(\.id).filter { editor.selection.contains($0) }
        guard ids.count >= 2 else { return }
        switch action {
        case .leftEdges:
            let target = ids.map { leftEdge($0, placed[$0]!) }.min()!
            for id in ids { setLabel(id, anchor: CGPoint(x: target, y: placed[id]!.anchor.y), kind: .leading) }
        case .rightEdges:
            let target = ids.map { rightEdge($0, placed[$0]!) }.max()!
            for id in ids { setLabel(id, anchor: CGPoint(x: target, y: placed[id]!.anchor.y), kind: .trailing) }
        case .sameRow:
            let y = ids.map { placed[$0]!.anchor.y }.reduce(0, +) / CGFloat(ids.count)
            for id in ids { setLabel(id, anchor: CGPoint(x: placed[id]!.anchor.x, y: y), kind: placed[id]!.kind) }
        case .distributeVertically:
            let sorted = ids.sorted { placed[$0]!.anchor.y < placed[$1]!.anchor.y }
            guard let top = placed[sorted.first!]?.anchor.y, let bottom = placed[sorted.last!]?.anchor.y, sorted.count > 2 else { return }
            let step = (bottom - top) / CGFloat(sorted.count - 1)
            for (i, id) in sorted.enumerated() {
                setLabel(id, anchor: CGPoint(x: placed[id]!.anchor.x, y: top + step * CGFloat(i)), kind: placed[id]!.kind)
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
                        labelView(c, pl, placed)
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
            .onContinuousHover { phase in
                if case .active(let loc) = phase { editor.hoverPoint[viewKey] = loc }
            }
            .onPreferenceChange(PillSizeKey.self) { sizes in
                let changed = sizes.filter { editor.pillSizes[$0.key] != $0.value }
                if !changed.isEmpty { editor.pillSizes.merge(changed) { $1 } }
            }
            .onAppear { editor.aligners[viewKey] = { action in align(action) } }
        }
    }

    /// Empty-space gestures: drag draws a selection box (Shift adds to the selection), click clears it.
    private func marqueeBackground(_ placed: [String: Placed]) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { if !NSEvent.modifierFlags.contains(.shift) { editor.selection = [] } }
            .gesture(DragGesture(minimumDistance: 4)
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
        let raw = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
        let group = editor.selection.contains(c.id) && editor.selection.count > 1
        let snappedPoint = snapped(raw, kind: pl.kind, excluding: c.id, in: group ? placed.filter { !editor.selection.contains($0.key) } : placed)
        var live = editor.liveAnchors
        live[c.id] = snappedPoint
        if group {
            let delta = CGSize(width: snappedPoint.x - origin.x, height: snappedPoint.y - origin.y)
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
        let live = editor.liveAnchors
        editor.liveAnchors = [:]
        editor.dragOrigin = [:]
        let single = live.count == 1
        for (id, anchor) in live {
            guard let kind = placed[id]?.kind else { continue }
            if single && kind != .center {
                let rect = pillRect(id, Placed(anchor: anchor, kind: kind))
                setLabel(id, anchor: CGPoint(x: rect.midX, y: rect.midY), kind: .center)
            } else {
                setLabel(id, anchor: anchor, kind: kind)
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
                .gesture(DragGesture(minimumDistance: 2)
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
                .gesture(DragGesture(minimumDistance: 2)
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
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        let o = editor.dragOrigin[key] ?? pts[i + 1]
                        editor.dragOrigin[key] = o
                        moveCorner(c, index: i, to: CGPoint(x: o.x + v.translation.width, y: o.y + v.translation.height))
                    }
                    .onEnded { _ in editor.dragOrigin[key] = nil })
        }
    }

    @ViewBuilder
    private func labelView(_ c: ControlLayout.Control, _ pl: Placed, _ placed: [String: Placed]) -> some View {
        let col = color(c)
        let fs = fontSize
        let pill = Text(c.label)
            .font(.system(size: fs, weight: .medium))
            .foregroundStyle(col)
            .padding(.horizontal, fs * 0.5)
            .padding(.vertical, fs * 0.2)
            .background(Color.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(col.opacity(editor.isEditing ? 0.9 : 0.5),
                                      style: StrokeStyle(lineWidth: editor.isEditing ? 1 : 0.5, dash: editor.isEditing ? [3, 2] : [])))
            .fixedSize()
            .background(GeometryReader { g in Color.clear.preference(key: PillSizeKey.self, value: [c.id: g.size]) })
            .onTapGesture {
                guard editor.isEditing else { return }
                editor.toggleSelection(c.id, extend: NSEvent.modifierFlags.contains(.shift))
            }
            .contextMenu {
                if editor.isEditing {
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
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { v in
                    guard editor.isEditing else { return }
                    dragLabels(c, pl, placed, translation: v.translation)
                }
                .onEnded { _ in commitDrag(placed) })
        switch pl.kind {
        case .center:
            pill.position(pl.anchor).transaction { $0.animation = nil }
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
                Button("Learn all (guided)") { device.startGuidedLearn() }
                    .disabled(learn != nil && learn?.mode == .guided)
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
                Text("Click a control to learn just that one, or use Learn all. Keep the controller untouched until prompted.")
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
                Group {
                    Button("Align left") { editor.perform(.leftEdges) }
                    Button("Align right") { editor.perform(.rightEdges) }
                    Button("Same row") { editor.perform(.sameRow) }
                }
                .disabled(editor.selection.count < 2)
                Button("Distribute") { editor.perform(.distributeVertically) }
                    .disabled(editor.selection.count < 3)
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
                Button("Edit layout") { device.beginEditingLayout() }
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

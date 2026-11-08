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
                    let views: [ControlLayout.Side] = [.sideLeft, .front, .back, .sideRight]
                    let spacing: CGFloat = 16
                    let titleHeight: CGFloat = 18
                    let totalWidth = views.reduce(0) { $0 + layout.images.info(for: $1).width }
                    let maxHeight = views.map { layout.images.info(for: $0).height }.max() ?? 1
                    let availWidth = max(geo.size.width - spacing * CGFloat(views.count - 1), 1)
                    let availHeight = max(geo.size.height - titleHeight, 1)
                    let scale = min(availWidth / totalWidth, availHeight / maxHeight)
                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(views, id: \.self) { side in
                            let info = layout.images.info(for: side)
                            ControllerSideView(device: device, layout: layout, side: side)
                                .frame(width: info.width * scale, height: info.height * scale + titleHeight)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal)
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
        VStack(spacing: 4) {
            Text(side.title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                if let img = ControllerImages.image(file: info.file) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
                GeometryReader { geo in
                    ForEach(controls) { c in
                        let d = 2 * layout.radius(of: c) * geo.size.width
                        HotspotView(
                            control: c,
                            diameter: d,
                            active: device.mapping.isActive(c.id, device.frame),
                            mapped: device.mapping.isMapped(c.id),
                            learning: learningId == c.id,
                            stick: c.kind == .stick ? device.mapping.stickPosition(c.id, device.frame) : nil,
                            trigger: c.kind == .trigger ? device.mapping.triggerValue(c.id, device.frame) : nil,
                            coverage: learningId == c.id ? device.learn?.circleCovered : nil,
                            onTap: { device.startLearn(controlId: c.id) }
                        )
                        .position(x: c.x * geo.size.width, y: c.y * geo.size.height)
                    }
                    CalloutLayer(controls: controls, layout: layout, size: geo.size, device: device, learningId: learningId)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(info.aspectRatio, contentMode: .fit)
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
    let size: CGSize
    @ObservedObject var device: EnvisionProDevice
    let learningId: String?

    private func point(_ c: ControlLayout.Control) -> CGPoint {
        CGPoint(x: c.x * size.width, y: c.y * size.height)
    }

    private func labelPoint(_ c: ControlLayout.Control) -> CGPoint {
        let r = layout.radius(of: c)
        let dx = c.labelDx ?? 0
        let dy = c.labelDy ?? (r * size.width / size.height + 0.06)
        return CGPoint(x: (c.x + dx) * size.width, y: (c.y + dy) * size.height)
    }

    private func color(_ c: ControlLayout.Control) -> Color {
        if learningId == c.id { return .blue }
        if device.mapping.isActive(c.id, device.frame) { return .orange }
        return device.mapping.isMapped(c.id) ? .white : .gray
    }

    var body: some View {
        // Hide the callouts entirely when the view is too small for 10pt text to be useful.
        if size.width >= 220 {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for c in controls {
                        let p = point(c), l = labelPoint(c)
                        let r = layout.radius(of: c) * size.width
                        let v = CGVector(dx: l.x - p.x, dy: l.y - p.y)
                        let len = max((v.dx * v.dx + v.dy * v.dy).squareRoot(), 1)
                        // Leader starts just outside the control and ends under the label pill.
                        let start = CGPoint(x: p.x + v.dx / len * r * 0.9, y: p.y + v.dy / len * r * 0.9)
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: l)
                        let col = color(c)
                        ctx.stroke(path, with: .color(col.opacity(0.75)), lineWidth: 0.75)
                        ctx.fill(Path(ellipseIn: CGRect(x: start.x - 1.5, y: start.y - 1.5, width: 3, height: 3)),
                                 with: .color(col.opacity(0.95)))
                    }
                }
                ForEach(controls) { c in
                    let col = color(c)
                    Text(c.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(col)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .overlay(Capsule().stroke(col.opacity(0.5), lineWidth: 0.5))
                        .fixedSize()
                        .position(labelPoint(c))
                }
            }
            .frame(width: size.width, height: size.height)
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

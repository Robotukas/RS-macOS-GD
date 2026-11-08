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
                HStack(alignment: .center, spacing: 16) {
                    ControllerSideView(device: device, layout: layout, side: .front)
                    ControllerSideView(device: device, layout: layout, side: .back)
                }
                .padding(.horizontal)
                LearnToolbar(device: device)
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
            Text(side == .front ? "Front" : "Back").font(.caption).foregroundStyle(.secondary)
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
                            onTap: { device.startLearn(controlId: c.id) }
                        )
                        .position(x: c.x * geo.size.width, y: c.y * geo.size.height)
                    }
                }
            }
            .aspectRatio(info.aspectRatio, contentMode: .fit)
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
    let onTap: () -> Void

    private var width: CGFloat { control.isPill ? diameter * 2 : diameter }
    private var shape: AnyShape { control.isPill ? AnyShape(Capsule()) : AnyShape(Circle()) }

    var body: some View {
        ZStack {
            if control.kind == .trigger, let t = trigger {
                ZStack(alignment: .bottom) {
                    Color.clear
                    Rectangle().fill(Color.orange.opacity(0.85)).frame(height: diameter * t)
                }
                .clipShape(shape)
            } else if control.kind != .stick {
                shape.fill(active ? Color.orange.opacity(0.85) : Color.clear)
            } else if active {
                shape.fill(Color.orange.opacity(0.3))
            }

            outline

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
        }
        .frame(width: width, height: diameter)
        .overlay(alignment: .bottom) {
            Text(control.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.55), in: Capsule())
                .fixedSize()
                .offset(y: 13)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .help("Click to learn \(control.label)")
    }

    @ViewBuilder private var outline: some View {
        if active {
            shape.stroke(Color.orange, lineWidth: 2)
        } else if mapped {
            shape.stroke(Color.white.opacity(0.9), lineWidth: 0.75)
                .shadow(color: .black.opacity(0.7), radius: 0.5)
        } else {
            shape.stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .shadow(color: .black.opacity(0.7), radius: 0.5)
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
                Text(device.status == .asleep
                     ? "Controller is asleep - press a button to wake it before learning."
                     : "Receiver not found - plug it in.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

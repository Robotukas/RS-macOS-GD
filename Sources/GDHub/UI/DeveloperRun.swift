import SwiftUI
import AppKit

// The views of a Developer run (docs/plans/developer-mode-plan.md, "UI pieces"): the instruction box with its ring, the
// live strip, the step chips and the result table, plus the value types the drawing uses for its purple overlay.

// MARK: - Pure helpers

/// The arithmetic of the ring, kept apart from the view so it can be tested.
enum DevRingMath {
    /// Share of the step's window still to run, 0...1 (1 = full). `sinceStamp` is how long ago the instruction was
    /// stamped; nil total = no countdown for this instruction.
    static func remaining(totalNs: UInt64?, elapsedNs: UInt64?, sinceStamp: TimeInterval) -> Double? {
        guard let total = totalNs, total > 0 else { return nil }
        let elapsed = Double(elapsedNs ?? 0) / 1e9 + max(sinceStamp, 0)
        return min(max(1 - elapsed / (Double(total) / 1e9), 0), 1)
    }

    /// The whole seconds to show in the middle (rounded up, so "1" stays until the window ends).
    static func secondsLeft(totalNs: UInt64?, elapsedNs: UInt64?, sinceStamp: TimeInterval) -> Int? {
        guard let total = totalNs, total > 0 else { return nil }
        let left = Double(total) / 1e9 - (Double(elapsedNs ?? 0) / 1e9 + max(sinceStamp, 0))
        return max(Int(left.rounded(.up)), 0)
    }
}

extension DevVerdict {
    /// The word in the result column.
    var label: String {
        switch self {
        case .pass: return "Pass"
        case .fail: return "Fail"
        case .skipped: return "Skipped"
        case .inconclusive: return "Inconclusive"
        case .invalid: return "Invalid"
        }
    }
}

extension DevChip.Status {
    var symbol: String {
        switch self {
        case .pending: return ""
        case .current: return "● "
        case .passed: return "✓ "
        case .failed: return "✗ "
        case .skipped: return "– "
        case .inconclusive: return "? "
        }
    }

    /// A finished step that can be run again from its chip.
    var canRerun: Bool { self == .failed || self == .inconclusive }
}

/// What the drawing needs from the session, as a value: the views that draw the controllers do not observe the session.
struct DevOverlay: Equatable {
    var highlights: [String: DevHighlight] = [:]
    var isPaused = false
    var isRunning = false
    var pad: PadDecodedState?

    @MainActor init(_ s: DevSession) {
        highlights = s.highlights
        isPaused = s.isPaused
        isRunning = s.isRunning
        pad = s.padState
    }

    func control(_ c: ControlLayout.Control) -> DevControlOverlay {
        let h = highlights[c.id]
        var pad: DevPadOverlay?
        if let state = self.pad, h == .wanted || h == .linked { pad = DevPadOverlay(control: c, state: state) }
        return DevControlOverlay(highlight: h, paused: isPaused, dimmed: isRunning && h == nil, pad: pad)
    }

    /// The control the loupe follows: the first wanted one in layout order.
    func wantedControl(in layout: ControlLayout) -> ControlLayout.Control? {
        layout.controls.first { highlights[$0.id] == .wanted }
    }
}

/// How one control is dressed for the run.
struct DevControlOverlay {
    var highlight: DevHighlight?
    var paused = false
    /// A run is active and this control has nothing to do with the step.
    var dimmed = false
    var pad: DevPadOverlay?
}

/// The virtual pad's state for one control, in the drawing's own coordinates.
struct DevPadOverlay: Equatable {
    /// -1...1, x to the right, y DOWN (like `ControlMapping.stickPosition`; the pad's Y is up-positive).
    var stick: CGPoint?
    var trigger: Double?
    var pressed = false

    init(control c: ControlLayout.Control, state: PadDecodedState) {
        switch c.kind {
        case .stick:
            let which: PadStick = c.id.hasPrefix("right") ? .right : .left
            let p = state.position(of: which)
            stick = CGPoint(x: p.x, y: -p.y)
        case .trigger:
            trigger = state.value(of: c.id == "rt" ? .right : .left)
        default:
            let items = state.items
            pressed = items.contains { $0.layoutControlID == c.id } || (c.id == "start" && state.guide)
        }
    }
}

// MARK: - Instruction box

/// Observes the session for the views that draw a run.
struct DevInstructionBox: View {
    @ObservedObject var session: DevSession

    var body: some View {
        let tint = session.isGo && !session.isPaused ? Color.green : DevPalette.purple
        HStack(spacing: 14) {
            DevRing(instruction: session.instruction, paused: session.isPaused, tint: tint)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.instruction.title.isEmpty ? "Get ready…" : session.instruction.title)
                    .font(.title3.weight(.bold))
                if !session.instruction.detail.isEmpty {
                    Text(session.instruction.detail).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button { session.back() } label: { Text("↶ " + session.backLabel) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!session.canGoToPreviousStep && !session.isRunning)
                    .help("During a step: redo it; before it starts: previous step (←)")
                Button { session.skip() } label: { Text("Skip →") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Skip this step; it is marked skipped (→)")
                Button { session.isPaused ? session.resume() : session.pause() } label: {
                    Text(session.isPaused ? "▶ Resume" : "❚❚ Pause")
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Pause for a call or a break and resume from the same step (Space)")
                Button { session.stop() } label: { Text("■ Stop") }
                    .keyboardShortcut(.cancelAction)
                    .help("End the run now; the table shows the steps done so far (Esc)")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(DevPalette.purpleSoft.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevPalette.purple, lineWidth: 1))
        .padding(.horizontal)
    }
}

/// The countdown ring: drains from the step's real length; steady with "❚❚" while paused.
struct DevRing: View {
    let instruction: DevInstruction
    let paused: Bool
    var tint: Color = DevPalette.purple

    var body: some View {
        let hasCountdown = (instruction.ringTotalNs ?? 0) > 0
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: paused || !hasCountdown)) { context in
            let since = paused ? 0 : context.date.timeIntervalSince(instruction.stampedAt)
            let remaining = DevRingMath.remaining(totalNs: instruction.ringTotalNs, elapsedNs: instruction.ringElapsedNs, sinceStamp: since)
            let secs = DevRingMath.secondsLeft(totalNs: instruction.ringTotalNs, elapsedNs: instruction.ringElapsedNs, sinceStamp: since)
            ZStack {
                Circle().stroke(Color.gray.opacity(0.3), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: remaining ?? 1)
                    .stroke(tint.opacity(remaining == nil ? 0.35 : 1), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if paused {
                    Text("❚❚").font(.system(size: 14, weight: .heavy))
                } else if let secs {
                    Text("\(secs)").font(.system(size: 20, weight: .heavy).monospacedDigit())
                }
            }
        }
        .accessibilityLabel(paused ? "Paused" : "Time left")
    }
}

// MARK: - Live strip

struct DevLiveStrip: View {
    @ObservedObject var session: DevSession

    var body: some View {
        let live = session.live
        HStack(spacing: 16) {
            item("path", live?.target ?? "–")
            item("armed", live?.armed ?? "–")
            item("frames in", String(format: "%.0f/s", live?.framesPerSecond ?? 0))
            item("pad reports", "\(live?.padReports ?? 0)")
            item("changed", "\(live?.padChanged ?? 0)")
            item("expected", "\(live?.expectedChanges ?? 0)")
            if let ok = live?.parityOkBucket {
                item("parity", "\(ok) ok / \(live?.parityMismatches ?? 0) off")
            }
            HStack(spacing: 4) {
                Text("pad matched").foregroundStyle(.secondary)
                Text("\(session.matchedCount)").bold().foregroundStyle(session.matchedCount == 1 ? Color.primary : Color.orange)
                if session.matchedCount != 1 { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            .help("Virtual pads the reader found; exactly one is expected")
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal)
    }

    private func item(_ name: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.secondary)
            Text(value).bold()
        }
    }
}

// MARK: - Chips

/// Wraps its children onto as many lines as the width needs.
struct DevFlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (i, p) in result.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}

struct DevChips: View {
    @ObservedObject var session: DevSession

    var body: some View {
        let canRerun = !session.isRunning && session.finishedWithResults
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.chips) { row in
                HStack(alignment: .top, spacing: 8) {
                    if session.chips.count > 1 {
                        Text(row.target.shortName).font(.caption.weight(.semibold)).foregroundStyle(DevPalette.purple)
                            .frame(width: 96, alignment: .leading)
                    }
                    DevFlowLayout {
                        ForEach(row.chips) { chip in
                            chipView(chip, pass: row.pass, canRerun: canRerun && chip.status.canRerun)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder private func chipView(_ chip: DevChip, pass: Int, canRerun: Bool) -> some View {
        let color = DevPalette.color(for: chip.status)
        let label = Text(chip.status.symbol + chip.title)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .foregroundStyle(chip.status == .pending ? Color.secondary : color)
            .background(color.opacity(chip.status == .pending ? 0.12 : 0.22), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(chip.status == .current ? 1 : 0.5), lineWidth: chip.status == .current ? 1.5 : 1))
        if canRerun {
            Button { session.rerun(index: chip.index, pass: pass) } label: { label }
                .buttonStyle(.plain)
                .help("Run \(chip.title) again")
        } else {
            label.help(chip.title)
        }
    }
}

// MARK: - Result table

struct DevResultTable: View {
    @ObservedObject var session: DevSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Table(session.rows) {
                TableColumn("#") { r in Text("\(r.index + 1)").monospacedDigit() }.width(28)
                TableColumn("Step") { r in Text(r.title) }.width(min: 90, ideal: 130)
                TableColumn("Expected") { r in Text(r.expected).lineLimit(2) }.width(min: 80, ideal: 140)
                TableColumn("Seen") { r in Text(r.seen).lineLimit(2).help(r.seen) }.width(min: 100, ideal: 220)
                TableColumn("Loss") { r in Text(r.loss).monospacedDigit() }.width(52)
                TableColumn("Onset") { r in Text(r.onset).monospacedDigit() }.width(68)
                TableColumn("Frames") { r in Text(r.frames).monospacedDigit() }.width(54)
                TableColumn("Result") { r in
                    Text(r.verdict?.label ?? "–")
                        .fontWeight(.semibold)
                        .foregroundStyle(DevPalette.color(for: r.verdict))
                        .help(r.verdict?.reason ?? "")
                }.width(min: 72, ideal: 90)
            }
            .frame(height: min(CGFloat(session.rows.count) * 28 + 34, 230))
            HStack(spacing: 10) {
                if let url = session.lastReportURL {
                    Button("Save report") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .help("Show the report file in Finder")
                    Text(url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                let failed = session.failedCount()
                if failed > 0 && !session.isRunning {
                    Button("Re-run failed (\(failed))") { session.rerunFailed() }
                }
                Spacer()
            }
        }
        .padding(.horizontal)
    }
}

/// Everything above the drawing in Developer mode.
struct DevPanel: View {
    @ObservedObject var session: DevSession

    var body: some View {
        VStack(spacing: 8) {
            DeveloperBar(session: session)
            if session.isRunning || session.prompt != nil {
                DevInstructionBox(session: session)
            }
            if session.isRunning {
                DevLiveStrip(session: session)
            }
            if !session.chips.isEmpty {
                DevChips(session: session)
            }
        }
    }
}

/// Re-renders its content when the session changes, with a value snapshot for the drawing; nil when the mode is off.
struct DevObserved<Content: View>: View {
    let session: DevSession?
    let content: (DevOverlay?) -> Content

    init(session: DevSession?, @ViewBuilder content: @escaping (DevOverlay?) -> Content) {
        self.session = session
        self.content = content
    }

    var body: some View {
        if let session {
            Inner(session: session, content: content)
        } else {
            content(nil)
        }
    }

    private struct Inner: View {
        @ObservedObject var session: DevSession
        let content: (DevOverlay?) -> Content
        var body: some View { content(DevOverlay(session)) }
    }
}

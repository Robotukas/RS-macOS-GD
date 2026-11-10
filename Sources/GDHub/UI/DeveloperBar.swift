import SwiftUI
import AppKit

/// Colours of Developer mode: purple is "this mode"; green, red, amber and grey are the verdicts.
enum DevPalette {
    static let purple = Color(red: 0xc7 / 255, green: 0x7d / 255, blue: 0xff / 255)
    static let purpleSoft = Color(red: 0x2d / 255, green: 0x1f / 255, blue: 0x3a / 255)
    static let pass = Color.green
    static let fail = Color.red
    static let inconclusive = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let skipped = Color.gray

    static func color(for highlight: DevHighlight) -> Color {
        switch highlight {
        case .wanted, .linked, .restOutline: return purple
        case .passed: return pass
        case .failed: return fail
        case .skipped: return skipped
        case .inconclusive: return inconclusive
        }
    }

    static func color(for verdict: DevVerdict?) -> Color {
        switch verdict {
        case .pass?: return pass
        case .fail?, .invalid?: return fail
        case .inconclusive?: return inconclusive
        case .skipped?, nil: return skipped
        }
    }

    static func color(for status: DevChip.Status) -> Color {
        switch status {
        case .pending: return skipped
        case .current: return purple
        case .passed: return pass
        case .failed: return fail
        case .skipped: return skipped
        case .inconclusive: return inconclusive
        }
    }
}

extension DevTarget {
    /// The segmented picker's short label (the long `displayName` is the tooltip).
    var shortName: String {
        switch self {
        case .engine: return "App"
        case .shadow: return "App + driver check"
        case .driver: return "Driver"
        case .inApp: return "In-app"
        }
    }
}

/// The bar above the drawing while Developer mode is on: Record on, Template, Start / Stop, and the notes.
struct DeveloperBar: View {
    @ObservedObject var session: DevSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                targetControl
                Divider().frame(height: 16)
                templateControl
                Spacer(minLength: 8)
                startStop
            }
            notes
            if let prompt = session.prompt {
                DevPromptStrip(session: session, prompt: prompt)
            }
        }
        .font(.callout)
        .padding(10)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DevPalette.purple.opacity(0.45), lineWidth: 1))
        .padding(.horizontal)
    }

    // MARK: Record on

    @ViewBuilder private var targetControl: some View {
        Text("Driven by").foregroundStyle(.secondary)
        if let note = session.pathsNote {
            // A `paths` template switches paths itself, so the choice is not the user's.
            Text(note).foregroundStyle(DevPalette.purple)
        } else if session.targets.isEmpty {
            Text("No path available").foregroundStyle(.secondary)
        } else {
            Picker("Record on", selection: $session.selectedTarget) {
                ForEach(session.targets) { t in
                    Text(t.shortName).tag(Optional(t)).help(t.displayName)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(session.isRunning)
            .help(session.selectedTarget?.displayName ?? "")
        }
    }

    // MARK: Template

    private var templateControl: some View {
        HStack(spacing: 6) {
            Text("Template").foregroundStyle(.secondary)
            Picker("Template", selection: $session.selectedTemplateID) {
                let numbers = Self.numbers(session.templates)
                ForEach(Self.groups(session.templates), id: \.source) { group in
                    Section(group.source.tag) {
                        ForEach(group.entries) { e in
                            Text(Self.rowLabel(e, number: numbers[e.id])).tag(Optional(e.id))
                        }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(session.isRunning || session.templates.isEmpty)
            Button("Reload") { session.reloadTemplates() }
                .disabled(session.isRunning)
                .help("Read the templates again (dev-scripts folder)")
        }
    }

    /// The number each template shows in the picker: 1, 2, 3… down the list as it is drawn (built-in, local override,
    /// local), so "template 7" in a message is row 7 on screen.
    static func numbers(_ entries: [DevTemplateEntry]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, e) in groups(entries).flatMap(\.entries).enumerated() { out[e.id] = i + 1 }
        return out
    }

    /// One picker row: "7. Volume keys under a remap: …", with " (problem)" when the template cannot run.
    static func rowLabel(_ e: DevTemplateEntry, number: Int?) -> String {
        let name = e.isRunnable ? e.title : e.title + " (problem)"
        return number.map { "\($0). \(name)" } ?? name
    }

    /// Entries grouped by where they come from, in the order built-in, local override, local.
    static func groups(_ entries: [DevTemplateEntry]) -> [(source: DevTemplateSource, entries: [DevTemplateEntry])] {
        let order: [DevTemplateSource] = [.builtIn, .localOverride, .local]
        return order.compactMap { src in
            let items = entries.filter { $0.source == src }
            return items.isEmpty ? nil : (src, items)
        }
    }

    // MARK: Start / Stop

    @ViewBuilder private var startStop: some View {
        if session.isRunning {
            Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .help("End the run now; the table shows the steps done so far (Esc)")
        } else {
            Button { session.start() } label: { Label("Start", systemImage: "play.fill") }
                .tint(.green)
                .buttonStyle(.borderedProminent)
                .disabled(!session.canStart)
                .help(session.startBlockReason ?? "Start the run")
        }
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        if !session.isRunning, let why = session.startBlockReason {
            HStack(spacing: 8) {
                Text(why).foregroundStyle(.orange)
                if why == "Engine not running" {
                    Button("Restart engine") { session.restartEngine() }
                }
            }
        }
        ForEach(Array(session.templateProblems.enumerated()), id: \.offset) { _, problem in
            Text(problem).font(.caption).foregroundStyle(.red)
        }
        if let hint = session.hint {
            Text(hint).font(.caption).foregroundStyle(.secondary)
        } else if !session.isRunning && session.startBlockReason == nil && !session.finishedWithResults {
            Text("Who drives the controller is switched for you when the run starts and put back when it ends.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error = session.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }
}

/// "Run anyway" / "Re-arm for this run": an inline question, not a modal.
private struct DevPromptStrip: View {
    @ObservedObject var session: DevSession
    let prompt: DevPrompt

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(confirmTitle) { session.answerRunAnyway() }
            Button("Cancel") { session.cancelPrompt() }
        }
        .padding(8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
    }

    private var text: String {
        switch prompt {
        case .runAnyway(let status): return status
        case .rearmLatched(let reason): return reason
        }
    }

    private var confirmTitle: String {
        switch prompt {
        case .runAnyway: return "Run anyway"
        case .rearmLatched: return "Re-arm for this run"
        }
    }
}

import Foundation

/// Where a template in the picker comes from.
enum DevTemplateSource: String, Equatable {
    /// Bundled with the app (`dev-script-<id>.json`), read-only, always the version this build shipped.
    case builtIn
    /// A file in `~/Library/Application Support/GDHub/dev-scripts/`.
    case local
    /// A local file whose id is a built-in's: it wins.
    case localOverride

    var tag: String {
        switch self {
        case .builtIn: return "built-in"
        case .local: return "local"
        case .localOverride: return "local override"
        }
    }
}

/// One line of the template picker. A file that does not decode or does not validate is still an entry, with its
/// problems, so the hint can say what is wrong instead of the template silently missing.
struct DevTemplateEntry: Equatable, Identifiable {
    var id: String
    var template: DevTemplate?
    var source: DevTemplateSource
    var url: URL
    var errors: [String] = []
    var warnings: [String] = []

    var problems: [String] { errors + warnings }
    /// Start is disabled while any error stands.
    var isRunnable: Bool { template != nil && errors.isEmpty }
    var title: String { template.map { $0.title.isEmpty ? $0.id : $0.title } ?? url.deletingPathExtension().lastPathComponent }
}

enum DevTemplates {
    static let filePrefix = "dev-script-"
    static let builtInOrder = ["full", "sticks", "gkeys"]

    /// `~/Library/Application Support/GDHub/dev-scripts/` (or under `GDHUB_SUPPORT_DIR`).
    static var folderURL: URL { MappingStore.defaultURL(fileName: "dev-scripts") }

    /// Built-ins from the bundle, then the folder's files, each validated against `layout`. A local file with a
    /// built-in's id replaces it. Nothing is copied anywhere, so a fix shipped in the app reaches every Mac.
    static func load(bundle: Bundle = .module, folder: URL? = nil, layout: ControlLayout) -> [DevTemplateEntry] {
        var entries: [DevTemplateEntry] = []

        let bundled = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in bundled { entries.append(entry(from: url, source: .builtIn, layout: layout)) }

        let dir = folder ?? folderURL
        let local = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in local {
            var e = entry(from: url, source: .local, layout: layout)
            if let t = e.template {
                if let at = entries.firstIndex(where: { $0.template?.id == t.id && $0.source == .builtIn }) {
                    e.source = .localOverride
                    entries[at] = e
                    continue
                }
                if entries.contains(where: { $0.template?.id == t.id }) {
                    e.errors.append("\(url.lastPathComponent): another local file already uses the id \"\(t.id)\"")
                }
            }
            entries.append(e)
        }

        func rank(_ e: DevTemplateEntry) -> (Int, Int, String) {
            let builtinSlot = e.template.flatMap { builtInOrder.firstIndex(of: $0.id) }
            return (e.source == .local ? 1 : 0, builtinSlot ?? builtInOrder.count, e.id)
        }
        return entries.sorted { rank($0) < rank($1) }
    }

    /// Reads and validates one file.
    static func entry(from url: URL, source: DevTemplateSource, layout: ControlLayout) -> DevTemplateEntry {
        let fallbackID = url.deletingPathExtension().lastPathComponent
        var e = DevTemplateEntry(id: fallbackID, template: nil, source: source, url: url)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            e.errors = ["\(url.lastPathComponent): cannot read the file (\(error.localizedDescription))"]
            return e
        }
        do {
            let t = try DevTemplate.decode(data)
            e.template = t
            if !t.id.isEmpty { e.id = t.id }
            let v = t.validation(layout: layout)
            e.errors = v.errors
            e.warnings = v.warnings
        } catch {
            e.errors = ["\(url.lastPathComponent): \(describe(error))"]
        }
        return e
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? DevSchemaError { return e.description }
        if let e = error as? DecodingError {
            switch e {
            case .dataCorrupted(let c): return "not a readable template (\(c.debugDescription))"
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c):
                let path = c.codingPath.map(\.stringValue).joined(separator: ".")
                return "not a readable template (\(path.isEmpty ? "top level" : path): \(c.debugDescription))"
            @unknown default: return "not a readable template"
            }
        }
        return error.localizedDescription
    }
}

/// The templates that are generated from the layout, so they cannot drift from it. The bundled
/// `dev-script-<id>.json` files are these, written out; a unit test fails when the two differ.
enum DevBuiltins {
    static func fileName(for template: DevTemplate) -> String { "\(DevTemplates.filePrefix)\(template.id).json" }

    static func generate(layout: ControlLayout) -> [DevTemplate] {
        let ordered = layout.controlsByOrder
        let full = DevTemplate(
            id: "full", title: "Full check",
            notes: "Every control: both sticks first, then a hands-off check, then the rest in layout order (triggers, every button "
                + "including the D-pad, the paddles, the SAX buttons, G1-G5, Profile and Start). About three minutes. Run it on the "
                + "Engine path first and on Driver LIVE after that, then compare the two reports. The sticks come before the "
                + "hands-off check because the pad posts nothing while idle and does not answer GetReport: its state is known only "
                + "after it has moved once, and a stick step ends at centre. Profile comes last: each press switches the "
                + "controller's onboard profile, which changes what the paddles and SAX keys echo (seen 2026-11-09).",
            steps: ordered.filter { $0.kind == .stick }.map(step(for:)) + [restStep()]
                + ordered.filter { $0.kind != .stick && $0.id != "profile" }.map(step(for:))
                + ordered.filter { $0.id == "profile" }.map(step(for:)))
        let sticks = DevTemplate(
            id: "sticks", title: "Sticks check",
            notes: "Both sticks, then a hands-off check (after the sticks, so the pad's state is known). Use it after changing "
                + "anything in the stick path (dead band, scaling).",
            steps: ordered.filter { $0.kind == .stick }.map(step(for:)) + [restStep()])
        let gkeyIDs = ["g1", "g2", "g3", "g4", "g5", "profile", "start"]
        let gkeys = DevTemplate(
            id: "gkeys", title: "G keys, Profile and Start",
            notes: "G1-G5 and Profile are not forwarded to the pad unless a mapping routes them, so the pad must stay quiet; "
                + "Start arrives as the Guide button (report 0x02). Use it after touching key mappings.",
            steps: gkeyIDs.compactMap { layout.control(id: $0) }.map(step(for:)))
        let echoIDs = ["paddle_outer_left", "paddle_inner_left", "paddle_inner_right", "paddle_outer_right", "sax_left", "sax_right"]
        var echo = DevTemplate(
            id: "paddles-sax-echo", title: "Paddles and SAX echo (App, then Driver)",
            notes: "The four paddles and the two SAX keys, without touching Profile, run on the App path and then on Driver LIVE "
                + "back to back. The expected column assumes the factory echo (paddles = D-pad, SAX = A/B); when the controller's "
                + "current onboard profile differs, the step fails with 'unexpected change on <button>' — that button IS the "
                + "echo. Both passes must show the same echoes; if they differ, the driver's translation is at fault, not the "
                + "profile. Added 2026-11-09 after the Full checks showed the profile cycling between runs.",
            steps: echoIDs.compactMap { layout.control(id: $0) }.map(step(for:)))
        echo.paths = ["engine", "driver"]
        return [full, sticks, gkeys, echo, remapG1AsY(), remapSwapAB(), t7RTHoldToggle(), t8Latency(layout: layout)]
    }

    // MARK: Remap checks

    /// A step that only counts when the mapping has these picks (the runner never sets a mapping; the owner does, in Mapping).
    private static func requiring(_ mapping: [String: String], _ step: DevStep) -> DevStep {
        var s = step
        var r = DevRequires()
        r.mapping = mapping
        s.requires = r
        return s
    }

    /// A digital step whose expectation is written out, so the template does not check the mapper against itself.
    private static func pressing(_ id: String, label: String, expect buttons: [String], detail: String) -> DevStep {
        var s = DevStep(id: id, kind: .digital, controls: [id], title: "Press \(label) twice", detail: detail, seconds: 3)
        var e = DevExpect()
        e.items = DevExpectedItems(buttons: buttons)
        s.expect = e
        return s
    }

    /// G1 sent to the pad's Y (remap R4): the key presses Y, the real Y still presses Y, and handing Y from one to the
    /// other leaves it held.
    static func remapG1AsY() -> DevTemplate {
        let need = ["g1": "y"]
        var hold = DevStep(id: "hold-g1-then-y", kind: .held, controls: ["g1", "y"],
                           title: "Hold G1, then also hold Y, let go of G1, keep Y held",
                           detail: "Press and hold G1. While it is held, also press and hold Y. Then let go of G1 and keep holding Y until the screen says \"Let go now\". The pad's Y must stay down the whole time.",
                           seconds: 6)
        var holdExpect = DevExpect()
        holdExpect.item = "Y"
        holdExpect.releases = ["g1"]
        hold.expect = holdExpect
        return DevTemplate(
            id: "remap-g1-as-y", title: "Remap check: G1 sent to Y (App, then Driver)",
            notes: "Use it after changing anything that remaps keys: the mapper, the driver's map or Mapping itself. Before you start: "
                + "Mapping → G1 → Y. Afterwards: Mapping → Reset all remaps. Pressing G1 must show Y on the pad, pressing Y must "
                + "still show Y, and with both down the pad's Y must stay down when G1 is let go. The expectations are written out in "
                + "the template on purpose, so it does not check the mapper against itself. Runs on the App path and then on Driver "
                + "LIVE; if the driver cannot express the mapping, the Driver pass says so instead of passing.",
            paths: ["engine", "driver"],
            steps: [
                requiring(need, restStep()),
                requiring(need, pressing("g1", label: "G1", expect: ["Y"],
                                         detail: "Press G1, let go, press it again, let go. With G1 sent to Y the pad shows Y.")),
                requiring(need, pressing("y", label: "Y", expect: ["Y"],
                                         detail: "Press Y, let go, press it again, let go. Y still shows Y on the pad.")),
                requiring(need, hold),
            ])
    }

    /// A and B swapped (remap R4): the two keys cross over on the pad, and a swap left on breaks games, so the notes end
    /// with the reset.
    static func remapSwapAB() -> DevTemplate {
        let need = ["a": "b", "b": "a"]
        return DevTemplate(
            id: "remap-swap-a-b", title: "Remap check: A and B swapped (App, then Driver)",
            notes: "Use it after changing anything that remaps keys. Before you start: Mapping → A → B, then Mapping → B → A. "
                + "Afterwards: Mapping → Reset all remaps (an A/B swap left on breaks games). Pressing A must show B on the pad "
                + "and pressing B must show A. The expectations are written out in the template on purpose, so it does not check the "
                + "mapper against itself. Runs on the App path and then on Driver LIVE.",
            paths: ["engine", "driver"],
            steps: [
                requiring(need, restStep()),
                requiring(need, pressing("a", label: "A", expect: ["B"],
                                         detail: "Press A, let go, press it again, let go. With A and B swapped the pad shows B.")),
                requiring(need, pressing("b", label: "B", expect: ["A"],
                                         detail: "Press B, let go, press it again, let go. With A and B swapped the pad shows A.")),
            ])
    }

    /// RT held while the app hands the controller between Driver and App (the T7 driver check the stopwatch kept
    /// failing): the window opens when RT is held and the pad's RT must never drop for the whole of it.
    static func t7RTHoldToggle() -> DevTemplate {
        var hold = DevStep(id: "rt-hold", kind: .held, controls: ["rt"], title: "Pull RT all the way in and just hold it still",
                           detail: "Only hold RT. Do not press or move anything else, and do not let go until the screen says \"Let go now\" (about 40 s). You have nothing else to do: the app itself switches who drives the controller, App and Driver in turn, 12 times while you hold.",
                           seconds: 45)
        var toggle = DevToggleInputPath()
        toggle.values = ["driver", "engine"]
        toggle.intervalMs = 3000
        toggle.count = 12
        var action = DevAction()
        action.toggleInputPath = toggle
        hold.actions = [action]
        var expect = DevExpect()
        expect.item = "RT"
        expect.minLevel = 0.5
        hold.expect = expect
        return DevTemplate(
            id: "t7-rt-hold-toggle", title: "Hold RT while the app switches App ↔ Driver (T7)",
            notes: "Pull RT all the way down and keep it there. While you hold it the app switches who drives the controller, "
                + "Driver then App, 12 times (every 3 s, about 40 s in all), and the check is that the virtual pad's RT never "
                + "drops below 0.5 in that time: no hand-over may let the trigger go. Use it after any change to pad "
                + "arbitration, pinning or the posting gate. It needs the background engine. Start it with the App path "
                + "selected; the path is put back to the run's target when the hand-overs are done and to what it was before "
                + "when the run ends. The result also says how many hand-overs the engine was seen following (armed live / inert). "
                + "Added 2026-11-09 for the T7 driver check.",
            steps: [hold])
    }

    /// The receiver-takeover gate's latency rows (docs/plans/receiver-takeover-plan.md 9.3, G4a and G4b): presses and
    /// stick onsets with the per-event latency from the kernel timestamps of the receiver frames and the pad reports,
    /// App path then Driver LIVE in one session so `dev-run-compare.py` can put the two side by side.
    static func t8Latency(layout: ControlLayout) -> DevTemplate {
        var flick = DevStep(id: "flick-left", kind: .stick, controls: ["left_stick"],
                            title: "Flick the LEFT stick hard and let it spring back, 10 times",
                            detail: "Snap the left stick out to the rim and let go so it springs back to centre by itself, ten times, about one a second. Wait for it to settle between flicks. Leave the right stick alone.",
                            seconds: 12, releaseSeconds: 0.5)
        var flickExpect = DevExpect()
        flickExpect.flicks = 10
        flickExpect.requireDirections = false
        flick.expect = flickExpect

        func taps(_ id: String, _ label: String) -> DevStep {
            var s = DevStep(id: id, kind: .digital, controls: [id.replacingOccurrences(of: "tap-", with: "")],
                            title: "Tap \(label) 10 times",
                            detail: "Press \(label) and let go again, ten times, at an easy pace (a few a second). Each press and each release is timed.",
                            seconds: 10)
            var e = DevExpect()
            e.times = 10
            s.expect = e
            return s
        }

        var pull = DevStep(id: "pull-rt", kind: .trigger, controls: ["rt"],
                           title: "Pull RT all the way and release, 5 times",
                           detail: "Squeeze RT all the way down and let it come fully back up, five times, with a short pause between.",
                           seconds: 10, releaseSeconds: 0.5)
        var pullExpect = DevExpect()
        pullExpect.times = 5
        pull.expect = pullExpect

        var circle = DevBuiltins.step(for: layout.control(id: "left_stick")!)
        circle.id = "circle-left"

        return DevTemplate(
            id: "t8-latency", title: "Latency: controller to pad, per press (App, then Driver) — T8 gate",
            notes: "Measures how long the virtual pad takes to show each press, release, trigger pull and stick onset after the "
                + "receiver reports it (kernel timestamps on both sides, per event). It is the evidence for the receiver-takeover gate "
                + "(docs/plans/receiver-takeover-plan.md 9.3): G4a, Driver digital p50 is 0.5 ms or less; G4b, Driver is at least "
                + "0.2 ms lower than App on digital and on stick onset. Both passes run back to back in one session (App path, then "
                + "Driver LIVE), so the two reports share the mapping and the template and can be compared with "
                + "scripts/tools/dev-run-compare.py A.json B.json, which prints the per-step latency columns and a one-line gate summary. "
                + "Each step also has to pass as an ordinary check (ten flicks, ten taps of A and of B, five full RT pulls). Do the "
                + "movements the same way in both passes; the hands-still gate waits for you between steps. Added 2026-11-09 for T8.",
            paths: ["engine", "driver"],
            steps: [flick, taps("tap-a", "A"), taps("tap-b", "B"), pull, circle])
    }

    static func restStep() -> DevStep {
        DevStep(id: "rest", kind: .rest, title: "Hands off everything",
                detail: "Put the controller down and let go of every stick, trigger and button. The pad has to stay completely still.",
                seconds: 3)
    }

    static func step(for control: ControlLayout.Control) -> DevStep {
        let where_ = "on the \(placeName(control.view))"
        switch control.kind {
        case .stick:
            let side = control.id.hasPrefix("left") ? "LEFT" : (control.id.hasPrefix("right") ? "RIGHT" : control.label.uppercased())
            let otherSide = control.id.hasPrefix("left") ? "right" : "left"
            return DevStep(id: control.id, kind: .stick, controls: [control.id],
                           title: "Roll the \(side) stick in one or two slow circles, then let go",
                           detail: "Push it to the rim and go all the way round, slowly, once or twice, then release it. Leave the \(otherSide) stick alone.",
                           seconds: 5, releaseSeconds: 0.5)
        case .trigger:
            return DevStep(id: control.id, kind: .trigger, controls: [control.id],
                           title: "Pull \(control.label) fully, then let go",
                           detail: "\(control.label) is \(where_). Squeeze it all the way down and release it completely.",
                           seconds: 3, releaseSeconds: 0.5)
        case .button:
            return DevStep(id: control.id, kind: .digital, controls: [control.id],
                           title: "Press \(control.label) twice",
                           detail: "\(control.label) is \(where_). Press it, let go, press it again, let go. \(buttonNote(control.id))",
                           seconds: 3)
        }
    }

    private static func buttonNote(_ id: String) -> String {
        switch id {
        case "g1", "g2", "g3", "g4", "g5":
            return "The pad should send nothing for this key unless a mapping routes it."
        case "profile":
            return "The pad should send nothing for this key. Each press also switches the controller's own profile, which changes what the paddles and SAX keys send."
        case "start":
            return "The pad shows Start as the Guide button."
        case "sax_left", "sax_right":
            return "The pad shows this one as the button the controller's own profile sends for it."
        default:
            return id.hasPrefix("paddle_") ? "The pad shows a paddle as the button the controller's own profile sends for it." : ""
        }
    }

    private static func placeName(_ side: ControlLayout.Side) -> String {
        switch side {
        case .front: return "front"
        case .back: return "back"
        case .sideLeft: return "left side"
        case .sideRight: return "right side"
        }
    }
}

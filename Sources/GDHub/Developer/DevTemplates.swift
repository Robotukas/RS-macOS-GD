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
            notes: "Every control, in layout order: one hands-off check, both sticks, both triggers, then every button including "
                + "the D-pad, the paddles, the SAX buttons, G1-G5, Profile and Start. About three minutes. Run it on the Engine "
                + "path first and on Driver LIVE after that, then compare the two reports.",
            steps: [restStep()] + ordered.map(step(for:)))
        let sticks = DevTemplate(
            id: "sticks", title: "Sticks check",
            notes: "A hands-off check, then both sticks. Use it after changing anything in the stick path (dead band, scaling).",
            steps: [restStep()] + ordered.filter { $0.kind == .stick }.map(step(for:)))
        let gkeyIDs = ["g1", "g2", "g3", "g4", "g5", "profile", "start"]
        let gkeys = DevTemplate(
            id: "gkeys", title: "G keys, Profile and Start",
            notes: "G1-G5 and Profile are not forwarded to the pad unless a mapping routes them, so the pad must stay quiet; "
                + "Start arrives as the Guide button (report 0x02). Use it after touching key mappings.",
            steps: gkeyIDs.compactMap { layout.control(id: $0) }.map(step(for:)))
        return [full, sticks, gkeys]
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
        case "g1", "g2", "g3", "g4", "g5", "profile":
            return "The pad should send nothing for this key unless a mapping routes it."
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

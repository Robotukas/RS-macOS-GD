import Foundation

// The data model of Developer mode (docs/plans/developer-mode-plan.md, "Model"): templates (what a run asks the
// owner to do) and run reports (what the virtual pad sent for it). Both files are read back by other builds and by the
// compare tool, so decoding is tolerant: a missing key takes its default, an unknown key is ignored, and only the
// schema number decides whether a file is understood at all.

extension KeyedDecodingContainer {
    /// `decodeIfPresent` with a default. A key of the wrong type still throws: that is a broken file, not an old one.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

/// A file written by a newer build (higher schema number) is refused rather than half-read.
struct DevSchemaError: Error, CustomStringConvertible, Equatable {
    let found: Int
    let supported: Int
    var description: String { "schema \(found) is newer than this build understands (\(supported))" }
}

// MARK: - Template

enum DevKind: String, Codable, CaseIterable {
    case rest, stick, trigger, digital, held

    /// Whether a control of this layout kind fits a step of this kind; `rest` takes no control. A held step watches
    /// one pad item: a button, or a trigger held down.
    func fits(_ control: ControlLayout.Kind) -> Bool {
        switch self {
        case .rest: return true
        case .stick: return control == .stick
        case .trigger: return control == .trigger
        case .digital: return control == .button
        case .held: return control == .button || control == .trigger
        }
    }

    /// What a control must be for this kind, for the validation message.
    var fitsDescription: String {
        switch self {
        case .rest: return "no control"
        case .stick: return "a stick"
        case .trigger: return "a trigger"
        case .digital: return "a button"
        case .held: return "a button or a trigger"
        }
    }

    var defaultSeconds: Double {
        switch self {
        case .rest: return 3
        case .stick: return 5
        case .trigger: return 3
        case .digital: return 3
        case .held: return 5
        }
    }

    var defaultReleaseSeconds: Double { self == .stick || self == .trigger || self == .held ? 0.5 : 0 }
}

/// Per-step overrides of the judge's thresholds and of the simulated expectation. Flat on purpose: only the keys of the
/// step's kind mean anything, the rest are ignored, and a template written for a newer build with more keys still loads.
struct DevExpect: Codable, Equatable {
    // stick
    var minReports: Int?
    var extent: Double?
    var deadZone: Double?
    var otherStickStill: Bool?
    var requireReturn: Bool?
    /// Flick steps: instead of the four-direction circle the stick has to leave the dead zone from rest this many times
    /// (and come back). nil = the circle rule.
    var flicks: Int?
    /// false drops the four-direction check (flick steps); nil = true.
    var requireDirections: Bool?
    // trigger
    var peak: Double?
    var release: Double?
    // digital: replaces the simulated expectation; `times` is also the number of full pulls (peak, then release) a
    // trigger step needs (1 when nil)
    var items: DevExpectedItems?
    var times: Int?
    // held: the pad item that has to stay held ("RT", "A", a hat direction "N"…"NW"; nil = derived from the control)
    // and the trigger level that counts as held (0.5)
    var item: String?
    var minLevel: Double?
    var seconds: Double?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minReports = try c.decodeIfPresent(Int.self, forKey: .minReports)
        extent = try c.decodeIfPresent(Double.self, forKey: .extent)
        deadZone = try c.decodeIfPresent(Double.self, forKey: .deadZone)
        otherStickStill = try c.decodeIfPresent(Bool.self, forKey: .otherStickStill)
        requireReturn = try c.decodeIfPresent(Bool.self, forKey: .requireReturn)
        flicks = try c.decodeIfPresent(Int.self, forKey: .flicks)
        requireDirections = try c.decodeIfPresent(Bool.self, forKey: .requireDirections)
        peak = try c.decodeIfPresent(Double.self, forKey: .peak)
        release = try c.decodeIfPresent(Double.self, forKey: .release)
        items = try c.decodeIfPresent(DevExpectedItems.self, forKey: .items)
        times = try c.decodeIfPresent(Int.self, forKey: .times)
        item = try c.decodeIfPresent(String.self, forKey: .item)
        minLevel = try c.decodeIfPresent(Double.self, forKey: .minLevel)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
    }
}

/// What a digital control should do on the pad: the buttons that go down, the hat direction (N, NE … NW) and Guide.
/// Empty means "nothing on the pad": the control is not forwarded (G keys, Profile) and the pad must stay quiet.
struct DevExpectedItems: Codable, Equatable {
    var buttons: [String] = []
    var hat: String?
    var guide = false

    init(buttons: [String] = [], hat: String? = nil, guide: Bool = false) {
        self.buttons = buttons
        self.hat = hat
        self.guide = guide
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try c.value(.buttons, [])
        hat = try c.decodeIfPresent(String.self, forKey: .hat)
        guide = try c.value(.guide, false)
    }

    init(items: Set<PadItem>) {
        buttons = PadItem.buttonItems.filter { items.contains($0) }.map(\.name)
        hat = PadHat.value(for: items).flatMap { $0 == 0 ? nil : PadHat.name($0) }
        guide = items.contains(.guide)
    }

    var isEmpty: Bool { buttons.isEmpty && hat == nil && !guide }

    /// The same expectation as pad items, which is what the judge compares with. Names that mean nothing are skipped
    /// here and reported by `DevTemplate.validate`.
    var items: Set<PadItem> {
        var s = Set(buttons.compactMap(PadItem.init(name:)))
        if let hat, let v = PadHat.value(named: hat) { s.formUnion(PadHat.items(v)) }
        if guide { s.insert(.guide) }
        return s
    }

    /// "A, D-pad left, Guide", or "nothing on the pad".
    var summary: String {
        if isEmpty { return "nothing on the pad" }
        var parts = buttons
        if let hat { parts.append("hat \(hat)") }
        if guide { parts.append("Guide") }
        return parts.joined(separator: ", ")
    }
}

struct DevToggleInputPath: Codable, Equatable {
    var values: [String] = []
    var intervalMs = 1000
    var count = 1

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.value(.values, [])
        intervalMs = try c.value(.intervalMs, 1000)
        count = try c.value(.count, 1)
    }
}

/// Something the app does during a held step: hands the controller over between input paths while the owner holds.
struct DevAction: Codable, Equatable {
    var toggleInputPath: DevToggleInputPath?
    init() {}
}

struct DevRequires: Codable, Equatable {
    /// control id → the output the control must currently send (`"g1": "y"`). The value comes from a closed
    /// vocabulary, exactly `ControlOutput(string:)`: a pad output id (`y`, `dpad_up`, `lt`, `guide` …), `nothing` or
    /// `built_in` (G2-G4 only). It is compared with `ControlMapping.effectiveOutput`, so a control left alone
    /// "sends" its default. A step whose requirement is not met is skipped, not failed.
    var mapping: [String: String]?
    init() {}
}

struct DevStep: Codable, Equatable {
    var id = ""
    /// Decoded as text and checked by `DevTemplate.validate`, so a template with a kind from a newer build is still
    /// listed, with a problem, instead of vanishing.
    var kind = ""
    var controls: [String] = []
    var title = ""
    var detail = ""
    var seconds: Double?
    var readySeconds: Double?
    var releaseSeconds: Double?
    var expect: DevExpect?
    var requires: DevRequires?
    var actions: [DevAction]?

    init(id: String, kind: DevKind, controls: [String] = [], title: String, detail: String = "",
         seconds: Double? = nil, readySeconds: Double? = nil, releaseSeconds: Double? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.controls = controls
        self.title = title
        self.detail = detail
        self.seconds = seconds
        self.readySeconds = readySeconds
        self.releaseSeconds = releaseSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        kind = try c.value(.kind, "")
        controls = try c.value(.controls, [])
        title = try c.value(.title, "")
        detail = try c.value(.detail, "")
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        readySeconds = try c.decodeIfPresent(Double.self, forKey: .readySeconds)
        releaseSeconds = try c.decodeIfPresent(Double.self, forKey: .releaseSeconds)
        expect = try c.decodeIfPresent(DevExpect.self, forKey: .expect)
        requires = try c.decodeIfPresent(DevRequires.self, forKey: .requires)
        actions = try c.decodeIfPresent([DevAction].self, forKey: .actions)
    }

    var devKind: DevKind? { DevKind(rawValue: kind) }

    /// The toggle actions in order. They run one after the other.
    var toggleActions: [DevToggleInputPath] { (actions ?? []).compactMap(\.toggleInputPath) }

    /// A step that switches the input path while it runs (needs the background engine).
    var hasInputPathActions: Bool { toggleActions.contains { !$0.values.isEmpty && $0.count >= 1 } }

    /// Every path write of the step as milliseconds from the window start, in order: each toggle cycles through its
    /// `values` `count` times, one write per `intervalMs`, starting at the window start; the next toggle starts when the
    /// previous one has completed (its last interval has run out).
    var inputPathSchedule: [(offsetMs: Int, value: String)] {
        var out: [(offsetMs: Int, value: String)] = []
        var base = 0
        for t in toggleActions where !t.values.isEmpty && t.count >= 1 {
            let step = max(t.intervalMs, 1)
            for k in 0..<t.count { out.append((base + k * step, t.values[k % t.values.count])) }
            base += t.count * step
        }
        return out
    }

    /// When the last action has completed, ms from the window start; nil without actions.
    var inputPathActionsMs: Int? {
        let toggles = toggleActions.filter { !$0.values.isEmpty && $0.count >= 1 }
        return toggles.isEmpty ? nil : toggles.reduce(0) { $0 + $1.count * max($1.intervalMs, 1) }
    }

    /// A held step with actions keeps its window until the last action is done and this much has passed.
    static let afterActionsSeconds = 1.5

    static let readyRange: ClosedRange<Double> = 0...30
    static let releaseRange: ClosedRange<Double> = 0...10
    static let defaultReadySeconds = 2.0

    /// Length of the capture window after clamping into 1…`DevTemplate.maxSeconds`.
    var effectiveSeconds: Double {
        min(max(seconds ?? devKind?.defaultSeconds ?? 3, 1), DevTemplate.maxSeconds)
    }

    /// How long the window really runs: `effectiveSeconds`, except that a held step with actions ends
    /// `afterActionsSeconds` after its last action has completed.
    var windowSeconds: Double {
        if devKind == .held, let ms = inputPathActionsMs { return Double(ms) / 1000 + Self.afterActionsSeconds }
        return effectiveSeconds
    }

    /// Minimum "hands off" time before Go; the hands-still gate may extend it.
    var effectiveReadySeconds: Double {
        min(max(readySeconds ?? Self.defaultReadySeconds, Self.readyRange.lowerBound), Self.readyRange.upperBound)
    }

    /// The "let go" tail after the window.
    var effectiveReleaseSeconds: Double {
        min(max(releaseSeconds ?? devKind?.defaultReleaseSeconds ?? 0, Self.releaseRange.lowerBound), Self.releaseRange.upperBound)
    }
}

struct DevTemplate: Codable, Equatable {
    static let schemaVersion = 1
    /// Longest window a template may ask for (the sleep test waits two minutes for the controller to doze off).
    static let maxSeconds = 120.0
    static let knownPaths = ["engine", "shadow", "driver"]

    var schema = DevTemplate.schemaVersion
    var id = ""
    var version = 1
    var title = ""
    var notes = ""
    /// Input paths to run the template on, one pass each; nil = the user's chosen target.
    var paths: [String]?
    var steps: [DevStep] = []

    init(id: String, version: Int = 1, title: String, notes: String = "", paths: [String]? = nil, steps: [DevStep]) {
        self.id = id
        self.version = version
        self.title = title
        self.notes = notes
        self.paths = paths
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.value(.schema, DevTemplate.schemaVersion)
        if schema > DevTemplate.schemaVersion { throw DevSchemaError(found: schema, supported: DevTemplate.schemaVersion) }
        id = try c.value(.id, "")
        version = try c.value(.version, 1)
        title = try c.value(.title, "")
        notes = try c.value(.notes, "")
        paths = try c.decodeIfPresent([String].self, forKey: .paths)
        steps = try c.value(.steps, [])
    }

    static func decode(_ data: Data) throws -> DevTemplate { try JSONDecoder().decode(DevTemplate.self, from: data) }

    /// Pretty, sorted keys: what the bundled files and the on-disk copies look like.
    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    // MARK: Validation

    struct Validation: Equatable {
        /// Start stays disabled while one of these stands.
        var errors: [String] = []
        /// The template runs, with the value clamped.
        var warnings: [String] = []
        var messages: [String] { errors + warnings }
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Messages in the plan's style ("full.json step 7: unknown control g6"), errors first.
    func validate(layout: ControlLayout) -> [String] { validation(layout: layout).messages }

    func validation(layout: ControlLayout) -> Validation {
        var v = Validation()
        let file = (id.isEmpty ? "template" : id) + ".json"
        if !Self.isValidID(id) {
            v.errors.append("\(file): id \"\(id)\" may only use lowercase letters, digits and dashes")
        }
        if version < 1 { v.errors.append("\(file): version must be 1 or more") }
        if steps.isEmpty { v.errors.append("\(file): has no steps") }
        if let paths {
            if paths.isEmpty { v.errors.append("\(file): paths is empty (leave it out to run on the chosen target)") }
            for p in paths where !Self.knownPaths.contains(p) {
                v.errors.append("\(file): paths value \"\(p)\" is not engine, shadow or driver")
            }
        }
        var firstIndexOfID: [String: Int] = [:]
        for (i, step) in steps.enumerated() {
            let at = "\(file) step \(i + 1)"
            if step.id.isEmpty {
                v.errors.append("\(at): has no id")
            } else if let first = firstIndexOfID[step.id] {
                v.errors.append("\(at): duplicate step id \"\(step.id)\" (also step \(first + 1))")
            } else {
                firstIndexOfID[step.id] = i
            }
            let kind = step.devKind
            if kind == nil { v.errors.append("\(at): unknown kind \"\(step.kind)\"") }
            if kind == .rest {
                if !step.controls.isEmpty { v.errors.append("\(at): a rest step takes no controls") }
            } else if kind != nil, step.controls.isEmpty {
                v.errors.append("\(at): needs at least one control")
            }
            for cid in step.controls {
                guard let control = layout.control(id: cid) else {
                    v.errors.append("\(at): unknown control \(cid)")
                    continue
                }
                if let kind, kind != .rest, !kind.fits(control.kind) {
                    v.errors.append("\(at): a \(kind.rawValue) step does not fit control \(cid) (a \(control.kind.rawValue))")
                }
            }
            if let s = step.seconds, !(1...Self.maxSeconds).contains(s) {
                v.warnings.append("\(at): seconds \(Self.number(s)) is outside 1…\(Self.number(Self.maxSeconds)), using \(Self.number(step.effectiveSeconds))")
            }
            if let s = step.readySeconds, !DevStep.readyRange.contains(s) {
                v.warnings.append("\(at): readySeconds \(Self.number(s)) is outside \(Self.number(DevStep.readyRange.lowerBound))…\(Self.number(DevStep.readyRange.upperBound)), using \(Self.number(step.effectiveReadySeconds))")
            }
            if let s = step.releaseSeconds, !DevStep.releaseRange.contains(s) {
                v.warnings.append("\(at): releaseSeconds \(Self.number(s)) is outside \(Self.number(DevStep.releaseRange.lowerBound))…\(Self.number(DevStep.releaseRange.upperBound)), using \(Self.number(step.effectiveReleaseSeconds))")
            }
            for (cid, value) in (step.requires?.mapping ?? [:]).sorted(by: { $0.key < $1.key }) {
                if layout.control(id: cid) == nil {
                    v.errors.append("\(at): unknown control \(cid) in requires")
                    continue
                }
                guard let output = ControlOutput(string: value) else {
                    v.errors.append("\(at): requires names unknown output \"\(value)\" (use a pad output such as y or dpad_up, nothing, or built_in)")
                    continue
                }
                if !ControlMapping.remappableIDs.contains(cid) {
                    v.errors.append("\(at): requires names \(cid), which has no output that can be remapped")
                } else if output == .builtIn, !ControlMapping.builtInIDs.contains(cid) {
                    v.errors.append("\(at): requires built_in for \(cid), but only g2, g3 and g4 have a built-in function")
                }
            }
            if let items = step.expect?.items {
                for name in items.buttons where !PadItem.buttonItems.contains(where: { $0.name == name }) {
                    v.errors.append("\(at): expect names unknown button \"\(name)\"")
                }
                if let hat = items.hat, PadHat.value(named: hat).map({ $0 == 0 }) ?? true {
                    v.errors.append("\(at): expect names unknown hat direction \"\(hat)\"")
                }
            }
            if let t = step.expect?.times, t < 1 {
                v.errors.append("\(at): expect times \(t) must be 1 or more")
            }
            if let f = step.expect?.flicks {
                if kind != nil, kind != .stick {
                    v.errors.append("\(at): expect flicks only applies to stick steps")
                } else if f < 1 {
                    v.errors.append("\(at): expect flicks \(f) must be 1 or more")
                }
            }
            if kind == .held {
                if let name = step.expect?.item, DevHeldItem(name: name) == nil {
                    v.errors.append("\(at): expect names unknown item \"\(name)\" (use RT, LT, a button such as A, or a hat direction N…NW)")
                }
                if let level = step.expect?.minLevel, !(level > 0 && level <= 1) {
                    v.errors.append("\(at): expect minLevel \(Self.number(level)) must be above 0 and at most 1")
                }
            }
            if !(step.actions ?? []).isEmpty, kind != nil, kind != .held {
                v.errors.append("\(at): actions are only supported on held steps")
            }
            if kind == .held, let ms = step.inputPathActionsMs, step.effectiveSeconds < step.windowSeconds {
                v.warnings.append("\(at): seconds \(Self.number(step.effectiveSeconds)) is shorter than the actions need; the window follows the actions and runs \(Self.number(step.windowSeconds)) s (\(Self.number(Double(ms) / 1000)) s of actions + \(Self.number(DevStep.afterActionsSeconds)) s)")
            }
            for action in step.actions ?? [] {
                guard let t = action.toggleInputPath else { continue }
                for value in t.values where !Self.knownPaths.contains(value) {
                    v.errors.append("\(at): toggleInputPath value \"\(value)\" is not engine, shadow or driver")
                }
                if t.values.isEmpty || t.count < 1 || t.intervalMs < 1 {
                    v.errors.append("\(at): toggleInputPath needs values, a count of 1 or more and an intervalMs of 1 or more")
                }
            }
        }
        return v
    }

    /// 5 not 5.0; 0.5 stays 0.5.
    private static func number(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}

// MARK: - Verdict

/// `{"verdict":"fail","reason":"…"}`; `pass` has no reason.
enum DevVerdict: Equatable, Codable {
    case pass
    case fail(String)
    case skipped(String)
    case inconclusive(String)
    case invalid(String)

    var tag: String {
        switch self {
        case .pass: return "pass"
        case .fail: return "fail"
        case .skipped: return "skipped"
        case .inconclusive: return "inconclusive"
        case .invalid: return "invalid"
        }
    }

    var reason: String? {
        switch self {
        case .pass: return nil
        case .fail(let r), .skipped(let r), .inconclusive(let r), .invalid(let r): return r
        }
    }

    var isPass: Bool { self == .pass }

    private enum CodingKeys: String, CodingKey { case verdict, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .verdict)
        let reason = try c.value(.reason, "")
        switch tag {
        case "pass": self = .pass
        case "fail": self = .fail(reason)
        case "skipped": self = .skipped(reason)
        case "inconclusive": self = .inconclusive(reason)
        case "invalid": self = .invalid(reason)
        // A verdict from a newer build is shown, not guessed at.
        default: self = .inconclusive("unknown verdict \"\(tag)\"" + (reason.isEmpty ? "" : ": \(reason)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tag, forKey: .verdict)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

// MARK: - Run report

/// One raw input report of the virtual pad as it was read.
struct DevRawReport: Codable, Equatable {
    enum Phase: String, Codable { case ready, window, release }

    /// Milliseconds from the window start; negative in the ready phase.
    var tMs: Double
    var id: UInt8
    /// Space-separated hex, ID byte first: `01 00 80 …`.
    var bytes: String
    var phase: Phase

    init(tMs: Double, id: UInt8, bytes: [UInt8], phase: Phase) {
        self.tMs = tMs
        self.id = id
        self.bytes = Self.hex(bytes)
        self.phase = phase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tMs = try c.value(.tMs, 0)
        id = try c.value(.id, 0)
        bytes = try c.value(.bytes, "")
        phase = try c.value(.phase, .window)
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    var byteValues: [UInt8] { bytes.split(separator: " ").compactMap { UInt8($0, radix: 16) } }
}

struct DevMetrics: Codable, Equatable {
    /// Reports read from the pad during the window and the release tail.
    var padReports = 0
    /// How many of them changed the held state at all (exact, no tolerance).
    var padChanged = 0
    var rawDropped = 0
    /// Frames the GUI saw from the receiver: labelled "frames seen by the GUI".
    var framesSeen = 0
    var framesPerSecond = 0.0
    var movingMs = 0.0
    /// Pad changes the receiver frames should have produced (the reference), if it was available.
    var expectedChanges: Int?
    /// `padChanged / expectedChanges`.
    var lossRatio: Double?
    /// First pad change minus first reference change, milliseconds.
    var onsetMs: Double?
    /// Fixed keys per kind: see `DevJudge`.
    var values: [String: Double] = [:]
    var detail = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        padReports = try c.value(.padReports, 0)
        padChanged = try c.value(.padChanged, 0)
        rawDropped = try c.value(.rawDropped, 0)
        framesSeen = try c.value(.framesSeen, 0)
        framesPerSecond = try c.value(.framesPerSecond, 0)
        movingMs = try c.value(.movingMs, 0)
        expectedChanges = try c.decodeIfPresent(Int.self, forKey: .expectedChanges)
        lossRatio = try c.decodeIfPresent(Double.self, forKey: .lossRatio)
        onsetMs = try c.decodeIfPresent(Double.self, forKey: .onsetMs)
        values = try c.value(.values, [:])
        detail = try c.value(.detail, "")
    }
}

struct DevEffectivePath: Codable, Equatable {
    var atReady: String?
    var atStart: String?
    var atEnd: String?
    init(atReady: String? = nil, atStart: String? = nil, atEnd: String? = nil) {
        self.atReady = atReady; self.atStart = atStart; self.atEnd = atEnd
    }
}

struct DevAttempt: Codable, Equatable {
    var startedNs: UInt64 = 0
    var readyNs: UInt64 = 0
    var windowStartNs: UInt64 = 0
    var windowEndNs: UInt64 = 0
    var superseded = false
    /// "Run anyway" after a path confirmation timed out.
    var pathUnconfirmed = false
    var verdict: DevVerdict = .inconclusive("not judged")
    var metrics = DevMetrics()
    /// The pad state the judge started from (nil = no report had been seen).
    var entryState: PadDecodedState?
    /// The last report of each ID before the step, as hex.
    var entryRaw: [String] = []
    var effectivePath = DevEffectivePath()
    var raw: [DevRawReport] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedNs = try c.value(.startedNs, 0)
        readyNs = try c.value(.readyNs, 0)
        windowStartNs = try c.value(.windowStartNs, 0)
        windowEndNs = try c.value(.windowEndNs, 0)
        superseded = try c.value(.superseded, false)
        pathUnconfirmed = try c.value(.pathUnconfirmed, false)
        verdict = try c.value(.verdict, DevVerdict.inconclusive("not judged"))
        metrics = try c.value(.metrics, DevMetrics())
        entryState = try c.decodeIfPresent(PadDecodedState.self, forKey: .entryState)
        entryRaw = try c.value(.entryRaw, [])
        effectivePath = try c.value(.effectivePath, DevEffectivePath())
        raw = try c.value(.raw, [])
    }
}

struct DevStepResult: Codable, Equatable {
    var index = 0
    var stepId = ""
    var kind = ""
    var controls: [String] = []
    var expected = DevExpectedItems()
    /// The last attempt carries the verdict; earlier ones were superseded by Back or a re-run.
    var attempts: [DevAttempt] = []

    var verdict: DevVerdict? { attempts.last?.verdict }

    init(index: Int, stepId: String, kind: String, controls: [String], expected: DevExpectedItems, attempts: [DevAttempt] = []) {
        self.index = index; self.stepId = stepId; self.kind = kind; self.controls = controls
        self.expected = expected; self.attempts = attempts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.value(.index, 0)
        stepId = try c.value(.stepId, "")
        kind = try c.value(.kind, "")
        controls = try c.value(.controls, [])
        expected = try c.value(.expected, DevExpectedItems())
        attempts = try c.value(.attempts, [])
    }
}

/// One change of the engine's tap status during the run.
struct DevPathEvent: Codable, Equatable {
    var tMs: Double = 0
    var armed = ""
    var fallback: String?
    var latched: String?
    var liveUnavailable = false
    var mappingNote: String?
    /// Set on an event that records a path write the run made during a step (a hand-over): the value written. `armed`
    /// and the rest are what the engine reported at that moment.
    var wrote: String?

    init(tMs: Double = 0, armed: String = "", fallback: String? = nil, latched: String? = nil,
         liveUnavailable: Bool = false, mappingNote: String? = nil, wrote: String? = nil) {
        self.tMs = tMs; self.armed = armed; self.fallback = fallback; self.latched = latched
        self.liveUnavailable = liveUnavailable; self.mappingNote = mappingNote; self.wrote = wrote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tMs = try c.value(.tMs, 0)
        armed = try c.value(.armed, "")
        fallback = try c.decodeIfPresent(String.self, forKey: .fallback)
        latched = try c.decodeIfPresent(String.self, forKey: .latched)
        liveUnavailable = try c.value(.liveUnavailable, false)
        mappingNote = try c.decodeIfPresent(String.self, forKey: .mappingNote)
        wrote = try c.decodeIfPresent(String.self, forKey: .wrote)
    }
}

/// The decode table a report was read with, so a report stays interpretable after the tables change.
struct DevDecodeTable: Codable, Equatable {
    struct Report: Codable, Equatable { var id: Int; var length: Int }
    struct Placement: Codable, Equatable { var reportIndex: Int; var item: Int; var bitOffset: Int; var bits: Int; var encoding: Int }
    var reports: [Report] = []
    var placements: [Placement] = []

    init() {}

    init(reports: [GDHMTable.Report], placements: [GDHMTable.Placement]) {
        self.reports = reports.map { Report(id: Int($0.id), length: Int($0.length)) }
        self.placements = placements.map {
            Placement(reportIndex: Int($0.reportIndex), item: Int($0.item), bitOffset: Int($0.bitOffset), bits: Int($0.bits), encoding: Int($0.encoding))
        }
    }

    static var current: DevDecodeTable {
        DevDecodeTable(reports: MapBlobEncoder.xboxBT16Reports, placements: MapBlobEncoder.xboxBT16Placements)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reports = try c.value(.reports, [])
        placements = try c.value(.placements, [])
    }
}

struct DevRunHeader: Codable, Equatable {
    var appBuild = ""
    var engineBuild: String?
    var dextBuild: String?
    var guiMode = ""
    var padIdentity = ""
    var readerMatched = 0
    var vpadMaxRateHz = 0.0
    var xlateCore = ""
    var mapping = ControlMapping()
    /// SHA-256 of the mapping as sorted-keys JSON.
    var mappingHash = ""
    var templateId = ""
    var templateVersion = 1
    var templateSha256 = ""
    var decodeTable = DevDecodeTable()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appBuild = try c.value(.appBuild, "")
        engineBuild = try c.decodeIfPresent(String.self, forKey: .engineBuild)
        dextBuild = try c.decodeIfPresent(String.self, forKey: .dextBuild)
        guiMode = try c.value(.guiMode, "")
        padIdentity = try c.value(.padIdentity, "")
        readerMatched = try c.value(.readerMatched, 0)
        vpadMaxRateHz = try c.value(.vpadMaxRateHz, 0)
        xlateCore = try c.value(.xlateCore, "")
        mapping = try c.value(.mapping, ControlMapping())
        mappingHash = try c.value(.mappingHash, "")
        templateId = try c.value(.templateId, "")
        templateVersion = try c.value(.templateVersion, 1)
        templateSha256 = try c.value(.templateSha256, "")
        decodeTable = try c.value(.decodeTable, DevDecodeTable())
    }
}

struct DevRunReport: Codable, Equatable {
    static let schemaVersion = 1

    var schema = DevRunReport.schemaVersion
    /// ISO-8601 with the local offset, e.g. `2026-11-09T14:03:22+01:00`.
    var startedAt = ""
    var endedAt: String?
    /// The run's time zero on `LatencyMeter.nowNs()`.
    var t0Ns: UInt64 = 0
    var complete = false
    var requestedPath = ""
    /// What the engine reported it was armed with, never the request.
    var effectivePath: String?
    var pathEvents: [DevPathEvent] = []
    var header = DevRunHeader()
    var steps: [DevStepResult] = []
    var notes: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.value(.schema, DevRunReport.schemaVersion)
        if schema > DevRunReport.schemaVersion { throw DevSchemaError(found: schema, supported: DevRunReport.schemaVersion) }
        startedAt = try c.value(.startedAt, "")
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        t0Ns = try c.value(.t0Ns, 0)
        complete = try c.value(.complete, false)
        requestedPath = try c.value(.requestedPath, "")
        effectivePath = try c.decodeIfPresent(String.self, forKey: .effectivePath)
        pathEvents = try c.value(.pathEvents, [])
        header = try c.value(.header, DevRunHeader())
        steps = try c.value(.steps, [])
        notes = try c.value(.notes, [])
    }

    /// nil for garbage or a newer schema.
    static func decode(_ data: Data) -> DevRunReport? { try? JSONDecoder().decode(DevRunReport.self, from: data) }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// ISO-8601 with the offset of `timeZone` (the local zone by default).
    static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    static func date(fromISO s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

import Foundation

// The runner of Developer mode as a pure state machine (docs/plans/developer-mode-plan.md, "Runner"). Events go in,
// actions come out; there is no clock, no IOKit, no UI and no file access in here, so every rule has a unit test with
// scripted events and a fake clock. `DevSession` is the thin shell that feeds it and carries the actions out.

// MARK: - Vocabulary

/// Who drives the virtual pad for a run ("Record on").
enum DevTarget: String, CaseIterable, Identifiable, Codable {
    case engine, shadow, driver, inApp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .engine: return "App drives the controller (the background engine)"
        case .shadow: return "App drives; the driver translates alongside and the app compares (diagnostic)"
        case .driver: return "Driver drives the controller"
        case .inApp: return "This app drives the controller (no background engine)"
        }
    }

    /// The `inputPath` value that selects it; nil for in-app, where nothing is switched.
    var pathValue: String? {
        switch self {
        case .engine: return "engine"
        case .shadow: return "shadow"
        case .driver: return "driver"
        case .inApp: return nil
        }
    }

    /// What `TapStatusReport.armed` says once the path really is in force.
    var expectedArmed: String? {
        switch self {
        case .engine: return "inert"
        case .shadow: return "shadow"
        case .driver: return "live"
        case .inApp: return nil
        }
    }

    /// The word the report and its file name use for the path.
    var pathName: String { self == .inApp ? "in-app" : (pathValue ?? "unknown") }

    /// A template's `paths` entry ("engine", "shadow", "driver").
    init?(templatePath: String) {
        switch templatePath {
        case "engine": self = .engine
        case "shadow": self = .shadow
        case "driver": self = .driver
        default: return nil
        }
    }

    /// `armed` → the path vocabulary of reports: inert is the engine's own path, live is the driver's.
    static func pathName(forArmed armed: String) -> String {
        switch armed {
        case "inert": return "engine"
        case "live": return "driver"
        default: return armed
        }
    }
}

/// How the drawing shows a control during a run.
enum DevHighlight: String, Equatable, Codable {
    case wanted, linked, passed, failed, skipped, inconclusive, restOutline
    /// A `record` step that stored its frames: no verdict colour.
    case recorded
}

/// Numbers for the live strip, refreshed at most 4 times a second.
struct DevLiveStats: Equatable {
    var target = ""
    /// What the engine reports it is armed with (nil while no report matches the running engine).
    var armed: String?
    /// Receiver frames the GUI saw in the last second.
    var framesPerSecond = 0.0
    /// Receiver frames seen since the window started.
    var framesInWindow = 0
    /// Pad reports and changes since the window started.
    var padReports = 0
    var padChanged = 0
    /// Changes the receiver frames should have produced so far.
    var expectedChanges = 0
    var parityOkBucket: Int?
    var parityMismatches: Int?
    var matched = 0
}

enum DevPrompt: Equatable {
    /// The path could not be confirmed in 10 s; the text is `InputPathMenu.status`.
    case runAnyway(String)
    /// The breaker or the limiter stopped the driver path; the text says why.
    case rearmLatched(String)
}

/// One step as the runner sees it: the template step plus everything worked out from the mapping and layout.
struct DevResolvedStep: Equatable {
    var step: DevStep
    /// What the pad should show (digital steps; empty otherwise).
    var expected: DevExpectedItems
    /// Controls to light as "press this".
    var wanted: [String]
    /// Output controls to light dimmer because the pad shows the press there.
    var linked: [String]
    /// The step is recorded as skipped without asking for anything.
    var skipReason: String?
    /// The step takes the `builtInEcho` rule (one pad item per press, whichever the controller's profile gives).
    var builtInEcho = false
    /// What the step's `background` controls send to the pad.
    var background: Set<PadItem> = []
    /// The remapped paddle and SAX keys among the step's controls: the ones whose hidden button the step makes a claim
    /// about (only in a template that records the receiver).
    var hiddenKeys: [String] = []

    /// Resolves every step against `mapping` and `layout`.
    static func resolve(template: DevTemplate, mapping: ControlMapping, layout: ControlLayout) -> [DevResolvedStep] {
        template.steps.enumerated().map { (index, step) in
            let kind = step.devKind
            var expected = DevExpectedItems()
            var linked: [String] = []
            var background: Set<PadItem> = []
            var echo = false
            if kind == .digital || kind == .held || kind == .trigger {
                echo = DevExpectation.usesBuiltInEcho(step: step, mapping: mapping)
                expected = DevExpectation.resolve(step: step, mapping: mapping, layout: layout)
                linked = DevExpectation.linkedOutputControls(for: expected).filter { !step.controls.contains($0) }
                background = DevExpectation.backgroundItems(step: step, mapping: mapping, layout: layout)
            }
            let hidden = template.recordsReceiver(stepAt: index) && kind != .record
                ? step.controls.filter { DevExpectation.isHiddenKey($0, mapping: mapping) } : []
            return DevResolvedStep(step: step, expected: expected, wanted: step.controls, linked: linked,
                                   skipReason: requirementSkip(step, mapping: mapping, layout: layout),
                                   builtInEcho: echo, background: background, hiddenKeys: hidden)
        }
    }

    // MARK: Skip reasons (plain words, layout labels)

    /// The owner's word for a control: the layout label ("G1"), else the id.
    static func label(_ id: String, _ layout: ControlLayout) -> String { layout.control(id: id)?.label ?? id }

    /// The owner's word for an output: "Y", "D-pad up", "Nothing", "its built-in function" ("Controller's profile" on a
    /// paddle or SAX key, where `built_in` is the menu's "Controller's profile (built in)").
    static func label(_ output: ControlOutput, _ layout: ControlLayout) -> String {
        switch output {
        case .nothing: return "Nothing"
        case .builtIn: return "its built-in function"
        case .pad(let p): return layout.control(id: p.rawValue)?.label ?? p.padItem?.name ?? p.rawValue.uppercased()
        }
    }

    /// One `requires.mapping` entry the current mapping does not meet.
    struct RequirementMiss: Equatable {
        var control: String
        /// The value as the template wrote it.
        var value: String
        /// nil when the value is not an output this build knows.
        var output: ControlOutput?
    }

    /// `requires.mapping`: every named control must currently send the named output (`effectiveOutput`, by value).
    /// The misses, in control order.
    static func requirementMisses(_ step: DevStep, mapping: ControlMapping) -> [RequirementMiss] {
        var want = step.requires?.mapping ?? [:]
        // A held step that names its own trigger (row 8 holds RT) needs that trigger to still send itself: with RT sent
        // elsewhere the pad's RT is not what the owner holds, and the step is skipped (as step 1 skipped it), not failed.
        if step.devKind == .held, let name = step.expect?.item, case .trigger(let t)? = DevHeldItem(name: name) {
            let id = t == .left ? "lt" : "rt"
            if step.controls == [id], want[id] == nil { want[id] = id }
        }
        guard !want.isEmpty else { return [] }
        var out: [RequirementMiss] = []
        for (cid, value) in want.sorted(by: { $0.key < $1.key }) {
            let output = ControlOutput(string: value)
            if let output, mapping.effectiveOutput(cid) == output { continue }
            out.append(RequirementMiss(control: cid, value: value, output: output))
        }
        return out
    }

    /// The first miss, in the owner's words.
    private static func requirementSkip(_ step: DevStep, mapping: ControlMapping, layout: ControlLayout) -> String? {
        guard let miss = requirementMisses(step, mapping: mapping).first else { return nil }
        let who = label(miss.control, layout)
        guard let output = miss.output else { return "needs \(who) → \"\(miss.value)\": not an output this build knows" }
        if output == .builtIn {
            let how = RemapMenuModel.builtInRequirement(for: miss.control)
            return "needs \(who) \(ControlMapping.echoKeyIDs.contains(miss.control) ? "" : "left ")\(how): Reset it in Mapping"
        }
        let how = mapping.defaultOutput(miss.control) == output ? "Reset it in Mapping" : "set it in Mapping"
        return "needs \(who) → \(label(output, layout)): \(how)"
    }
}

/// Everything `start` needs, gathered by the shell.
struct DevRunSetup {
    var target: DevTarget
    var template: DevTemplate
    var steps: [DevResolvedStep]
    var mapping: ControlMapping
    /// Every control of the layout, for the rest step's outline.
    var allControlIDs: [String]
    /// Report header with everything the shell knows (builds, mapping hash, template hash …).
    var header: DevRunHeader
    var startedAt: Date
    /// The run's time zero on the `LatencyMeter.nowNs()` timeline; `nowNs` is that clock at `start`.
    var t0Ns: UInt64
    var nowNs: UInt64
    /// What the pad reader held when the run began (nil = it had seen nothing): the first step's entry state.
    var padSeed: PadDecodedState?

    init(target: DevTarget, template: DevTemplate, steps: [DevResolvedStep], mapping: ControlMapping,
         allControlIDs: [String] = [], header: DevRunHeader = DevRunHeader(), startedAt: Date = Date(),
         t0Ns: UInt64 = 0, nowNs: UInt64 = 0, padSeed: PadDecodedState? = nil) {
        self.target = target; self.template = template; self.steps = steps; self.mapping = mapping
        self.allControlIDs = allControlIDs; self.header = header; self.startedAt = startedAt
        self.t0Ns = t0Ns == 0 ? nowNs : t0Ns; self.nowNs = nowNs; self.padSeed = padSeed
    }
}

// MARK: - Core

struct DevRunCore {
    enum Phase: Equatable { case ready, window, release, judging }

    /// Where Resume goes back to.
    enum Resume: Equatable {
        /// The ready phase of the step at this index.
        case step(Int)
        /// The path switch (it re-confirms).
        case switching
    }

    enum State: Equatable {
        case idle
        /// Left within the `start` event: the shell takes its snapshot while the actions of that event run.
        case snapshot
        case switching(startedNs: UInt64, expectedArmed: String)
        case step(index: Int, phase: Phase)
        case paused(index: Int, resumeTo: Resume)
        /// The switch to the next pass of a `paths` template: the same confirmation, but with the drawing cleared.
        case betweenPasses(next: Int, startedNs: UInt64, expectedArmed: String)
        case finished
    }

    enum Event {
        case start(DevRunSetup)
        case tick(UInt64)
        /// A receiver frame with its kernel timestamp (`tK`, ns).
        case frame(GamepadFrame, tNs: UInt64)
        case reports([DevJudge.TimedReport])
        case status(TapStatusReport?)
        case enginePid(Int?)
        case controllerActive(Bool)
        /// How many virtual pads the reader matches.
        case readerMatched(Int)
        /// The default output device as it stands (when the watch starts), for steps with `expect.volume`.
        case volumeState(VolumeState, tNs: UInt64)
        /// A real change of the default output device's volume, mute or identity.
        case volumeEvent(VolumeEvent)
        /// A raw 0x11 report from the receiver's consumer interface (the volume keys).
        case consumerReport(DevConsumerReport)
        case pause, resume, back, skip, stop, terminate
        /// Answers the open prompt: "Run anyway" for `.runAnyway`, "Re-arm" for `.rearmLatched`.
        case runAnyway
        case cancelSwitch
        /// The run cannot go on (the mode flipped, say): finish as incomplete with this note.
        case abort(String)
        /// After `finished`: run one step again (on the last pass unless `pass` says otherwise).
        case rerun(Int, pass: Int? = nil)
        case rerunFailed(pass: Int? = nil)
    }

    enum Action: Equatable {
        case setCapture(Bool)
        /// Read the raw path keys now and keep them for `restorePath`.
        case takeSnapshot
        case writePath(String)
        case restorePath
        case writeReport(DevRunReport, complete: Bool)
        case setHighlights([String: DevHighlight])
        case setInstruction(title: String, detail: String, ringTotalNs: UInt64?, ringElapsedNs: UInt64?)
        case setLiveStrip(DevLiveStats)
        case needsPrompt(DevPrompt)
        case clearPrompt
        case done
    }

    enum Timing {
        static let still: UInt64 = 300_000_000
        static let readyTimeout: UInt64 = 5_000_000_000
        static let confirmTimeout: UInt64 = 10_000_000_000
        /// The judge runs on the running stream at most this often.
        static let evalEvery: UInt64 = 100_000_000
        /// The control must have been at rest this long before the window may end early: the judge wants 300 ms
        /// of held rest on the pad, which lags the receiver by a few ms.
        static let restForEarlyEnd: UInt64 = 350_000_000
        static let framesFlowing: UInt64 = 250_000_000
        /// Reports still on their way from the reader when a window ends.
        static let grace: UInt64 = 30_000_000
        static let backRestartsWithin: UInt64 = 1_000_000_000
        /// The release tail stretches until the control has been at rest for `restForEarlyEnd`, up to this much
        /// beyond its nominal length: an owner who rolls the stick until the ring fills needs a moment to let go.
        static let releaseGrace: UInt64 = 3_000_000_000
        static let liveEvery: UInt64 = 250_000_000
        /// A held step's last 2 s say "Keep holding…" without the hand-over count.
        static let holdingTail: UInt64 = 2_000_000_000
    }

    // MARK: State

    private(set) var state = State.idle
    private(set) var results: [[DevStepResult?]] = []
    private(set) var passes: [DevTarget] = []
    private(set) var pass = 0
    private(set) var notes: [String] = []
    private(set) var pathEvents: [DevPathEvent] = []
    private(set) var prompt: DevPrompt?
    private(set) var pauseReason: String?
    /// True from the moment the hands are still until the window starts: the box says "Go".
    var isGo: Bool { cur?.goNs != nil }

    private var setup: DevRunSetup?
    private var order: [Int] = []
    private var pos = 0
    private var isRerun = false
    private var cur: Cur?
    private var clock: UInt64 = 0
    private var phaseStartNs: UInt64 = 0

    // Inputs the core keeps track of whatever the state.
    private var pid: Int?
    private var status: TapStatusReport?
    private var controllerActive = false
    private var matched = 0
    private var lastFrameNs: UInt64?
    private var stillSince: UInt64?
    private var lastSeen: PadDecodedState?
    private var lastRaw: [UInt8: [UInt8]] = [:]
    private var refLast: PadState?
    private var cached: (frame: GamepadFrame, sum: FrameSummary)?
    private var digitalIDs: [String] = []
    /// The default output device's state over the run (the state at the watch's start, then after every event).
    private var volumeTimeline: [(tNs: UInt64, state: VolumeState)] = []
    /// The run-long filter: the rule that hides a remapped paddle or SAX key's own button (`EchoFilter`), stepped on every
    /// receiver report of the run, so that the reference, the window of a step and the hiding check all see the report the
    /// pad is meant to show. Parameters come from the mapping the run started with.
    private var echoState = EchoState()
    private var echoParams = EchoParams.none
    private var echoHeld: UInt8 = 0
    private var echoCounters = EchoCounters()
    /// Set when the Driver pass was not run because the driver cannot take the mapping and the owner stopped there: the
    /// pass (index) and the plain words. The views show a "stood down" chip instead of a row of steps.
    private(set) var standDownPass: Int?
    private(set) var standDownNote: String?
    private var promptStandDownWhy: String?

    /// The pass whose results the finished screen shows and a re-run defaults to: the last one, or the one before a Driver
    /// pass that stood down (that pass never ran, so its row is empty).
    var shownPass: Int { standDownPass.map { max($0 - 1, 0) } ?? max(results.count - 1, 0) }

    /// What the run's own filter did, counted over the run: reports it changed, reports that showed a direction the
    /// controller did not send, presses that showed another item than the stored one, presses it could not read.
    struct EchoCounters: Equatable {
        var hiddenFrames = 0
        var recoveredFrames = 0
        var other = 0
        var unconfirmed = 0
    }

    // Per pass.
    private var pathUnconfirmed = false
    private var armedBaseline: String?
    private var rearmAccepted = false
    /// The last value a hand-over wrote and has not been undone yet: the path goes back to the pass's target as soon
    /// as no hand-over can follow (window over, paused, stepped away from).
    private var handOverValue: String?

    // Output de-duplication.
    private var lastHighlights: [String: DevHighlight]?
    private var lastInstruction: InstructionKey?
    private var lastLiveNs: UInt64 = 0
    private var framesTotal = 0
    private var framesAtLastLive = 0

    private struct InstructionKey: Equatable {
        var title: String
        var detail: String
        var total: UInt64?
        var ringStart: UInt64?
    }

    private struct FrameSummary {
        var pad: PadState
        var neutral: Bool
        var snapped: PadState
    }

    /// One path write of a held step's actions: when (ms from the window start, as ns) and what.
    private struct ScheduledWrite: Equatable {
        var offsetNs: UInt64
        var value: String
    }

    /// A path write that has been made, and whether the engine was seen armed as it should be before the next one.
    private struct HandOver: Equatable {
        var value: String
        var expectedArmed: String?
        var atNs: UInt64
        var confirmed = false
    }

    /// The attempt being recorded.
    private struct Cur {
        var idx: Int
        var startedNs: UInt64
        var entry: PadDecodedState?
        var entryRaw: [UInt8: [UInt8]]
        var reports: [DevJudge.TimedReport] = []
        var goNs: UInt64?
        var windowStartNs: UInt64?
        var windowEndNs: UInt64?
        var releaseEndNs: UInt64?
        var pathAtReady: String?
        var pathAtStart: String?
        var pathAtEnd: String?
        var matchedAtStart = 1
        var padReportsInWindow = 0
        var padChanged = 0
        var refChanges: [UInt64] = []
        var frameTimes: [UInt64] = []
        /// The receiver-derived pad state of each of those frames (same order), for the per-event latency.
        var frameStates: [PadState] = []
        /// A held step with `expect.releases`: which of those controls each receiver frame had active.
        var controlActivity: [DevJudge.ControlSample] = []
        var wantedActiveSeen = false
        var wantedNowActive = false
        /// A step with `background` controls counts its presses without them (the held control stays down the whole step).
        var pressedNowActive = false
        var lastWantedActiveNs: UInt64?
        var wantedRises = 0
        /// Steps with `expect.volume`: the change events and the 0x11 reports since the step began.
        var volumeEvents: [VolumeEvent] = []
        var consumerReports: [DevConsumerReport] = []
        var lastEvalNs: UInt64 = 0
        var evalVersion = 0
        var lastEvalVersion = -1
        /// Shadow runs: the parity counters when the step began.
        var parityBefore: (ok: Int, mismatches: Int)?
        /// A held step with actions: the writes still to make, how many are done, and what became of each.
        var schedule: [ScheduledWrite] = []
        var nextWrite = 0
        var handOvers: [HandOver] = []
        /// A step that records the receiver: the reports whose non-stick bytes changed (and the first of the step), the
        /// ones left out over the cap, the non-stick bytes of the previous report and of the report at Go, and since
        /// when the receiver has shown the bytes it showed at Go.
        var receiver: [ReceiverSample] = []
        var receiverDropped = 0
        var lastNonStick: [UInt8]?
        var baselineNonStick: [UInt8]?
        var quietSinceNs: UInt64?
        /// A `record` step: for each of its controls, how often it came down and whether it has gone back up.
        var recordControls: [String: RecordedControl] = [:]
        /// The presses of remapped paddle and SAX keys since the step began, and the run's echo counters at its start.
        var echoHolds: [EchoHold] = []
        var echoBefore: (counters: EchoCounters, valid: Bool)?
    }

    private struct EchoHold {
        var key: Int
        var pressN: Int
        var releaseN: Int?
        var code: UInt8
        var found: DevJudge.HidingEvidence.Found
        var recovered: UInt16 = 0
    }

    private struct ReceiverSample: Equatable {
        var n: Int
        var tNs: UInt64
        var bytes: [UInt8]
        /// `EchoFilter.items` of the report as the controller sent it.
        var items: UInt16
    }

    private struct RecordedControl: Equatable {
        var active = false
        var rises = 0
        var fell = false
    }

    // MARK: Read-only views for the shell

    var isRunning: Bool {
        switch state {
        case .idle, .finished: return false
        default: return true
        }
    }

    /// The index of the step being worked on (or paused on).
    var currentStepIndex: Int? {
        switch state {
        case .step(let i, _), .paused(let i, _): return i
        default: return nil
        }
    }

    /// True when Back would go to a previous step; false when it restarts this one ("Restart step").
    var canGoToPreviousStep: Bool { previousPos(before: pos) != nil }

    var setupSteps: [DevResolvedStep] { setup?.steps ?? [] }

    /// The verdict a step stands on: the last attempt that was not superseded.
    static func latestVerdict(_ r: DevStepResult?) -> DevVerdict? {
        r?.attempts.last(where: { !$0.superseded })?.verdict
    }

    // MARK: Events

    @discardableResult
    mutating func handle(_ event: Event, now: UInt64? = nil) -> [Action] {
        if let now { clock = max(clock, now) }
        var a: [Action] = []
        switch event {
        case .start(let s): start(s, a: &a)
        case .tick(let t): tick(t, a: &a)
        case .frame(let f, let t): onFrame(f, tIn: t, a: &a)
        case .reports(let r): onReports(r, a: &a)
        case .status(let s): onStatus(s, a: &a)
        case .enginePid(let p): onPid(p, a: &a)
        case .controllerActive(let on): onController(on, a: &a)
        case .readerMatched(let n): onMatched(n, a: &a)
        case .volumeState(let s, let t): volumeTimeline.append((t, s))
        case .volumeEvent(let e): onVolumeEvent(e)
        case .consumerReport(let r): onConsumerReport(r)
        case .pause: pause(reason: nil, a: &a)
        case .resume: resume(a: &a)
        case .back: back(a: &a)
        case .skip: skip(a: &a)
        case .stop: if isRunning { finish(complete: false, note: nil, a: &a) }
        case .terminate: if isRunning { finish(complete: false, note: "the app was quit during the run", a: &a) }
        case .abort(let note): if isRunning { finish(complete: false, note: note, a: &a) }
        case .runAnyway: answerRunAnyway(a: &a)
        case .cancelSwitch: cancelSwitch(a: &a)
        case .rerun(let i, let p): rerun([i], pass: p, a: &a)
        case .rerunFailed(let p): rerunFailed(pass: p, a: &a)
        }
        putPathBackAfterHandOvers(&a)
        refreshOutputs(&a)
        return a
    }

    // MARK: Start

    private mutating func start(_ s: DevRunSetup, a: inout [Action]) {
        guard !isRunning else { return }
        var s = s
        // Actions switch the input path, which only the background engine can follow.
        if s.target == .inApp {
            for i in s.steps.indices where s.steps[i].skipReason == nil && s.steps[i].step.hasInputPathActions {
                s.steps[i].skipReason = "needs the background engine"
            }
        }
        setup = s
        clock = max(clock, s.nowNs)
        passes = Self.passes(for: s)
        pass = 0
        results = passes.map { _ in Array(repeating: nil, count: s.steps.count) }
        notes = []
        pathEvents = []
        isRerun = false
        order = Array(s.steps.indices)
        pos = 0
        cur = nil
        prompt = nil
        pauseReason = nil
        digitalIDs = Array(Set(s.mapping.buttons.keys).union(s.mapping.physicalBits.keys)).sorted()
        echoState = EchoState()
        echoParams = s.mapping.echoParams
        echoHeld = 0
        echoCounters = EchoCounters()
        standDownPass = nil
        standDownNote = nil
        promptStandDownWhy = nil
        volumeTimeline = []
        handOverValue = nil
        resetPassFlags()
        lastHighlights = nil
        lastInstruction = nil
        refLast = nil
        cached = nil
        lastSeen = s.padSeed
        lastRaw = [:]
        stillSince = nil
        framesTotal = 0; framesAtLastLive = 0; lastLiveNs = clock
        state = .snapshot
        phaseStartNs = clock
        a.append(.setCapture(true))
        if s.target != .inApp { a.append(.takeSnapshot) }
        recordPathEvent()
        beginSwitch(a: &a)
    }

    private static func passes(for s: DevRunSetup) -> [DevTarget] {
        if s.target == .inApp { return [.inApp] }
        if let p = s.template.paths?.compactMap(DevTarget.init(templatePath:)), !p.isEmpty { return p }
        return [s.target]
    }

    private mutating func resetPassFlags() {
        pathUnconfirmed = false
        armedBaseline = nil
        rearmAccepted = false
        prompt = nil
    }

    // MARK: Switching the path

    private var target: DevTarget { passes.indices.contains(pass) ? passes[pass] : .inApp }

    /// The report of the running engine, or nil when the file belongs to another process.
    private var liveStatus: TapStatusReport? {
        guard let s = status, let pid, s.pid == Int32(truncatingIfNeeded: pid) else { return nil }
        return s
    }

    private var statusText: String {
        InputPathMenu.status(mode: .engine, engineRunningPid: pid.map { Int32(truncatingIfNeeded: $0) }, report: status)
    }

    /// The engine's note when the driver cannot take the current mapping (build 24 cannot hide a paddle's own button, or
    /// pull a trigger from a button), without its closing full stop. A note that starts with "internal:" is a GDHub fault,
    /// which resetting a remap does not fix, so it is not one.
    private var standDownWhy: String? {
        guard target == .driver, let s = liveStatus, s.latched == nil, s.fallback == nil,
              let note = s.mappingNote, !note.hasPrefix("internal:") else { return nil }
        return note.hasSuffix(".") ? String(note.dropLast()) : note
    }

    /// The "Run anyway" question. A Driver pass that cannot be confirmed because the driver cannot express the current
    /// mapping names that mapping note and what to do (the App pass has run, so Stop keeps its result); every other reason
    /// keeps the status line.
    private var runAnywayText: String {
        if let why = standDownWhy {
            return "Driver pass cannot be confirmed: \(why). Press Stop to keep the App result, or Reset that remap first."
        }
        return statusText
    }

    /// The plan's confirm rule: this engine, no fallback, no latch, no mapping note, and armed as the target needs.
    /// The engine path keeps posting whatever the driver does, so it only needs `inert`.
    private func confirmed(for t: DevTarget) -> Bool {
        guard let s = liveStatus, let want = t.expectedArmed else { return false }
        if t == .engine { return s.armed == want }
        return s.armed == want && s.fallback == nil && s.latched == nil && s.mappingNote == nil
            && !(t == .driver && s.liveUnavailable)
    }

    /// Whether the engine already acts on the path this target asks for, so nothing needs writing.
    private func requestSatisfied(for t: DevTarget) -> Bool {
        guard let s = liveStatus, s.path == t.pathValue else { return false }
        if t == .engine { return true }
        return s.latched == nil && (s.fallback == nil || s.fallbackRetrying)
    }

    private func latchReason() -> String? {
        guard let s = liveStatus else { return nil }
        if let l = s.latched {
            return l == "limiter" ? "limiter: repeated fallbacks" : "breaker: repeated driver restarts"
        }
        if let f = s.fallback, !s.fallbackRetrying { return "fallback: \(f)" }
        return nil
    }

    private mutating func beginSwitch(a: inout [Action]) {
        let t = target
        guard let expected = t.expectedArmed, let value = t.pathValue else {
            // In-app: nothing is switched and nothing is confirmed.
            armedBaseline = nil
            beginSteps(a: &a)
            return
        }
        let between = pass > 0 && !isRerun
        func set(_ at: UInt64) -> State {
            between ? .betweenPasses(next: pass, startedNs: at, expectedArmed: expected) : .switching(startedNs: at, expectedArmed: expected)
        }
        if !requestSatisfied(for: t) {
            if t != .engine, !rearmAccepted, let why = latchReason() {
                prompt = .rearmLatched(why)
                state = set(clock); phaseStartNs = clock
                a.append(.needsPrompt(.rearmLatched(why)))
                return
            }
            a.append(.writePath(value))
        }
        state = set(clock)
        phaseStartNs = clock
        checkSwitch(now: clock, a: &a)
    }

    private var switchStart: UInt64? {
        switch state {
        case .switching(let s, _), .betweenPasses(_, let s, _): return s
        default: return nil
        }
    }

    private mutating func checkSwitch(now: UInt64, a: inout [Action]) {
        guard let started = switchStart, prompt == nil else { return }
        if confirmed(for: target) {
            armedBaseline = target.expectedArmed
            beginSteps(a: &a)
        } else if now >= started, now - started >= Timing.confirmTimeout {
            let p = DevPrompt.runAnyway(runAnywayText)
            promptStandDownWhy = standDownWhy
            prompt = p
            a.append(.needsPrompt(p))
        }
    }

    private mutating func answerRunAnyway(a: inout [Action]) {
        guard let p = prompt, switchStart != nil else { return }
        prompt = nil
        a.append(.clearPrompt)
        switch p {
        case .runAnyway:
            pathUnconfirmed = true
            armedBaseline = liveStatus?.armed
            notes.append("Run anyway: the \(target.pathName) path could not be confirmed (\(statusText)); every step of this pass is marked pathUnconfirmed.")
            beginSteps(a: &a)
        case .rearmLatched(let why):
            rearmAccepted = true
            notes.append("The driver path was stopped (\(why)); the owner chose to re-arm it for this run.")
            beginSwitch(a: &a)
        }
    }

    private mutating func cancelSwitch(a: inout [Action]) {
        guard switchStart != nil || (prompt != nil && isRunning) else { return }
        finish(complete: false, note: "cancelled while switching the input path", a: &a)
    }

    // MARK: Steps

    private mutating func beginSteps(a: inout [Action]) {
        order = isRerun ? order : Array(setup!.steps.indices)
        enterStep(at: 0, a: &a)
    }

    private func previousPos(before p: Int) -> Int? {
        guard let s = setup else { return nil }
        var i = min(p, order.count) - 1
        while i >= 0 {
            if s.steps[order[i]].skipReason == nil { return i }
            i -= 1
        }
        return nil
    }

    private mutating func enterStep(at start: Int, a: inout [Action]) {
        guard let s = setup else { return }
        var p = start
        while p < order.count {
            let idx = order[p]
            if let reason = s.steps[idx].skipReason {
                var att = DevAttempt()
                att.startedNs = clock
                att.verdict = .skipped(reason)
                att.metrics.detail = reason
                append(att, to: idx)
                p += 1
                continue
            }
            pos = p
            var c = Cur(idx: idx, startedNs: clock, entry: lastSeen, entryRaw: lastRaw)
            c.pathAtReady = observedPathName()
            c.parityBefore = parity()
            c.echoBefore = (echoCounters, echoState.flags & EchoState.valid != 0)
            cur = c
            state = .step(index: idx, phase: .ready)
            phaseStartNs = clock
            pauseReason = nil
            evaluateReady(now: clock, a: &a)
            return
        }
        passFinished(a: &a)
    }

    private mutating func passFinished(a: inout [Action]) {
        cur = nil
        if pass < passes.count - 1 && !isRerun {
            // Each pass is a report of its own: the compare tool pairs a report with a report.
            a.append(.writeReport(buildReport(complete: true), complete: true))
            pass += 1
            resetPassFlags()
            lastHighlights = nil
            beginSwitch(a: &a)
        } else {
            finish(complete: true, note: nil, a: &a)
        }
    }

    /// The engine's parity counters while a shadow run is in force.
    private func parity() -> (ok: Int, mismatches: Int)? {
        guard let s = liveStatus, s.armed == "shadow" || s.parityChecked else { return nil }
        return (s.parityOkBucket, s.parityMismatches)
    }

    private func observedPathName() -> String? {
        liveStatus.map { DevTarget.pathName(forArmed: $0.armed) }
    }

    private var rs: DevResolvedStep? {
        guard let c = cur, let s = setup, s.steps.indices.contains(c.idx) else { return nil }
        return s.steps[c.idx]
    }

    private mutating func setPhase(_ p: Phase, now: UInt64) {
        guard let c = cur else { return }
        state = .step(index: c.idx, phase: p)
        phaseStartNs = now
    }

    // MARK: Ready

    private func readyGate(now: UInt64) -> (ok: Bool, why: String) {
        guard let c = cur, let r = rs else { return (false, "") }
        if !controllerActive { return (false, "Waiting for the controller (asleep or not connected)") }
        if lastFrameNs.map({ now >= $0 && now - $0 > Timing.framesFlowing }) ?? true { return (false, "Waiting for controller frames") }
        if matched != 1 { return (false, "Waiting for the virtual pad (the reader sees \(matched))") }
        if !pathReady() {
            return (false, "Waiting for the \(target.pathName) path (engine armed: \(liveStatus?.armed ?? "unknown"), needs \(armedBaseline ?? target.expectedArmed ?? "?"))")
        }
        if stillSince.map({ now < $0 || now - $0 < Timing.still }) ?? true { return (false, "Let go of everything; waiting for the controller to be still") }
        let need = UInt64(r.step.effectiveReadySeconds * 1e9)
        // `now` may be a receiver frame's kernel timestamp, taken before the step started on the runner's clock.
        if now < c.startedNs || now - c.startedNs < need { return (false, "Keep still for a moment") }
        return (true, "")
    }

    /// The path is as it was confirmed (or as it stood when the owner chose to run anyway).
    private func pathReady() -> Bool {
        if target == .inApp { return true }
        guard let s = liveStatus else { return pathUnconfirmed && armedBaseline == nil }
        if pathUnconfirmed { return armedBaseline == nil || s.armed == armedBaseline }
        return confirmed(for: target)
    }

    private mutating func evaluateReady(now: UInt64, a: inout [Action]) {
        guard case .step(_, .ready) = state, cur != nil, let r = rs else { return }
        let gate = readyGate(now: now)
        if gate.ok {
            if cur!.goNs == nil {
                cur!.goNs = now
                cur!.pathAtReady = observedPathName()
            }
            if r.step.devKind == .rest { startWindow(at: now, a: &a) }
        } else if cur!.goNs != nil {
            // Something the Go depended on broke before the hands moved (frames stopped, the path changed).
            cur!.goNs = nil
        }
    }

    // MARK: Window

    private mutating func startWindow(at t: UInt64, a: inout [Action]) {
        guard let r = rs else { return }
        cur!.windowStartNs = t
        // A held step with actions runs until its last action is done and 1.5 s have passed; any other step for
        // `seconds`.
        cur!.windowEndNs = t + UInt64(r.step.windowSeconds * 1e9)
        cur!.schedule = r.step.devKind == .held
            ? r.step.inputPathSchedule.map { ScheduledWrite(offsetNs: UInt64($0.offsetMs) * 1_000_000, value: $0.value) } : []
        cur!.nextWrite = 0
        cur!.handOvers = []
        cur!.pathAtStart = observedPathName()
        cur!.matchedAtStart = matched
        cur!.refChanges = []
        cur!.frameTimes = []
        cur!.frameStates = []
        cur!.controlActivity = []
        cur!.padReportsInWindow = 0
        cur!.padChanged = 0
        cur!.wantedRises = 0
        cur!.wantedActiveSeen = false
        cur!.wantedNowActive = false
        cur!.pressedNowActive = false
        cur!.lastWantedActiveNs = nil
        cur!.evalVersion = 0; cur!.lastEvalVersion = -1; cur!.lastEvalNs = t
        // Reports that arrived before the window (the ready phase) are in `reports`; padChanged counts from here on.
        setPhase(.window, now: t)
        emitDueWrites(a: &a)
    }

    // MARK: Hand-overs

    /// Makes the writes of a held step's actions that are due: the first one with the window start, then one per
    /// interval. All the timing is the runner's clock; the shell only carries each `.writePath` out.
    private mutating func emitDueWrites(a: inout [Action]) {
        guard cur != nil, case .step(_, .window) = state, let ws = cur!.windowStartNs else { return }
        while cur!.nextWrite < cur!.schedule.count, clock >= ws + cur!.schedule[cur!.nextWrite].offsetNs {
            let w = cur!.schedule[cur!.nextWrite]
            cur!.nextWrite += 1
            cur!.handOvers.append(HandOver(value: w.value, expectedArmed: DevTarget(templatePath: w.value)?.expectedArmed, atNs: clock))
            handOverValue = w.value
            writePathEvent(w.value, a: &a)
        }
        noteHandOverConfirmation()
    }

    /// The engine counts as having followed a write once it reports the armed state the value asks for, before the
    /// next write: `inert` for engine, `live` for driver, `shadow` for shadow.
    private mutating func noteHandOverConfirmation() {
        guard cur != nil, let i = cur!.handOvers.indices.last, !cur!.handOvers[i].confirmed,
              let want = cur!.handOvers[i].expectedArmed, liveStatus?.armed == want else { return }
        cur!.handOvers[i].confirmed = true
    }

    private mutating func writePathEvent(_ value: String, a: inout [Action]) {
        a.append(.writePath(value))
        let s = liveStatus
        pathEvents.append(DevPathEvent(tMs: pathEventMs(), armed: s?.armed ?? "", fallback: s?.fallback, latched: s?.latched,
                                       liveUnavailable: s?.liveUnavailable ?? false, mappingNote: s?.mappingNote, wrote: value))
    }

    private func pathEventMs() -> Double {
        guard let t0 = setup?.t0Ns else { return 0 }
        return clock >= t0 ? Double(clock - t0) / 1e6 : 0
    }

    /// After the hand-overs: the path goes back to what the pass is testing, so the next step waits on the right path
    /// and Resume finds it as it should be. Not while a window may still hand over, and not once the run has
    /// finished: `restorePath` puts the original keys back and must have the last word.
    private mutating func putPathBackAfterHandOvers(_ a: inout [Action]) {
        guard let v = handOverValue, state != .finished else { return }
        if case .step(_, .window) = state { return }
        handOverValue = nil
        if let want = target.pathValue, want != v { writePathEvent(want, a: &a) }
    }

    /// Hand-overs reached and confirmed, for the verdict detail.
    private func handOverText(_ c: Cur) -> String {
        guard !c.handOvers.isEmpty else { return "" }
        let ok = c.handOvers.filter(\.confirmed).count
        var byArmed: [String: (ok: Int, all: Int)] = [:]
        for h in c.handOvers {
            let k = h.expectedArmed ?? h.value
            var e = byArmed[k] ?? (0, 0)
            e.all += 1; if h.confirmed { e.ok += 1 }
            byArmed[k] = e
        }
        let groups = byArmed.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.ok)/\($0.value.all)" }.joined(separator: ", ")
        var t = " Hand-overs confirmed \(ok)/\(c.handOvers.count) (armed \(groups))."
        if ok < c.handOvers.count {
            t += " The engine was not seen following every write, so the driver may not have carried the pad all the time."
        }
        return t
    }

    private mutating func endWindow(at t: UInt64, a: inout [Action]) {
        guard let r = rs, cur != nil else { return }
        cur!.windowEndNs = t
        cur!.pathAtEnd = observedPathName()
        let release = UInt64(r.step.effectiveReleaseSeconds * 1e9)
        cur!.releaseEndNs = t + release
        setPhase(release > 0 ? .release : .judging, now: t)
    }

    private mutating func finalizeIfDue(now: UInt64, a: inout [Action]) {
        guard let c = cur, let end = c.releaseEndNs ?? c.windowEndNs else { return }
        switch state {
        case .step(_, .release):
            if now >= end {
                // Nominal tail over: judge as soon as the control has been at rest long enough, or give up after the grace.
                let atRest = !c.wantedNowActive && (c.lastWantedActiveNs.map { now >= $0 && now - $0 >= Timing.restForEarlyEnd } ?? true)
                let hardEnd = (c.windowEndNs ?? end) + UInt64(rs.map { $0.step.effectiveReleaseSeconds * 1e9 } ?? 0) + Timing.releaseGrace
                if atRest || now >= hardEnd {
                    cur!.releaseEndNs = now
                    setPhase(.judging, now: now)
                } else {
                    return
                }
            }
        default: break
        }
        if case .step(_, .judging) = state, now >= end + Timing.grace {
            judgeAndAdvance(a: &a)
        }
    }

    private func rules(for r: DevResolvedStep) -> DevJudge.Rules { DevJudge.Rules().applying(r.step.expect) }

    private func reference(_ c: Cur, from ws: UInt64, to end: UInt64) -> DevJudge.Reference? {
        let frames = c.frameTimes.filter { $0 >= ws && $0 <= end }
        guard !frames.isEmpty else { return nil }
        let changes = c.refChanges.filter { $0 >= ws && $0 <= end }
        let fps: Double
        if frames.count > 1, let f = frames.first, let l = frames.last, l > f {
            fps = Double(frames.count - 1) / (Double(l - f) / 1e9)
        } else {
            fps = 0
        }
        var moving = 0.0
        if changes.count > 1, let f = changes.first, let l = changes.last { moving = Double(l - f) / 1e6 }
        var states: [DevJudge.Reference.Frame] = []
        states.reserveCapacity(frames.count)
        for (i, t) in c.frameTimes.enumerated() where t >= ws && t <= end && c.frameStates.indices.contains(i) {
            states.append(.init(tNs: t, pad: c.frameStates[i]))
        }
        return DevJudge.Reference(expectedChanges: changes.count, firstFrameChangeNs: changes.first,
                                  framesSeen: frames.count, framesPerSecond: fps, movingMs: moving, frames: states)
    }

    private func judgeInput(_ c: Cur, _ r: DevResolvedStep, ws: UInt64, we: UInt64, end: UInt64) -> DevJudge.Input {
        // A pad that said nothing before the step but spoke during the ready phase is known by then.
        let entry = c.entry ?? (c.reports.contains { $0.tNs < ws } ? PadDecodedState.neutral : nil)
        // From Go, not from the first movement: the key's report may reach the app a moment before its receiver frame.
        let volume = r.step.expect?.volume == nil ? nil
            : DevVolumeObservation.make(timeline: volumeTimeline, events: c.volumeEvents, reports: c.consumerReports,
                                        from: min(c.goNs ?? ws, ws), to: end)
        return DevJudge.Input(step: r.step, expected: r.expected, entryState: entry, reports: c.reports,
                              windowStartNs: ws, windowEndNs: we, endNs: end, matchedCount: c.matchedAtStart,
                              reference: reference(c, from: ws, to: end), handOvers: c.handOvers.count,
                              controlActivity: c.controlActivity, volume: volume,
                              background: r.background, builtInEcho: r.builtInEcho, hiding: hidingEvidence(c, r))
    }

    private mutating func judgeAndAdvance(a: inout [Action]) {
        guard let c = cur, let r = rs, let ws = c.windowStartNs, let we = c.windowEndNs else { return }
        let end = c.releaseEndNs ?? we
        let input = judgeInput(c, r, ws: ws, we: we, end: end)
        let o = DevJudge.judge(input)
        var att = makeAttempt(c, raw: input.rawReports())
        att.verdict = o.verdict
        att.metrics = o.metrics
        att.volume = o.volume
        att.hiding = o.hiding
        att.echoItem = o.echoItem
        if r.step.devKind == .record {
            att.verdict = .recorded(DevRecorder.summary(frames: c.receiver.count, dropped: c.receiverDropped, seconds: Double(end - ws) / 1e9))
            att.metrics.detail = DevRecorder.kept(frames: c.receiver.count, dropped: c.receiverDropped)
        }
        // The run's own filter, before and after the step (a Driver pass gets the driver's counters from S6 on).
        if echoParams.hideMask != 0, let before = c.echoBefore {
            let now = (echoCounters, echoState.flags & EchoState.valid != 0)
            let v: [(String, Double, Double)] = [
                ("hiddenFrames", Double(before.counters.hiddenFrames), Double(now.0.hiddenFrames)),
                ("recoveredFrames", Double(before.counters.recoveredFrames), Double(now.0.recoveredFrames)),
                ("other", Double(before.counters.other), Double(now.0.other)),
                ("unconfirmed", Double(before.counters.unconfirmed), Double(now.0.unconfirmed)),
                ("valid", before.valid ? 1 : 0, now.1 ? 1 : 0),
            ]
            for (name, b, n) in v {
                att.metrics.values["echo.\(name)Before"] = b
                att.metrics.values["echo.\(name)After"] = n
            }
        }
        if !c.handOvers.isEmpty {
            att.metrics.values["held.handOvers"] = Double(c.handOvers.count)
            att.metrics.values["held.handOversConfirmed"] = Double(c.handOvers.filter(\.confirmed).count)
            att.metrics.detail += handOverText(c)
        }
        // A shadow run's driver evidence is parity: keep the counters from before and after the step.
        if let before = c.parityBefore, let after = parity() {
            att.metrics.values["parity.okBefore"] = Double(before.ok)
            att.metrics.values["parity.okAfter"] = Double(after.ok)
            att.metrics.values["parity.mismatchesBefore"] = Double(before.mismatches)
            att.metrics.values["parity.mismatchesAfter"] = Double(after.mismatches)
        }
        append(att, to: c.idx)
        cur = nil
        enterStep(at: pos + 1, a: &a)
    }

    private func makeAttempt(_ c: Cur, raw: [DevRawReport]) -> DevAttempt {
        var att = DevAttempt()
        att.startedNs = c.startedNs
        att.readyNs = c.goNs ?? 0
        att.windowStartNs = c.windowStartNs ?? 0
        att.windowEndNs = c.windowEndNs ?? 0
        att.pathUnconfirmed = pathUnconfirmed
        att.entryState = c.entry
        att.entryRaw = c.entryRaw.keys.sorted().map { DevRawReport.hex(c.entryRaw[$0] ?? []) }
        att.effectivePath = DevEffectivePath(atReady: c.pathAtReady, atStart: c.pathAtStart, atEnd: c.pathAtEnd)
        att.raw = raw
        if let s = setup, s.template.recordsReceiver(stepAt: c.idx) {
            let base = c.windowStartNs ?? c.startedNs
            att.receiver = c.receiver.map {
                DevReceiverFrame(n: $0.n, t: ($0.tNs >= base ? Double($0.tNs - base) : -Double(base - $0.tNs)) / 1e6, bytes: $0.bytes)
            }
            if c.receiverDropped > 0 { att.receiverDropped = c.receiverDropped }
        }
        return att
    }

    /// Closes the open attempt without judging it. Only an attempt that reached its window is worth keeping.
    private mutating func closeOpen(_ verdict: DevVerdict, superseded: Bool, detail: String) {
        guard let c = cur else { return }
        defer { cur = nil }
        guard let ws = c.windowStartNs else { return }
        let we = c.windowEndNs ?? ws
        let input = DevJudge.Input(step: rs?.step ?? DevStep(id: "", kind: .rest, title: ""), entryState: c.entry,
                                   reports: c.reports, windowStartNs: ws, windowEndNs: min(we, max(clock, ws)),
                                   endNs: min(c.releaseEndNs ?? we, max(clock, ws)), matchedCount: c.matchedAtStart)
        var att = makeAttempt(c, raw: input.rawReports())
        att.verdict = verdict
        att.superseded = superseded
        att.metrics.detail = detail
        att.metrics.padReports = c.padReportsInWindow
        att.metrics.padChanged = c.padChanged
        att.windowEndNs = clock
        append(att, to: c.idx)
    }

    private mutating func append(_ att: DevAttempt, to idx: Int) {
        guard let s = setup, s.steps.indices.contains(idx), results.indices.contains(pass) else { return }
        let rsx = s.steps[idx]
        var r = results[pass][idx] ?? DevStepResult(index: idx, stepId: rsx.step.id, kind: rsx.step.kind,
                                                      controls: rsx.step.controls, expected: rsx.expected)
        if !att.superseded {
            for i in r.attempts.indices { r.attempts[i].superseded = true }
        }
        r.attempts.append(att)
        results[pass][idx] = r
    }

    private mutating func supersedeLast(of idx: Int) {
        guard results.indices.contains(pass), results[pass].indices.contains(idx),
              var r = results[pass][idx], !r.attempts.isEmpty else { return }
        r.attempts[r.attempts.count - 1].superseded = true
        results[pass][idx] = r
    }

    // MARK: Frames

    private mutating func summary(for f: GamepadFrame) -> FrameSummary {
        if let c = cached, c.frame == f { return c.sum }
        let m = setup!.mapping
        let pad = PassthroughPadMapper.padState(f, m)
        let base = DevJudge.Rules()
        func mag(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }
        var neutral = pad.buttons.isEmpty
            && mag(pad.lx, pad.ly) <= base.deadZone && mag(pad.rx, pad.ry) <= base.deadZone
            && pad.lt <= base.triggerRelease && pad.rt <= base.triggerRelease
        if neutral { neutral = !digitalIDs.contains { m.isActive($0, f) } }
        let sum = FrameSummary(pad: pad, neutral: neutral,
                               snapped: VirtualPadSink.snapped(pad, axisDeadband: 0.002, triggerDeadband: 0.002))
        cached = (f, sum)
        return sum
    }

    private func wantedActive(_ r: DevResolvedStep, _ f: GamepadFrame, _ pad: PadState, excluding: Set<String> = []) -> Bool {
        let ru = rules(for: r)
        func mag(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }
        let m = setup!.mapping
        switch r.step.devKind {
        case .stick?:
            return r.step.controls.filter { !excluding.contains($0) }.contains { cid in
                switch cid {
                case "left_stick": return mag(pad.lx, pad.ly) > ru.deadZone
                case "right_stick": return mag(pad.rx, pad.ry) > ru.deadZone
                default: return m.isActive(cid, f)
                }
            }
        case .trigger?, .held?:
            return r.step.controls.filter { !excluding.contains($0) }.contains { cid in
                switch cid {
                // The physical pull (the control's own binding), not the pad's trigger: under a remap the pad's value
                // may come from another control. Without remaps this is the same number the mapper puts on the pad.
                case "lt", "rt": return (m.triggerValue(cid, f) ?? 0) > ru.triggerRelease
                default: return m.isActive(cid, f)
                }
            }
        case .digital?:
            return r.step.controls.filter { !excluding.contains($0) }.contains { m.isActive($0, f) }
        case .record?:
            return r.step.controls.filter { !excluding.contains($0) }.contains { DevRecorder.isActive($0, f, mapping: m) }
        default:
            return false
        }
    }

    private mutating func onFrame(_ raw: GamepadFrame, tIn: UInt64, a: inout [Action]) {
        // Kernel timestamps are monotonic per device; a frame that still arrives older than the last one (a replay, a
        // second reader) keeps its data but takes the last time, so no interval below ever runs backwards.
        let t = max(tIn, lastFrameNs ?? tIn)
        clock = max(clock, t)
        lastFrameNs = t
        guard isRunning, setup != nil else { return }
        framesTotal += 1
        // The run-long filter sees every report. `f` is the report as the pad is meant to show it (a remapped paddle's own
        // button hidden); `raw` is what the controller sent, which the receiver recording keeps.
        let pre = echoState
        let word = echoState.step(echoParams, frame: raw)
        let f = EchoFilter.apply(word, to: raw)
        noteEcho(word: word, raw: raw, pre: pre, tNs: t)
        let sum = summary(for: f)
        if sum.neutral { if stillSince == nil { stillSince = t } } else { stillSince = nil }

        var changed = false
        if let last = refLast {
            if !VirtualPadSink.unchanged(sum.snapped, last, axisDeadband: 0.002, triggerDeadband: 0.002) {
                changed = true
                refLast = sum.snapped
            }
        } else {
            refLast = sum.snapped
        }

        guard case .step(_, let phase) = state, cur != nil, let r = rs else { return }
        if setup!.template.recordsReceiver(stepAt: cur!.idx) { noteReceiverFrame(raw, tNs: t) }
        // A record step is about what the controller sent, whatever the mapping hides.
        let seen = r.step.devKind == .record ? raw : f
        if phase == .ready {
            // The window starts on the frame that first moves a wanted control.
            if cur!.goNs != nil, r.step.devKind != .rest, wantedActive(r, seen, sum.pad) {
                startWindow(at: t, a: &a)
            } else {
                evaluateReady(now: t, a: &a)
            }
        }
        guard case .step(_, let phase2) = state, phase2 == .window || phase2 == .release,
              let ws = cur!.windowStartNs, t >= ws else { return }
        cur!.frameTimes.append(t)
        cur!.frameStates.append(sum.snapped)
        if r.step.devKind == .held, let ids = r.step.expect?.releases, !ids.isEmpty {
            let m = setup!.mapping
            // Every control of the step, not only the listed ones: the judge also needs to know when the owner let go of
            // the held item's own button (the end of the step, as opposed to the pad dropping it).
            cur!.controlActivity.append(.init(tNs: t, active: Set(Set(ids).union(r.step.controls).filter { m.isActive($0, f) })))
        }
        if changed { cur!.refChanges.append(t) }
        if r.step.devKind == .record, phase2 == .window { noteRecordedControls(r, raw) }
        // Tracked in the release phase too: the tail ends when the control has come back to rest.
        let act = wantedActive(r, seen, sum.pad)
        let background = Set(r.step.expect?.background ?? [])
        let pressed = background.isEmpty ? act : wantedActive(r, seen, sum.pad, excluding: background)
        if act {
            if phase2 == .window {
                if pressed && !cur!.pressedNowActive { cur!.wantedRises += 1 }
                cur!.wantedActiveSeen = true
                cur!.evalVersion += 1
            }
            cur!.lastWantedActiveNs = t
        }
        cur!.wantedNowActive = act
        cur!.pressedNowActive = pressed
    }

    // MARK: The run's echo filter

    /// Counts what the filter did on this report and keeps the presses of remapped keys for the step on hand.
    private mutating func noteEcho(word: UInt32, raw: GamepadFrame, pre: EchoState, tNs t: UInt64) {
        if word & EchoFilter.wordApplied != 0 { echoCounters.hiddenFrames += 1 }
        if word & EchoFilter.wordRecovered != 0 { echoCounters.recoveredFrames += 1 }
        if word & EchoFilter.wordOther != 0 { echoCounters.other += 1 }
        if word & EchoFilter.wordUnconfirmed != 0 { echoCounters.unconfirmed += 1 }
        let held: UInt8 = word == 0 ? 0 : UInt8((word >> 16) & 0x3F)
        let pressed = held & ~echoHeld
        let released = echoHeld & ~held
        echoHeld = held
        guard cur != nil, (pressed | released) != 0 || word & EchoFilter.wordRecovered != 0 else { return }
        for k in 0..<6 where (pressed >> UInt8(k)) & 1 == 1 {
            let code = UInt8((echoState.cur >> UInt64(8 * k)) & 0xFF)
            let stored = echoParams.items[k]
            let found: DevJudge.HidingEvidence.Found
            if (echoState.known >> UInt8(k)) & 1 == 1 {
                // "Seen" only when the rule read the item off this very press: its stored item was not on before, exactly one
                // of the six keys changed and exactly one item changed. Every other known press was agreed with ("confirmed"),
                // including a key pressed together with another key or with another change in the same report.
                let obs = EchoFilter.items(word: 0, buttons: raw.buttons, hat: raw.hat)
                let single = pre.flags & EchoState.valid != 0 && (UInt8(truncatingIfNeeded: raw.extra & 0x3F) ^ pre.six).nonzeroBitCount == 1
                let c: UInt16 = single ? EchoFilter.changed(pre.prev, obs) : 0
                let readOffThePress = !EchoFilter.on(EchoFilter.mask(stored), in: pre.prev) && c.nonzeroBitCount == 1
                found = readOffThePress ? .seen : .confirmed
            } else {
                found = code != stored ? .other : .unconfirmed
            }
            cur!.echoHolds.append(EchoHold(key: k, pressN: framesTotal, releaseN: nil, code: code, found: found))
        }
        for k in 0..<6 where (released >> UInt8(k)) & 1 == 1 {
            if let i = cur!.echoHolds.lastIndex(where: { $0.key == k && $0.releaseN == nil }) { cur!.echoHolds[i].releaseN = framesTotal }
        }
        if word & EchoFilter.wordRecovered != 0 {
            // A direction the pad shows and the controller did not send.
            let sent = EchoFilter.items(word: 0, buttons: raw.buttons, hat: raw.hat)
            let shown = EchoFilter.items(word: word, buttons: raw.buttons, hat: raw.hat)
            let extra = shown & ~sent & 0x3C00
            for i in cur!.echoHolds.indices where cur!.echoHolds[i].releaseN == nil { cur!.echoHolds[i].recovered |= extra }
        }
    }

    /// What the judge needs for the hiding check of a step, or nil when the step has no remapped key to check.
    private func hidingEvidence(_ c: Cur, _ r: DevResolvedStep) -> DevJudge.HidingEvidence? {
        guard !r.hiddenKeys.isEmpty else { return nil }
        let ids = ControlMapping.echoKeyIDs
        let holds = c.echoHolds.compactMap { h -> DevJudge.HidingEvidence.Hold? in
            guard ids.indices.contains(h.key), r.hiddenKeys.contains(ids[h.key]) else { return nil }
            return .init(control: ids[h.key], pressN: h.pressN, releaseN: h.releaseN, code: h.code, found: h.found, recovered: h.recovered)
        }
        return .init(keys: r.hiddenKeys, holds: holds, reports: c.receiver.map { .init(n: $0.n, items: $0.items) })
    }

    // MARK: Receiver recording

    /// Keeps `f` when its non-stick bytes differ from the report before (and always the step's first report), up to the
    /// cap, and tracks how long the receiver has shown what it showed at Go.
    private mutating func noteReceiverFrame(_ f: GamepadFrame, tNs t: UInt64) {
        let bytes = f.nonStickBytes
        if cur!.goNs == nil { cur!.baselineNonStick = bytes }
        if cur!.lastNonStick != bytes {
            if cur!.receiver.count < DevRecorder.maxFramesPerStep {
                cur!.receiver.append(ReceiverSample(n: framesTotal, tNs: t, bytes: f.rawBytes,
                                                    items: EchoFilter.items(word: 0, buttons: f.buttons, hat: f.hat)))
            } else {
                cur!.receiverDropped += 1
            }
            cur!.lastNonStick = bytes
        }
        if let base = cur!.baselineNonStick, base == bytes {
            if cur!.quietSinceNs == nil { cur!.quietSinceNs = t }
        } else {
            cur!.quietSinceNs = nil
        }
    }

    /// A record step counts how often each of its controls comes down and whether it has gone back up.
    private mutating func noteRecordedControls(_ r: DevResolvedStep, _ f: GamepadFrame) {
        let m = setup!.mapping
        for cid in r.step.controls {
            var s = cur!.recordControls[cid] ?? RecordedControl()
            let on = DevRecorder.isActive(cid, f, mapping: m)
            if on && !s.active { s.rises += 1 }
            if !on && s.active { s.fell = true }
            s.active = on
            cur!.recordControls[cid] = s
        }
    }

    /// A record step may end early once every one of its controls has gone down and up, the presses asked for (`rises`)
    /// are in, and the receiver has shown what it showed at Go for `restForEarlyEnd` (so a late echo release is seen).
    private func recordIsDone(_ c: Cur, _ r: DevResolvedStep, now: UInt64) -> Bool {
        guard !r.step.controls.isEmpty,
              r.step.controls.allSatisfy({ c.recordControls[$0].map { $0.rises >= 1 && $0.fell } ?? false }),
              c.recordControls.values.reduce(0, { $0 + $1.rises }) >= (r.step.expect?.rises ?? 0),
              let quiet = c.quietSinceNs, now >= quiet, now - quiet >= Timing.restForEarlyEnd else { return false }
        return true
    }

    // MARK: Volume

    /// Only a step that asks for the volume keeps what comes in, so every other step costs nothing.
    private var watchesVolume: Bool { rs?.step.expect?.volume != nil }

    private mutating func onVolumeEvent(_ e: VolumeEvent) {
        volumeTimeline.append((e.tNs, e.state))
        if cur != nil, watchesVolume { cur!.volumeEvents.append(e) }
    }

    private mutating func onConsumerReport(_ r: DevConsumerReport) {
        if cur != nil, watchesVolume { cur!.consumerReports.append(r) }
    }

    // MARK: Pad reports

    private mutating func onReports(_ list: [DevJudge.TimedReport], a: inout [Action]) {
        let dec = PadReportDecoder.xboxBT16
        for r in list {
            var held = lastSeen ?? .neutral
            let didChange = dec.apply(reportID: r.id, bytes: r.bytes, to: &held)
            lastSeen = held
            lastRaw[r.id] = r.bytes
            clock = max(clock, r.tNs)
            guard cur != nil else { continue }
            if r.tNs < cur!.startedNs {
                // Late delivery of a report that happened before this attempt: it belongs to the entry state.
                var e = cur!.entry ?? .neutral
                dec.apply(reportID: r.id, bytes: r.bytes, to: &e)
                cur!.entry = e
                cur!.entryRaw[r.id] = r.bytes
                continue
            }
            cur!.reports.append(r)
            if let ws = cur!.windowStartNs, r.tNs >= ws {
                cur!.padReportsInWindow += 1
                if didChange { cur!.padChanged += 1 }
                cur!.evalVersion += 1
            }
        }
    }

    // MARK: Ticks

    private mutating func tick(_ now: UInt64, a: inout [Action]) {
        guard isRunning, now >= phaseStartNs else { return }
        clock = max(clock, now)
        switch state {
        case .switching, .betweenPasses:
            checkSwitch(now: now, a: &a)
        case .step(_, let phase):
            switch phase {
            case .ready:
                evaluateReady(now: now, a: &a)
                if case .step(_, .ready) = state, let g = cur?.goNs, now >= g, now - g >= Timing.readyTimeout, let r = rs {
                    noMovement(r, now: now, a: &a)
                }
            case .window:
                tickWindow(now: now, a: &a)
            case .release, .judging:
                finalizeIfDue(now: now, a: &a)
            }
        default:
            break
        }
        emitLive(now: now, a: &a)
    }

    private mutating func noMovement(_ r: DevResolvedStep, now: UInt64, a: inout [Action]) {
        guard let c = cur else { return }
        var att = makeAttempt(c, raw: [])
        att.windowStartNs = 0
        att.verdict = .fail("no movement: \(r.step.controls.joined(separator: ", ")) did not move within 5 s of Go")
        att.metrics.detail = "The controller was still and the path confirmed, but no wanted control moved within 5 s of Go."
        att.effectivePath.atEnd = observedPathName()
        append(att, to: c.idx)
        cur = nil
        enterStep(at: pos + 1, a: &a)
    }

    private mutating func tickWindow(now: UInt64, a: inout [Action]) {
        guard let c = cur, let r = rs, let ws = c.windowStartNs, let we = c.windowEndNs else { return }
        emitDueWrites(a: &a)
        if now >= we {
            endWindow(at: we, a: &a)
            finalizeIfDue(now: now, a: &a)
            return
        }
        // Early end: the judge would pass on what has been seen and the control has been at rest long enough. A held
        // step never ends early: it is about the whole window.
        let kind = r.step.devKind
        if kind == .record {
            if recordIsDone(c, r, now: now) {
                endWindow(at: now, a: &a)
                finalizeIfDue(now: now, a: &a)
            }
            return
        }
        guard kind != .rest, kind != .held, c.wantedActiveSeen, !c.wantedNowActive, let lastAct = c.lastWantedActiveNs,
              now >= lastAct, now - lastAct >= Timing.restForEarlyEnd,
              kind != .digital || c.wantedRises >= rules(for: r).digitalTimes,
              now >= c.lastEvalNs, now - c.lastEvalNs >= Timing.evalEvery, c.evalVersion != c.lastEvalVersion else { return }
        cur!.lastEvalNs = now
        cur!.lastEvalVersion = c.evalVersion
        let input = judgeInput(c, r, ws: ws, we: now, end: now)
        if DevJudge.judge(input).verdict == .pass {
            endWindow(at: now, a: &a)
            finalizeIfDue(now: now, a: &a)
        }
    }

    // MARK: Status, engine, controller, reader

    private mutating func recordPathEvent() {
        guard isRunning, let s = liveStatus, setup != nil else { return }
        let ev = DevPathEvent(tMs: pathEventMs(), armed: s.armed, fallback: s.fallback,
                              latched: s.latched, liveUnavailable: s.liveUnavailable, mappingNote: s.mappingNote)
        if let last = pathEvents.last(where: { $0.wrote == nil }),
           (last.armed, last.fallback, last.latched, last.liveUnavailable, last.mappingNote)
            == (ev.armed, ev.fallback, ev.latched, ev.liveUnavailable, ev.mappingNote) { return }
        pathEvents.append(ev)
    }

    private mutating func onStatus(_ s: TapStatusReport?, a: inout [Action]) {
        let before = liveStatus
        status = s
        guard isRunning else { return }
        recordPathEvent()
        noteHandOverConfirmation()
        switch state {
        case .switching, .betweenPasses:
            checkSwitch(now: clock, a: &a)
        case .step(_, let phase):
            guard target != .inApp else { return }
            let after = liveStatus
            if target != .engine {
                let appeared = (after?.fallback != nil && before?.fallback == nil) || (after?.latched != nil && before?.latched == nil)
                if appeared {
                    let why = after?.latched != nil ? "the driver path was stopped (\(after!.latched!))" : "the driver fell back (\(after?.fallback ?? "?"))"
                    pause(reason: "Paused: \(why). \(statusText)", a: &a)
                    return
                }
            }
            // A step with actions switches the path itself: the changes are expected (they are in pathEvents).
            let handsOver = !(cur?.schedule.isEmpty ?? true)
            if phase == .window || phase == .release, !handsOver, let s = after, let base = armedBaseline, s.armed != base {
                let text = "path changed: the engine went from \(base) to \(s.armed) during the step"
                closeOpen(.invalid(text), superseded: false, detail: text)
                enterStep(at: pos + 1, a: &a)
                return
            }
            if phase == .ready { evaluateReady(now: clock, a: &a) }
        default:
            break
        }
    }

    private mutating func onPid(_ p: Int?, a: inout [Action]) {
        let old = pid
        pid = p
        guard isRunning, target != .inApp else { return }
        if case .step = state, let old, old != p {
            pause(reason: p == nil ? "Paused: the engine stopped" : "Paused: the engine restarted (pid \(old) to \(p!))", a: &a)
        }
    }

    private mutating func onController(_ on: Bool, a: inout [Action]) {
        let was = controllerActive
        controllerActive = on
        guard isRunning, was, !on, case .step(_, let phase) = state else { return }
        // A rest step may run while the controller dozes off: that is the sleep check.
        if phase != .ready, rs?.step.devKind == .rest { return }
        pause(reason: "Paused: the controller left the connected state", a: &a)
    }

    private mutating func onMatched(_ n: Int, a: inout [Action]) {
        let was = matched
        matched = n
        guard isRunning, was != n, n != 1, case .step = state else { return }
        pause(reason: "Paused: the pad reader sees \(n) virtual pads (needs exactly 1)", a: &a)
    }

    // MARK: Pause, resume, back, skip

    private mutating func pause(reason: String?, a: inout [Action]) {
        guard prompt == nil else { return }
        switch state {
        case .step(let idx, _):
            closeOpen(.invalid("paused" + (reason.map { ": " + $0 } ?? "")), superseded: true, detail: reason ?? "Paused by the owner.")
            state = .paused(index: idx, resumeTo: .step(pos))
        case .switching, .betweenPasses:
            let idx = order.first ?? 0
            state = .paused(index: idx, resumeTo: .switching)
        default:
            return
        }
        phaseStartNs = clock
        pauseReason = reason
    }

    private mutating func resume(a: inout [Action]) {
        guard case .paused(_, let to) = state else { return }
        pauseReason = nil
        switch to {
        case .step(let p): enterStep(at: p, a: &a)
        case .switching: beginSwitch(a: &a)
        }
    }

    private mutating func back(a: inout [Action]) {
        switch state {
        case .step(_, let phase):
            let early = phase == .ready || (phase == .window && (cur?.windowStartNs).map { clock >= $0 && clock - $0 < Timing.backRestartsWithin } ?? true)
            if early, let p = previousPos(before: pos) {
                closeOpen(.invalid("went back"), superseded: true, detail: "The owner went back.")
                supersedeLast(of: order[p])
                enterStep(at: p, a: &a)
            } else {
                closeOpen(.invalid("restarted"), superseded: true, detail: "The owner restarted the step.")
                enterStep(at: pos, a: &a)
            }
        case .paused(_, .step(let at)):
            if let p = previousPos(before: at) {
                supersedeLast(of: order[p])
                pos = p
                state = .paused(index: order[p], resumeTo: .step(p))
            }
        default:
            break
        }
    }

    private mutating func skip(a: inout [Action]) {
        func skipped(_ idx: Int) -> DevAttempt {
            var att = DevAttempt()
            att.startedNs = clock
            att.verdict = .skipped("by user")
            att.metrics.detail = "Skipped by the owner."
            return att
        }
        switch state {
        case .step(let idx, _):
            // A window that was already open is kept, superseded, as what the owner walked away from.
            closeOpen(.invalid("skipped"), superseded: true, detail: "Skipped by the owner.")
            append(skipped(idx), to: idx)
            cur = nil
            enterStep(at: pos + 1, a: &a)
        case .paused(let idx, .step(let at)):
            append(skipped(idx), to: idx)
            var p = at + 1
            while p < order.count, setup!.steps[order[p]].skipReason != nil {
                var att = DevAttempt(); att.verdict = .skipped(setup!.steps[order[p]].skipReason!)
                append(att, to: order[p])
                p += 1
            }
            if p >= order.count {
                passFinished(a: &a)
            } else {
                pos = p
                state = .paused(index: order[p], resumeTo: .step(p))
            }
        default:
            break
        }
    }

    // MARK: Finish

    /// The single exit of a run: stop capture, close the open attempt as "stopped", write the report once, put the path
    /// back, say done.
    private mutating func finish(complete: Bool, note: String?, a: inout [Action]) {
        guard isRunning else { return }
        closeOpen(.invalid("stopped"), superseded: false, detail: "The run was stopped during this step.")
        if let note { notes.append(note) }
        // Stopped at the question of a Driver pass the driver cannot take: that pass stood down, the earlier one counts.
        if let why = promptStandDownWhy, case .runAnyway? = prompt {
            let words = "Driver pass not run: this driver version cannot take this mapping (\(why)). The App pass is the result of this run."
            standDownPass = pass
            standDownNote = words
            notes.append(words)
        }
        promptStandDownWhy = nil
        let hasAttempt = results.indices.contains(pass) && results[pass].contains { $0 != nil }
        state = .finished
        phaseStartNs = clock
        prompt = nil
        pauseReason = nil
        a.append(.setCapture(false))
        a.append(.clearPrompt)
        refreshOutputs(&a)
        if hasAttempt || complete {
            a.append(.writeReport(buildReport(complete: complete), complete: complete))
        }
        if setup?.target != .inApp { a.append(.restorePath) }
        a.append(.done)
    }

    private func buildReport(complete: Bool) -> DevRunReport {
        guard let s = setup else { return DevRunReport() }
        var r = DevRunReport()
        let started = rerunStart ?? s.startedAt
        r.startedAt = DevRunReport.iso(started)
        r.t0Ns = s.t0Ns
        r.complete = complete
        r.requestedPath = target.pathName
        r.effectivePath = armedBaseline.map(DevTarget.pathName(forArmed:)) ?? observedPathName()
        r.pathEvents = pathEvents
        r.header = s.header
        r.header.readerMatched = matched
        r.steps = results.indices.contains(pass) ? results[pass].compactMap { $0 } : []
        r.notes = notes
        return r
    }

    /// Wall-clock start of a re-run, derived from the monotonic clock so the core needs no calendar.
    private var rerunStartedAt: Date?
    private var rerunStart: Date? { isRerun ? rerunStartedAt : nil }

    // MARK: Re-run

    private mutating func rerunFailed(pass p: Int?, a: inout [Action]) {
        let p = p ?? shownPass
        guard results.indices.contains(p) else { return }
        let idx = results[p].enumerated().compactMap { (i, r) -> Int? in
            guard setup?.steps[i].skipReason == nil, let v = Self.latestVerdict(r) else { return nil }
            switch v {
            case .fail, .inconclusive, .invalid: return i
            case .pass, .skipped, .recorded: return nil
            }
        }
        rerun(idx, pass: p, a: &a)
    }

    private mutating func rerun(_ indices: [Int], pass p: Int?, a: inout [Action]) {
        guard state == .finished, let s = setup, !indices.isEmpty else { return }
        let p = p ?? shownPass
        let valid = indices.filter { s.steps.indices.contains($0) && s.steps[$0].skipReason == nil }
        guard results.indices.contains(p), !valid.isEmpty else { return }
        pass = p
        isRerun = true
        order = valid
        pos = 0
        cur = nil
        resetPassFlags()
        pathEvents = []
        handOverValue = nil
        notes.append("Re-run of \(valid.map { s.steps[$0].step.id }.joined(separator: ", ")) merged into the earlier results of this pass.")
        rerunStartedAt = s.startedAt.addingTimeInterval(clock >= s.nowNs ? Double(clock - s.nowNs) / 1e9 : 0)
        lastHighlights = nil
        lastInstruction = nil
        state = .snapshot
        phaseStartNs = clock
        a.append(.setCapture(true))
        if target != .inApp { a.append(.takeSnapshot) }
        recordPathEvent()
        beginSwitch(a: &a)
    }

    // MARK: Outputs

    private func highlightMap() -> [String: DevHighlight] {
        guard let s = setup, results.indices.contains(pass) else { return [:] }
        switch state {
        case .switching, .betweenPasses, .snapshot, .idle: return [:]
        default: break
        }
        var map: [String: DevHighlight] = [:]
        for (i, st) in s.steps.enumerated() {
            guard let v = Self.latestVerdict(results[pass][i]) else { continue }
            let h: DevHighlight
            switch v {
            case .pass: h = .passed
            case .fail: h = .failed
            case .skipped: h = .skipped
            case .inconclusive, .invalid: h = .inconclusive
            case .recorded: h = .recorded
            }
            for cid in st.step.controls { map[cid] = h }
        }
        var idx: Int?
        switch state {
        case .step(let i, _), .paused(let i, _): idx = i
        default: break
        }
        if let i = idx, s.steps.indices.contains(i) {
            let r = s.steps[i]
            if r.step.devKind == .rest {
                for cid in s.allControlIDs where map[cid] == nil { map[cid] = .restOutline }
            }
            for cid in r.linked where !r.wanted.contains(cid) { map[cid] = .linked }
            for cid in r.wanted { map[cid] = .wanted }
        }
        return map
    }

    private func instruction(now: UInt64) -> (title: String, detail: String, total: UInt64?, ringStart: UInt64?) {
        let name = target.displayName
        switch state {
        case .idle, .snapshot:
            return ("", "", nil, nil)
        case .switching(let started, let expected), .betweenPasses(_, let started, let expected):
            if let p = prompt {
                switch p {
                case .runAnyway(let text): return ("Could not confirm the \(name) path", text, nil, nil)
                case .rearmLatched(let why): return ("The driver path is stopped", "\(why). Re-arm it for this run?", nil, nil)
                }
            }
            let secs = now >= started ? Int((now - started) / 1_000_000_000) : 0
            var detail = "Engine armed: \(liveStatus?.armed ?? "unknown"); waiting for \(expected) (\(secs) s of 10). Keep the controller awake."
            if case .betweenPasses = state { detail = "Hands off. " + detail }
            return ("Switching to \(name)…", detail, Timing.confirmTimeout, started)
        case .step(_, let phase):
            guard let r = rs, let c = cur else { return ("", "", nil, nil) }
            switch phase {
            case .ready:
                if c.goNs != nil { return (r.step.title, "Go. " + r.step.detail, nil, nil) }
                let gate = readyGate(now: now)
                return ("Let go of everything", gate.why, nil, nil)
            case .window:
                let total = c.windowStartNs.flatMap { ws in c.windowEndNs.map { $0 >= ws ? $0 - ws : 0 } } ?? UInt64(r.step.windowSeconds * 1e9)
                if r.step.devKind == .held { return (r.step.title, holdingText(c, r, now: now), total, c.windowStartNs) }
                return (r.step.title, r.step.detail, total, c.windowStartNs)
            case .release:
                let nominal = UInt64(r.step.effectiveReleaseSeconds * 1e9)
                let overdue = c.windowEndNs.map { now >= $0 + nominal } ?? false
                return ("Let go now", overdue ? "Waiting for the control to come back to rest." : "Release it and keep your hands off.",
                        nominal + Timing.releaseGrace, c.windowEndNs)
            case .judging:
                return ("Checking…", "", nil, nil)
            }
        case .paused:
            return ("Paused", pauseReason ?? "Press Resume to carry on.", nil, nil)
        case .finished:
            return lastFinishedText
        }
    }

    /// The line under a held step's title: which hand-over is on, and "Keep holding…" for the last 2 s.
    private func holdingText(_ c: Cur, _ r: DevResolvedStep, now: UInt64) -> String {
        if let we = c.windowEndNs, now + Timing.holdingTail >= we { return "Keep holding…" }
        guard let last = c.handOvers.last else { return "Keep holding…" }
        let who: String
        switch last.value {
        case "driver": who = "Driver"
        case "engine": who = "App"
        case "shadow": who = "App, driver alongside"
        default: who = last.value
        }
        return "Keep holding RT still, nothing else to do — switch \(c.handOvers.count) of \(c.schedule.count), now driven by \(who)"
    }

    private var lastFinishedText: (title: String, detail: String, total: UInt64?, ringStart: UInt64?) {
        var pass_ = 0, fail = 0, other = 0, recorded = 0
        if results.indices.contains(finishedPass) {
            for r in results[finishedPass] {
                guard let v = Self.latestVerdict(r) else { continue }
                switch v {
                case .pass: pass_ += 1
                case .fail: fail += 1
                case .recorded: recorded += 1
                default: other += 1
                }
            }
        }
        let title = finishedComplete ? "Run complete" : "Run stopped"
        var text = "\(pass_) passed, \(fail) failed, \(other) skipped or unclear."
        if recorded > 0 { text += " \(recorded) recorded." }
        return (title, text, nil, nil)
    }

    /// The pass the finished summary counts: the one before a Driver pass that stood down, else the one that was running.
    private var finishedPass: Int { standDownPass.map { max($0 - 1, 0) } ?? pass }

    private var finishedComplete: Bool {
        guard let s = setup, results.indices.contains(finishedPass) else { return false }
        return !s.steps.indices.contains { Self.latestVerdict(results[finishedPass][$0]) == nil }
    }

    private mutating func refreshOutputs(_ a: inout [Action]) {
        guard setup != nil else { return }
        let h = highlightMap()
        if h != lastHighlights {
            lastHighlights = h
            a.append(.setHighlights(h))
        }
        guard state != .idle, state != .snapshot else { return }
        let i = instruction(now: clock)
        let key = InstructionKey(title: i.title, detail: i.detail, total: i.total, ringStart: i.ringStart)
        if key != lastInstruction {
            lastInstruction = key
            let elapsed = i.ringStart.map { clock >= $0 ? clock - $0 : 0 }
            a.append(.setInstruction(title: i.title, detail: i.detail, ringTotalNs: i.total, ringElapsedNs: elapsed))
        }
    }

    private mutating func emitLive(now: UInt64, a: inout [Action]) {
        guard now >= lastLiveNs, now - lastLiveNs >= Timing.liveEvery else { return }
        let dt = Double(now - lastLiveNs) / 1e9
        var st = DevLiveStats()
        st.target = target.pathName
        st.armed = liveStatus?.armed
        st.framesPerSecond = Double(framesTotal - framesAtLastLive) / dt
        lastLiveNs = now
        framesAtLastLive = framesTotal
        if let c = cur, let ws = c.windowStartNs {
            let end = c.releaseEndNs ?? .max
            st.framesInWindow = c.frameTimes.filter { $0 >= ws && $0 <= end }.count
            st.padReports = c.padReportsInWindow
            st.padChanged = c.padChanged
            st.expectedChanges = c.refChanges.count
        }
        if let s = liveStatus, s.armed == "shadow" || s.parityChecked {
            st.parityOkBucket = s.parityOkBucket
            st.parityMismatches = s.parityMismatches
        }
        st.matched = matched
        a.append(.setLiveStrip(st))
    }
}

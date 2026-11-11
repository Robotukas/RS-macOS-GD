import Foundation
import Combine
import os

// The shell around `DevRunCore` (docs/plans/developer-mode-plan.md, "Runner"): it owns the pad reader, the input-path
// control and the timers, feeds the core with what happens, carries out the actions it returns and publishes what the
// views draw. Every rule about *what* a run does lives in the core; this file only connects it to the world.

/// What the instruction box shows. `stampedAt` is when the shell received it: the ring runs from
/// `ringElapsedNs` at that moment to `ringTotalNs`, so a view can animate it without a timer in the model.
struct DevInstruction: Equatable {
    var title = ""
    var detail = ""
    var ringTotalNs: UInt64?
    var ringElapsedNs: UInt64?
    var stampedAt = Date()
    static let empty = DevInstruction()
}

/// One step in the chip strip.
struct DevChip: Identifiable, Equatable {
    enum Status: Equatable { case pending, current, passed, failed, skipped, inconclusive, recorded }
    var index: Int
    var stepId: String
    var title: String
    var controls: [String]
    var status: Status
    /// A pass that does not prove everything it claims: the hiding of a remapped key's own button was not conclusive
    /// ("cannot judge", "not exercised"). The chip is amber.
    var caveat = false
    var id: Int { index }
}

/// One chip row; a `paths` template has one per pass.
struct DevPassChips: Identifiable, Equatable {
    var pass: Int
    var target: DevTarget
    var chips: [DevChip]
    /// The words of a pass that was not run because the driver cannot take the mapping (the row shows "stood down").
    var standDown: String?
    var id: Int { pass }
}

/// One line of the result table.
struct DevResultRow: Identifiable, Equatable {
    var index: Int
    var title: String
    var expected: String
    /// What the pad did, in words (the metrics detail) or the reason a step was skipped.
    var seen: String
    var loss: String
    var onset: String
    var frames: String
    var verdict: DevVerdict?
    var attempts: Int
    /// The sentence under the verdict (the tooltip): what the hiding check found, with a held background item.
    var note: String?
    /// The step passed without proving that the controller's own button was hidden.
    var caveat = false
    var id: Int { index }
    /// The tooltip of the Result cell.
    var help: String { [verdict?.reason, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
}

@MainActor
final class DevSession: ObservableObject {
    /// The Expected cell of a record step (mockup v7): nothing is expected, nothing is judged.
    static let recordExpected = "—"
    /// The Expected cell of a step on an untouched paddle or SAX key.
    static let builtInEchoExpected = "one pad item per press (the controller's profile decides)"
    /// The tooltip of the grey "stood down" chip of a Driver pass that was not run.
    static let standDownChipHelp = "Driver pass not run: this driver version cannot take this mapping, so the App drove the controller for the whole run."

    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "devmode")
    static let lastTemplateKey = "devLastTemplate"
    static let lastTargetKey = "devLastTarget"

    // MARK: Published surface

    /// The runner's state (idle until the first Start).
    @Published private(set) var state: DevRunCore.State = .idle
    /// True from Start until the run has finished (paused counts). The Driver ▸ Input path menu is disabled while it is.
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    /// True between "hands still" and the first movement: the box says Go.
    @Published private(set) var isGo = false
    @Published private(set) var instruction = DevInstruction.empty
    /// How the drawing marks each control (wanted, linked, verdict colours, rest outline).
    @Published private(set) var highlights: [String: DevHighlight] = [:]
    /// The live strip, refreshed at most 4 times a second.
    @Published private(set) var live: DevLiveStats?
    @Published private(set) var chips: [DevPassChips] = []
    /// Results per pass, in step order (steps not reached are missing).
    @Published private(set) var passResults: [[DevStepResult]] = []
    /// The table of the last pass.
    @Published private(set) var rows: [DevResultRow] = []
    @Published private(set) var lastReportURL: URL?
    @Published private(set) var lastReport: DevRunReport?
    /// Plain information: what was restored, why a run stopped, why Start is disabled.
    @Published private(set) var hint: String?
    /// Something went wrong (a report could not be written).
    @Published private(set) var error: String?
    @Published private(set) var prompt: DevPrompt?
    @Published private(set) var matchedCount = 0
    /// The decoded state of the virtual pad, for the purple overlay (nil until the reader has seen the pad).
    @Published private(set) var padState: PadDecodedState?
    @Published private(set) var currentStepIndex: Int?
    @Published private(set) var currentPass = 0
    /// Back goes to the previous step; false = it restarts this one ("Restart step").
    @Published private(set) var canGoToPreviousStep = false

    // Choices.
    @Published private(set) var targets: [DevTarget] = []
    @Published var selectedTarget: DevTarget? {
        didSet { if let t = selectedTarget, t != oldValue { defaults.set(t.rawValue, forKey: Self.lastTargetKey) }; updateStartBlock() }
    }
    @Published private(set) var templates: [DevTemplateEntry] = []
    @Published var selectedTemplateID: String? {
        didSet { if let id = selectedTemplateID, id != oldValue { defaults.set(id, forKey: Self.lastTemplateKey) }; updateStartBlock() }
    }
    /// Why Start is disabled; nil = it can start.
    @Published private(set) var startBlockReason: String?

    var canStart: Bool { startBlockReason == nil && !isRunning }
    var selectedEntry: DevTemplateEntry? { templates.first { $0.id == selectedTemplateID } }
    /// Template problems to show in the hint (errors first).
    var templateProblems: [String] { selectedEntry?.problems ?? [] }
    var backLabel: String { canGoToPreviousStep ? "Back" : "Restart step" }
    /// "Runs on: Engine → Driver LIVE" for a `paths` template (the target picker is read-only then); nil otherwise.
    var pathsNote: String? {
        guard let paths = selectedEntry?.template?.paths, !paths.isEmpty else { return nil }
        return "Runs on: " + paths.compactMap { DevTarget(templatePath: $0)?.displayName }.joined(separator: " → ")
    }
    var finishedWithResults: Bool { if case .finished = state { return true } else { return false } }
    /// The steps the core runs, resolved against the mapping (titles and expectations for the views).
    var resolvedSteps: [DevResolvedStep] { core.setupSteps }

    // MARK: Plumbing

    private weak var device: EnvisionProDevice?
    private let driver: DriverManager
    private let reader: VirtualPadReader
    private let pathControl: DevInputPathControlling
    private let volumeObserver: VolumeObserving
    private let defaults: UserDefaults
    private var core = DevRunCore()
    private var subscriptions = Set<AnyCancellable>()
    private var pumpTask: Task<Void, Never>?
    private var generation = 0
    private var cursor: UInt64 = 0
    private var snapshot: DevPathSnapshot?
    private var markerWritten = false
    private var wroteAnyPath = false
    private var restoreNote: String?
    private var setup: DevRunSetup?
    private var lastIdentityCheck: UInt64 = 0
    private var matchedTask: Task<Void, Never>?
    private var closed = false
    private var volumeWatching = false

    init(device: EnvisionProDevice, driver: DriverManager, reader: VirtualPadReader = VirtualPadReader(),
         pathControl: DevInputPathControlling = DevInputPathControl(), defaults: UserDefaults = .standard,
         volumeObserver: VolumeObserving = CoreAudioVolumeObserver()) {
        self.device = device
        self.driver = driver
        self.reader = reader
        self.pathControl = pathControl
        self.volumeObserver = volumeObserver
        self.defaults = defaults
        reader.open()
        reloadTemplates()
        refreshTargets()
        subscribe()
    }

    private func subscribe() {
        if let device {
            device.$status.removeDuplicates().sink { [weak self] status in
                MainActor.assumeIsolated { self?.send(.controllerActive(status == .active)) }
            }.store(in: &subscriptions)
        }
        driver.$tapStatus.sink { [weak self] report in
            MainActor.assumeIsolated { self?.send(.status(report)) }
        }.store(in: &subscriptions)
        driver.$engineStatus.map { $0.isRunning ? $0.pid.map { Int($0) } : nil }.removeDuplicates().sink { [weak self] pid in
            MainActor.assumeIsolated {
                self?.send(.enginePid(pid))
                self?.refreshTargets()
            }
        }.store(in: &subscriptions)
        driver.$mode.removeDuplicates().sink { [weak self] mode in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshTargets()
                if mode != .engine, self.isRunning, self.core.setupSteps.isEmpty == false, self.selectedTargetIsPathBased {
                    self.send(.abort("the GUI left engine mode during the run"))
                }
            }
        }.store(in: &subscriptions)
        reader.$matchedCount.removeDuplicates().sink { [weak self] n in
            MainActor.assumeIsolated { self?.readerMatchedChanged(n) }
        }.store(in: &subscriptions)
    }

    private var selectedTargetIsPathBased: Bool { setup.map { $0.target != .inApp } ?? false }

    /// Switches the mode off for good: stops a run (report written, path restored), closes the reader.
    func shutDown() {
        if core.isRunning { send(.stop) }
        closed = true
        pumpTask?.cancel()
        matchedTask?.cancel()
        subscriptions.removeAll()
        device?.frameTap = nil
        stopVolumeWatch()
        reader.close()
    }

    // MARK: Choices

    func reloadTemplates() {
        guard let layout = device?.layout else {
            templates = []
            selectedTemplateID = nil
            return
        }
        templates = DevTemplates.load(layout: layout)
        let wanted = selectedTemplateID ?? defaults.string(forKey: Self.lastTemplateKey)
        if let wanted, templates.contains(where: { $0.id == wanted }) {
            if selectedTemplateID != wanted { selectedTemplateID = wanted }
        } else {
            selectedTemplateID = templates.first(where: \.isRunnable)?.id ?? templates.first?.id
        }
        updateStartBlock()
    }

    private func refreshTargets() {
        switch driver.mode {
        case .inApp:
            targets = [.inApp]
        case .engine:
            targets = driver.runningEnginePid != nil ? [.engine, .shadow, .driver] : []
        case .displayOnly:
            targets = []
        }
        if let t = selectedTarget, targets.contains(t) {
            // keep
        } else if let stored = defaults.string(forKey: Self.lastTargetKey).flatMap(DevTarget.init(rawValue:)), targets.contains(stored) {
            selectedTarget = stored
        } else {
            selectedTarget = targets.first
        }
        updateStartBlock()
    }

    private func updateStartBlock() {
        startBlockReason = computeStartBlock()
    }

    private func computeStartBlock() -> String? {
        switch driver.mode {
        case .displayOnly: return "This is a display-only copy of GDHub: the engine belongs to another copy."
        case .engine: if driver.runningEnginePid == nil { return "Engine not running" }
        case .inApp: break
        }
        guard selectedTarget != nil else { return "No target to record on" }
        guard let entry = selectedEntry else { return "No template selected" }
        guard let template = entry.template else { return entry.errors.first ?? "The template cannot be read" }
        if !entry.errors.isEmpty { return entry.errors[0] }
        if template.paths != nil, driver.mode == .inApp {
            return "This template switches who drives the controller, which needs the background engine; in-app mode has none."
        }
        guard let device, let layout = device.layout else { return "No controller layout loaded" }
        // Every step would be skipped for the mapping: nothing to record, so say what to set first.
        return DevRequirementCheck.startBlock(template: template, mapping: device.mapping, layout: layout)
    }

    func restartEngine() { driver.restartEngine() }

    // MARK: Controls

    func start() {
        guard !isRunning else { return }
        updateStartBlock()
        if let why = startBlockReason { hint = why; return }
        guard let device, let layout = device.layout, let target = selectedTarget,
              let template = selectedEntry?.template else { return }
        error = nil
        hint = nil
        restoreNote = nil
        lastReportURL = nil
        lastReport = nil
        core = DevRunCore()
        wroteAnyPath = false
        let mapping = device.mapping
        let steps = DevResolvedStep.resolve(template: template, mapping: mapping, layout: layout)
        let held = reader.heldSnapshot()
        cursor = held.seq
        let now = LatencyMeter.nowNs()
        var s = DevRunSetup(target: target, template: template, steps: steps, mapping: mapping,
                            allControlIDs: layout.controlsByOrder.map(\.id), header: makeHeader(template: template, mapping: mapping),
                            startedAt: Date(), t0Ns: now, nowNs: now, padSeed: held.state)
        s.header.readerMatched = reader.matchedCount
        setup = s
        feedCurrentInputs()
        send(.start(s))
    }

    func pause() { send(.pause) }
    func resume() { send(.resume) }
    func back() { send(.back) }
    func skip() { send(.skip) }
    func stop() { send(.stop) }
    func answerRunAnyway() { send(.runAnyway) }
    func cancelPrompt() { send(.cancelSwitch) }

    /// Runs one finished step again, on the path of its pass (the last pass unless `pass` says otherwise).
    func rerun(index: Int, pass: Int? = nil) {
        guard !isRunning, finishedWithResults, startBlockReason == nil else { return }
        prepareForRerun()
        send(.rerun(index, pass: pass))
    }

    /// Runs every step that ended red or amber again.
    func rerunFailed(pass: Int? = nil) {
        guard !isRunning, finishedWithResults, startBlockReason == nil else { return }
        prepareForRerun()
        send(.rerunFailed(pass: pass))
    }

    /// How many steps of `pass` (default: the last) a re-run would repeat.
    func failedCount(pass: Int? = nil) -> Int {
        let p = pass ?? max(passResults.count - 1, 0)
        guard passResults.indices.contains(p) else { return 0 }
        return passResults[p].filter {
            switch DevRunCore.latestVerdict($0) {
            case .fail?, .inconclusive?, .invalid?: return true
            default: return false
            }
        }.count
    }

    /// Cmd-Q: synchronous. The report is written and the path put back before this returns.
    func finishForTermination() {
        guard core.isRunning else { return }
        send(.terminate)
    }

    private func prepareForRerun() {
        error = nil
        hint = nil
        restoreNote = nil
        wroteAnyPath = false
        drainReader()
        feedCurrentInputs()
    }

    private func feedCurrentInputs() {
        send(.enginePid(driver.runningEnginePid.map { Int($0) }))
        send(.status(driver.tapStatus))
        send(.controllerActive(device?.status == .active))
        send(.readerMatched(reader.matchedCount))
    }

    // MARK: Events in

    private func send(_ event: DevRunCore.Event) {
        guard !closed || core.isRunning else { return }
        let before = core.state
        let actions = core.handle(event, now: LatencyMeter.nowNs())
        perform(actions)
        if core.isRunning, core.state != before { armPump() }
        if !actions.isEmpty || core.state != before { publishDerived() }
    }

    private func onFrame(_ frame: GamepadFrame, _ tNs: UInt64) {
        send(.frame(frame, tNs: tNs))
    }

    private func readerMatchedChanged(_ n: Int) {
        matchedCount = n
        matchedTask?.cancel()
        if n == 1 || !core.isRunning {
            send(.readerMatched(n))
            return
        }
        // The pad is destroyed and made again on an identity switch, and a pad can appear before the old one is gone:
        // only a count that stays for a moment pauses the run.
        matchedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.reader.matchedCount == n else { return }
            self.send(.readerMatched(n))
        }
    }

    // MARK: Timers

    private func armPump() {
        pumpTask?.cancel()
        generation += 1
        let gen = generation
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let ms = self?.pumpStep(generation: gen) else { return }
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
                // Every wake-up checks (in `pumpStep`) that it still belongs to the phase it was made for.
            }
        }
    }

    /// One wake-up: nil when this Task's phase is over, else the milliseconds to sleep.
    private func pumpStep(generation gen: Int) -> UInt64? {
        guard generation == gen, core.isRunning else { return nil }
        pumpOnce()
        return generation == gen ? pumpIntervalMs : nil
    }

    private var pumpIntervalMs: UInt64 {
        switch core.state {
        case .step(_, let phase): return phase == .ready ? 20 : 10
        default: return 100
        }
    }

    private func pumpOnce() {
        drainReader()
        let now = LatencyMeter.nowNs()
        if now &- lastIdentityCheck > 1_000_000_000 {
            lastIdentityCheck = now
            reader.reopenIfIdentityChanged()
        }
        send(.tick(now))
    }

    private func drainReader() {
        let d = reader.drain(after: cursor)
        cursor = d.lastSeq
        if d.lost { hint = "The pad reader's buffer overflowed; some reports were lost." }
        guard !d.reports.isEmpty else { return }
        padState = reader.heldSnapshot().state
        send(.reports(d.reports))
    }

    // MARK: Actions out

    private func perform(_ actions: [DevRunCore.Action]) {
        for action in actions {
            switch action {
            case .setCapture(let on):
                if on {
                    device?.frameTap = { [weak self] f, t in MainActor.assumeIsolated { self?.onFrame(f, t) } }
                    startVolumeWatch()
                } else {
                    stopVolumeWatch()
                }
            case .takeSnapshot:
                snapshot = pathControl.snapshot()
                markerWritten = false
            case .writePath(let value):
                writePath(value)
            case .restorePath:
                restorePath()
            case .writeReport(let report, _):
                write(report)
            case .setHighlights(let h):
                highlights = h
            case .setInstruction(let title, let detail, let total, let elapsed):
                instruction = DevInstruction(title: title, detail: detail, ringTotalNs: total, ringElapsedNs: elapsed, stampedAt: Date())
            case .setLiveStrip(let stats):
                live = stats
            case .needsPrompt(let p):
                prompt = p
            case .clearPrompt:
                prompt = nil
            case .done:
                runEnded()
            }
        }
    }

    // MARK: Volume watch

    /// Only a template with a volume step pays for the listeners: CoreAudio on the default output device and the
    /// receiver's 0x11 reports. Both only observe; nothing here sets a volume or a mute.
    private func startVolumeWatch() {
        guard setup?.template.steps.contains(where: { $0.expect?.volume != nil }) == true else { return }
        stopVolumeWatch()
        volumeObserver.start { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.send(.volumeEvent(event)) } }
        }
        send(.volumeState(volumeObserver.currentState(), tNs: LatencyMeter.nowNs()))
        device?.consumerTap = { [weak self] bytes, t in
            MainActor.assumeIsolated { self?.send(.consumerReport(DevConsumerReport(tNs: t, bytes: bytes))) }
        }
        volumeWatching = true
    }

    private func stopVolumeWatch() {
        guard volumeWatching else { return }
        volumeWatching = false
        volumeObserver.stop()
        device?.consumerTap = nil
    }

    private func writePath(_ value: String) {
        if let snap = snapshot {
            let marker = DevInflightMarker(pid: getpid(), processStart: DevInputPathControl.processStartTime(), snapshot: snap,
                                           writtenValue: value, startedAt: DevRunReport.iso(Date()))
            do { try pathControl.writeMarker(marker); markerWritten = true } catch {
                Self.log.error("could not write the run marker: \(error.localizedDescription, privacy: .public)")
            }
        }
        pathControl.write(path: value)
        wroteAnyPath = true
        Self.log.notice("developer run: input path set to \(value, privacy: .public)")
    }

    private func restorePath() {
        if let snap = snapshot {
            // Defaults first, then the marker: a crash in between leaves a marker whose restore is idempotent.
            pathControl.restore(snap)
            restoreNote = wroteAnyPath
                ? "Path put back to \(snap.restoredDescription)"
                : "Driven-by setting left as it was: \(snap.restoredDescription)"
        }
        pathControl.removeMarker()
        snapshot = nil
        markerWritten = false
    }

    private func write(_ report: DevRunReport) {
        var r = report
        r.endedAt = DevRunReport.iso(Date())
        lastReport = r
        let started = DevRunReport.date(fromISO: r.startedAt) ?? Date()
        do {
            lastReportURL = try DevRunReportStore.write(r, startedAt: started)
        } catch {
            lastReportURL = nil
            self.error = "Could not save the report: \(error.localizedDescription). It is kept in memory until the next run."
            Self.log.error("report write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runEnded() {
        pumpTask?.cancel()
        generation += 1
        device?.frameTap = nil
        stopVolumeWatch()
        var parts: [String] = []
        if let t = hint, !t.isEmpty, t.hasPrefix("The pad reader") { parts.append(t) }
        if let note = core.standDownNote { parts.append(note) }
        if let note = restoreNote { parts.append(note) }
        if let url = lastReportURL { parts.append("Report saved: \(url.lastPathComponent)") }
        hint = parts.isEmpty ? nil : parts.joined(separator: ". ")
        // The last tick may not have run: leave the table and strip in their final state.
        publishDerived()
    }

    // MARK: Published state out

    private func publishDerived() {
        if state != core.state { state = core.state }
        let running = core.isRunning
        if isRunning != running { isRunning = running }
        var paused = false
        if case .paused = core.state { paused = true }
        if isPaused != paused { isPaused = paused }
        if isGo != core.isGo { isGo = core.isGo }
        if prompt != core.prompt { prompt = core.prompt }
        if currentStepIndex != core.currentStepIndex { currentStepIndex = core.currentStepIndex }
        if currentPass != core.pass { currentPass = core.pass }
        let canPrev = core.canGoToPreviousStep
        if canGoToPreviousStep != canPrev { canGoToPreviousStep = canPrev }
        let newChips = buildChips()
        if chips != newChips { chips = newChips }
        let results = core.results.map { $0.compactMap { $0 } }
        if passResults != results { passResults = results }
        let newRows = buildRows(results.last ?? [])
        if rows != newRows { rows = newRows }
        if !running, case .finished = core.state, live != nil, case .finished = state { /* strip stays at its last values */ }
    }

    private func buildChips() -> [DevPassChips] {
        let steps = core.setupSteps
        guard !steps.isEmpty else { return [] }
        return core.passes.enumerated().map { (p, target) in
            let row = core.results.indices.contains(p) ? core.results[p] : []
            let chips = steps.enumerated().map { (i, s) -> DevChip in
                var status = DevChip.Status.pending
                var caveat = false
                if let v = row.indices.contains(i) ? DevRunCore.latestVerdict(row[i]) : nil {
                    switch v {
                    case .pass:
                        status = .passed
                        caveat = row[i]?.attempts.last(where: { !$0.superseded })?.hiding.map { !$0.conclusive } ?? false
                    case .fail: status = .failed
                    case .skipped: status = .skipped
                    case .inconclusive, .invalid: status = .inconclusive
                    case .recorded: status = .recorded
                    }
                } else if p == core.pass, core.currentStepIndex == i, core.isRunning {
                    status = .current
                }
                return DevChip(index: i, stepId: s.step.id, title: s.step.title, controls: s.step.controls, status: status, caveat: caveat)
            }
            return DevPassChips(pass: p, target: target, chips: chips, standDown: core.standDownPass == p ? DevSession.standDownChipHelp : nil)
        }
    }

    private func buildRows(_ results: [DevStepResult]) -> [DevResultRow] {
        let steps = core.setupSteps
        return results.map { r in
            let title = steps.indices.contains(r.index) ? steps[r.index].step.title : r.stepId
            let last = r.attempts.last(where: { !$0.superseded }) ?? r.attempts.last
            let m = last?.metrics
            func pct(_ v: Double?) -> String { v.map { String(format: "%.0f %%", $0 * 100) } ?? "–" }
            let verdict = DevRunCore.latestVerdict(r)
            var seen = m?.detail ?? ""
            if seen.isEmpty, let reason = verdict?.reason { seen = reason }
            let (expectedText, background) = Self.expectedCell(steps.indices.contains(r.index) ? steps[r.index] : nil, expected: r.expected)
            let note = Self.resultNote(last, background: background, verdict: verdict)
            return DevResultRow(index: r.index, title: title, expected: expectedText, seen: seen,
                                loss: pct(m?.lossRatio),
                                onset: m?.onsetMs.map { String(format: "%.1f ms", $0) } ?? "–",
                                frames: m.map { $0.framesSeen > 0 ? "\($0.framesSeen)" : "–" } ?? "–",
                                verdict: verdict, attempts: r.attempts.count, note: note,
                                caveat: verdict == .pass && (last?.hiding.map { !$0.conclusive } ?? false))
        }
    }

    /// The Expected cell of a step, and the background items it holds (named, "R3 and L3"; empty for none).
    nonisolated static func expectedCell(_ rs: DevResolvedStep?, expected: DevExpectedItems) -> (text: String, background: String) {
        var text = expected.summary
        var background = ""
        if let rs {
            if let times = rs.step.expect?.times, rs.step.devKind == .digital || rs.step.devKind == .trigger { text = expected.summary(times: times) }
            // A held step watches one item (a trigger has no place in the expected buttons).
            if rs.step.devKind == .held { text = DevJudge.heldSummary(step: rs.step, expected: expected) }
            if rs.step.devKind == .record { text = recordExpected }
            if rs.builtInEcho { text = builtInEchoExpected }
            if !rs.background.isEmpty {
                background = rs.background.sorted().map(\.ownerName).joined(separator: " and ")
                text += "; \(background) held in the background"
            }
        }
        return (text, background)
    }

    /// The sentence under a result (its tooltip): a held background item that never dropped, then what the hiding check found.
    nonisolated static func resultNote(_ attempt: DevAttempt?, background: String, verdict: DevVerdict?) -> String? {
        var note = attempt?.hiding?.line
        if !background.isEmpty, verdict == .pass {
            note = "\(background) never dropped: pass." + (note.map { " " + $0.prefix(1).uppercased() + $0.dropFirst() } ?? "")
        }
        return note
    }

    // MARK: Header

    private func makeHeader(template: DevTemplate, mapping: ControlMapping) -> DevRunHeader {
        var h = DevRunHeader()
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        h.appBuild = [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        if h.appBuild.isEmpty { h.appBuild = "dev" }
        if case .active(let b) = driver.state { h.dextBuild = b }
        switch driver.mode {
        case .engine: h.guiMode = "engine"
        case .inApp: h.guiMode = "inApp"
        case .displayOnly: h.guiMode = "displayOnly"
        }
        h.padIdentity = reader.openedIdentityID ?? VirtualPadReader.activeIdentity().id
        h.vpadMaxRateHz = VirtualPadSink.runtimeMaxRateHz()
        h.xlateCore = VirtualPadSink.runtimeXlateCore() == .swift ? "swift" : "c"
        h.mapping = mapping
        h.mappingHash = DevRunReportStore.mappingHash(mapping)
        h.templateId = template.id
        h.templateVersion = template.version
        h.templateSha256 = DevRunReportStore.templateSha256(template)
        h.decodeTable = .current
        return h
    }
}

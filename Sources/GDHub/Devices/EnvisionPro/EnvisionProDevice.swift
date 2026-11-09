import Foundation
import Combine

struct LoggedEvent: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let text: String
}

@MainActor
final class EnvisionProDevice: ObservableObject, DeviceModule {
    typealias Status = ControllerStatus

    // DeviceModule
    let id = "envision-pro"
    let displayName = "SCUF Envision Pro"
    /// 0x3a08: composite identity while a controller is linked (audio + gamepad + control).
    /// 0x3a09: HID-only identity the receiver takes when no controller is linked.
    let matchList: [(vendorId: Int, productId: Int)] = [(0x1b1c, 0x3a08), (0x1b1c, 0x3a09)]
    static let linkedProductId = 0x3a08
    static let idleProductId = 0x3a09

    static let gamepadUsagePage = 0xFF58
    static let consumerUsagePage = 0x0C
    private let asleepAfter: TimeInterval = 2
    private let maxLogEntries = 500

    /// While editing, every change is written to the user layout file shortly after it happens, so a
    /// crash or relaunch never loses work; Done only locks, Cancel restores the snapshot taken at start.
    @Published var layout: ControlLayout? {
        didSet { if editor.isEditing { scheduleLayoutAutosave() } }
    }
    let editor = LayoutEditor()
    private var autosaveWork: DispatchWorkItem?

    private func scheduleLayoutAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.layout?.saveAsUserLayout() }
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @Published private(set) var frame = GamepadFrame()
    @Published private(set) var status: Status = .disconnected {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    @Published private(set) var eventLog: [LoggedEvent] = []
    @Published var mapping: ControlMapping {
        didSet { if mapping != oldValue { mappingRevision &+= 1; store.save(mapping) } }
    }
    /// Bumped on every mapping change; lets the virtual pad feed drop duplicate frames cheaply.
    private(set) var mappingRevision = 0
    @Published private(set) var learn: LearnSession?
    /// Summary of the last learn step of the most recently finished session.
    @Published private(set) var lastLearnResult = ""

    /// Every parsed report 0x06 with the current mapping, on the main actor (virtual pad feed, design §5.6).
    /// Called after `status` has been set to `.active` for that frame.
    /// `stamp` carries the report's kernel timestamp and callback entry time for the latency meter (zeros when unknown).
    var onFrame: ((GamepadFrame, ControlMapping, LatencyStamp) -> Void)?
    /// Called when `status` changes: asleep, receiver idle and disconnected all mean "pad neutral".
    var onStatusChange: ((Status) -> Void)?
    /// Developer mode: every parsed report 0x06 with its kernel timestamp (ns on `LatencyMeter.nowNs()`), on the main
    /// actor, before the 125 Hz publish cap. Set only while a run is going, so a normal session pays nothing for it.
    var frameTap: ((GamepadFrame, UInt64) -> Void)?
    /// Developer mode needs the driver manager (input path, engine pid, tap status); the app sets it at launch.
    var driverForDeveloper: DriverManager?
    /// Developer mode: non-nil while the mode is on. Exclusive with the layout editor and the guided learn.
    @Published private(set) var dev: DevSession?

    private let store: MappingStore
    private var latestFrame = GamepadFrame()
    private var hasFrame = false
    private var lastReportAt: Date?
    private var interfaces: [Int: Int] = [:]
    private var lastRawText: String?
    private var timer: Timer?
    private var learnForward: AnyCancellable?
    private var editorForward: AnyCancellable?

    // Frame publishing is limited to ~125 Hz; events and learning see every frame.
    private var lastPublish = Date.distantPast
    private var flushScheduled = false
    private let publishInterval: TimeInterval = 0.008

    init(layout: ControlLayout?, store: MappingStore = .envisionPro) {
        self.layout = layout
        self.store = store
        self.mapping = store.load()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.timerTick() } }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Views observe the device for the row layout; re-publish only for the editor state that
        // changes it (edit mode and zoom), not for every selection or drag update.
        editorForward = editor.$isEditing.map { _ in () }.merge(with: editor.$zoom.map { _ in () })
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    deinit { timer?.invalidate() }

    // MARK: DeviceModule

    func interfaceConnected(usagePage: Int, productId: Int) {
        interfaces[usagePage, default: 0] += 1
        log("interface connected (page 0x\(String(usagePage, radix: 16, uppercase: true)), product 0x\(String(productId, radix: 16, uppercase: true)))")
        if productId == Self.idleProductId {
            status = .receiverIdle
        } else if status == .disconnected || status == .receiverIdle {
            status = .asleep
        }
    }

    func interfaceDisconnected(usagePage: Int) {
        if let n = interfaces[usagePage] {
            if n <= 1 { interfaces[usagePage] = nil } else { interfaces[usagePage] = n - 1 }
        }
        log("interface removed (page 0x\(String(usagePage, radix: 16, uppercase: true)))")
        if interfaces.isEmpty {
            status = .disconnected
            lastReportAt = nil
        }
    }

    func handle(reportID: UInt32, bytes: [UInt8], usagePage: Int) {
        guard usagePage == Self.gamepadUsagePage, reportID == 6 else {
            logRaw(reportID: reportID, bytes: bytes, usagePage: usagePage)
            return
        }
        guard let new = GamepadFrame.parse(bytes) else {
            logRaw(reportID: reportID, bytes: bytes, usagePage: usagePage, prefix: "malformed 0x06")
            return
        }
        ingest(new, stamp: LatencyStamp())
    }

    /// Synchronous entry for the gamepad interface (page 0xFF58), called from the HID callback on the main run loop.
    /// `report` is the IOKit buffer: it is parsed before this returns and never kept. `tK` / `tC`: see `HIDMonitor`.
    func handleGamepadReport(reportID: UInt32, report: UnsafeBufferPointer<UInt8>, tK: UInt64, tC: UInt64) {
        guard reportID == 6 else {
            handle(reportID: reportID, bytes: Array(report), usagePage: Self.gamepadUsagePage)
            return
        }
        guard let new = GamepadFrame.parse(report) else {
            handle(reportID: reportID, bytes: Array(report), usagePage: Self.gamepadUsagePage)      // logs it as malformed
            return
        }
        ingest(new, stamp: LatencyStamp(tK: tK, tC: tC, tD: 0))
    }

    private func ingest(_ new: GamepadFrame, stamp: LatencyStamp) {
        let now = Date()
        lastReportAt = now
        if status != .active { status = .active }

        let previous = hasFrame ? latestFrame : GamepadFrame()
        for e in new.diff(from: previous) { log(e.text, at: now) }
        latestFrame = new
        hasFrame = true
        onFrame?(new, mapping, stamp)
        frameTap?(new, stamp.tK != 0 ? stamp.tK : LatencyMeter.nowNs())
        publish(new)
        learn?.feed(new, now: now)
    }

    // MARK: Learning

    func startGuidedLearn() {
        guard let layout else { return }
        beginLearn(controls: layout.controlsByOrder, mode: .guided)
    }

    func startLearn(controlId: String) {
        guard let c = layout?.control(id: controlId) else { return }
        beginLearn(controls: [c], mode: .single)
    }

    func skipLearn() { learn?.skip() }

    // MARK: Layout editing

    func updateControl(_ id: String, _ change: (inout ControlLayout.Control) -> Void) {
        guard var l = layout, let i = l.controls.firstIndex(where: { $0.id == id }) else { return }
        change(&l.controls[i])
        layout = l
    }

    /// Apply a leader preset ("oneCorner", "twoCorners" or nil for straight) to controls, discarding hand-placed corners.
    func setLeaderPreset(_ preset: String?, for ids: Set<String>) {
        for id in ids { updateControl(id) { $0.leaderPreset = preset; $0.leader = nil } }
    }

    private var layoutBeforeEdit: ControlLayout?

    func beginEditingLayout() {
        guard dev == nil else { return }
        layoutBeforeEdit = layout
        layout?.writePreEditSnapshot()
        editor.isEditing = true
    }

    /// If the app was quit (or relaunched) while editing, autosave has already written the
    /// in-progress state. Offer the layout from before that session instead and keep the autosaved
    /// one as a backup. Called once at startup.
    func recoverInterruptedEditIfNeeded() {
        guard let snapshot = ControlLayout.load(from: ControlLayout.preEditSnapshotURL) else { return }
        layout?.saveAsUserLayout()          // keeps a backup of the autosaved in-progress state
        layout = snapshot
        snapshot.saveAsUserLayout()
        ControlLayout.clearPreEditSnapshot()
        log("recovered the layout from before an interrupted edit session (the in-progress one is in layout-backups)")
    }

    func restoreLayout(from url: URL) {
        guard let l = ControlLayout.load(from: url) else { return }
        editor.isEditing = false
        editor.selection = []
        layout = l
        l.saveAsUserLayout()
        log("layout restored from \(url.lastPathComponent)")
    }

    /// Leave edit mode and throw away everything changed since it was entered.
    func cancelEditingLayout() {
        editor.isEditing = false
        autosaveWork?.cancel()
        if let l = layoutBeforeEdit { layout = l; l.saveAsUserLayout() }
        ControlLayout.clearPreEditSnapshot()
        editor.selection = []
        editor.zoom = 1
        log("layout edits discarded")
    }

    /// Where leaders leave the selected labels: "side", "below", "above" or nil for automatic.
    func setLeaderAttach(_ attach: String?, for ids: Set<String>) {
        for id in ids { updateControl(id) { $0.leaderAttach = attach } }
    }

    func setLeaderOrientation(_ orientation: String?, for ids: Set<String>) {
        for id in ids { updateControl(id) { $0.leaderOrientation = orientation } }
    }

    /// Swap horizontal-first / vertical-first for each control (relative to what it currently shows).
    func flipLeaderOrientation(for ids: Set<String>) {
        for id in ids {
            updateControl(id) {
                let current = $0.leaderOrientation ?? "auto"
                $0.leaderOrientation = current == "vFirst" ? "hFirst" : (current == "hFirst" ? "vFirst" : "flip")
            }
        }
    }

    func selectAllLabels() {
        editor.selection = Set((layout?.controls ?? []).map(\.id))
    }

    func moveView(_ side: ControlLayout.Side, dx: Int, dy: Int) {
        guard var l = layout else { return }
        l.moveView(side, dx: dx, dy: dy)
        layout = l
    }

    func setViewColumns(_ cols: [[ControlLayout.Side]]) {
        guard var l = layout else { return }
        l.viewColumns = cols.map { $0.map(\.rawValue) }
        layout = l
    }

    /// Lock the layout: leave edit mode and persist it.
    func lockLayout() {
        editor.isEditing = false
        autosaveWork?.cancel()
        editor.selection = []
        editor.zoom = 1
        layout?.saveAsUserLayout()
        ControlLayout.clearPreEditSnapshot()
        log("layout saved")
    }

    func resetLayout() {
        ControlLayout.deleteUserLayout()
        layout = ControlLayout.loadFromBundle()
        editor.selection = []
        log("layout reset to built-in")
    }
    func backLearn() { learn?.back() }

    func cancelLearn() { learn?.cancel() }

    // MARK: Developer mode

    /// Switches Developer mode on. Cancels a learn in progress; refuses while the layout is being edited, while it is
    /// already on, or when there is no driver manager to run against.
    @discardableResult
    func beginDeveloper() -> Bool {
        guard dev == nil, !editor.isEditing, let driver = driverForDeveloper else { return false }
        cancelLearn()
        dev = DevSession(device: self, driver: driver)
        return true
    }

    /// Switches Developer mode off: stops a run (which writes its report and restores the input path), closes the pad
    /// reader and drops the session.
    func endDeveloper() {
        guard let session = dev else { return }
        session.shutDown()
        dev = nil
    }

    private func beginLearn(controls: [ControlLayout.Control], mode: LearnSession.Mode) {
        guard dev == nil else { return }
        learn?.cancel()
        let session = LearnSession(
            controls: controls, mode: mode, baseline: latestFrame,
            onAssign: { [weak self] a in self?.mapping.apply(a) },
            onFinish: { [weak self] in
                // Defer so the session can finish updating itself first; keep the final
                // result visible for a moment.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.learnFinished() } }
            })
        learn = session
        learnForward = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.objectWillChange.send() } }
        }
    }

    private func learnFinished() {
        // Only clear if the finished session is still the current one.
        if let l = learn, l.isFinished {
            lastLearnResult = l.lastResult
            learn = nil
            learnForward = nil
        }
    }

    // MARK: Log

    func clearLog() { eventLog.removeAll() }

    private func log(_ text: String, at time: Date = Date()) {
        eventLog.insert(LoggedEvent(time: time, text: text), at: 0)
        if eventLog.count > maxLogEntries { eventLog.removeLast(eventLog.count - maxLogEntries) }
    }

    private func logRaw(reportID: UInt32, bytes: [UInt8], usagePage: Int, prefix: String? = nil) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let source: String
        if let prefix { source = prefix }
        else if usagePage == Self.consumerUsagePage { source = "consumer interface" }
        else { source = "page 0x\(String(usagePage, radix: 16, uppercase: true))" }
        let text = "\(source) id=0x\(String(format: "%02x", reportID)) [\(bytes.count)]: \(hex)"
        if text == lastRawText { return } // collapse identical consecutive reports
        lastRawText = text
        log(text)
    }

    // MARK: Publishing / sleep detection

    private func publish(_ f: GamepadFrame) {
        let now = Date()
        if now.timeIntervalSince(lastPublish) >= publishInterval {
            lastPublish = now
            if frame != f { frame = f }
        } else if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + publishInterval) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.flushScheduled = false
                    self.lastPublish = Date()
                    if self.frame != self.latestFrame { self.frame = self.latestFrame }
                }
            }
        }
    }

    private func timerTick() {
        if status == .active, let last = lastReportAt, Date().timeIntervalSince(last) > asleepAfter {
            status = .asleep
            // Make sure the UI shows the last frame.
            if frame != latestFrame { frame = latestFrame }
        }
        learn?.tick()
    }
}

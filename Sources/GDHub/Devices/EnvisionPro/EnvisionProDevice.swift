import Foundation
import Combine

struct LoggedEvent: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let text: String
}

@MainActor
final class EnvisionProDevice: ObservableObject, DeviceModule {
    enum Status: String {
        case disconnected, receiverIdle, asleep, active

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .receiverIdle: return "Receiver idle (controller off)"
            case .asleep: return "Asleep"
            case .active: return "Connected"
            }
        }
    }

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
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var eventLog: [LoggedEvent] = []
    @Published var mapping: ControlMapping {
        didSet { if mapping != oldValue { store.save(mapping) } }
    }
    @Published private(set) var learn: LearnSession?
    /// Summary of the last learn step of the most recently finished session.
    @Published private(set) var lastLearnResult = ""

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
        // Views observe the device; re-publish when edit-mode state changes.
        editorForward = editor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.objectWillChange.send() } }
        }
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
        let now = Date()
        lastReportAt = now
        if status != .active { status = .active }

        let previous = hasFrame ? latestFrame : GamepadFrame()
        for e in new.diff(from: previous) { log(e.text, at: now) }
        latestFrame = new
        hasFrame = true
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
        layoutBeforeEdit = layout
        editor.isEditing = true
    }

    /// Leave edit mode and throw away everything changed since it was entered.
    func cancelEditingLayout() {
        editor.isEditing = false
        autosaveWork?.cancel()
        if let l = layoutBeforeEdit { layout = l; l.saveAsUserLayout() }
        editor.selection = []
        editor.zoom = 1
        log("layout edits discarded")
    }

    /// Lock the layout: leave edit mode and persist it.
    func lockLayout() {
        editor.isEditing = false
        autosaveWork?.cancel()
        editor.selection = []
        editor.zoom = 1
        layout?.saveAsUserLayout()
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

    private func beginLearn(controls: [ControlLayout.Control], mode: LearnSession.Mode) {
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

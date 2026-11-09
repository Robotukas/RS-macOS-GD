import Foundation
import AppKit
import SystemExtensions
import os

/// Installs, updates and removes the embedded DriverKit extension (design §5.1).
@MainActor
final class DriverManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case checking
        case notBundled
        case wrongLocation(String)
        case notInstalled
        case activating
        case updating(from: String, to: String)
        case needsApproval
        case active(String)
        case rebootRequired
        case uninstalling
        case failed(code: Int, message: String)
    }

    static let dextID = "com.interlinked.gdhub.VirtualHID"
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")

    @Published private(set) var state: State = .checking {
        didSet { if state != oldValue { Self.log.info("driver state: \(String(describing: self.state), privacy: .public)") } }
    }

    /// Connection to the running dext (design §5.2). Shown in the Driver menu.
    @Published private(set) var connection: DextClient.State = .stopped

    /// Serial queue for every dext call and callback (design §5.2). Later phases share it with the pad sink.
    let vhidQueue = DispatchQueue(label: "com.interlinked.gdhub.vhid", qos: .userInteractive)
    let dext: DextClient
    let sink: VirtualPadSink
    private let poller: DextStatusPoller

    /// Pad publication state (design §5.4) and whether the test pattern is running.
    @Published private(set) var padState: PadPublishState = .off {
        didSet {
            updatePadActivity()
            if padState == .off, oldValue != .off { evaluateAutoPublish() }
        }
    }
    @Published private(set) var testPatternRunning = false
    /// Live traffic from `getStatus` (nil while not connected).
    @Published private(set) var padStats: PadStats?
    /// Latency of the last 10 s (nil while not connected). Shown in the Driver menu; also written to the `latency` log.
    @Published private(set) var latency: LatencySnapshot?
    /// Number of synthetic pads macOS GameController made from our pad (normally 1 while published).
    @Published private(set) var syntheticPadCount = 0

    /// Holds the App Nap opt-out while the pad is published (latency plan fix #1).
    private let padActivity = PadActivity()
    private let syntheticWatcher = SyntheticPadWatcher()

    // Auto-publish policy: publish the pad when the controller connects (the pad then stays, reporting neutral, while
    // the controller sleeps). An explicit Unpublish holds auto-publish off until the user publishes again or the app
    // restarts.
    static let autoPublishKey = "vhid.pad.autoPublish"
    @Published var autoPublish: Bool = (UserDefaults.standard.object(forKey: DriverManager.autoPublishKey) as? Bool) ?? true {
        didSet {
            guard autoPublish != oldValue else { return }
            UserDefaults.standard.set(autoPublish, forKey: Self.autoPublishKey)
            evaluateAutoPublish(retryBlocked: true)
        }
    }
    private var controllerActive = false
    private var autoPublishHeldOff = false

    // Dev aids from the command line (confined to vhidQueue once running).
    private var pendingDevTerminate = CommandLine.arguments.contains("--dev-terminate-driver")
    /// True from launch until `--dev-terminate-driver` has terminated the old driver process (main actor).
    private var devTerminateOutstanding = CommandLine.arguments.contains("--dev-terminate-driver")
    private var pendingTestPattern = CommandLine.arguments.contains("--test-pattern")
    private var lastActiveBuild: String?

    let embeddedDextURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/SystemExtensions/\(DriverManager.dextID).dext")
    let embeddedBuild: String?

    private var pollTask: Task<Void, Never>?
    private var started = false

    override init() {
        embeddedBuild = Bundle(url: embeddedDextURL)?.infoDictionary?["CFBundleVersion"] as? String
        let client = DextClient(queue: vhidQueue)
        dext = client
        // 1000 Hz unless `defaults write com.interlinked.gdhub vpadMaxRateHz -float <60…1000>` says otherwise; read here, so
        // changing it needs a relaunch. `Config()` itself stays at 250 Hz.
        var config = VirtualPadSink.Config()
        config.maxRateHz = VirtualPadSink.runtimeMaxRateHz()
        let padSink = VirtualPadSink(queue: vhidQueue, transport: client, config: config)
        sink = padSink
        // `--latency-log` (dev aid): print the `latency` log line every 2 s instead of every 10 s.
        poller = DextStatusPoller(queue: vhidQueue, dext: client, sink: padSink,
                                  latencyLogEvery: CommandLine.arguments.contains("--latency-log") ? 2 : 10)
        super.init()
        Self.log.info("virtual pad rate cap \(Int(config.maxRateHz)) Hz")
        poller.onLatency = { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.latency != snapshot else { return }
                self.latency = snapshot
            }
        }
        syntheticWatcher.onCount = { [weak self] count in
            Task { @MainActor in self?.syntheticPadCount = count }
        }
        poller.onUpdate = { [weak self] stats in
            Task { @MainActor in
                guard let self, self.padStats != stats else { return }
                self.padStats = stats
            }
        }
        dext.onState = { [weak self] new in
            // Called on vhidQueue.
            guard let self else { return }
            if case .connected = new { self.sink.transportConnected(); self.poller.start() }
            else { self.sink.transportLost(); self.poller.stop() }
            self.runDevAidsIfConnected(new)
            Task { @MainActor in
                if new != self.connection { Self.log.info("connection: \(String(describing: new), privacy: .public)") }
                self.connection = new
                self.evaluateAutoPublish()
            }
        }
        sink.onPadState = { [weak self] new in
            Task { @MainActor in
                guard let self else { return }
                if new != self.padState { Self.log.info("pad: \(String(describing: new), privacy: .public)") }
                self.padState = new
            }
            self?.startPatternIfRequested(new)
        }
        sink.onTestPattern = { [weak self] on in Task { @MainActor in self?.testPatternRunning = on } }
        // `--publish-pad <identity>` (dev aid): publish without persisting; it waits for the connection.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--publish-pad"), i + 1 < args.count {
            if let id = PadIdentity.named(args[i + 1]) { vhidQueue.async { [sink] in sink.publish(id, persist: false) } }
            else { Self.log.error("--publish-pad: unknown identity \(args[i + 1], privacy: .public)") }
        }
        // Dev aids for scripted checks: `--unpublish-after <s>` and `--switch-pad-after <s> <identity>`.
        if let i = args.firstIndex(of: "--unpublish-after"), i + 1 < args.count, let sec = Double(args[i + 1]) {
            vhidQueue.asyncAfter(deadline: .now() + sec) { [sink] in sink.unpublish(persist: false) }
        }
        if let i = args.firstIndex(of: "--switch-pad-after"), i + 2 < args.count, let sec = Double(args[i + 1]),
           let id = PadIdentity.named(args[i + 2]) {
            vhidQueue.asyncAfter(deadline: .now() + sec) { [sink] in sink.publish(id, persist: false) }
        }
    }

    /// vhidQueue. `--dev-terminate-driver`: once connected, ask the dext to terminate (DEBUG-only experiment).
    private func runDevAidsIfConnected(_ s: DextClient.State) {
        guard case .connected = s, pendingDevTerminate else { return }
        pendingDevTerminate = false
        vhidQueue.asyncAfter(deadline: .now() + 1) { [dext] in
            Self.log.info("--dev-terminate-driver: calling devTerminate")
            dext.devTerminate()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.devTerminateOutstanding = false
            }
        }
    }

    /// vhidQueue. `--test-pattern`: loop the pattern once the pad is published.
    private func startPatternIfRequested(_ s: PadPublishState) {
        guard case .published = s, pendingTestPattern else { return }
        pendingTestPattern = false
        vhidQueue.asyncAfter(deadline: .now() + 1) { [sink] in sink.runTestPattern(loop: true) }
    }

    // MARK: Launch

    func start() {
        guard !started else { return }
        started = true
        syntheticWatcher.start()
        // Always start the client: it waits for the service, which also lets a SwiftPM build be refused by the
        // dext's Team ID check (design §5.1 step 4).
        vhidQueue.async { [dext] in dext.start() }
        guard embeddedBuild != nil else { state = .notBundled; return }
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") else { state = .wrongLocation(path); return }
        queryProperties()
    }

    private func queryProperties() {
        let req = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.dextID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    // MARK: Actions

    func installOrUpdate() {
        guard embeddedBuild != nil else { return }
        // Close the connection first (D3+: destroy the devices too); it reconnects when the new dext matches.
        vhidQueue.sync { sink.shutdown(); dext.stop() }
        let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.dextID, queue: .main)
        req.delegate = self
        if case .updating = state {} else { state = .activating }
        Self.log.info("submitting activation request (bundled build \(self.embeddedBuild ?? "?", privacy: .public))")
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func uninstall() {
        guard embeddedBuild != nil else { return }
        vhidQueue.sync { sink.shutdown(); dext.stop() }
        let req = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.dextID, queue: .main)
        req.delegate = self
        state = .uninstalling
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func retry() {
        if case .failed = state { state = .checking; queryProperties() }
    }

    // MARK: Pad actions (design §5.4; all hop to vhidQueue)

    func publishPad(_ identity: PadIdentity) {
        autoPublishHeldOff = false
        vhidQueue.async { [sink] in sink.publish(identity) }
    }
    func unpublishPad() {
        autoPublishHeldOff = true
        vhidQueue.async { [sink] in sink.unpublish() }
    }
    func runTestPattern() { vhidQueue.async { [sink] in sink.runTestPattern() } }
    func stopTestPattern() { vhidQueue.async { [sink] in sink.stopTestPattern() } }

    // MARK: Controller and lifecycle hooks (design §5.6; called by AppModel on the main actor)

    /// The controller's status changed. Not-active means asleep, receiver idle or disconnected: the pad goes neutral
    /// but stays published. Becoming active may auto-publish.
    func controllerStatusChanged(_ status: EnvisionProDevice.Status) {
        controllerActive = (status == .active)
        if status != .active { vhidQueue.async { [sink] in sink.neutral() } }
        evaluateAutoPublish(retryBlocked: true)
    }

    /// Neutral pad immediately (system sleep). Synchronous so it lands before the Mac sleeps.
    func neutralNow() { vhidQueue.sync { sink.neutral() } }

    /// App is quitting: destroy the pad and close the connection so the devices disappear at once.
    func prepareForTermination() {
        vhidQueue.sync { sink.shutdown(); dext.stop() }
        padActivity.setHeld(false)
        syntheticWatcher.stop()
    }

    /// Fix #1: no App Nap while the pad is published. A pad that is only re-publishing (identity switch, lost device)
    /// keeps the activity; off, blocked and error release it.
    private func updatePadActivity() {
        switch padState {
        case .published:
            if padActivity.setHeld(true) { Self.log.info("App Nap opt-out on (pad published)") }
        case .off, .blockedDuplicate, .error:
            if padActivity.setHeld(false) { Self.log.info("App Nap opt-out off") }
        case .publishing:
            break
        }
    }

    /// Publishes the persisted (or default) identity when the policy says so. `retryBlocked` also re-tries a pad that
    /// was blocked by a duplicate device.
    private func evaluateAutoPublish(retryBlocked: Bool = false) {
        guard autoPublish, controllerActive, !autoPublishHeldOff, case .connected = connection else { return }
        guard padState == .off || (retryBlocked && { if case .blockedDuplicate = padState { return true } else { return false } }())
        else { return }
        let id = PadIdentity.named(UserDefaults.standard.string(forKey: VirtualPadSink.identityKey) ?? "") ?? .default
        Self.log.info("auto-publish: controller connected, publishing \(id.id, privacy: .public)")
        vhidQueue.async { [sink] in sink.publish(id, persist: false) }
    }

    /// Clears the connection back-off and the refusal latch (Retry in the Driver menu).
    func retryConnection() { vhidQueue.async { [dext] in dext.retry() } }

    /// DEBUG-ONLY dev experiment: the dext terminates its root service so the process exits and a staged build can
    /// start without a reboot.
    func devTerminateDriver() { vhidQueue.async { [dext] in dext.devTerminate() } }

    func openSystemSettings() {
        let urls = ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                    "x-apple.systempreferences:"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: Polling while waiting for approval

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.state == .needsApproval else { return }
                self.queryProperties()
            }
        }
    }

    private func set(_ new: State) {
        state = new
        if new == .needsApproval { startPolling() } else { pollTask?.cancel() }
    }

    // MARK: Errors

    static func describe(_ error: Error) -> (Int, String) {
        let ns = error as NSError
        guard ns.domain == OSSystemExtensionErrorDomain else { return (ns.code, ns.localizedDescription) }
        let text: String
        switch ns.code {
        case 2: text = "App lacks System Extension entitlement"
        case 3: text = "Run from /Applications"
        case 4: text = "Dext not embedded"
        case 7: text = "Dext not recognised (CFBundlePackageType must be DEXT)"
        case 8: text = "Signature/profile mismatch"
        case 9: text = "Validation failed (entitlements vs profile, or CFBundlePackageType)"
        default: text = ns.localizedDescription
        }
        return (ns.code, text)
    }

    // MARK: OSSystemExtensionRequestDelegate

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
            .info("replacing dext \(existing.bundleVersion, privacy: .public) -> \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { self.set(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            Self.log.info("request finished: \(result.rawValue)")
            if result == .willCompleteAfterReboot { self.set(.rebootRequired); return }
            if self.state == .uninstalling { self.set(.notInstalled); return }
            self.queryProperties()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let (code, msg) = Self.describe(error)
            Self.log.error("request failed: \(code) \(msg, privacy: .public)")
            self.set(.failed(code: code, message: msg))
            // installOrUpdate closed the connection first; a failed request leaves the old driver running, so keep using it.
            self.vhidQueue.async { [dext] in dext.start() }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let infos = properties.map { (v: $0.bundleVersion, enabled: $0.isEnabled, uninstalling: $0.isUninstalling, awaiting: $0.isAwaitingUserApproval) }
        MainActor.assumeIsolated { self.handleProperties(infos) }
    }

    private func handleProperties(_ infos: [(v: String, enabled: Bool, uninstalling: Bool, awaiting: Bool)]) {
        let enabled = infos.filter { $0.enabled && !$0.uninstalling }
        if let match = enabled.first(where: { $0.v == embeddedBuild }) {
            set(.active(match.v))
            if lastActiveBuild != match.v {
                // A new driver build may accept an app the old one refused: clear the refusal latch.
                if lastActiveBuild != nil { retryConnection() }
                lastActiveBuild = match.v
            }
            vhidQueue.async { [dext] in dext.start() }       // no-op when already running
        } else if let old = enabled.map(\.v).max(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            if case .updating = state { return }   // already replacing
            if devTerminateOutstanding {
                // Dev aid: sysextd refuses a second replacement while the previous driver process is still running
                // ("two entries ... terminating_for_upgrade"), so let `--dev-terminate-driver` end that process first.
                Self.log.info("update \(old) -> \(self.embeddedBuild ?? "?", privacy: .public) deferred until the old driver process has been terminated")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.queryProperties()
                }
                return
            }
            set(.updating(from: old, to: embeddedBuild ?? "?"))
            installOrUpdate()
        } else if infos.contains(where: { $0.awaiting }) {
            set(.needsApproval)
        } else if state == .activating || state == .uninstalling {
            return   // request in flight
        } else {
            set(.notInstalled)
            // Dev aid: `open -a GDHub --args --install-driver` installs without the menu.
            if CommandLine.arguments.contains("--install-driver") { installOrUpdate() }
        }
    }
}

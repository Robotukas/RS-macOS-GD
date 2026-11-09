import Foundation
import os

/// The runtime half of the pad path: the dext connection, the pad sink, the auto-publish policy and the recovery from a
/// busy dext. Confined to `queue` (the engine's `vhidQueue`) and free of AppKit: the engine process never creates an
/// application object. Every method must be called on `queue`; callbacks run on `queue` too.
final class EngineCore: @unchecked Sendable {
    static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")
    static let autoPublishKey = "vhid.pad.autoPublish"
    /// Seconds before the n-th `retry()` after the dext reported `.exclusive` or `.failed`; the last value repeats.
    static let retrySchedule: [Double] = [0.25, 0.5, 1, 2]

    let queue: DispatchQueue
    let dext: DextControlling
    let sink: VirtualPadSink
    private let scheduler: SinkScheduler
    private let defaults: UserDefaults

    // Connection and publication policy
    private(set) var connection: DextClient.State = .stopped
    private(set) var padState: PadPublishState = .off
    private(set) var testPatternRunning = false
    private(set) var controllerActive = false
    private(set) var autoPublishHeldOff = false
    private(set) var autoPublish: Bool

    // Mapping
    private(set) var mapping: ControlMapping
    private(set) var mappingRevision = 0

    // `.exclusive` / `.failed` recovery
    private var retryActive = false
    private var retryAttempts = 0
    private var retryTimer: SinkTimer?
    private var retryGeneration = 0

    // Dev aids
    private var pendingTestPattern: Bool
    private let options: EngineOptions

    var onConnection: ((DextClient.State) -> Void)?
    var onPadState: ((PadPublishState) -> Void)?
    var onTestPattern: ((Bool) -> Void)?

    init(queue: DispatchQueue, dext: DextControlling, sink: VirtualPadSink, scheduler: SinkScheduler,
         defaults: UserDefaults = .standard, mapping: ControlMapping, options: EngineOptions = EngineOptions()) {
        self.queue = queue
        self.dext = dext
        self.sink = sink
        self.scheduler = scheduler
        self.defaults = defaults
        self.mapping = mapping
        self.options = options
        self.pendingTestPattern = options.testPattern
        self.autoPublish = (defaults.object(forKey: Self.autoPublishKey) as? Bool) ?? true
        dext.onState = { [weak self] new in self?.handleDextState(new) }
        sink.onPadState = { [weak self] new in self?.handlePadState(new) }
        sink.onTestPattern = { [weak self] on in
            self?.testPatternRunning = on
            self?.onTestPattern?(on)
        }
    }

    // MARK: Lifecycle

    /// Starts the dext client and arms the dev aids.
    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        dext.start()
        if let id = options.publishPad {
            if let identity = PadIdentity.named(id) { sink.publish(identity, persist: false) }
            else { Self.log.error("--publish-pad: unknown identity \(id, privacy: .public)") }
        }
        if let s = options.unpublishAfter {
            scheduler.after(UInt64(s * 1e9)) { [weak self] in self?.sink.unpublish(persist: false) }
        }
        if let sw = options.switchPadAfter {
            if let identity = PadIdentity.named(sw.identity) {
                scheduler.after(UInt64(sw.seconds * 1e9)) { [weak self] in self?.sink.publish(identity, persist: false) }
            } else {
                Self.log.error("--switch-pad-after: unknown identity \(sw.identity, privacy: .public)")
            }
        }
    }

    /// Destroys the pad and closes the connection (SIGTERM, uninstall).
    func shutdown() {
        dispatchPrecondition(condition: .onQueue(queue))
        cancelRetry()
        autoPublishHeldOff = true           // the unpublish below must not trigger an auto-publish
        sink.shutdown()
        dext.stop()
    }

    /// Neutral pad now (system sleep).
    func neutral() {
        dispatchPrecondition(condition: .onQueue(queue))
        sink.neutral()
    }

    // MARK: Dext connection

    func handleDextState(_ new: DextClient.State) {
        dispatchPrecondition(condition: .onQueue(queue))
        if new != connection { Self.log.notice("connection: \(String(describing: new), privacy: .public)") }
        connection = new
        switch new {
        case .connected:
            cancelRetry()
            sink.transportConnected()
        default:
            sink.transportLost()
        }
        switch new {
        case .exclusive, .failed:
            startRetry()
        case .rejected:
            cancelRetry()
            Self.log.error("dext refused this process (not signed by team 79XF6HYX8A); not retrying")
        case .protocolMismatch(let d):
            cancelRetry()
            Self.log.error("dext protocol v\(d) differs from this build; install the matching driver. Not retrying")
        case .connected, .stopped:
            cancelRetry()
        case .waitingForService:
            break           // part of a retry attempt, or the initial wait: the retry loop keeps its own schedule
        }
        onConnection?(new)
        evaluateAutoPublish()
    }

    private var isConnected: Bool { if case .connected = connection { return true } else { return false } }

    private func startRetry() {
        guard !retryActive else { return }
        retryActive = true
        retryAttempts = 0
        scheduleNextRetry()
    }

    private func cancelRetry() {
        retryActive = false
        retryAttempts = 0
        retryGeneration += 1
        retryTimer?.cancel(); retryTimer = nil
    }

    private func scheduleNextRetry() {
        guard retryActive else { return }
        let delay = Self.retrySchedule[min(retryAttempts, Self.retrySchedule.count - 1)]
        let gen = retryGeneration
        retryTimer = scheduler.after(UInt64(delay * 1e9)) { [weak self] in
            guard let self, self.retryActive, self.retryGeneration == gen else { return }
            self.retryTimer = nil
            self.retryAttempts += 1
            let n = self.retryAttempts
            if n <= 5 || n % 30 == 0 { Self.log.notice("exclusive: retry #\(n)") }
            self.dext.retry()
            // A successful attempt reported `.connected` from inside `retry()` and ended the loop.
            if self.retryActive, !self.isConnected { self.scheduleNextRetry() }
        }
    }

    // MARK: Pad and controller

    private func handlePadState(_ new: PadPublishState) {
        let old = padState
        if new != old { Self.log.notice("pad: \(String(describing: new), privacy: .public)") }
        padState = new
        onPadState?(new)
        startPatternIfRequested(new)
        if new == .off, old != .off { evaluateAutoPublish() }
    }

    private func startPatternIfRequested(_ s: PadPublishState) {
        guard case .published = s, pendingTestPattern else { return }
        pendingTestPattern = false
        scheduler.after(1_000_000_000) { [weak self] in self?.sink.runTestPattern(loop: true) }
    }

    /// The controller's status changed. Not active (asleep, receiver idle, gone): the pad goes neutral but stays
    /// published. Becoming active may auto-publish.
    func controllerStatus(_ status: ControllerStatus) {
        dispatchPrecondition(condition: .onQueue(queue))
        controllerActive = (status == .active)
        if status != .active { sink.neutral(force: false) }       // LIVE: the driver's silence / Stop neutrals cover it
        evaluateAutoPublish(retryBlocked: true)
    }

    func setAutoPublish(_ on: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard on != autoPublish else { return }
        autoPublish = on
        defaults.set(on, forKey: Self.autoPublishKey)
        evaluateAutoPublish(retryBlocked: true)
    }

    /// An explicit publish clears the hold-off an earlier unpublish set.
    func publish(_ identity: PadIdentity) {
        dispatchPrecondition(condition: .onQueue(queue))
        autoPublishHeldOff = false
        sink.publish(identity)
    }

    /// An explicit unpublish holds auto-publish off until the next `publish` or an engine restart.
    func unpublish() {
        dispatchPrecondition(condition: .onQueue(queue))
        autoPublishHeldOff = true
        sink.unpublish()
    }

    /// Publishes the persisted (or default) identity when the policy says so. `retryBlocked` also retries a pad that a
    /// duplicate device blocked.
    func evaluateAutoPublish(retryBlocked: Bool = false) {
        guard autoPublish, controllerActive, !autoPublishHeldOff, isConnected else { return }
        let blocked: Bool = { if case .blockedDuplicate = padState { return true } else { return false } }()
        guard padState == .off || (retryBlocked && blocked) else { return }
        let id = PadIdentity.named(defaults.string(forKey: VirtualPadSink.identityKey) ?? "") ?? .default
        Self.log.notice("auto-publish: controller connected, publishing \(id.id, privacy: .public)")
        sink.publish(id, persist: false)
    }

    // MARK: Mapping

    /// Replaces the mapping (a learn or remap result written by the GUI). Equal mappings change nothing.
    func setMapping(_ m: ControlMapping) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard m != mapping else { return }
        mapping = m
        mappingRevision &+= 1
        Self.log.notice("mapping reloaded (rev \(self.mappingRevision))")
    }
}

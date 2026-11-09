import Foundation
import IOKit
import os

/// What the sink needs from the dext connection. `DextClient` conforms; tests use a fake. Every call runs on the
/// sink's queue.
protocol PadTransport: AnyObject {
    func createDevice(_ spec: DeviceSpec) -> kern_return_t
    func destroyDevice(slot: UInt8) -> kern_return_t
    func post(slot: UInt8, report: [UInt8]) -> kern_return_t
    func postNeutral(slot: UInt8) -> kern_return_t
    func heartbeat() -> kern_return_t
}

extension DextClient: PadTransport {}

enum PadPublishState: Equatable {
    case off
    case publishing(String)         // wanted, waiting for the driver connection or for the device to appear
    case published(String)
    case blockedDuplicate(String)   // another HID device already has the identity's VID:PID (description)
    case error(String)
}

// MARK: - Time

/// Cancellable timer handed out by a `SinkScheduler`.
protocol SinkTimer: AnyObject {
    func cancel()
}

/// Timers for the sink. Production uses `DispatchSinkScheduler`; tests use a manual clock. Blocks run on the sink's
/// queue.
protocol SinkScheduler: AnyObject {
    /// One-shot timer. `strict` asks the system not to coalesce the wake-up with others (`DISPATCH_TIMER_STRICT`):
    /// used for the trailing flush that delivers the last state.
    @discardableResult func after(_ ns: UInt64, strict: Bool, _ block: @escaping () -> Void) -> SinkTimer
    @discardableResult func every(_ ns: UInt64, _ block: @escaping () -> Void) -> SinkTimer
}

extension SinkScheduler {
    @discardableResult func after(_ ns: UInt64, _ block: @escaping () -> Void) -> SinkTimer {
        after(ns, strict: false, block)
    }
}

final class DispatchSinkScheduler: SinkScheduler {
    private final class Timer: SinkTimer {
        let source: DispatchSourceTimer
        init(_ s: DispatchSourceTimer) { source = s }
        func cancel() { source.cancel() }
    }
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }

    func after(_ ns: UInt64, strict: Bool, _ block: @escaping () -> Void) -> SinkTimer {
        let s = DispatchSource.makeTimerSource(flags: strict ? .strict : [], queue: queue)
        s.schedule(deadline: .now() + .nanoseconds(Int(ns)), leeway: .microseconds(100))
        // Strong capture on purpose: fire-and-forget callers drop the token, and the source must outlive it. The cycle
        // ends when the handler cancels the source.
        s.setEventHandler { s.cancel(); block() }
        s.resume()
        return Timer(s)
    }

    func every(_ ns: UInt64, _ block: @escaping () -> Void) -> SinkTimer {
        let s = DispatchSource.makeTimerSource(queue: queue)
        let leeway = max(ns / 10, 100_000)
        s.schedule(deadline: .now() + .nanoseconds(Int(ns)), repeating: .nanoseconds(Int(ns)), leeway: .nanoseconds(Int(leeway)))
        s.setEventHandler(handler: block)
        s.resume()
        return Timer(s)
    }
}

// MARK: - Duplicate-pad guard

/// Finds another HID device with the identity's VID:PID (design §5.4 step 8). A real Xbox controller (02E0), another
/// virtual driver, or a leftover of ours with a different serial would give hosts two controllers.
enum DuplicatePadGuard {
    /// Description of the first `IOHIDDevice` with this vendor and product whose serial is not `ownSerial`; nil if none.
    static func conflict(vendorID: UInt32, productID: UInt32, ownSerial: String = PadIdentity.serial) -> String? {
        let dict = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
        dict["VendorID"] = Int(vendorID)
        dict["ProductID"] = Int(productID)
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dict, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            func prop(_ key: String) -> String? {
                IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            }
            let serial = prop("SerialNumber")
            if serial == ownSerial { continue }
            let product = prop("Product") ?? "HID device"
            return "\(product)\(serial.map { " (serial \($0))" } ?? "")"
        }
        return nil
    }
}

// MARK: - Sink

/// Turns pad states into dext reports (design §5.4). Confined to `queue` (the app's `vhidQueue`); the only entry
/// point that may be called from any thread is `submit(frame:mapping:)`.
///
/// Delivery policy
/// - Send on change only: a state that equals the last sent one within the deadbands posts nothing.
/// - At most `maxRateHz` flushes per second. A state arriving inside the interval is coalesced and delivered by a
///   trailing flush, so the last state always goes out.
/// - A 500 ms heartbeat feeds the dext watchdog while the pad exists (the watchdog neutralises the pad after 2 s of
///   silence, and at rest nothing is posted).
/// - If the heartbeat timer fires much later than due, the process was stalled and the watchdog may have neutralised
///   the pad behind our back: the next state is re-sent in full.
final class VirtualPadSink: @unchecked Sendable {
    struct Config {
        var maxRateHz = 250.0
        var axisDeadband = 0.002
        var triggerDeadband = 0.002
        var heartbeatMs = 500
    }

    /// `UserDefaults` key for the runtime rate cap (Hz), read when the sink is built.
    static let maxRateKey = "vpadMaxRateHz"
    static let runtimeDefaultRateHz = 1000.0

    /// The cap GDHub runs with: `vpadMaxRateHz` clamped to 60…1000, 1000 when unset or not a finite number.
    /// `Config()` itself stays at 250 Hz so the unit tests keep their meaning.
    static func runtimeMaxRateHz(defaults: UserDefaults = .standard) -> Double {
        guard let v = (defaults.object(forKey: maxRateKey) as? NSNumber)?.doubleValue, v.isFinite else { return runtimeDefaultRateHz }
        return min(max(v, 60), 1000)
    }

    /// Queue-confined counters, read by the Driver menu's status poller.
    struct Stats: Equatable {
        var statesChanged = 0       // states that passed the deadband test
        var flushes = 0             // flushes that posted at least one report
        var posts = 0               // reports posted to the transport
    }

    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
    static let identitySwitchGap: UInt64 = 300_000_000          // ns
    static let recreateDelay: UInt64 = 1_000_000_000            // ns, after a lost device
    static let enabledKey = "vhid.pad.enabled"
    static let identityKey = "vhid.pad.identity"
    private static let slot = DextProtocol.Slot.pad.rawValue

    private let queue: DispatchQueue
    private let transport: PadTransport
    private let defaults: UserDefaults
    private let clock: () -> UInt64
    private let scheduler: SinkScheduler
    private let config: Config
    private let duplicateCheck: (PadIdentity) -> String?
    /// Latency meter (plan §3); written on `queue`, read by the status poller on `queue`.
    let meter: LatencyMeter

    var onPadState: ((PadPublishState) -> Void)?       // called on queue
    var onTestPattern: ((Bool) -> Void)?               // called on queue; true while the pattern runs
    private(set) var state: PadPublishState = .off
    private(set) var stats = Stats()

    private var desired: PadIdentity?
    private var connected = false
    private var created = false                         // a device exists in the dext for `createdIdentity`
    private var createdIdentity: PadIdentity?
    private var generation = 0                          // invalidates delayed create/retry closures

    // Frame mailbox (any thread). Controller frames arrive at ~1 kHz, mostly identical at rest; identical frames are
    // dropped before they cost a queue hop, and a busy queue only ever processes the newest frame.
    private struct Mailbox {
        var slot: (frame: GamepadFrame, mapping: ControlMapping)?
        var tK: UInt64 = 0, tC: UInt64 = 0          // oldest stamp since the last drain; valid while `slot` is set
        var last: (frame: GamepadFrame, revision: Int)?
        var drainScheduled = false
        var received = 0
    }
    private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())

    // Delivery state
    private var pending: PadState?
    private var pendingStamp: LatencyStamp?             // oldest input behind `pending`
    private var lastSentState: PadState?                // nil: unknown, the next state is sent whatever it is
    private var lastSentBytes: [UInt8: [UInt8]] = [:]
    private var lastPostAt: UInt64?
    private var flushTimer: SinkTimer?
    private var heartbeatTimer: SinkTimer?
    private var lastHeartbeatTickAt: UInt64 = 0
    private var lastPostErrorLogAt: UInt64 = 0

    // Test pattern
    private var patternTimer: SinkTimer?
    private var patternStartNs: UInt64 = 0
    private var patternLoop = false

    static func realClock() -> UInt64 { LatencyMeter.nowNs() }

    init(queue: DispatchQueue, transport: PadTransport,
         clock: @escaping () -> UInt64 = VirtualPadSink.realClock,
         scheduler: SinkScheduler? = nil,
         config: Config = Config(),
         defaults: UserDefaults = .standard,
         duplicateCheck: ((PadIdentity) -> String?)? = nil) {
        self.queue = queue
        self.transport = transport
        self.clock = clock
        self.scheduler = scheduler ?? DispatchSinkScheduler(queue: queue)
        self.config = config
        self.defaults = defaults
        self.meter = LatencyMeter(clock: clock)
        self.duplicateCheck = duplicateCheck ?? { id in
            DuplicatePadGuard.conflict(vendorID: id.vendorID, productID: id.productID, ownSerial: id.serialNumber)
        }
    }

    var isPatternRunning: Bool { patternTimer != nil }
    var isPublished: Bool { created }

    private var intervalNs: UInt64 { UInt64(1e9 / max(config.maxRateHz, 1)) }

    // MARK: Publish / unpublish

    /// Design §5.4 `setEnabled`: publish `identity` (or switch to it), or unpublish.
    func setEnabled(_ on: Bool, identity: PadIdentity, persist: Bool = true) {
        if on { publish(identity, persist: persist) } else { unpublish(persist: persist) }
    }

    /// Publishes `identity`, or switches to it (destroy, 300 ms gap, create). Waits for the connection if needed.
    func publish(_ identity: PadIdentity, persist: Bool = true) {
        dispatchPrecondition(condition: .onQueue(queue))
        if persist {
            defaults.set(true, forKey: Self.enabledKey)
            defaults.set(identity.id, forKey: Self.identityKey)
        }
        desired = identity
        generation += 1
        if created, createdIdentity != identity {
            stopPattern()
            destroyCurrent()
            setState(.publishing(identity.id))
            let gen = generation
            scheduler.after(Self.identitySwitchGap) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.createIfWanted()
            }
            return
        }
        if created { setState(.published(identity.id)); return }
        setState(.publishing(identity.id))
        createIfWanted()
    }

    func unpublish(persist: Bool = true) {
        dispatchPrecondition(condition: .onQueue(queue))
        if persist { defaults.set(false, forKey: Self.enabledKey) }
        desired = nil
        generation += 1
        stopPattern()
        if created { _ = transport.postNeutral(slot: Self.slot) }
        destroyCurrent()
        setState(.off)
    }

    /// Called when the dext connection (re)appears. Restores a persisted or requested publication; the device is
    /// created again from `desired` after a dext restart or reconnect.
    func transportConnected() {
        dispatchPrecondition(condition: .onQueue(queue))
        connected = true
        resetDeliveryState()
        created = false; createdIdentity = nil          // a new connection starts with no devices
        if desired == nil, defaults.bool(forKey: Self.enabledKey) {
            desired = PadIdentity.named(defaults.string(forKey: Self.identityKey) ?? "") ?? .default
        }
        if let d = desired { setState(.publishing(d.id)); createIfWanted() }
    }

    /// Called when the connection is gone: the dext destroyed our devices with the user client.
    func transportLost() {
        dispatchPrecondition(condition: .onQueue(queue))
        connected = false
        created = false; createdIdentity = nil
        generation += 1
        stopPattern()
        resetDeliveryState()
        if let d = desired { setState(.publishing(d.id)) }
    }

    func shutdown() {
        dispatchPrecondition(condition: .onQueue(queue))
        unpublish(persist: false)
    }

    private func createIfWanted() {
        guard connected, !created, let id = desired else { return }
        if let other = duplicateCheck(id) {
            Self.log.error("not publishing \(id.id, privacy: .public): another device has \(String(id.vendorID, radix: 16), privacy: .public):\(String(id.productID, radix: 16), privacy: .public): \(other, privacy: .public)")
            setState(.blockedDuplicate(other))
            return
        }
        do {
            let spec = try id.spec()
            let kr = transport.createDevice(spec)
            guard kr == KERN_SUCCESS else {
                let e = DextError(kr)
                Self.log.error("createDevice \(id.id, privacy: .public) failed: \(e.description, privacy: .public)")
                setState(.error("\(id.id): \(e.description)"))
                return
            }
            created = true; createdIdentity = id
            resetDeliveryState()
            _ = transport.postNeutral(slot: Self.slot)
            lastSentState = .neutral
            lastSentBytes = neutralBytes(id)
            startHeartbeat()
            Self.log.info("published \(id.id, privacy: .public)")
            setState(.published(id.id))
        } catch {
            Self.log.error("spec for \(id.id, privacy: .public) invalid: \(String(describing: error), privacy: .public)")
            setState(.error("\(id.id): \(error)"))
        }
    }

    private func destroyCurrent() {
        if created { _ = transport.destroyDevice(slot: Self.slot) }
        created = false; createdIdentity = nil
        resetDeliveryState()
    }

    /// Forgets everything about what was sent and stops the timers tied to a device.
    private func resetDeliveryState() {
        mailbox.withLock { $0.last = nil }          // frames dropped while no device existed must not hide a held state
        pending = nil
        pendingStamp = nil
        lastSentState = nil
        lastSentBytes = [:]
        lastPostAt = nil
        flushTimer?.cancel(); flushTimer = nil
        stopHeartbeat()
    }

    private func neutralBytes(_ id: PadIdentity) -> [UInt8: [UInt8]] {
        Dictionary(uniqueKeysWithValues: id.reports(for: .neutral).map { ($0.id, $0.bytes) })
    }

    private func setState(_ s: PadPublishState) {
        guard s != state else { return }
        state = s
        onPadState?(s)
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        lastHeartbeatTickAt = clock()
        let interval = UInt64(config.heartbeatMs) * 1_000_000
        heartbeatTimer = scheduler.every(interval) { [weak self] in self?.heartbeatTick(interval: interval) }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel(); heartbeatTimer = nil
    }

    private func heartbeatTick(interval: UInt64) {
        guard created else { return }
        let now = clock()
        if lastHeartbeatTickAt != 0, now &- lastHeartbeatTickAt > interval * 3 {
            // The process was stalled (SIGSTOP, debugger, heavy load): the dext watchdog may have neutralised the pad
            // while the sink still believes the last state is on it. Send the next state in full.
            Self.log.info("heartbeat gap \((now &- self.lastHeartbeatTickAt) / 1_000_000) ms: re-sending state")
            lastSentState = nil
            lastSentBytes = [:]
            mailbox.withLock { $0.last = nil }          // identical controller frames must reach the sink again
        }
        lastHeartbeatTickAt = now
        let kr = transport.heartbeat()
        if kr == DextProtocol.krNotReady || kr == DextProtocol.krNotPermitted { deviceLost(kr: kr) }
    }

    // MARK: Posting

    /// Number of controller frames handed to `submit(frame:mapping:revision:)`, including dropped duplicates.
    var framesReceived: Int { mailbox.withLock { $0.received } }

    /// Frame entry point. Callable from any thread; the work happens on the sink's queue. `revision` identifies the
    /// mapping: bump it whenever the mapping changes, because a frame equal to the previous one is dropped only while
    /// the revision is unchanged too.
    ///
    /// `tK` / `tC` are the report's kernel timestamp and the HID callback's entry time (nanoseconds, `LatencyMeter.nowNs`
    /// timeline; 0 = unknown). Frames coalesced before a drain keep the oldest pair.
    func submit(frame: GamepadFrame, mapping: ControlMapping, revision: Int = 0, tK: UInt64 = 0, tC: UInt64 = 0) {
        let schedule: Bool = mailbox.withLock { m in
            m.received += 1
            if let l = m.last, l.frame == frame, l.revision == revision { return false }
            m.last = (frame, revision)
            if m.slot == nil { m.tK = tK; m.tC = tC }
            m.slot = (frame, mapping)
            if m.drainScheduled { return false }
            m.drainScheduled = true
            return true
        }
        if schedule { queue.async { [self] in drainMailbox() } }
    }

    private func drainMailbox() {
        let tD = clock()
        let item = mailbox.withLock { m -> (frame: GamepadFrame, mapping: ControlMapping, tK: UInt64, tC: UInt64)? in
            m.drainScheduled = false
            defer { m.slot = nil }
            guard let s = m.slot else { return nil }
            return (s.frame, s.mapping, m.tK, m.tC)
        }
        if let item {
            // Unstamped frames (tests, anything not from the timestamped HID callback) count from the drain.
            let stamp = LatencyStamp(tK: item.tK == 0 ? tD : item.tK, tC: item.tC == 0 ? tD : item.tC, tD: tD)
            handle(frame: item.frame, mapping: item.mapping, stamp: stamp)
        }
    }

    /// Queue-confined body of the frame path. While the test pattern runs, frames are ignored.
    func handle(frame: GamepadFrame, mapping: ControlMapping, stamp: LatencyStamp? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard created, !isPatternRunning else { return }
        submit(state: PassthroughPadMapper.padState(frame, mapping), stamp: stamp)
    }

    /// Delivers `state` subject to the deadband, the rate cap and send-on-change.
    func submit(state raw: PadState, stamp: LatencyStamp? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard created, createdIdentity != nil else { return }
        let s = snapped(raw)
        if let last = lastSentState, unchanged(s, last) {
            // Back to what the host already has: drop whatever was waiting for the trailing flush.
            pending = nil
            pendingStamp = nil
            flushTimer?.cancel(); flushTimer = nil
            return
        }
        stats.statesChanged += 1
        let now = clock()
        meter.noteChanged()
        if pending != nil { meter.noteCoalesced() }
        pending = s
        // A coalesced state is attributed to the oldest input still waiting. Unstamped states (test pattern, tests)
        // count from now.
        if pendingStamp == nil { pendingStamp = stamp ?? LatencyStamp(tK: now, tC: now, tD: now) }
        if let last = lastPostAt, now < last &+ intervalNs {
            if flushTimer == nil {
                let due = last &+ intervalNs
                flushTimer = scheduler.after(due &- now, strict: true) { [weak self] in self?.flushTimerFired() }
            }
            return
        }
        flush()
    }

    private func flushTimerFired() {
        flushTimer = nil
        // Never post early: if the timer fired before the interval elapsed, wait out the remainder.
        let now = clock()
        if let last = lastPostAt, now < last &+ intervalNs, pending != nil {
            flushTimer = scheduler.after(last &+ intervalNs &- now, strict: true) { [weak self] in self?.flushTimerFired() }
            return
        }
        flush()
    }

    /// Posts the reports of `pending` whose bytes changed.
    private func flush() {
        guard let s = pending, created, let id = createdIdentity else { return }
        pending = nil
        let stamp = pendingStamp
        pendingStamp = nil
        flushTimer?.cancel(); flushTimer = nil
        let tS = clock()
        var posted = false
        for r in id.reports(for: s) where lastSentBytes[r.id] != r.bytes {
            let kr = transport.post(slot: Self.slot, report: r.bytes)
            guard kr == KERN_SUCCESS else {
                postFailed(kr, reportID: r.id)
                return
            }
            lastSentBytes[r.id] = r.bytes
            stats.posts += 1
            posted = true
        }
        lastSentState = s
        if posted {
            let tR = clock()
            lastPostAt = tR
            stats.flushes += 1
            if let stamp { meter.record(tK: stamp.tK, tC: stamp.tC, tD: stamp.tD, tS: tS, tR: tR) }
        }
    }

    private func postFailed(_ kr: kern_return_t, reportID: UInt8) {
        let now = clock()
        if now &- lastPostErrorLogAt > 1_000_000_000 {          // at most one line per second
            lastPostErrorLogAt = now
            Self.log.error("post 0x\(String(reportID, radix: 16), privacy: .public) failed: \(DextError(kr).description, privacy: .public)")
        }
        if kr == DextProtocol.krNotReady || kr == DextProtocol.krNotPermitted { deviceLost(kr: kr) }
    }

    /// The device is gone: mark it unpublished and re-create it once after 1 s (design §5.4 step 5).
    private func deviceLost(kr: kern_return_t) {
        guard created, let id = createdIdentity else { return }
        stopPattern()
        created = false; createdIdentity = nil
        resetDeliveryState()
        generation += 1
        setState(.publishing(id.id))
        let gen = generation
        scheduler.after(Self.recreateDelay) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.createIfWanted()
        }
    }

    /// Neutral pad now: used when the controller sleeps or disconnects, on system sleep, on app termination and when
    /// the test pattern stops. Anything waiting for a trailing flush is discarded.
    func neutral() {
        dispatchPrecondition(condition: .onQueue(queue))
        mailbox.withLock { $0.last = nil }          // the next frame must be processed even if it equals the last
        pending = nil
        pendingStamp = nil
        flushTimer?.cancel(); flushTimer = nil
        guard created, let id = createdIdentity else { return }
        _ = transport.postNeutral(slot: Self.slot)
        lastSentState = .neutral
        lastSentBytes = neutralBytes(id)
    }

    // MARK: Quantisation

    private func snapped(_ s: PadState) -> PadState {
        var s = s
        func ax(_ v: Double) -> Double { abs(v) < config.axisDeadband ? 0 : v }
        func tr(_ v: Double) -> Double { v < config.triggerDeadband ? 0 : v }
        s.lx = ax(s.lx); s.ly = ax(s.ly); s.rx = ax(s.rx); s.ry = ax(s.ry)
        s.lt = tr(s.lt); s.rt = tr(s.rt)
        return s
    }

    /// True when `s` would not change what the host sees. Moves onto an end stop (±1, trigger 1) always count, so a
    /// full deflection is never left one deadband short; moves back to 0 count because `snapped` makes the
    /// difference at least one deadband.
    private func unchanged(_ s: PadState, _ last: PadState) -> Bool {
        func same(_ a: Double, _ b: Double, _ db: Double) -> Bool {
            if a == b { return true }
            if abs(a) >= 1 { return false }
            return abs(a - b) < db
        }
        let ad = config.axisDeadband, td = config.triggerDeadband
        return s.buttons == last.buttons
            && same(s.lx, last.lx, ad) && same(s.ly, last.ly, ad)
            && same(s.rx, last.rx, ad) && same(s.ry, last.ry, ad)
            && same(s.lt, last.lt, td) && same(s.rt, last.rt, td)
    }

    // MARK: Test pattern

    /// Pattern segments in order: each button 300 ms (A B X Y LB RB View Menu LS RS Guide), D-pad N E S W 250 ms,
    /// LT ramp, RT ramp, left-stick circle, right-stick circle, then neutral.
    private static let buttonOrder: [PadButtons] = [.a, .b, .x, .y, .lb, .rb, .view, .menu, .ls, .rs, .guide]
    private static let dpadOrder: [PadButtons] = [.dpadUp, .dpadRight, .dpadDown, .dpadLeft]
    private static let buttonMs = 300, dpadMs = 250, rampMs = 700, circleMs = 1000

    static var testPatternDurationMs: Int {
        buttonOrder.count * buttonMs + dpadOrder.count * dpadMs + 2 * rampMs + 2 * circleMs
    }

    /// The pad state `ms` milliseconds into the pattern; nil once it has finished.
    static func testPatternState(atMs ms: Int) -> PadState? {
        guard ms >= 0, ms < testPatternDurationMs else { return nil }
        var t = ms
        var s = PadState()
        if t < buttonOrder.count * buttonMs { s.buttons = buttonOrder[t / buttonMs]; return s }
        t -= buttonOrder.count * buttonMs
        if t < dpadOrder.count * dpadMs { s.buttons = dpadOrder[t / dpadMs]; return s }
        t -= dpadOrder.count * dpadMs
        if t < rampMs { s.lt = Double(t) / Double(rampMs - 1); return s }
        t -= rampMs
        if t < rampMs { s.rt = Double(t) / Double(rampMs - 1); return s }
        t -= rampMs
        let angle = 2 * Double.pi * Double(t % circleMs) / Double(circleMs)
        if t < circleMs { s.lx = cos(angle); s.ly = sin(angle); return s }
        s.rx = cos(angle); s.ry = sin(angle)
        return s
    }

    /// Feeds the pattern at 100 Hz. `loop` repeats it with a 3 s pause until stopped. Neutral on stop.
    func runTestPattern(loop: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard created, patternTimer == nil else { return }
        patternLoop = loop
        patternStartNs = clock()
        patternTimer = scheduler.every(10_000_000) { [weak self] in self?.patternTick() }
        Self.log.info("test pattern started (\(Self.testPatternDurationMs) ms, loop=\(loop))")
        onTestPattern?(true)
    }

    func stopTestPattern() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopPattern()
    }

    private func patternTick() {
        let elapsed = Int((clock() &- patternStartNs) / 1_000_000)
        if patternLoop {
            let e = elapsed % (Self.testPatternDurationMs + 3000)      // 3 s of neutral between loops
            submit(state: Self.testPatternState(atMs: e) ?? .neutral)
        } else if let s = Self.testPatternState(atMs: elapsed) {
            submit(state: s)
        } else {
            stopPattern()
        }
    }

    private func stopPattern() {
        guard let t = patternTimer else { return }
        t.cancel()
        patternTimer = nil
        neutral()
        Self.log.info("test pattern stopped")
        onTestPattern?(false)
    }
}

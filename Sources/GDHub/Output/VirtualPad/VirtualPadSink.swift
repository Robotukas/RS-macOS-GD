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
    case error(String)
}

/// Minimal D3 sink (design §5.4): publish / unpublish and the test pattern. Confined to `queue` (the app's
/// `vhidQueue`). Send-on-change, deadbands, the rate cap and the duplicate check arrive in D4. The dext connection's
/// own 500 ms heartbeat keeps the watchdog fed, so the sink sends none.
final class VirtualPadSink: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
    static let identitySwitchGap: DispatchTimeInterval = .milliseconds(300)
    static let enabledKey = "vhid.pad.enabled"
    static let identityKey = "vhid.pad.identity"

    private let queue: DispatchQueue
    private let transport: PadTransport
    private let defaults: UserDefaults

    var onPadState: ((PadPublishState) -> Void)?       // called on queue
    var onTestPattern: ((Bool) -> Void)?               // called on queue; true while the pattern runs
    private(set) var state: PadPublishState = .off

    private var desired: PadIdentity?
    private var connected = false
    private var created = false                         // a device exists in the dext for `createdIdentity`
    private var createdIdentity: PadIdentity?
    private var lastSent: [UInt8: [UInt8]] = [:]
    private var patternTimer: DispatchSourceTimer?
    private var patternStart: DispatchTime = .now()
    private var patternLoop = false
    private var generation = 0                          // invalidates delayed create/retry closures

    init(queue: DispatchQueue, transport: PadTransport, defaults: UserDefaults = .standard) {
        self.queue = queue
        self.transport = transport
        self.defaults = defaults
    }

    var isPatternRunning: Bool { patternTimer != nil }

    // MARK: Publish / unpublish

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
            queue.asyncAfter(deadline: .now() + Self.identitySwitchGap) { [weak self] in
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
        if created { _ = transport.postNeutral(slot: DextProtocol.Slot.pad.rawValue); destroyCurrent() }
        setState(.off)
    }

    /// Called when the dext connection (re)appears. Restores a persisted or requested publication.
    func transportConnected() {
        dispatchPrecondition(condition: .onQueue(queue))
        connected = true
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
        if let d = desired { setState(.publishing(d.id)) }
    }

    func shutdown() {
        dispatchPrecondition(condition: .onQueue(queue))
        unpublish(persist: false)
    }

    private func createIfWanted() {
        guard connected, !created, let id = desired else { return }
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
            lastSent = [:]
            _ = transport.postNeutral(slot: DextProtocol.Slot.pad.rawValue)
            Self.log.info("published \(id.id, privacy: .public)")
            setState(.published(id.id))
        } catch {
            Self.log.error("spec for \(id.id, privacy: .public) invalid: \(String(describing: error), privacy: .public)")
            setState(.error("\(id.id): \(error)"))
        }
    }

    private func destroyCurrent() {
        if created { _ = transport.destroyDevice(slot: DextProtocol.Slot.pad.rawValue) }
        created = false; createdIdentity = nil; lastSent = [:]
    }

    private func setState(_ s: PadPublishState) {
        guard s != state else { return }
        state = s
        onPadState?(s)
    }

    // MARK: Posting

    /// Posts the reports of `state` that changed since the last post.
    func submit(state s: PadState) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard created, let id = createdIdentity else { return }
        for r in id.reports(for: s) where lastSent[r.id] != r.bytes {
            let kr = transport.post(slot: DextProtocol.Slot.pad.rawValue, report: r.bytes)
            if kr == KERN_SUCCESS { lastSent[r.id] = r.bytes; continue }
            Self.log.error("post 0x\(String(r.id, radix: 16), privacy: .public) failed: \(DextError(kr).description, privacy: .public)")
            if kr == DextProtocol.krNotReady || kr == DextProtocol.krNotPermitted {
                // The device is gone: mark it unpublished and re-create it once after 1 s (design §5.4 step 5).
                stopPattern()
                created = false; createdIdentity = nil
                setState(.publishing(id.id))
                let gen = generation
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.createIfWanted()
                }
            }
            return
        }
    }

    func neutral() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard created else { return }
        _ = transport.postNeutral(slot: DextProtocol.Slot.pad.rawValue)
        if let id = createdIdentity {
            lastSent = Dictionary(uniqueKeysWithValues: id.reports(for: .neutral).map { ($0.id, $0.bytes) })
        }
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
        patternStart = .now()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.patternTick() }
        patternTimer = t
        t.resume()
        Self.log.info("test pattern started (\(Self.testPatternDurationMs) ms, loop=\(loop))")
        onTestPattern?(true)
    }

    func stopTestPattern() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopPattern()
    }

    private func patternTick() {
        let elapsed = Int(Double(DispatchTime.now().uptimeNanoseconds &- patternStart.uptimeNanoseconds) / 1_000_000)
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

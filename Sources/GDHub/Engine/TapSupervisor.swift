import Foundation
import os
#if canImport(GDHubXlate)
import GDHubXlate
#endif

/// Interface-up to tap-present timing (T4): from the engine's "controller interface up" to the first status2 that shows a
/// tap attached, abandoned after `limitNs`. Its p99 sets the grace period of the later "tap absent" fallback (plan F2).
/// Pure; the clock is injected.
struct TapAttachTiming {
    static let limitNs: UInt64 = 5_000_000_000

    private(set) var upAtNs: UInt64?
    private(set) var samplesMs: [Double] = []
    private(set) var gaveUp = 0

    mutating func interfaceUp(atNs ns: UInt64) { upAtNs = ns }
    mutating func interfaceDown() { upAtNs = nil }
    var isWaiting: Bool { upAtNs != nil }

    /// Feed one status2 reading. Returns the elapsed milliseconds when this reading is the first one with a tap attached
    /// since the interface came up.
    mutating func observe(tapPresent: Bool, atNs ns: UInt64) -> Double? {
        guard let up = upAtNs, tapPresent else { return nil }
        upAtNs = nil
        let ms = Double(ns &- up) / 1e6
        samplesMs.append(ms)
        return ms
    }

    /// True once, when the wait has lasted longer than `limitNs` (the tap never came: an old dext, a decline build, or Apple's
    /// driver is still on the interface). The wait then ends, so status2 is no longer read for it.
    mutating func expire(atNs ns: UInt64) -> Bool {
        guard let up = upAtNs, ns &- up > Self.limitNs else { return false }
        upAtNs = nil
        gaveUp += 1
        return true
    }

    /// Nearest-rank percentile of the recorded samples (0 when there are none).
    func percentileMs(_ p: Double) -> Double {
        guard !samplesMs.isEmpty else { return 0 }
        let sorted = samplesMs.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// What the engine can offer the dext as a mapping right now (T5).
enum MappingOffer {
    case none                                   // no pad exists yet: nothing to target
    case unsupported(String)                    // the mapping needs more than GDHM v1 (the engine path stays)
    case blob([UInt8], spec: [UInt8])           // a GDHM blob for the given revision, and the spec of the pad it targets
}

/// T4 TapSupervisor: applies `inputPath` to the dext and measures how long the tap takes to attach. It does NOT fall back,
/// translate or re-arm after a relaunch (fallbacks arrive with T6/T7). Confined to `queue` (the engine's `vhidQueue`).
///
/// **SHADOW (T5).** `inputPath = shadow` arms SHADOW through the same rules (owner-only on the dext side, nonce trip, 2 Hz status
/// read instead of 1 Hz). While SHADOW is armed the supervisor pushes the GDHM blob: after hello, after the pad is created (the
/// spec CRC the blob targets must match the live pad), and on every mapping change; a dext that lost the mapping (pad
/// recreated, owner change) is detected from status2 and gets it again. A 2 Hz parity sampler compares the dext's last
/// translated frame with the engine's own C core for the frame with the same kernel timestamp. SHADOW never posts.
///
/// **Arming and the trip.** `count` sends COUNT after hello; everything else sends INERT. The dext's `instanceNonce` of the
/// instance on which COUNT was accepted is remembered. If any later hello or status2 shows a different nonce, the dext was
/// relaunched or replaced; the supervisor then does NOT arm again (a crash anywhere in the COUNT path would otherwise
/// become a crash loop at the reconnect back-off). It stays INERT, logs one line, and the trip clears only when
///   - the stored `inputPath` value changes (any change of the stored value, including a different spelling such as `Count`,
///     or `engine` and then `count` again; `UserDefaults` cannot show that the identical value was written again), or
///   - the engine restarts (U7 does that after every driver upgrade).
/// A re-enumeration inside the same dext process (controller off/on, Mac wake) keeps the nonce: the new tap instance finds
/// COUNT still asked for and no engine action is needed.
///
/// **Cost.** `inputPath` is read once per second (A20). status2 is read: never while INERT and settled; once per second while
/// armed (nonce check and the tap fields); every 100 ms for at most 5 s after the controller interface comes up, and only if
/// the dext has a tap (the attach timing).
final class TapSupervisor: @unchecked Sendable {
    static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")
    static let tickMs = 100
    static let defaultsEveryTicks = 10
    static let statusEveryTicks = 10
    static let shadowEveryTicks = 5

    private let queue: DispatchQueue
    private let dext: TapControlling
    private let readDefault: () -> Any?
    private let clock: () -> UInt64
    private var timer: DispatchSourceTimer?
    private var connected = false
    private var tick = 0
    private var path = InputPath.engine
    private var rawPath = ""                    // the stored value as text, to see that it changed
    private var sent: UInt64?                   // the forwarding state last sent on this connection
    private var sentAccepted = false            // the dext answered success for it (an Unsupported answer ends the asking but proves nothing)
    private var connNonce: UInt64?              // instance nonce read on this connection
    private var armedNonce: UInt64?             // nonce of the dext instance on which COUNT was accepted
    private(set) var tripped = false
    private var trippedRaw = ""
    private var interfaceUpAtNs: UInt64?
    private var loggedUnsupportedPath = false
    // T5
    /// Set by the engine once its core and sink exist (it needs them); `.none` until then.
    var mappingOffer: (UInt32) -> MappingOffer
    let parity: ParitySampler
    private var mappingDirty = true
    private var lastRevision: UInt32 = 0
    private(set) var pushedRevision: UInt32?
    private var pushCore: XlateCore?
    private var loggedMappingNote: String?
    private var lastPushFailedNs: UInt64 = 0
    private var pushFailures = 0                // consecutive transient failures of this generation: the retry backs off 0.5, 1, 2, 4, 5 s
    /// Bumped by everything that makes the last answer obsolete: a mapping change, a new pad (both arrive as `invalidateMapping`)
    /// and a new connection. A refusal is final for the generation it was given in.
    private var mappingGeneration = 0
    private var settledGeneration = -1          // the generation in which the driver (or the encoder) definitely said no
    private var loggedShadowRefusal = false
    private(set) var pushes = 0
    private var loggedPidMismatch = false
    private(set) var timing = TapAttachTiming()
    private(set) var lastStatus: DextStatus2?
    private(set) var status2Reads = 0           // for tests and the cost statement above

    init(queue: DispatchQueue, dext: TapControlling,
         readDefault: @escaping () -> Any? = { UserDefaults.standard.object(forKey: InputPath.defaultsKey) },
         clock: @escaping () -> UInt64 = LatencyMeter.nowNs,
         mappingOffer: @escaping (UInt32) -> MappingOffer = { _ in .none },
         parity: ParitySampler? = nil) {
        self.queue = queue
        self.dext = dext
        self.mappingOffer = mappingOffer
        self.parity = parity ?? ParitySampler(clock: clock, log: { TapSupervisor.log.error("\($0, privacy: .public)") })
        self.readDefault = readDefault
        self.clock = clock
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(Self.tickMs), repeating: .milliseconds(Self.tickMs), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        timer = t
    }

    /// Clean exit: leave the dext INERT, then stop. (The dext also returns to INERT by itself when the connection closes.)
    func shutdown() {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel(); timer = nil
        if connected, sent != DextProtocol.Forwarding.inert { _ = dext.setForwarding(DextProtocol.Forwarding.inert) }
        sent = nil
    }

    /// The dext connection came up (after hello) or went away. A new connection always gets the state decided again, and the
    /// instance nonce is read first: a different nonce than the one COUNT was accepted on trips the supervisor.
    func connection(up: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        connected = up
        sent = nil
        sentAccepted = false
        connNonce = nil
        lastStatus = nil
        pushedRevision = nil; pushCore = nil; mappingDirty = true; parity.ring.enabled = false; lastPushFailedNs = 0; pushFailures = 0
        mappingGeneration += 1; settledGeneration = -1
        guard up else { return }
        refreshPath()
        if let s = readStatus() { observe(s) }
        startTimingIfEligible()
        apply()
        pushMappingIfNeeded()                                  // right after hello (and the SHADOW request): no waiting for a tick
    }

    /// The mapping changed, or the pad was (re)created: the dext needs the blob again.
    func invalidateMapping() {
        dispatchPrecondition(condition: .onQueue(queue))
        mappingDirty = true
        mappingGeneration += 1; pushFailures = 0; lastPushFailedNs = 0
        pushMappingIfNeeded()                                  // a learn edit reaches the dext at once, not at the next 2 Hz read
    }

    /// The tap part of the engine's meter line (SHADOW): what the dext translated and how the parity check is going.
    var shadowText: String? {
        guard path == .shadow || parity.stats != ParitySampler.Stats() else { return nil }
        return parity.stats.text + (pushedRevision.map { " rev=\($0)" } ?? "")
    }

    func controllerInterface(up: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        if up { interfaceUpAtNs = clock(); timingPending = true } else { interfaceUpAtNs = nil; timingPending = false; timing.interfaceDown() }
        startTimingIfEligible()
    }

    /// The attach timing needs a dext with a tap and a connection; otherwise nothing would ever answer it, so it does not start.
    private var timingPending = false
    private func startTimingIfEligible() {
        guard timingPending, connected, dext.hasTap, let up = interfaceUpAtNs else { return }
        timingPending = false
        timing.interfaceUp(atNs: up)
    }

    func onTick() {
        dispatchPrecondition(condition: .onQueue(queue))
        tick += 1
        if tick % Self.defaultsEveryTicks == 0 { refreshPath() }
        guard connected else { return }
        apply()
        let armed = armedNonce != nil
        let timingWindow = timing.isWaiting
        let shadow = sent == DextProtocol.Forwarding.shadow && sentAccepted && !tripped
        // selector 11 per second: INERT settled 0, COUNT 1, SHADOW 2 (every 5th tick), 10 only in the attach timing window.
        let shadowDue = shadow && tick % Self.shadowEveryTicks == 0
        guard timingWindow || shadowDue || (armed && !shadow && tick % Self.statusEveryTicks == 0) else { return }
        guard let s = readStatus() else { return }
        observe(s)
        if shadow, !tripped { shadowStep(s) }
        if timingWindow {
            if let ms = timing.observe(tapPresent: s.tapPresent, atNs: clock()) {
                Self.log.notice("tap: attached \(Int(ms.rounded())) ms after the controller interface came up (n=\(self.timing.samplesMs.count) p99=\(Int(self.timing.percentileMs(99).rounded())) ms)")
            } else if timing.expire(atNs: clock()) {
                Self.log.notice("tap: not present 5 s after the controller interface came up")
            }
        }
        if s.tapPresent, s.tapPid != 0, s.tapPid != s.rootPid, !loggedPidMismatch {
            loggedPidMismatch = true
            Self.log.error("tap: runs in pid \(s.tapPid) but the root runs in pid \(s.rootPid): the services are not in one process")
        }
    }

    private func readStatus() -> DextStatus2? {
        status2Reads += 1
        let s = dext.status2()
        if let s { lastStatus = s }
        return s
    }

    /// SHADOW bookkeeping from one status2 reading: the dext lost the mapping? push again. A parity record? compare it.
    private func shadowStep(_ s: DextStatus2) {
        // The driver lost the mapping (pad recreated, owner changed)? Offer it again. Not after a refusal of this very mapping.
        if settledGeneration != mappingGeneration,
           s.acceptedRevision == 0 || (pushedRevision != nil && s.acceptedRevision != pushedRevision!) { mappingDirty = true }
        pushMappingIfNeeded()
        if let rec = s.parity, let core = pushCore, let rev = pushedRevision, s.hasMap { parity.sample(rec, core: core, revision: rev) }
    }

    private func pushMappingIfNeeded() {
        guard mappingDirty, connected, dext.hasXlate, !tripped, sent == DextProtocol.Forwarding.shadow, sentAccepted else { return }
        let now = clock()
        let backoffNs = min(UInt64(500_000_000) << UInt64(max(pushFailures - 1, 0)), 5_000_000_000)
        guard lastPushFailedNs == 0 || now &- lastPushFailedNs >= backoffNs else { return }
        let rev = lastRevision &+ 1
        switch mappingOffer(rev) {
        case .none:
            return                                                       // no pad yet: asked again at the next tick
        case .unsupported(let why):
            mappingDirty = false; settledGeneration = mappingGeneration       // not encoded again until the mapping changes
            pushedRevision = nil; pushCore = nil; parity.ring.enabled = false
            note("SHADOW: the mapping needs more than GDHM v1 (\(why)); nothing is pushed, the tap counts only")
        case .blob(let blob, let spec):
            let r = dext.setMapping(blob)
            guard r.kr == KERN_SUCCESS, let res = r.result else {
                lastPushFailedNs = now; pushFailures += 1
                if r.kr == DextProtocol.krUnsupported || r.kr == DextProtocol.krNotPermitted || r.kr == DextProtocol.krBadArgument {
                    mappingDirty = false; settledGeneration = mappingGeneration
                }
                note("SHADOW: setMapping failed: \(DextError(r.kr).description)")
                return
            }
            pushes += 1
            if res.accepted {
                lastRevision = rev
                pushedRevision = rev
                pushCore = try? XlateCore(blob: blob, spec: spec)
                parity.ring.enabled = pushCore != nil
                mappingDirty = false
                lastPushFailedNs = 0; pushFailures = 0
                Self.log.notice("SHADOW: mapping revision \(rev) accepted by the driver (\(blob.count) bytes)")
                loggedMappingNote = nil
            } else if res.reason == DextProtocol.MapReason.noPad {
                // the pad is not (yet) in the dext: retried when it is published (invalidateMapping) or, backing off, at a status read
                lastPushFailedNs = now; pushFailures += 1
                note("SHADOW: no pad in the driver yet; the mapping is pushed once it exists")
            } else {
                mappingDirty = false; settledGeneration = mappingGeneration        // final for this pad and this mapping
                lastPushFailedNs = now
                pushedRevision = nil; pushCore = nil; parity.ring.enabled = false
                note("SHADOW: the driver refused the mapping: \(DextProtocol.MapReason.text(res.reason, gdxText: { String(cString: gdx_reason($0)) }))")
            }
        }
    }

    private func note(_ text: String) {
        guard text != loggedMappingNote else { return }
        loggedMappingNote = text
        Self.log.notice("\(text, privacy: .public)")
    }

    /// Remember the instance; trip if it is not the one COUNT was accepted on.
    private func observe(_ s: DextStatus2) {
        connNonce = s.instanceNonce
        guard let armed = armedNonce, armed != s.instanceNonce else { return }
        tripped = true
        trippedRaw = rawPath
        armedNonce = nil
        sent = DextProtocol.Forwarding.inert            // a relaunched or replaced dext starts INERT
        Self.log.notice("tap: driver instance changed since COUNT was accepted (relaunch or upgrade); staying INERT. To re-arm change the stored inputPath value (for example write engine, then count) or restart the engine")
    }

    private func refreshPath() {
        let value = readDefault()
        let raw = value.map { String(describing: $0) } ?? ""
        let new = InputPath(defaultsValue: value)
        if new != path {
            Self.log.notice("inputPath: \(self.path.rawValue, privacy: .public) -> \(new.rawValue, privacy: .public)")
        }
        if tripped, raw != trippedRaw {
            tripped = false
            Self.log.notice("tap: inputPath value changed after the trip; re-armed")
        }
        path = new
        rawPath = raw
        if path.isRecognisedButNotYetSupported, !loggedUnsupportedPath {
            loggedUnsupportedPath = true
            Self.log.notice("inputPath \(self.path.rawValue, privacy: .public) needs a later driver; running as INERT")
        }
    }

    private static func stateName(_ s: UInt64) -> String {
        switch s { case DextProtocol.Forwarding.count: return "COUNT"; case DextProtocol.Forwarding.shadow: return "SHADOW"; default: return "INERT" }
    }

    private func apply() {
        guard connected else { return }
        let want = tripped ? DextProtocol.Forwarding.inert : path.forwardingState
        guard sent != want else { return }
        if want != DextProtocol.Forwarding.inert {
            // COUNT and SHADOW are sent only on an instance whose nonce we know, and that nonce is remembered with the acceptance.
            if connNonce == nil, let s = readStatus() { observe(s) }
            if tripped { return }                                      // observe() may have tripped it
            guard let nonce = connNonce else { return }
            if let armed = armedNonce, armed != nonce { return }       // never arm across instances
        }
        // The instance is marked armed BEFORE the call. If the driver dies inside it (selector 9 runs the SHADOW self-test), the
        // connection drops, the supervisor never sees an answer, and the next hello finds another instance nonce: it trips and
        // does not send the request again, so a fault inside the call cannot become a crash loop at the reconnect back-off.
        // Only a definite refusal (Unsupported, NotPermitted) takes the mark back; any other failure leaves it.
        let previouslyArmed = armedNonce
        if want != DextProtocol.Forwarding.inert { armedNonce = connNonce }
        let r = dext.setForwarding(want)
        if r.kr == KERN_SUCCESS {
            sent = want
            sentAccepted = true
            if want == DextProtocol.Forwarding.inert { armedNonce = nil }
            parity.ring.enabled = (want == DextProtocol.Forwarding.shadow)
            if want == DextProtocol.Forwarding.shadow { mappingDirty = true }
            Self.log.notice("tap: setForwarding(\(Self.stateName(want), privacy: .public)) applied=\(r.result?.appliedState ?? 99) tapPresent=\(r.result?.tapPresent ?? 99)")
        } else if r.kr == DextProtocol.krNotPermitted, want == DextProtocol.Forwarding.shadow {
            armedNonce = previouslyArmed            // a definite answer: the driver did not arm
            sent = want                 // the driver refuses SHADOW (its self-test failed): do not ask again on this connection
            if !loggedShadowRefusal { loggedShadowRefusal = true; Self.log.error("tap: the driver refused SHADOW (self-test failed in this driver process); the tap does not translate") }
        } else if r.kr == DextProtocol.krUnsupported {
            armedNonce = previouslyArmed
            sent = want                 // this dext cannot do it (no tap, or no SHADOW): do not ask again until the next connection
            if want != DextProtocol.Forwarding.inert { Self.log.notice("tap: this driver cannot do \(Self.stateName(want), privacy: .public)") }
        } else {
            Self.log.error("tap: setForwarding failed: \(DextError(r.kr).description, privacy: .public)")
        }
    }
}

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

/// Why the driver path was left. `text` is what the log (`fallback: <text>`) and the Driver menu show.
enum TapFallbackReason: Equatable {
    case stall                          // F1
    case tapAbsent                      // F2
    case driverRestarted(String)        // F3 (instance change, counters going backwards)
    case driverRefused(String)          // F4 (SHADOW refused, self-test failed, mapping refused)
    case parityMismatch                 // F5

    var text: String {
        switch self {
        case .stall: return "tap stalled"
        case .tapAbsent: return "tap absent"
        case .driverRestarted(let why): return "driver restarted (\(why))"
        case .driverRefused(let why): return "driver refused (\(why))"
        case .parityMismatch: return "parity mismatch"
        }
    }
}

/// A fallback in force. `rearmAtNs == nil` means final: it ends only when the stored `inputPath` value changes (or, with
/// `clearOnMapping`, when the mapping changes).
struct TapFallback: Equatable {
    var reason: TapFallbackReason
    var atNs: UInt64
    var rearmAtNs: UInt64?
    var clearOnMapping = false
}

/// What stopped the driver path altogether (plan 6.5 #3 and #4). Persisted in defaults by the engine, cleared only by the owner.
enum TapLatch: String, Equatable { case breaker, limiter }

/// The engine's TapSupervisor (T4-T6). Confined to `queue` (the engine's `vhidQueue`); the GUI never talks to the dext for any
/// of this (it reads the report the supervisor publishes, see `TapStatusReport`).
///
/// # State machine (T6; there is no LIVE yet, so "fallback" always means INERT and the engine keeps posting)
///
///     OFF ........ inputPath = engine, or no connection, or a dext without CAP_TAP / CAP_XLATE for the asked state.
///        |         INERT is sent once per connection; nothing else runs; status2 is not read.
///        | inputPath = count | shadow | driver       (driver runs as shadow: no CAP_LIVE yet)
///        v
///     ARMED(count | shadow)   the dext accepted setForwarding. armedNonce = this instance (set BEFORE the call, so a dext that
///        |   |                dies inside the call trips on the next hello). SHADOW pushes the mapping. status2 at 1 Hz (COUNT)
///        |   |                or 2 Hz (SHADOW). F1, F2, F4, F5 are evaluated on every reading.
///        |   +--- F1 stall, F2 tap absent ---------> FALLBACK(retry): INERT, re-armed after 5 s ("hold-off") if the
///        |        F4 refused, F5 parity mismatch --> FALLBACK(final): INERT until the stored inputPath value changes
///        |        F3 instance change / counters back --> TRIPPED (final, as FALLBACK(final)); never re-armed across instances
///        |   +--- 3 fallbacks within 10 min (limiter) or 3 instance changes within 120 s (breaker) --> LATCHED
///        v
///     LATCHED .... INERT; persisted in defaults (`tapBreakerTrippedAt`); cleared only when that key is removed (the Driver menu
///                  does it when the owner picks the driver path again, or `defaults delete`).
///
/// Every transition is logged once with its reason (`tap: setForwarding(..)`, `fallback: <reason>`, `fallback cleared`,
/// `breaker: tripped`); nothing is logged per frame, per poll or per retry.
///
/// # Detection rules (thresholds are constants below)
/// - **F1 stall** (COUNT, SHADOW): at two consecutive status2 readings at least 300 ms apart the engine's own reader counted
///   >= 50 frames since the previous reading while `status2.framesIn` did not move, with the tap present, `appliedState` equal to
///   the state asked for, and the grace period (below) over since both the arming and the controller interface coming up.
/// - **F2 tap absent**: the controller interface has been up for longer than the grace period and `status2.tapPresent == 0`
///   while armed. Grace = max(1 s, 3 x p99 of the measured interface-up to tap-present times (118-119 ms in T4)).
/// - **F3 instance change**: the dext's `instanceNonce` differs from the one the arming was accepted on, or `framesIn` or
///   `tapStarts` went backwards on one nonce. Never re-armed (the trip). The breaker counts every nonce change it sees.
/// - **F4 refusal**: `setForwarding(SHADOW)` answered NotPermitted (the dext's self-test failed), `status2.selfTest == fail`, or
///   `setMapping` was refused by the dext's validator or answered Unsupported / NotPermitted / BadArgument. A refused mapping
///   ends when the mapping changes; the others when `inputPath` changes.
/// - **F5 parity**: 3 or more mismatches of the parity sampler within 10 s (`noMatch` never counts: about a third of the
///   samples cannot be matched by design).
/// F6 (output stall) belongs to LIVE (T7).
///
/// # Cost (all on `queue`)
/// `inputPath`, `tapDrill` and `tapBreakerTrippedAt` are read once per second (the R14 reversal). status2 is read: never while
/// INERT and settled; 1 Hz while COUNT is armed; 2 Hz while SHADOW is armed; 10 Hz for at most 5 s after the controller
/// interface comes up (the attach timing, only on a dext with a tap); once per reconnect. A 100 ms tick evaluates nothing else.
///
/// # SHADOW (T5)
/// While SHADOW is armed the supervisor pushes the GDHM blob: after hello, after the pad is created (the spec CRC the blob targets
/// must match the live pad), and on every mapping change; a dext that lost the mapping (pad recreated, owner change) is detected
/// from status2 and gets it again. A parity sampler compares the dext's last translated frame with the engine's own C core for
/// the frame with the same kernel timestamp. SHADOW never posts.
///
/// # Arming and the trip
/// `count`/`shadow`/`driver` send COUNT or SHADOW after hello; everything else sends INERT. The dext's `instanceNonce` of the
/// instance on which the arming was accepted is remembered. If any later hello or status2 shows a different nonce, the dext was
/// relaunched or replaced; the supervisor then does NOT arm again (a crash anywhere in the armed path would otherwise become a
/// crash loop at the reconnect back-off). It stays INERT, logs one line, and the trip clears only when
///   - the stored `inputPath` value changes (any change of the stored value, including a different spelling such as `Count`,
///     or `engine` and then `count` again; `UserDefaults` cannot show that the identical value was written again), or
///   - the engine restarts (U7 does that after every driver upgrade).
/// A fallback with a re-arm keeps the mark too, so it can only re-arm on the very instance it left.
final class TapSupervisor: @unchecked Sendable {
    static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")
    static let tickMs = 100
    static let defaultsEveryTicks = 10
    static let statusEveryTicks = 10
    static let shadowEveryTicks = 5
    static let tickGapNs: UInt64 = 1_500_000_000

    // Thresholds (T6)
    static let stallMinFrames: UInt64 = 50
    static let stallWindowNs: UInt64 = 300_000_000
    static let stallConfirmations = 2
    static let graceMinNs: UInt64 = 1_000_000_000
    static let rearmHoldNs: UInt64 = 5_000_000_000
    static let parityMismatchLimit = 3
    static let parityWindowNs: UInt64 = 10_000_000_000
    static let limiterCount = 3
    static let limiterWindowNs: UInt64 = 600_000_000_000
    static let breakerCount = 3
    static let breakerWindowNs: UInt64 = 120_000_000_000

    private let queue: DispatchQueue
    private let dext: TapControlling
    private let readDefault: () -> Any?
    private let readDrill: () -> Any?
    private let clearDrill: () -> Void
    private let readChoice: () -> Any?
    private let continuousClock: () -> UInt64      // keeps counting while the Mac sleeps (the engine clock does not): a gap = a wake
    private var lastTickContinuous: UInt64?
    private let readBreaker: () -> (since: Double, reason: String)?
    private let writeBreaker: ((since: Double, reason: String)?) -> Void
    private let clock: () -> UInt64
    private let pid: Int32
    /// The engine reader's running count of valid controller frames (F1). Read on `queue`.
    var engineFrames: () -> UInt64 = { 0 }
    /// Called on `queue` with the report for the Driver menu whenever it differs from the last one.
    var statusSink: ((TapStatusReport) -> Void)?
    private var lastReport: TapStatusReport?

    private var timer: DispatchSourceTimer?
    private var connected = false
    private var tick = 0
    private var path = InputPath.engine
    private var rawPath = ""                    // the stored value as text, to see that it changed
    private var sent: UInt64?                   // the forwarding state last sent on this connection
    private var sentAccepted = false            // the dext answered success for it (an Unsupported answer ends the asking but proves nothing)
    private var connNonce: UInt64?              // instance nonce read on this connection
    private var armedNonce: UInt64?             // nonce of the dext instance on which COUNT/SHADOW was (asked to be) accepted
    private var lastSeenNonce: UInt64?          // the nonce of the previous instance this engine run has seen (breaker)
    private(set) var tripped = false
    private var trippedRaw = ""
    private var interfaceUpAtNs: UInt64?
    private var ifaceUpSinceNs: UInt64?         // the controller interface is up since (F1/F2 grace); nil while it is down
    private var loggedDriverNote = false
    private var lastApplyError: kern_return_t?
    private var lastApplyFailedNs: UInt64?
    // T6 fallback state
    private(set) var fallback: TapFallback?
    private(set) var latched: TapLatch?
    private var fallbackTimes: [UInt64] = []
    private var nonceChangeTimes: [UInt64] = []
    private var mismatchTimes: [UInt64] = []
    private var armedAtNs: UInt64?
    private var prevStatus: DextStatus2?
    private var f1Prev: (engine: UInt64, tap: UInt64, at: UInt64)?
    private var f1Suspect = 0
    private var f2First: UInt64?                // first reading of the current run of "tap absent" readings (F2 needs two)
    private(set) var unsupportedNote: String?
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
    private(set) var pushes = 0
    private var loggedPidMismatch = false
    private(set) var timing = TapAttachTiming()
    private(set) var lastStatus: DextStatus2?
    private(set) var status2Reads = 0           // for tests and the cost statement above

    init(queue: DispatchQueue, dext: TapControlling,
         readDefault: @escaping () -> Any? = { UserDefaults.standard.object(forKey: InputPath.defaultsKey) },
         readDrill: @escaping () -> Any? = { UserDefaults.standard.object(forKey: InputPath.drillKey) },
         clearDrill: @escaping () -> Void = { UserDefaults.standard.removeObject(forKey: InputPath.drillKey) },
         readChoice: @escaping () -> Any? = { UserDefaults.standard.object(forKey: InputPath.choiceKey) },
         readBreaker: @escaping () -> (since: Double, reason: String)? = TapSupervisor.defaultsReadBreaker,
         writeBreaker: @escaping ((since: Double, reason: String)?) -> Void = TapSupervisor.defaultsWriteBreaker,
         clock: @escaping () -> UInt64 = LatencyMeter.nowNs,
         continuousClock: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_MONOTONIC) },
         pid: Int32 = getpid(),
         mappingOffer: @escaping (UInt32) -> MappingOffer = { _ in .none },
         parity: ParitySampler? = nil) {
        self.queue = queue
        self.dext = dext
        self.mappingOffer = mappingOffer
        self.parity = parity ?? ParitySampler(clock: clock, log: { TapSupervisor.log.error("\($0, privacy: .public)") })
        self.readDefault = readDefault
        self.readDrill = readDrill
        self.clearDrill = clearDrill
        self.readChoice = readChoice
        self.readBreaker = readBreaker
        self.writeBreaker = writeBreaker
        self.clock = clock
        self.continuousClock = continuousClock
        self.pid = pid
    }

    static func defaultsReadBreaker() -> (since: Double, reason: String)? {
        guard let t = UserDefaults.standard.object(forKey: InputPath.breakerKey) as? Double else { return nil }
        return (t, UserDefaults.standard.string(forKey: InputPath.breakerReasonKey) ?? TapLatch.breaker.rawValue)
    }

    static func defaultsWriteBreaker(_ v: (since: Double, reason: String)?) {
        if let v {
            UserDefaults.standard.set(v.since, forKey: InputPath.breakerKey)
            UserDefaults.standard.set(v.reason, forKey: InputPath.breakerReasonKey)
        } else {
            UserDefaults.standard.removeObject(forKey: InputPath.breakerKey)
            UserDefaults.standard.removeObject(forKey: InputPath.breakerReasonKey)
        }
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
        prevStatus = nil; f1Prev = nil; f1Suspect = 0; f2First = nil; armedAtNs = nil; lastApplyError = nil
        pushedRevision = nil; pushCore = nil; mappingDirty = true; parity.ring.enabled = false; lastPushFailedNs = 0; pushFailures = 0
        mappingGeneration += 1; settledGeneration = -1
        defer { publishIfChanged() }
        guard up else { return }
        if let f = fallback, f.clearOnMapping {                // the mapping state of a new connection is a new generation
            fallback = nil
            Self.log.notice("fallback cleared: new connection after \(f.reason.text, privacy: .public)")
        }
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
        unsupportedNote = nil
        defer { publishIfChanged() }
        if let f = fallback, f.clearOnMapping {
            fallback = nil
            Self.log.notice("fallback cleared: the mapping changed after \(f.reason.text, privacy: .public); arming again")
            apply()
        }
        pushMappingIfNeeded()                                  // a learn edit reaches the dext at once, not at the next 2 Hz read
    }

    /// The tap part of the engine's meter line (SHADOW): what the dext translated and how the parity check is going.
    var shadowText: String? {
        guard path == .shadow || path == .driver || parity.stats != ParitySampler.Stats() else { return nil }
        return parity.stats.text + (pushedRevision.map { " rev=\($0)" } ?? "")
    }

    /// The Mac woke up (on `queue`): the controller and the tap re-attach, so F1 and F2 start a fresh grace period.
    func didWake() {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = clock()
        if ifaceUpSinceNs != nil { ifaceUpSinceNs = now }
        if armedAtNs != nil { armedAtNs = now }
        f1Prev = nil; f1Suspect = 0; f2First = nil
    }

    func controllerInterface(up: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        if up {
            interfaceUpAtNs = clock(); timingPending = true
            ifaceUpSinceNs = interfaceUpAtNs
        } else {
            interfaceUpAtNs = nil; timingPending = false; timing.interfaceDown(); ifaceUpSinceNs = nil
        }
        f1Prev = nil; f1Suspect = 0; f2First = nil             // a new interface starts a new grace period
        startTimingIfEligible()
    }

    /// The attach timing needs a dext with a tap and a connection; otherwise nothing would ever answer it, so it does not start.
    private var timingPending = false
    private func startTimingIfEligible() {
        guard timingPending, connected, dext.hasTap, let up = interfaceUpAtNs else { return }
        timingPending = false
        timing.interfaceUp(atNs: up)
    }

    /// COUNT or SHADOW as accepted by the dext and not (yet) left again; nil in every other state.
    private var armedState: UInt64? {
        guard connected, sentAccepted, fallback == nil, !tripped, latched == nil, let s = sent,
              s == DextProtocol.Forwarding.count || s == DextProtocol.Forwarding.shadow else { return nil }
        return s
    }

    /// max(1 s, 3 x p99 of the measured interface-up to tap-present times).
    var graceNs: UInt64 { max(Self.graceMinNs, UInt64(3 * timing.percentileMs(99) * 1e6)) }

    func onTick() {
        dispatchPrecondition(condition: .onQueue(queue))
        tick += 1
        defer { publishIfChanged() }
        // A gap between two 100 ms ticks that the engine clock (which stops in sleep) cannot explain is a wake, or a stalled
        // queue: either way the graces start again BEFORE the first reading after it, whether or not PowerObserver has run yet.
        let c = continuousClock()
        if let last = lastTickContinuous, c &- last > Self.tickGapNs { didWake() }
        lastTickContinuous = c
        if tick % Self.defaultsEveryTicks == 0 { refreshPath() }
        guard connected else { return }
        rearmIfDue()
        apply()
        let watching = armedNonce != nil && latched == nil && (sent != DextProtocol.Forwarding.inert || fallback?.rearmAtNs != nil)
        let timingWindow = timing.isWaiting
        let shadow = sent == DextProtocol.Forwarding.shadow && sentAccepted && !tripped && fallback == nil
        // selector 11 per second: INERT settled 0, COUNT 1, SHADOW 2 (every 5th tick), 10 only in the attach timing window.
        let shadowDue = shadow && tick % Self.shadowEveryTicks == 0
        guard timingWindow || shadowDue || (watching && !shadow && tick % Self.statusEveryTicks == 0) else { return }
        guard let s = readStatus() else { return }
        observe(s)
        if !tripped { detect(s) }
        if shadow, !tripped, fallback == nil { shadowStep(s) }
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

    // MARK: Detection (F1-F5)

    /// The rules of the table at the top, evaluated on one status2 reading.
    private func detect(_ s: DextStatus2) {
        let now = clock()
        defer { prevStatus = s }
        // F3, counters going backwards on one instance: the process was replaced without the nonce showing it.
        if let prev = prevStatus, prev.instanceNonce == s.instanceNonce, s.framesIn < prev.framesIn || s.tapStarts < prev.tapStarts {
            instanceChanged("counters went backwards")
            return
        }
        guard let state = armedState else { f1Prev = nil; f1Suspect = 0; return }
        // F4: the dext's own self-test failed in this process.
        if s.selfTest == DextProtocol.SelfTest.fail {
            enterFallback(.driverRefused("self-test failed in the driver"), retry: false)
            return
        }
        // F2: the interface has been up for longer than the grace period and no tap is attached.
        if dext.hasTap, !s.tapPresent, let up = ifaceUpSinceNs, now &- up > graceNs {
            // Two readings at least 300 ms apart, with no good reading between: one reading can land after the old tap stopped
            // and before the engine hears the interface go away (wake, controller off).
            guard let first = f2First else { f2First = now; return }
            if now &- first >= Self.stallWindowNs { enterFallback(.tapAbsent, retry: true) }
            return
        }
        f2First = nil
        // F1: the engine's reader sees frames and the tap's counter does not move.
        guard s.tapPresent, s.appliedState == UInt8(truncatingIfNeeded: state),
              let up = ifaceUpSinceNs, now &- up > graceNs, let at = armedAtNs, now &- at > graceNs else { f1Prev = nil; f1Suspect = 0; return }
        let engine = engineFrames()
        guard let prev = f1Prev else { f1Prev = (engine, s.framesIn, now); return }
        guard now &- prev.at >= Self.stallWindowNs else { return }
        if engine &- prev.engine >= Self.stallMinFrames, s.framesIn == prev.tap { f1Suspect += 1 } else { f1Suspect = 0 }
        f1Prev = (engine, s.framesIn, now)
        if f1Suspect >= Self.stallConfirmations { enterFallback(.stall, retry: true) }
    }

    /// F3: this is not the instance the arming was accepted on. Final; the breaker counts it.
    private func instanceChanged(_ why: String) {
        guard !tripped else { return }
        tripped = true
        trippedRaw = rawPath
        armedNonce = nil
        sent = nil                                      // apply() sends INERT: after a counters-backwards trip the instance may still be armed
        let reason = TapFallbackReason.driverRestarted(why)
        fallback = TapFallback(reason: reason, atNs: clock(), rearmAtNs: nil)
        Self.log.notice("fallback: \(reason.text, privacy: .public); not re-armed on this instance. To arm again change the stored inputPath value (for example write engine, then shadow) or restart the engine")
        recordFallback()
    }

    /// F1, F2, F4, F5. `retry`: the engine arms again by itself after the hold-off; otherwise it stays INERT until `inputPath`
    /// changes (or, for a refused mapping, until the mapping does).
    private func enterFallback(_ reason: TapFallbackReason, retry: Bool, clearOnMapping: Bool = false) {
        guard fallback == nil, !tripped else { return }
        let now = clock()
        fallback = TapFallback(reason: reason, atNs: now, rearmAtNs: retry ? now &+ Self.rearmHoldNs : nil, clearOnMapping: clearOnMapping)
        trippedRaw = rawPath
        f1Prev = nil; f1Suspect = 0; f2First = nil
        parity.ring.enabled = false
        let tail = retry ? "; arming again in \(Self.rearmHoldNs / 1_000_000_000) s" : (clearOnMapping ? "; waiting for the next mapping change" : "; staying on the engine path until inputPath changes")
        Self.log.notice("fallback: \(reason.text, privacy: .public)\(tail, privacy: .public)")
        recordFallback()
        apply()                                                // sends INERT now
    }

    /// The limiter (3 fallbacks within 10 min) and the breaker bookkeeping.
    private func recordFallback() {
        let now = clock()
        fallbackTimes.append(now)
        fallbackTimes.removeAll { now &- $0 > Self.limiterWindowNs }
        if fallbackTimes.count >= Self.limiterCount { latch(.limiter, "\(fallbackTimes.count) fallbacks within 10 min") }
    }

    private func noteNonceChange() {
        let now = clock()
        nonceChangeTimes.append(now)
        nonceChangeTimes.removeAll { now &- $0 > Self.breakerWindowNs }
        if nonceChangeTimes.count >= Self.breakerCount { latch(.breaker, "\(nonceChangeTimes.count) driver restarts within 120 s") }
    }

    private func latch(_ kind: TapLatch, _ why: String) {
        guard latched == nil else { return }
        latched = kind
        fallback?.rearmAtNs = nil                       // nothing re-arms while latched, and status2 is no longer read for it
        writeBreaker((Date().timeIntervalSince1970, kind.rawValue))
        Self.log.error("\(kind.rawValue, privacy: .public): tripped (\(why, privacy: .public)); the driver path stays off until the owner picks it again in the Driver menu (or: defaults delete com.interlinked.gdhub tapBreakerTrippedAt)")
        apply()
    }

    private func rearmIfDue() {
        guard let f = fallback, let at = f.rearmAtNs, latched == nil, clock() >= at else { return }
        fallback = nil
        f1Prev = nil; f1Suspect = 0
        Self.log.notice("fallback cleared: arming again after \(f.reason.text, privacy: .public)")
        apply()
        pushMappingIfNeeded()
    }

    /// SHADOW bookkeeping from one status2 reading: the dext lost the mapping? push again. A parity record? compare it (F5).
    private func shadowStep(_ s: DextStatus2) {
        // The driver lost the mapping (pad recreated, owner changed)? Offer it again. Not after a refusal of this very mapping.
        if settledGeneration != mappingGeneration,
           s.acceptedRevision == 0 || (pushedRevision != nil && s.acceptedRevision != pushedRevision!) { mappingDirty = true }
        pushMappingIfNeeded()
        if let rec = s.parity, let core = pushCore, let rev = pushedRevision, s.hasMap {
            if case .mismatch = parity.sample(rec, core: core, revision: rev) {
                let now = clock()
                mismatchTimes.append(now)
                mismatchTimes.removeAll { now &- $0 > Self.parityWindowNs }
                if mismatchTimes.count >= Self.parityMismatchLimit {
                    mismatchTimes.removeAll()
                    enterFallback(.parityMismatch, retry: false)
                }
            }
        }
    }

    private func pushMappingIfNeeded() {
        guard mappingDirty, connected, dext.hasXlate, !tripped, fallback == nil, latched == nil,
              sent == DextProtocol.Forwarding.shadow, sentAccepted else { return }
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
            unsupportedNote = why
            note("SHADOW: the mapping needs more than GDHM v1 (\(why)); nothing is pushed, the tap counts only")
        case .blob(let blob, let spec):
            unsupportedNote = nil
            let r = dext.setMapping(blob)
            guard r.kr == KERN_SUCCESS, let res = r.result else {
                lastPushFailedNs = now; pushFailures += 1
                if r.kr == DextProtocol.krUnsupported || r.kr == DextProtocol.krNotPermitted || r.kr == DextProtocol.krBadArgument {
                    mappingDirty = false; settledGeneration = mappingGeneration
                    note("SHADOW: setMapping failed: \(DextError(r.kr).description)")
                    enterFallback(.driverRefused("setMapping \(DextError(r.kr).description)"), retry: false, clearOnMapping: true)
                    return
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
                let text = DextProtocol.MapReason.text(res.reason, gdxText: { String(cString: gdx_reason($0)) })
                note("SHADOW: the driver refused the mapping: \(text)")
                enterFallback(.driverRefused("mapping: \(text)"), retry: false, clearOnMapping: true)
            }
        }
    }

    private func note(_ text: String) {
        guard text != loggedMappingNote else { return }
        loggedMappingNote = text
        Self.log.notice("\(text, privacy: .public)")
    }

    /// Remember the instance; trip if it is not the one COUNT/SHADOW was accepted on.
    private func observe(_ s: DextStatus2) {
        connNonce = s.instanceNonce
        // Restarts count toward the breaker only when something was armed or the path asks for arming: an upgrade or rollback drill
        // on the engine path must not leave a latch behind.
        if let last = lastSeenNonce, last != s.instanceNonce, armedNonce != nil || path.arms { noteNonceChange() }
        let changed = lastSeenNonce.map { $0 != s.instanceNonce } ?? false
        lastSeenNonce = s.instanceNonce
        // A refusal of the arming belongs to the driver process that gave it (its self-test): a new process gets its own chance.
        if changed, !tripped, let f = fallback, case .driverRefused = f.reason, armedNonce == nil || armedNonce == s.instanceNonce {
            fallback = nil
            Self.log.notice("fallback cleared: a new driver instance after \(f.reason.text, privacy: .public)")
        }
        guard let armed = armedNonce, armed != s.instanceNonce else { return }
        instanceChanged("instance changed since the arming was accepted")
    }

    // MARK: Defaults (once per second)

    private func refreshPath() {
        let value = readDefault()
        // "The stored path changed" = the text changed OR the owner picked an item in the menu again (the choice counter moved).
        let raw = (value.map { String(describing: $0) } ?? "") + "#" + (readChoice().map { String(describing: $0) } ?? "")
        let new = InputPath(defaultsValue: value)
        if new != path {
            Self.log.notice("inputPath: \(self.path.rawValue, privacy: .public) -> \(new.rawValue, privacy: .public)")
        }
        if tripped || fallback != nil, raw != trippedRaw {
            let was = fallback?.reason.text ?? "the trip"
            tripped = false
            fallback = nil
            Self.log.notice("fallback cleared: inputPath was written or chosen again after \(was, privacy: .public)")
        }
        // Leaving the driver path: whatever INERT was accepted on this instance, the arming mark and any fault state go with it
        // (otherwise a later driver restart would show a fallback the owner never asked for, and count toward the limiter).
        if !new.arms {
            armedNonce = nil
            if tripped || fallback != nil { tripped = false; fallback = nil }
        }
        path = new
        rawPath = raw
        if path == .driver, !dext.hasLive, !loggedDriverNote {
            loggedDriverNote = true
            Self.log.notice("inputPath driver: this driver reports no LIVE capability; running as shadow (the engine keeps posting)")
        }
        // The breaker / limiter latch is persisted: it survives an engine restart and ends only when the key is removed.
        let stored = readBreaker()
        if let st = stored, latched == nil {
            latched = TapLatch(rawValue: st.reason) ?? .breaker
            Self.log.error("\(self.latched!.rawValue, privacy: .public): tripped earlier; the driver path stays off until the owner picks it again in the Driver menu")
        } else if stored == nil, let l = latched {
            latched = nil
            fallbackTimes.removeAll(); nonceChangeTimes.removeAll()
            Self.log.notice("\(l.rawValue, privacy: .public): cleared by the owner")
        }
        if let d = readDrill() {
            clearDrill()                                        // read once, then deleted
            handleDrill(String(describing: d))
        }
    }

    /// `tapDrill`: `pause5` pauses the tap's counting for 5 s so that F1 can be seen to fire and to re-arm. The dext side of it
    /// (a pause flag on selector 9) does not exist in driver builds up to 23.
    private func handleDrill(_ raw: String) {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard v == "pause5" else {
            Self.log.notice("tapDrill: unknown value \(v, privacy: .public) ignored (known: pause5)")
            return
        }
        guard armedState != nil else { Self.log.notice("tapDrill pause5 ignored: the tap is not armed"); return }
        guard dext.supportsPauseDrill else {
            Self.log.notice("tapDrill pause5 ignored: this driver build has no pause flag (it arrives with the LIVE phase)")
            return
        }
        let kr = dext.pauseTap(ms: 5000)
        if kr == KERN_SUCCESS { Self.log.notice("tapDrill: tap paused for 5 s") }
        else { Self.log.error("tapDrill pause5 failed: \(DextError(kr).description, privacy: .public)") }
    }

    private static func stateName(_ s: UInt64) -> String {
        switch s { case DextProtocol.Forwarding.count: return "COUNT"; case DextProtocol.Forwarding.shadow: return "SHADOW"; default: return "INERT" }
    }

    private func apply() {
        guard connected else { return }
        let off = tripped || fallback != nil || latched != nil
        let want = off ? DextProtocol.Forwarding.inert : path.forwardingState
        guard sent != want else { return }
        // A call that failed is not repeated faster than once a second (this is selector 9 on the vhid queue).
        if lastApplyError != nil, let at = lastApplyFailedNs, clock() &- at < 1_000_000_000 { return }
        if want != DextProtocol.Forwarding.inert {
            // COUNT and SHADOW are sent only on an instance whose nonce we know, and that nonce is remembered with the acceptance.
            if connNonce == nil, let s = readStatus() { observe(s) }
            if tripped || fallback != nil || latched != nil { return }     // observe() may have tripped it
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
            lastApplyError = nil; lastApplyFailedNs = nil
            if want == DextProtocol.Forwarding.inert {
                if !off { armedNonce = nil }                   // a deliberate INERT; a fallback keeps the mark (no re-arm across instances)
                armedAtNs = nil
            } else {
                armedAtNs = clock()
                f1Prev = nil; f1Suspect = 0
            }
            parity.ring.enabled = (want == DextProtocol.Forwarding.shadow)
            if want == DextProtocol.Forwarding.shadow { mappingDirty = true }
            Self.log.notice("tap: setForwarding(\(Self.stateName(want), privacy: .public)) applied=\(r.result?.appliedState ?? 99) tapPresent=\(r.result?.tapPresent ?? 99)")
        } else if r.kr == DextProtocol.krNotPermitted, want == DextProtocol.Forwarding.shadow {
            armedNonce = previouslyArmed            // a definite answer: the driver did not arm
            enterFallback(.driverRefused("SHADOW refused: the driver's self-test failed"), retry: false)
        } else if r.kr == DextProtocol.krUnsupported {
            armedNonce = previouslyArmed
            sent = want                 // this dext cannot do it (no tap, or no SHADOW): do not ask again until the next connection
            if want != DextProtocol.Forwarding.inert { Self.log.notice("tap: this driver cannot do \(Self.stateName(want), privacy: .public)") }
        } else {
            lastApplyFailedNs = clock()
            guard lastApplyError != r.kr else { return }
            lastApplyError = r.kr                   // logged once per distinct error until it succeeds, not at every retry
            Self.log.error("tap: setForwarding failed: \(DextError(r.kr).description, privacy: .public)")
        }
    }

    // MARK: Status for the Driver menu

    func makeReport() -> TapStatusReport {
        var r = TapStatusReport()
        r.pid = pid
        r.path = path.rawValue
        r.connected = connected
        r.capTap = connected && dext.hasTap
        r.capXlate = connected && dext.hasXlate
        if let a = armedState { r.armed = a == DextProtocol.Forwarding.shadow ? "shadow" : "count" }
        r.liveUnavailable = path == .driver && !dext.hasLive
        r.parityChecked = parity.stats.isChecked
        r.parityOkBucket = parity.stats.matched / 100 * 100
        r.parityMismatches = parity.stats.mismatched
        r.fallback = fallback?.reason.text
        r.fallbackRetrying = fallback?.rearmAtNs != nil && latched == nil
        r.latched = latched?.rawValue
        r.mappingNote = unsupportedNote
        return r
    }

    private func publishIfChanged() {
        guard let sink = statusSink else { return }
        let r = makeReport()
        guard r != lastReport else { return }
        lastReport = r
        sink(r)
    }
}

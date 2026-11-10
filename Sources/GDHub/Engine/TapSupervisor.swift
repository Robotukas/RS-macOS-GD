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
    case outputStall                    // F6 (LIVE only)

    var text: String {
        switch self {
        case .stall: return "tap stalled"
        case .tapAbsent: return "tap absent"
        case .driverRestarted(let why): return "driver restarted (\(why))"
        case .driverRefused(let why): return "driver refused (\(why))"
        case .parityMismatch: return "parity mismatch"
        case .outputStall: return "output stalled"
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
    /// What the engine sends while the fallback lasts: INERT, or COUNT after a LIVE path stalled (the tap keeps counting and the
    /// engine posts again at once).
    var target: UInt64 = DextProtocol.Forwarding.inert
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
    // T7 (LIVE): status2 every tick (100 ms; the engine posts nothing meanwhile), F1 on a 200 ms window with one confirmation
    static let liveStallWindowNs: UInt64 = 200_000_000
    static let liveShadowMinNs: UInt64 = 2_000_000_000         // SHADOW must have run this long ...
    static let liveShadowMinFrames: UInt64 = 100               // ... translated this many frames ...
    static let outputStallMinReports: UInt64 = 3               // F6: the engine's own step would have posted this many reports
    static let appliedMismatchNs: UInt64 = 300_000_000         // F6: appliedState != desired for longer than this
    static let liveRetryNs: UInt64 = 1_000_000_000
    static let orphanDeferNs: UInt64 = 1_000_000_000           // an orphaned pinned pad is waited for this long after the first controller report
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
    /// T7: the posting gate. Called on `queue` with true right after the driver accepted LIVE and with false whenever the pad is the
    /// engine's again (a fallback, INERT, the connection gone).
    var onDrive: ((Bool) -> Void)?
    /// T7: the device this process just created was ADOPTED from a pinned pad that the driver's tap is driving (startup stay-LIVE).
    var padAdopted: () -> Bool = { false }
    /// T7: this process has created (or adopted) a device of its own.
    var sinkHasPad: () -> Bool = { false }
    /// T7 (F6): the engine's shadow step; the supervisor configures it with the core of the mapping the driver holds.
    var liveWatch: LiveWatch?
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
    // T7
    private var f6Prev: (would: UInt64, posts: UInt64, at: UInt64)?
    private var f6AppliedSince: UInt64?
    private var liveRetryAt: UInt64 = 0
    private var activeSinceNs: UInt64?          // the first controller report of this engine run (starts the orphan deferral window)
    private var loggedDefer = false
    private var loggedInertBySelf = false
    private var liveUnsupported = false         // this dext answered Unsupported to LIVE: not asked again on this connection
    private var shadowBaseTranslated: UInt64 = 0
    private var shadowBaseMismatches = 0
    private(set) var unsupportedHold = false    // the mapping needs more than GDHM v1: the driver path is INERT (engine posts) until it changes
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
        if connected, sent != DextProtocol.Forwarding.inert { _ = dext.setForwarding(DextProtocol.Forwarding.inert) }   // LIVE: source UC, neutral, INERT; the pad is then destroyed, not pinned
        liveWatch?.enabled = false
        onDrive?(false)
        sent = nil
    }

    /// The dext connection came up (after hello) or went away. A new connection always gets the state decided again, and the
    /// instance nonce is read first: a different nonce than the one COUNT was accepted on trips the supervisor.
    func connection(up: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        let wasLive = sent == DextProtocol.Forwarding.live
        connected = up
        sent = nil
        sentAccepted = false
        connNonce = nil
        lastStatus = nil
        if wasLive { liveWatch?.enabled = false; onDrive?(false) }       // the pad (and its pinning) belong to the old connection
        prevStatus = nil; f1Prev = nil; f1Suspect = 0; f2First = nil; armedAtNs = nil; lastApplyError = nil
        f6Prev = nil; f6AppliedSince = nil; liveRetryAt = 0; liveUnsupported = false
        pushedRevision = nil; pushCore = nil; mappingDirty = true; parity.ring.enabled = false; lastPushFailedNs = 0; pushFailures = 0
        mappingGeneration += 1; settledGeneration = -1
        defer { publishIfChanged() }
        guard up else { return }
        if let f = fallback, f.clearOnMapping {                // the mapping state of a new connection is a new generation
            fallback = nil
            Self.log.notice("fallback cleared: new connection after \(f.reason.text, privacy: .public)")
        }
        refreshPath()
        if let s = readStatus() { observe(s); adoptLiveIfPossible(s) }
        startTimingIfEligible()
        apply()
        pushMappingIfNeeded()                                  // right after hello (and the SHADOW request): no waiting for a tick
    }

    /// The first controller report of this engine run: the pad is about to be published, and the orphan deferral window starts.
    func controllerActive() {
        dispatchPrecondition(condition: .onQueue(queue))
        if activeSinceNs == nil { activeSinceNs = clock() }
    }

    /// A pinned pad nobody owns is waiting and this engine has no pad yet: it will ADOPT it when the sink creates its device (the
    /// pad is published on the first controller report). Until then nothing is sent to the driver (the driver would refuse it
    /// anyway; the engine does not rely on that), for at most `orphanDeferNs` after the first controller report. If the adoption does
    /// not happen (another spec, Busy) the window ends and the normal path replaces the pad and arms from scratch.
    private func deferForOrphan() -> Bool {
        guard connected, path == .driver, dext.hasLive, !tripped, latched == nil, sent == nil, let s = lastStatus,
              s.padOrphaned, s.padSource == DextProtocol.PadSource.tap.rawValue, !padAdopted(), !sinkHasPad() else { return false }
        if let a = activeSinceNs, clock() &- a > Self.orphanDeferNs { return false }
        if !loggedDefer { loggedDefer = true; Self.log.notice("startup: a pinned pad is waiting for an owner; adopting it (nothing is sent to the driver until then)") }
        return true
    }

    /// The sink published its device (created or adopted): look at the driver once more. An adopted pad that the tap drives is the
    /// startup stay-LIVE case; otherwise the normal arming goes on from here.
    func padPublished() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connected else { return }
        loggedDefer = false
        if let s = readStatus() { observe(s); adoptLiveIfPossible(s); takeBackAdoptedPad() }
        apply()
        pushMappingIfNeeded()
        publishIfChanged()
    }

    /// The sink opened its gate by itself (identity switch, unpublish, connection events): the device and with it LIVE are gone. The
    /// driver left LIVE together with the pad, so nothing is sent; the supervisor forgets what it had armed and starts from scratch,
    /// without a fallback and without a limiter entry.
    func gateForcedOpen() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard sent != nil, sent != DextProtocol.Forwarding.inert else { return }
        if sent == DextProtocol.Forwarding.live { liveWatch?.enabled = false }
        sent = nil; sentAccepted = false; armedAtNs = nil
        mappingDirty = true; f1Prev = nil; f1Suspect = 0; f6Prev = nil; f6AppliedSince = nil
        Self.log.notice("the device went away while armed: the driver path starts again with the next one")
    }

    /// This process just adopted a pad that the driver's tap was driving (`padAdopted`), and what it believes it has sent is not LIVE: the INERT
    /// (or SHADOW) it sent after hello came while it owned nothing, and the driver answered success with no effect. Forget it, so
    /// that `apply()` sends the wanted state again now that the pad is ours; the driver then leaves LIVE properly (source UC, neutral).
    /// Without this the pad stays with the tap on a path that never asked for it (the runtime rollback of a crash loop, the App path).
    private func takeBackAdoptedPad() {
        guard padAdopted(), sent != DextProtocol.Forwarding.live else { return }
        Self.log.notice("the adopted pad is still driven by the tap; asking for \(Self.stateName(self.wantedState()), privacy: .public) again now that it is ours")
        sent = nil; sentAccepted = false; armedAtNs = nil
        mappingDirty = true; f1Prev = nil; f1Suspect = 0; f6Prev = nil; f6AppliedSince = nil
        lastApplyError = nil; lastApplyFailedNs = nil
    }

    /// Startup stay-LIVE (plan 6.6): this process just adopted a pinned pad that the driver's tap is driving, the driver is in LIVE on
    /// a passed self-test, and `inputPath` asks for the driver path. The supervisor takes the instance as armed and LIVE without
    /// sending anything (no SHADOW warm-up, no neutral), closes the posting gate, and pushes the engine's current mapping at once:
    /// the swap is atomic in the driver (full repost, the same output if the mapping is unchanged). If the mapping is not
    /// expressible the normal rules take LIVE down with INERT.
    private func adoptLiveIfPossible(_ s: DextStatus2) {
        guard path == .driver, dext.hasLive, padAdopted(), !tripped, latched == nil, fallback == nil, sent == nil,
              s.desiredState == UInt8(DextProtocol.Forwarding.live), s.appliedState == UInt8(DextProtocol.Forwarding.live),
              s.padSource == DextProtocol.PadSource.tap.rawValue, s.selfTest == DextProtocol.SelfTest.pass, s.padLive, s.ownerPresent,
              s.tapPresent, armedNonce == nil || armedNonce == s.instanceNonce else { return }
        armedNonce = s.instanceNonce
        connNonce = s.instanceNonce
        sent = DextProtocol.Forwarding.live
        sentAccepted = true
        armedAtNs = clock()
        mappingDirty = true
        parity.ring.enabled = true
        liveWatch?.configure(core: pushCore)            // the push that follows configures the core of the mapping the driver holds
        liveWatch?.enabled = true                       // F6 is on for an adopted session too
        onDrive?(true)
        Self.log.notice("startup: the driver already drives the adopted pad; staying LIVE without a neutral")
    }

    /// The mapping changed, or the pad was (re)created: the dext needs the blob again.
    ///
    /// While the driver path stands down because the mapping needs more than GDHM v1 (`unsupportedHold`), the encoder is asked
    /// first: if the new mapping is still unsupported (or its blob does not pass the local check) the hold stays, the note takes
    /// the new reason and the driver is not called at all (releasing the hold would send SHADOW and the push would send INERT
    /// again for nothing). If it can be expressed now, or there is no pad to ask about, the hold is released as before.
    func invalidateMapping() {
        dispatchPrecondition(condition: .onQueue(queue))
        mappingGeneration += 1; pushFailures = 0; lastPushFailedNs = 0
        defer { publishIfChanged() }
        let stillUnsupported: String? = {
            guard unsupportedHold, case .unsupported(let why) = checked(mappingOffer(lastRevision &+ 1)) else { return nil }
            return why
        }()
        if let why = stillUnsupported {
            standDown(why)                                     // no driver call: the driver is INERT already (apply() only repairs a state that is not)
        } else {
            mappingDirty = true
            unsupportedNote = nil
            let wasHold = unsupportedHold
            unsupportedHold = false
            if wasHold { apply() }                             // the mapping may be expressible now: the driver path comes back
        }
        if let f = fallback, f.clearOnMapping {
            fallback = nil
            Self.log.notice("fallback cleared: the mapping changed after \(f.reason.text, privacy: .public); arming again")
            apply()
        }
        pushMappingIfNeeded()                                  // a learn edit reaches the dext at once, not at the next 2 Hz read
    }

    /// An offer after the local check: a blob has been validated against its spec by the same C validator the sink uses, so a blob
    /// the driver would refuse for its own reasons is found here, before any call, and is treated like an unsupported mapping.
    private enum CheckedOffer {
        case none
        case unsupported(String)
        case blob([UInt8], XlateCore)
    }

    private func checked(_ offer: MappingOffer) -> CheckedOffer {
        switch offer {
        case .none: return .none
        case .unsupported(let why): return .unsupported(why)
        case .blob(let blob, let spec):
            do { return .blob(blob, try XlateCore(blob: blob, spec: spec)) }
            catch { return .unsupported("internal: blob rejected locally (\(error))") }
        }
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
        prevStatus = nil                                // counters are compared only between readings of one tap instance
        f1Prev = nil; f1Suspect = 0; f2First = nil; f6Prev = nil; f6AppliedSince = nil
        // LIVE across a Mac sleep: the engine's willSleep neutral set the driver's hold; asking for LIVE again (idempotent) clears it
        // (the tap's SetPowerState(On) does too). One call, only when LIVE is what the driver was in.
        if connected, sent == DextProtocol.Forwarding.live, sentAccepted, !tripped, fallback == nil, latched == nil {
            let kr = dext.setForwarding(DextProtocol.Forwarding.live).kr
            Self.log.notice("resume: LIVE asked again after the wake, hold cleared (rc 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public))")
        }
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
              s == DextProtocol.Forwarding.count || s == DextProtocol.Forwarding.shadow || s == DextProtocol.Forwarding.live else { return nil }
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
        let live = sent == DextProtocol.Forwarding.live && sentAccepted && !tripped && fallback == nil
        // selector 11 per second: INERT settled 0, COUNT 1, SHADOW 2 (every 5th tick), LIVE 10 (every tick: the engine posts
        // nothing then, and F1/F6 must see a stall within ~300 ms), 10 in the attach timing window for at most 5 s.
        let shadowDue = (shadow || deferForOrphan()) && tick % Self.shadowEveryTicks == 0
        guard timingWindow || live || shadowDue || (watching && !shadow && !live && tick % Self.statusEveryTicks == 0) else { return }
        guard let s = readStatus() else { return }
        observe(s)
        if !tripped { detect(s) }
        if (shadow || live), !tripped, fallback == nil { shadowStep(s) }
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
        // The driver went back to INERT by itself (its pad left the slot: stopped, replaced, removed): what we armed is gone. Forget it
        // and arm again for the next pad; not a fault.
        if s.desiredState == UInt8(DextProtocol.Forwarding.inert), state != DextProtocol.Forwarding.inert {
            if !loggedInertBySelf { loggedInertBySelf = true; Self.log.notice("the driver is back in INERT by itself (its pad went away); arming again") }
            if state == DextProtocol.Forwarding.live { liveWatch?.enabled = false; onDrive?(false) }
            sent = nil; sentAccepted = false; armedAtNs = nil; mappingDirty = true; f1Prev = nil; f1Suspect = 0; f6Prev = nil; f6AppliedSince = nil
            return
        }
        loggedInertBySelf = false
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
            if now &- first >= Self.stallWindowNs { enterFallback(.tapAbsent, retry: true, toCount: true) }
            return
        }
        f2First = nil
        let isLive = state == DextProtocol.Forwarding.live
        // F6 (LIVE only): the driver must be posting what the engine's own step says it should.
        if isLive, detectOutputStall(s, now) { return }
        if !isLive { f6Prev = nil; f6AppliedSince = nil }
        // F1: the engine's reader sees frames and the tap's counter does not move. LIVE: a 200 ms window, one confirmation.
        guard s.tapPresent, s.appliedState == UInt8(truncatingIfNeeded: state),
              let up = ifaceUpSinceNs, now &- up > graceNs, let at = armedAtNs, now &- at > graceNs else { f1Prev = nil; f1Suspect = 0; return }
        let engine = engineFrames()
        guard let prev = f1Prev else { f1Prev = (engine, s.framesIn, now); return }
        guard now &- prev.at >= (isLive ? Self.liveStallWindowNs : Self.stallWindowNs) else { return }
        if engine &- prev.engine >= Self.stallMinFrames, s.framesIn == prev.tap { f1Suspect += 1 } else { f1Suspect = 0 }
        f1Prev = (engine, s.framesIn, now)
        if f1Suspect >= (isLive ? 1 : Self.stallConfirmations) { enterFallback(.stall, retry: true, toCount: isLive) }
    }

    /// F6, evaluated on a LIVE reading. True when it fell back.
    ///  - `padSource` is not TAP, or `framesIgnored` rose while the tap is powered: at once.
    ///  - `appliedState` differs from LIVE for longer than 300 ms.
    ///  - the engine's own step (same core, same frames) would have posted >= 3 reports in a window of at least 200 ms and the
    ///    driver's `tapPosts` did not move.
    private func detectOutputStall(_ s: DextStatus2, _ now: UInt64) -> Bool {
        // No tap, no output stall: the tap is gone (controller off or asleep, a wake) and F2 / the new instance cover it. The driver sets
        // appliedState to INERT when the tap unregisters while padSource stays TAP, which is correct and not a stall.
        guard s.tapPresent else { f6Prev = nil; f6AppliedSince = nil; return false }
        // The engine's own willSleep hold: the driver holds the tap's frames back until the tap powers off, so tapPosts stands still on
        // purpose. Not a stall, and nothing from before the hold is compared with what comes after it.
        if s.holdNeutral { f6Prev = nil; f6AppliedSince = nil; return false }
        if s.padSource != DextProtocol.PadSource.tap.rawValue {
            enterFallback(.outputStall, retry: true, toCount: true)
            return true
        }
        // framesIgnored is a counter of the whole process: compare only two readings of the SAME tap instance, both powered.
        if let prev = prevStatus, prev.tapPresent, prev.tapStarts == s.tapStarts, prev.powered, s.powered, s.framesIgnored > prev.framesIgnored {
            enterFallback(.outputStall, retry: true, toCount: true)
            return true
        }
        if prevStatus?.tapStarts != s.tapStarts { f6AppliedSince = nil; f6Prev = nil }
        if s.appliedState != UInt8(DextProtocol.Forwarding.live) {
            let since = f6AppliedSince ?? now
            f6AppliedSince = since
            if now &- since > Self.appliedMismatchNs { enterFallback(.outputStall, retry: true, toCount: true); return true }
        } else {
            f6AppliedSince = nil
        }
        guard let watch = liveWatch, watch.enabled else { f6Prev = nil; return false }
        let would = watch.wouldPostReports
        guard let prev = f6Prev else { f6Prev = (would, s.tapPosts, now); return false }
        guard now &- prev.at >= Self.liveStallWindowNs else { return false }
        f6Prev = (would, s.tapPosts, now)
        if would &- prev.would >= Self.outputStallMinReports, s.tapPosts == prev.posts {
            enterFallback(.outputStall, retry: true, toCount: true)
            return true
        }
        return false
    }

    /// F3: this is not the instance the arming was accepted on. Final; the breaker counts it.
    private func instanceChanged(_ why: String) {
        guard !tripped else { return }
        if sent == DextProtocol.Forwarding.live { liveWatch?.enabled = false; onDrive?(false) }          // the pad died with the old instance
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
    private func enterFallback(_ reason: TapFallbackReason, retry: Bool, clearOnMapping: Bool = false, toCount: Bool = false) {
        guard fallback == nil, !tripped else { return }
        let now = clock()
        // A LIVE path that stalls falls back to COUNT (the tap keeps counting), everything else to INERT (plan 6.6).
        let target = (toCount && sent == DextProtocol.Forwarding.live) ? DextProtocol.Forwarding.count : DextProtocol.Forwarding.inert
        fallback = TapFallback(reason: reason, atNs: now, rearmAtNs: retry ? now &+ Self.rearmHoldNs : nil, clearOnMapping: clearOnMapping, target: target)
        trippedRaw = rawPath
        f1Prev = nil; f1Suspect = 0; f2First = nil; f6Prev = nil; f6AppliedSince = nil
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
              sent == DextProtocol.Forwarding.shadow || sent == DextProtocol.Forwarding.live, sentAccepted else { return }
        let now = clock()
        let backoffNs = min(UInt64(500_000_000) << UInt64(max(pushFailures - 1, 0)), 5_000_000_000)
        guard lastPushFailedNs == 0 || now &- lastPushFailedNs >= backoffNs else { return }
        let rev = lastRevision &+ 1
        switch checked(mappingOffer(rev)) {
        case .none:
            return                                                       // no pad yet: asked again at the next tick
        case .unsupported(let why):
            standDown(why)
        case .blob(let blob, let core):
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
                pushCore = core
                liveWatch?.configure(core: pushCore)
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

    /// The mapping cannot go to the driver (the encoder says GDHM v1 cannot express it, or its blob failed the local check): the
    /// driver path is INERT (its map is cleared there) and the engine path posts. Not a fault: no fallback, no limiter entry. The
    /// answer is final for this generation, so the mapping is not encoded again until it changes.
    private func standDown(_ why: String) {
        mappingDirty = false; settledGeneration = mappingGeneration
        pushedRevision = nil; pushCore = nil; parity.ring.enabled = false
        unsupportedNote = why
        unsupportedHold = true
        liveWatch?.configure(core: nil)
        note("the mapping cannot go to the driver (\(why)); the driver path stands down and the engine posts")
        apply()
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
        if raw != rawPath { unsupportedHold = false; liveRetryAt = 0 }
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
        let kr = dext.pauseTap(state: sent ?? DextProtocol.Forwarding.shadow, ms: 5000)
        if kr == KERN_SUCCESS { Self.log.notice("tapDrill: tap paused for 5 s") }
        else { Self.log.error("tapDrill pause5 failed: \(DextError(kr).description, privacy: .public)") }
    }

    private static func stateName(_ s: UInt64) -> String {
        switch s {
        case DextProtocol.Forwarding.count: return "COUNT"; case DextProtocol.Forwarding.shadow: return "SHADOW"
        case DextProtocol.Forwarding.live: return "LIVE"; default: return "INERT"
        }
    }

    /// What the engine wants the driver to be in right now. A trip or a latch means INERT; a fallback means its target (INERT, or
    /// COUNT after a LIVE path stalled); a mapping the driver cannot express means INERT (the engine path posts); otherwise the
    /// path decides. `driver` goes SHADOW first and LIVE only when `liveEligible()` (plan 6.6, "return to LIVE").
    private func wantedState() -> UInt64 {
        if tripped || latched != nil { return DextProtocol.Forwarding.inert }
        if let f = fallback { return f.target }
        if unsupportedHold { return DextProtocol.Forwarding.inert }
        if path == .driver, dext.hasLive, !liveUnsupported {
            if sent == DextProtocol.Forwarding.live && sentAccepted { return DextProtocol.Forwarding.live }
            return liveEligible() ? DextProtocol.Forwarding.live : DextProtocol.Forwarding.shadow
        }
        return path.forwardingState
    }

    /// SHADOW has run long enough, translated enough frames and agreed with the engine's own core on every sampled one, the mapping
    /// the driver translates with is the one just pushed and targets this pad, and nothing is in the way. Evaluated at every tick
    /// from the last status reading (at most 500 ms old in SHADOW).
    private func liveEligible() -> Bool {
        guard path == .driver, dext.hasLive, !liveUnsupported, sent == DextProtocol.Forwarding.shadow, sentAccepted,
              fallback == nil, !tripped, latched == nil, !unsupportedHold,
              let s = lastStatus, let armedAt = armedAtNs else { return false }
        let now = clock()
        guard now >= liveRetryAt, now &- armedAt >= Self.liveShadowMinNs else { return false }
        guard s.tapPresent, s.appliedState == UInt8(DextProtocol.Forwarding.shadow), s.selfTest == DextProtocol.SelfTest.pass,
              s.padLive, s.padSource == DextProtocol.PadSource.userClient.rawValue, s.hasMap, s.padSpecCRC != 0,
              s.acceptedSpecCRC == s.padSpecCRC, let pushed = pushedRevision, s.appliedRevision == pushed else { return false }
        return s.framesTranslated &- shadowBaseTranslated >= Self.liveShadowMinFrames && parity.stats.mismatched == shadowBaseMismatches
    }

    private func apply() {
        guard connected else { return }
        if deferForOrphan() { return }
        let want = wantedState()
        let off = tripped || fallback != nil || latched != nil || unsupportedHold
        guard sent != want else { return }
        // A call that failed is not repeated faster than once a second (this is selector 9 on the vhid queue).
        if lastApplyError != nil, let at = lastApplyFailedNs, clock() &- at < 1_000_000_000 { return }
        if want != DextProtocol.Forwarding.inert {
            // COUNT, SHADOW and LIVE are sent only on an instance whose nonce we know, and that nonce is remembered with the acceptance.
            if connNonce == nil, let s = readStatus() { observe(s) }
            if tripped || latched != nil { return }                    // observe() may have tripped it
            guard let nonce = connNonce else { return }
            if let armed = armedNonce, armed != nonce { return }       // never arm across instances
        }
        // The instance is marked armed BEFORE the call. If the driver dies inside it (selector 9 runs the SHADOW self-test), the
        // connection drops, the supervisor never sees an answer, and the next hello finds another instance nonce: it trips and
        // does not send the request again, so a fault inside the call cannot become a crash loop at the reconnect back-off.
        // Only a definite refusal (Unsupported, NotPermitted) takes the mark back; any other failure leaves it.
        let previouslyArmed = armedNonce
        if want != DextProtocol.Forwarding.inert { armedNonce = connNonce }
        let wasLive = sent == DextProtocol.Forwarding.live
        let r = dext.setForwarding(want)
        // Leaving LIVE opens the posting gate whatever the driver answered: the supervisor has decided that the engine posts again, and
        // a driver that did not confirm is retried while its (TAP) source simply refuses the engine's posts.
        if wasLive && want != DextProtocol.Forwarding.live { liveWatch?.enabled = false; onDrive?(false) }
        if r.kr == KERN_SUCCESS {
            sent = want
            sentAccepted = true
            lastApplyError = nil; lastApplyFailedNs = nil
            if want == DextProtocol.Forwarding.inert {
                if !off { armedNonce = nil }                   // a deliberate INERT; a fallback keeps the mark (no re-arm across instances)
                armedAtNs = nil
            } else {
                armedAtNs = clock()
                f1Prev = nil; f1Suspect = 0; f6Prev = nil; f6AppliedSince = nil
            }
            let translating = want == DextProtocol.Forwarding.shadow || want == DextProtocol.Forwarding.live
            parity.ring.enabled = translating
            if want == DextProtocol.Forwarding.shadow {
                mappingDirty = true
                shadowBaseTranslated = lastStatus?.framesTranslated ?? 0
                shadowBaseMismatches = parity.stats.mismatched
            }
            if want == DextProtocol.Forwarding.live { liveWatch?.configure(core: pushCore) }
            liveWatch?.enabled = (want == DextProtocol.Forwarding.live)
            if want == DextProtocol.Forwarding.live { onDrive?(true) }
            Self.log.notice("tap: setForwarding(\(Self.stateName(want), privacy: .public)) applied=\(r.result?.appliedState ?? 99) tapPresent=\(r.result?.tapPresent ?? 99)")
        } else if r.kr == DextProtocol.krNotPermitted, want >= DextProtocol.Forwarding.shadow {
            armedNonce = previouslyArmed            // a definite answer: the driver did not arm
            enterFallback(.driverRefused(want == DextProtocol.Forwarding.live ? "LIVE refused by the driver" : "SHADOW refused: the driver's self-test failed"), retry: false)
        } else if r.kr == DextProtocol.krUnsupported {
            armedNonce = previouslyArmed
            if want == DextProtocol.Forwarding.live { liveUnsupported = true; Self.log.notice("tap: this driver cannot do LIVE; staying in SHADOW") }
            else {
                sent = want                 // this dext cannot do it (no tap, or no SHADOW): do not ask again until the next connection
                if want != DextProtocol.Forwarding.inert { Self.log.notice("tap: this driver cannot do \(Self.stateName(want), privacy: .public)") }
            }
        } else if want == DextProtocol.Forwarding.live && (r.kr == DextProtocol.krNotReady || r.kr == DextProtocol.krBadArgument) {
            // Not yet (no pad / tap / SHADOW applied / mapping) or the accepted mapping targets another pad: SHADOW goes on, and LIVE is
            // asked again later; a mapping that targets another pad is pushed again first.
            liveRetryAt = clock() &+ (r.kr == DextProtocol.krBadArgument ? 2 * Self.liveRetryNs : Self.liveRetryNs)
            if r.kr == DextProtocol.krBadArgument { mappingDirty = true; mappingGeneration += 1; settledGeneration = -1 }
            note("LIVE not accepted yet: \(DextError(r.kr).description); SHADOW goes on")
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
        r.capLive = connected && dext.hasLive
        if let a = armedState {
            r.armed = a == DextProtocol.Forwarding.live ? "live" : (a == DextProtocol.Forwarding.shadow ? "shadow" : "count")
        }
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

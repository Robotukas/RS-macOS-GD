import Foundation
import IOKit

/// Swift mirror of `Dext/GDHubVirtualHID/GDHubProtocol.h` (design §3.5, §5.3). Little-endian wire format.
/// `DextProtocolTests` parses the header text and compares every `#define` number with the constants below.
enum DextProtocol {
    static let version = 1
    /// Version of the DeviceSpec blob. Checked by the dext's spec validation instead of `version` (T3); both are 1.
    static let specVersion = 1
    static let userClientType: UInt32 = 0

    enum Selector {
        static let hello: UInt32 = 0
        static let createDevice: UInt32 = 1
        static let destroyDevice: UInt32 = 2
        static let postReport: UInt32 = 3
        static let postNeutral: UInt32 = 4
        static let heartbeat: UInt32 = 5
        static let registerOutput: UInt32 = 6
        static let getStatus: UInt32 = 7
        /// DEBUG-ONLY dev experiment (not in the design): the dext calls Terminate(0) on its root service.
        static let devTerminate: UInt32 = 8
        /// T3, behind `Capability.rootPad`. Scalars in: state, flags, argMs. Scalars out: appliedState, tapPresent, padSource, lastError.
        static let setForwarding: UInt32 = 9
        /// T5, behind `Capability.xlate`: struct in = a GDHM blob (<= 1024 bytes); scalars out = [acceptedRevision, reason].
        static let setMapping: UInt32 = 10
        static let getStatus2: UInt32 = 11
        /// T7, behind `Capability.live`: struct in = a DeviceSpec; scalars out = [adopted, padSource]. A live pinned pad with a
        /// byte-identical spec and no owner becomes the caller's (adopted = 1) without a neutral and without a new device.
        static let createDevice2: UInt32 = 12
        static let count: UInt32 = 13
    }

    enum Slot: UInt8 {
        case pad = 0, keyboard = 1, pointer = 2
        static let count = 3
    }

    /// `hello` output[2] bits. Bits 0-2 are `1 << slot`; higher bits are features, only ever added (the additive rule in
    /// GDHubProtocol.h). A dext that does not set a bit does not have the selectors behind it: the app must not call them.
    enum Capability {
        static let pad: UInt64 = 1
        static let keyboard: UInt64 = 2
        static let pointer: UInt64 = 4
        /// T3: the root service owns the pad; selectors `setForwarding` (9) and `getStatus2` (11) exist.
        static let rootPad: UInt64 = 1 << 8
        /// T4: the receiver tap exists in this dext; `setForwarding` also accepts COUNT. A dext built with GDHUB_TAP_DECLINE
        /// does not set it.
        static let tap: UInt64 = 1 << 9
        /// T5: selector 10 (`setMapping`) and the SHADOW state exist (the in-driver translator passed no self-test yet; that is
        /// reported separately in status2).
        static let xlate: UInt64 = 1 << 10
        /// T7: LIVE (the tap drives the pad), selector 12, the pause and release-pad flags of selector 9, pinning and adoption.
        static let live: UInt64 = 1 << 11
    }

    /// Forwarding state of `setForwarding`. INERT: the tap is attached but the interface is not opened. COUNT (T4): opened,
    /// counting frames, nothing translated or posted. Later phases add SHADOW (2) and LIVE (3).
    enum Forwarding {
        static let inert: UInt64 = 0
        static let count: UInt64 = 1
        /// T5: COUNT, plus the in-driver translator runs on every report with the accepted mapping and records a parity sample.
        /// Nothing is posted. Without a mapping it is COUNT.
        static let shadow: UInt64 = 2
        /// T7: SHADOW, and the tap hands what it translates to the pad (padSource TAP).
        static let live: UInt64 = 3
        /// Flags of selector 9 (owner only, with `Capability.live`). The pause flag leaves the state as it is (pass the current one);
        /// release-pad goes with INERT.
        static let flagDevPauseTap: UInt64 = 1 << 8
        static let flagReleasePad: UInt64 = 1 << 9
        static let pauseMaxMs: UInt64 = 10_000
        /// Argument check of selector 9 in this protocol version (mirror of gdh_fwd_validate).
        static func isAccepted(state: UInt64, flags: UInt64) -> Bool {
            guard state <= live, flags & ~(flagDevPauseTap | flagReleasePad) == 0 else { return false }
            if flags & flagReleasePad != 0 { return state == inert && flags & flagDevPauseTap == 0 }
            return true
        }
    }

    /// Who may post to the pad (`padSource` in status2 and in `setForwarding`'s output).
    /// `setMapping` reasons (scalar output 1): 0 accepted, 1...21 `GDX_E_*` of Shared/GDHubXlate.h, then these.
    enum MapReason {
        static let ok: UInt32 = 0
        static let noPad: UInt32 = 100
        static let tooBig: UInt32 = 101
        static let noRegistry: UInt32 = 102
        /// Text for a reason, for logs. `gdxText` supplies the `GDX_E_*` descriptions.
        static func text(_ code: UInt32, gdxText: (Int32) -> String) -> String {
            switch code {
            case 0: return "accepted"
            case noPad: return "no pad has been created yet"
            case tooBig: return "does not fit the driver's handoff buffer"
            case noRegistry: return "driver registry unavailable"
            default: return gdxText(Int32(truncatingIfNeeded: code))
            }
        }
    }

    enum SelfTest {
        static let notRun: UInt8 = 0, pass: UInt8 = 1, fail: UInt8 = 2
    }

    enum PadSource: UInt8 {
        case none = 0, userClient = 1, tap = 2
    }

    enum Limit {
        static let maxDescriptor = 1024
        static let maxReport = 64
        static let maxInputReports = 4
        static let maxNeutral = 256
    }

    /// DeviceSpec blob layout (header 256 bytes, then descriptor, then neutral reports).
    enum Spec {
        static let magic: UInt32 = 0x5348_4447          // bytes 'G' 'D' 'H' 'S'
        static let headerSize = 256
        static let flagHIDDefaultBehavior: UInt8 = 1
    }

    /// Where the app's `DextClient` finds the dext's root service: a service of class IOUserService that has both of these
    /// properties. `IOUserServerName` alone is not enough from T4 on, when a second service of the same dext (the receiver
    /// tap) carries the same server name.
    static let rootUserClass = "GDHubVirtualHID"

    enum Offset {
        static let magic = 0
        static let version = 4
        static let headerSize = 6
        static let slot = 8
        static let flags = 9
        static let inputCount = 10
        static let vendor = 12
        static let product = 16
        static let versionNumber = 20
        static let country = 24
        static let location = 28
        static let intervalUs = 32
        static let usagePage = 36
        static let usage = 40
        static let descLen = 44
        static let neutralLen = 46
        static let inputTable = 48          // 4 x { u8 reportID, u8 sendLength, u16 lengthInclID }
        static let transport = 64
        static let manufacturer = 96
        static let productName = 128
        static let serial = 192
    }

    enum Length {
        static let inputTableEntry = 4
        static let transport = 32
        static let manufacturer = 32
        static let productName = 64
        static let serial = 32
    }

    /// Async output notification: `outputArgCount` words, see `OutputReport.init(words:)`.
    static let outputArgCount = 10

    // IOReturn codes the protocol uses (IOKit's iokit_common_err values).
    static let krNotPermitted: kern_return_t = kern_return_t(bitPattern: 0xE000_02E2)
    static let krExclusiveAccess: kern_return_t = kern_return_t(bitPattern: 0xE000_02C5)
    static let krBadArgument: kern_return_t = kern_return_t(bitPattern: 0xE000_02C2)
    static let krBusy: kern_return_t = kern_return_t(bitPattern: 0xE000_02D5)
    static let krUnsupported: kern_return_t = kern_return_t(bitPattern: 0xE000_02C7)
    static let krNotReady: kern_return_t = kern_return_t(bitPattern: 0xE000_02D8)
}

// MARK: - GDHubStatus2 (T3 subset)

/// Summary of one dext histogram over its last completed 10 s window, in nanoseconds (bucket upper edges, clamped to the max).
struct DextMeterSummary: Equatable {
    var count: UInt32 = 0, p50Ns: UInt32 = 0, p99Ns: UInt32 = 0, maxNs: UInt32 = 0, meanNs: UInt32 = 0

    /// "p50/p99/max/mean" in microseconds: the percentiles and the maximum in whole microseconds (rounded to nearest; the
    /// dext's smallest bucket edge is 1 us), the mean exact to a tenth, truncated.
    var microsecondsText: String {
        func us(_ ns: UInt32) -> Int { Int((Double(ns) / 1000).rounded()) }
        return "\(us(p50Ns))/\(us(p99Ns))/\(us(maxNs))/\(meanNs / 1000).\((meanNs % 1000) / 100)"
    }
}

/// `getStatus2` (selector 11), mirror of GDHUB_ST2_* in GDHubProtocol.h. Decoded by offset; a buffer shorter than the
/// dext wrote, or longer than this app knows, both decode: fields beyond min(declared size, bytes received) read as 0.
struct DextStatus2: Equatable {
    enum Offset {
        static let version = 0, size = 2, build = 4, nonce = 8, rootPid = 16
        static let desiredState = 20, padSource = 21, padLive = 22, ownerPresent = 23
        static let ucPosts = 24, ucRejected = 32, neutralPosts = 40, postErrors = 48, syncViolations = 56
        static let padCreates = 64, padDestroys = 72, createFails = 80, outputsSeen = 88, outputsNoOwner = 96, createEarly = 104
        static let padSpecCRC = 112, meterWindows = 116
        static let hopCount = 120, hopP50 = 124, hopP99 = 128, hopMax = 132, hopMean = 136
        static let hrCount = 140, hrP50 = 144, hrP99 = 148, hrMax = 152, hrMean = 156
        static let syncInline = 160, topology = 168, probeExt = 169, probeSubmit = 170
        static let tapPresent = 172, tapOpened = 173, appliedState = 174, powered = 175
        static let tapPid = 176, tapStarts = 180, lastPowerFlags = 184, lastError = 188
        static let framesIn = 192, framesR06 = 200, framesOther = 208, framesIgnored = 216, framesBad = 224
        static let poolMiss = 232, readdFail = 240, openFailures = 248
        static let k2dCount = 256, k2dP50 = 260, k2dP99 = 264, k2dMax = 268, k2dMean = 272
        static let pokesRun = 276, tickApplies = 284, closeFailures = 292, reopens = 300, tapFrees = 308
        static let selfTest = 316, translating = 317, hasMap = 318
        static let acceptedRevision = 320, appliedRevision = 324, acceptedSpecCRC = 328
        static let framesTranslated = 336, framesSkipped = 344, framesNoMap = 352, framesUnmapped = 360
        static let statesChanged = 368, reportsWouldPost = 376, mapAccepted = 384, mapRefused = 392, mapSwaps = 400
        static let xlateCount = 408, xlateP50 = 412, xlateP99 = 416, xlateMax = 420, xlateMean = 424
        static let parityCount = 428, parityRevision = 432, parityTimestamp = 436
        static let parityFrame = 444, parityOut01 = 460, parityOut02 = 476
        // T7
        static let holdNeutral = 480, padOrphaned = 481, paused = 482
        static let tapPosts = 484, tapRejected = 492, tapSubmitErrors = 500, framesUnchanged = 508
        static let switchNeutrals = 516, stopNeutrals = 524, silenceNeutrals = 532, powerNeutrals = 540, holdNeutrals = 548
        static let adopts = 556, orphanDestroys = 564, pauseDrops = 572, sourceSwitches = 580, liveNoPad = 588
        static let totalCount = 596, totalP50 = 600, totalP99 = 604, totalMax = 608, totalMean = 612
        static let occCount = 616, occP50 = 620, occP99 = 624, occMax = 628, occMean = 632
        static let addPoolCount = 636, addPoolP50 = 640, addPoolP99 = 644, addPoolMax = 648, addPoolMean = 652
        static let submitCount = 656, submitP50 = 660, submitP99 = 664, submitMax = 668, submitMean = 672
    }
    static let version = 1
    static let size = 676
    static let maxSize = 1024
    /// version, size and build: the least a reader needs.
    static let minimumBytes = 8

    var version: UInt16 = 0
    var declaredSize: UInt16 = 0
    var build: UInt32 = 0
    var instanceNonce: UInt64 = 0
    var rootPid: UInt32 = 0
    var desiredState: UInt8 = 0
    var padSource: UInt8 = 0
    var padLive = false
    var ownerPresent = false
    var ucPosts: UInt64 = 0, ucRejected: UInt64 = 0, neutralPosts: UInt64 = 0, postErrors: UInt64 = 0
    var syncViolations: UInt64 = 0, padCreates: UInt64 = 0, padDestroys: UInt64 = 0, createFails: UInt64 = 0
    var outputsSeen: UInt64 = 0, outputsNoOwner: UInt64 = 0, createEarly: UInt64 = 0
    var padSpecCRC: UInt32 = 0
    var meterWindows: UInt32 = 0
    var syncInline: UInt64 = 0
    var topology: UInt8 = 0, probeExt: UInt8 = 0, probeSubmit: UInt8 = 0
    // T4 receiver tap
    var tapPresent = false, tapOpened = false, powered = false
    var appliedState: UInt8 = 0
    var tapPid: UInt32 = 0, tapStarts: UInt32 = 0, lastPowerFlags: UInt32 = 0, lastError: UInt32 = 0
    var framesIn: UInt64 = 0, framesR06: UInt64 = 0, framesOther: UInt64 = 0, framesIgnored: UInt64 = 0, framesBad: UInt64 = 0
    var poolMiss: UInt64 = 0, readdFail: UInt64 = 0, openFailures: UInt64 = 0
    var k2d = DextMeterSummary()
    var pokesRun: UInt64 = 0, tickApplies: UInt64 = 0, closeFailures: UInt64 = 0, reopens: UInt64 = 0, tapFrees: UInt64 = 0
    // T5 SHADOW
    var selfTest: UInt8 = 0
    var translating = false, hasMap = false
    var acceptedRevision: UInt32 = 0, appliedRevision: UInt32 = 0, acceptedSpecCRC: UInt32 = 0
    var framesTranslated: UInt64 = 0, framesSkipped: UInt64 = 0, framesNoMap: UInt64 = 0, framesUnmapped: UInt64 = 0
    var statesChanged: UInt64 = 0, reportsWouldPost: UInt64 = 0, mapAccepted: UInt64 = 0, mapRefused: UInt64 = 0, mapSwaps: UInt64 = 0
    var xlate = DextMeterSummary()
    // T7 LIVE
    var holdNeutral = false, padOrphaned = false, paused = false
    var tapPosts: UInt64 = 0, tapRejected: UInt64 = 0, tapSubmitErrors: UInt64 = 0, framesUnchanged: UInt64 = 0
    var switchNeutrals: UInt64 = 0, stopNeutrals: UInt64 = 0, silenceNeutrals: UInt64 = 0, powerNeutrals: UInt64 = 0, holdNeutrals: UInt64 = 0
    var adopts: UInt64 = 0, orphanDestroys: UInt64 = 0, pauseDrops: UInt64 = 0, sourceSwitches: UInt64 = 0, liveNoPad: UInt64 = 0
    var total = DextMeterSummary(), occ = DextMeterSummary(), addPool = DextMeterSummary(), submit = DextMeterSummary()
    var parity: DextParityRecord?
    var hop = DextMeterSummary()
    var hr = DextMeterSummary()

    var source: DextProtocol.PadSource? { DextProtocol.PadSource(rawValue: padSource) }

    /// nil if fewer than `minimumBytes` arrived or the structure claims a size or version this reader cannot use.
    static func decode(_ bytes: [UInt8]) -> DextStatus2? {
        guard bytes.count >= minimumBytes else { return nil }
        func le(_ off: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<n { v |= UInt64(bytes[off + i]) << UInt64(8 * i) }
            return v
        }
        let ver = UInt16(le(Offset.version, 2)), declared = UInt16(le(Offset.size, 2))
        guard ver >= 1, Int(declared) >= minimumBytes else { return nil }
        let valid = min(Int(declared), bytes.count)
        func u(_ off: Int, _ n: Int) -> UInt64 { off + n <= valid ? le(off, n) : 0 }
        var s = DextStatus2()
        s.version = ver; s.declaredSize = declared
        s.build = UInt32(u(Offset.build, 4)); s.instanceNonce = u(Offset.nonce, 8); s.rootPid = UInt32(u(Offset.rootPid, 4))
        s.desiredState = UInt8(u(Offset.desiredState, 1)); s.padSource = UInt8(u(Offset.padSource, 1))
        s.padLive = u(Offset.padLive, 1) != 0; s.ownerPresent = u(Offset.ownerPresent, 1) != 0
        s.ucPosts = u(Offset.ucPosts, 8); s.ucRejected = u(Offset.ucRejected, 8); s.neutralPosts = u(Offset.neutralPosts, 8)
        s.postErrors = u(Offset.postErrors, 8); s.syncViolations = u(Offset.syncViolations, 8)
        s.padCreates = u(Offset.padCreates, 8); s.padDestroys = u(Offset.padDestroys, 8); s.createFails = u(Offset.createFails, 8)
        s.outputsSeen = u(Offset.outputsSeen, 8); s.outputsNoOwner = u(Offset.outputsNoOwner, 8); s.createEarly = u(Offset.createEarly, 8)
        s.padSpecCRC = UInt32(u(Offset.padSpecCRC, 4)); s.meterWindows = UInt32(u(Offset.meterWindows, 4))
        s.hop = DextMeterSummary(count: UInt32(u(Offset.hopCount, 4)), p50Ns: UInt32(u(Offset.hopP50, 4)),
                                 p99Ns: UInt32(u(Offset.hopP99, 4)), maxNs: UInt32(u(Offset.hopMax, 4)),
                                 meanNs: UInt32(u(Offset.hopMean, 4)))
        s.hr = DextMeterSummary(count: UInt32(u(Offset.hrCount, 4)), p50Ns: UInt32(u(Offset.hrP50, 4)),
                                p99Ns: UInt32(u(Offset.hrP99, 4)), maxNs: UInt32(u(Offset.hrMax, 4)),
                                meanNs: UInt32(u(Offset.hrMean, 4)))
        s.syncInline = u(Offset.syncInline, 8)
        s.topology = UInt8(u(Offset.topology, 1)); s.probeExt = UInt8(u(Offset.probeExt, 1)); s.probeSubmit = UInt8(u(Offset.probeSubmit, 1))
        s.tapPresent = u(Offset.tapPresent, 1) != 0; s.tapOpened = u(Offset.tapOpened, 1) != 0
        s.appliedState = UInt8(u(Offset.appliedState, 1)); s.powered = u(Offset.powered, 1) != 0
        s.tapPid = UInt32(u(Offset.tapPid, 4)); s.tapStarts = UInt32(u(Offset.tapStarts, 4))
        s.lastPowerFlags = UInt32(u(Offset.lastPowerFlags, 4)); s.lastError = UInt32(u(Offset.lastError, 4))
        s.framesIn = u(Offset.framesIn, 8); s.framesR06 = u(Offset.framesR06, 8); s.framesOther = u(Offset.framesOther, 8)
        s.framesIgnored = u(Offset.framesIgnored, 8); s.framesBad = u(Offset.framesBad, 8)
        s.poolMiss = u(Offset.poolMiss, 8); s.readdFail = u(Offset.readdFail, 8); s.openFailures = u(Offset.openFailures, 8)
        s.k2d = DextMeterSummary(count: UInt32(u(Offset.k2dCount, 4)), p50Ns: UInt32(u(Offset.k2dP50, 4)),
                                 p99Ns: UInt32(u(Offset.k2dP99, 4)), maxNs: UInt32(u(Offset.k2dMax, 4)),
                                 meanNs: UInt32(u(Offset.k2dMean, 4)))
        s.pokesRun = u(Offset.pokesRun, 8); s.tickApplies = u(Offset.tickApplies, 8); s.closeFailures = u(Offset.closeFailures, 8)
        s.reopens = u(Offset.reopens, 8); s.tapFrees = u(Offset.tapFrees, 8)
        s.selfTest = UInt8(u(Offset.selfTest, 1)); s.translating = u(Offset.translating, 1) != 0; s.hasMap = u(Offset.hasMap, 1) != 0
        s.acceptedRevision = UInt32(u(Offset.acceptedRevision, 4)); s.appliedRevision = UInt32(u(Offset.appliedRevision, 4))
        s.acceptedSpecCRC = UInt32(u(Offset.acceptedSpecCRC, 4))
        s.framesTranslated = u(Offset.framesTranslated, 8); s.framesSkipped = u(Offset.framesSkipped, 8)
        s.framesNoMap = u(Offset.framesNoMap, 8); s.framesUnmapped = u(Offset.framesUnmapped, 8)
        s.statesChanged = u(Offset.statesChanged, 8); s.reportsWouldPost = u(Offset.reportsWouldPost, 8)
        s.mapAccepted = u(Offset.mapAccepted, 8); s.mapRefused = u(Offset.mapRefused, 8); s.mapSwaps = u(Offset.mapSwaps, 8)
        s.xlate = DextMeterSummary(count: UInt32(u(Offset.xlateCount, 4)), p50Ns: UInt32(u(Offset.xlateP50, 4)),
                                   p99Ns: UInt32(u(Offset.xlateP99, 4)), maxNs: UInt32(u(Offset.xlateMax, 4)),
                                   meanNs: UInt32(u(Offset.xlateMean, 4)))
        s.holdNeutral = u(Offset.holdNeutral, 1) != 0; s.padOrphaned = u(Offset.padOrphaned, 1) != 0; s.paused = u(Offset.paused, 1) != 0
        s.tapPosts = u(Offset.tapPosts, 8); s.tapRejected = u(Offset.tapRejected, 8); s.tapSubmitErrors = u(Offset.tapSubmitErrors, 8)
        s.framesUnchanged = u(Offset.framesUnchanged, 8); s.switchNeutrals = u(Offset.switchNeutrals, 8)
        s.stopNeutrals = u(Offset.stopNeutrals, 8); s.silenceNeutrals = u(Offset.silenceNeutrals, 8)
        s.powerNeutrals = u(Offset.powerNeutrals, 8); s.holdNeutrals = u(Offset.holdNeutrals, 8)
        s.adopts = u(Offset.adopts, 8); s.orphanDestroys = u(Offset.orphanDestroys, 8); s.pauseDrops = u(Offset.pauseDrops, 8)
        s.sourceSwitches = u(Offset.sourceSwitches, 8); s.liveNoPad = u(Offset.liveNoPad, 8)
        func summary(_ c: Int, _ a: Int, _ b: Int, _ m: Int, _ e: Int) -> DextMeterSummary {
            DextMeterSummary(count: UInt32(u(c, 4)), p50Ns: UInt32(u(a, 4)), p99Ns: UInt32(u(b, 4)), maxNs: UInt32(u(m, 4)), meanNs: UInt32(u(e, 4)))
        }
        s.total = summary(Offset.totalCount, Offset.totalP50, Offset.totalP99, Offset.totalMax, Offset.totalMean)
        s.occ = summary(Offset.occCount, Offset.occP50, Offset.occP99, Offset.occMax, Offset.occMean)
        s.addPool = summary(Offset.addPoolCount, Offset.addPoolP50, Offset.addPoolP99, Offset.addPoolMax, Offset.addPoolMean)
        s.submit = summary(Offset.submitCount, Offset.submitP50, Offset.submitP99, Offset.submitMax, Offset.submitMean)
        // the parity record exists only if the dext wrote that far and recorded a frame
        if Offset.parityOut02 + 2 <= valid, u(Offset.parityTimestamp, 8) != 0 {
            func bytes(_ off: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(u(off + $0, 1)) } }
            s.parity = DextParityRecord(count: UInt32(u(Offset.parityCount, 4)), revision: UInt32(u(Offset.parityRevision, 4)),
                                        timestamp: u(Offset.parityTimestamp, 8), frame: bytes(Offset.parityFrame, 16),
                                        out01: bytes(Offset.parityOut01, 16), out02: bytes(Offset.parityOut02, 2))
        }
        return s
    }

    /// The tap part of the engine's meter line: nil while no tap is attached. `state` is what was asked for / what is applied.
    var tapLogText: String? {
        guard tapPresent else { return nil }
        var t = "tap: state=\(desiredState)/\(appliedState) opened=\(tapOpened ? 1 : 0) frames=\(framesIn) r06=\(framesR06)"
        if framesOther > 0 { t += " other=\(framesOther)" }
        if poolMiss > 0 { t += " poolMiss=\(poolMiss)" }
        if readdFail > 0 { t += " readdFail=\(readdFail)" }
        if openFailures > 0 { t += " openFail=\(openFailures)" }
        if closeFailures > 0 { t += " closeFail=\(closeFailures)" }
        if reopens > 0 { t += " reopens=\(reopens)" }
        if tapStarts > 0 { t += " starts=\(tapStarts) frees=\(tapFrees)" }   // starts == frees + live instances when nothing leaks
        if k2d.count > 0 { t += " k2d p50/p99/max/mean \(k2d.microsecondsText) us" }
        if framesTranslated > 0 || translating || appliedState == 2 {
            t += " shadow: xlate=\(framesTranslated) chg=\(statesChanged) rev=\(acceptedRevision)/\(appliedRevision)"
            if framesNoMap > 0 { t += " noMap=\(framesNoMap)" }
            if framesSkipped > 0 { t += " skipped=\(framesSkipped)" }
            if framesUnmapped > 0 { t += " unmapped=\(framesUnmapped)" }
            if xlate.count > 0 { t += " xl p50/p99/max \(xlate.p50Ns)/\(xlate.p99Ns)/\(xlate.maxNs) ns" }
        }
        if appliedState == 3 || tapPosts > 0 {
            t += " live: posts=\(tapPosts) rej=\(tapRejected) err=\(tapSubmitErrors) unch=\(framesUnchanged) src=\(padSource)"
            if total.count > 0 { t += " total p50/p99/max \(total.microsecondsText) us" }
        }
        if selfTest == DextProtocol.SelfTest.fail { t += " selftest=FAIL" }
        if tapPid != 0 && tapPid != rootPid { t += " tapPid=\(tapPid)!=rootPid" }
        return t
    }

    /// Topology flags (`GDHUB_TOPO_*`): the two queues are the same object. nil while one side has not started yet.
    enum Topology {
        static let ucEqRoot: UInt8 = 0x01, padEqRoot: UInt8 = 0x02, padEqUC: UInt8 = 0x04, knownShift: UInt8 = 4
    }
    enum Probe {
        static let root: UInt8 = 0x01, uc: UInt8 = 0x02, pad: UInt8 = 0x04, valid: UInt8 = 0x80
    }

    func isSame(_ bit: UInt8) -> Bool? { topology & (bit << Topology.knownShift) == 0 ? nil : topology & bit != 0 }

    /// "dext topo: uc=root:1 pad=root:0 pad=uc:0" ("?" while unknown); nil when nothing is known yet.
    var topologyText: String? {
        guard topology >> Topology.knownShift != 0 else { return nil }
        func f(_ b: Bool?) -> String { b.map { $0 ? "1" : "0" } ?? "?" }
        return "dext topo: uc=root:\(f(isSame(Topology.ucEqRoot))) pad=root:\(f(isSame(Topology.padEqRoot))) pad=uc:\(f(isSame(Topology.padEqUC)))"
    }

    /// The part of the engine's meter line that comes from the dext; nil until the dext has closed a 10 s window with posts.
    var meterLogText: String? {
        var parts: [String] = []
        if hr.count > 0 {
            parts.append("dext: hop p50/p99/max/mean \(hop.microsecondsText) us hr \(hr.microsecondsText) us n=\(hr.count) win=\(meterWindows)")
        }
        if let t = topologyText { parts.append(t) }
        if let t = tapLogText { parts.append(t) }
        if syncViolations > 0 { parts.append("syncViolations=\(syncViolations)") }
        if syncInline > 0 { parts.append("syncInline=\(syncInline)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The last frame the dext's tap translated in SHADOW: the raw report, and the stateless `gdx_eval` + `gdx_build` result for it
/// (report 0 and report 1 of the mapping: xbox-bt16's 0x01 of 16 bytes and 0x02 of 2 bytes), with the frame's kernel timestamp.
struct DextParityRecord: Equatable {
    var count: UInt32
    var revision: UInt32
    var timestamp: UInt64
    var frame: [UInt8]
    var out01: [UInt8]
    var out02: [UInt8]
}

/// Outputs of `createDevice2`.
struct DextCreate2Result: Equatable {
    var adopted: Bool
    var padSource: UInt64
    init(words: [UInt64]) {
        let w = words + [UInt64](repeating: 0, count: 2)
        adopted = w[0] != 0; padSource = w[1]
    }
}

/// Outputs of `setMapping`.
struct DextMappingResult: Equatable {
    var acceptedRevision: UInt32
    var reason: UInt32
    var accepted: Bool { reason == DextProtocol.MapReason.ok && acceptedRevision != 0 }
    init(words: [UInt64]) {
        let w = words + [UInt64](repeating: 0, count: 2)
        acceptedRevision = UInt32(truncatingIfNeeded: w[0]); reason = UInt32(truncatingIfNeeded: w[1])
    }
}

/// Outputs of `setForwarding`.
struct DextForwardingResult: Equatable {
    var appliedState: UInt64 = 0, tapPresent: UInt64 = 0, padSource: UInt64 = 0, lastError: UInt64 = 0
    static let scalarCount = 4
    init(words: [UInt64]) {
        let w = words + [UInt64](repeating: 0, count: Self.scalarCount)
        appliedState = w[0]; tapPresent = w[1]; padSource = w[2]; lastError = w[3]
    }
}

/// Error codes the dext returns, as Swift cases.
enum DextError: Error, Equatable, CustomStringConvertible {
    case notPermitted           // 0xE00002E2: caller is not team 79XF6HYX8A
    case exclusiveAccess        // 0xE00002C5: another client owns the dext
    case badArgument            // 0xE00002C2
    case busy                   // 0xE00002D5
    case unsupported            // 0xE00002C7
    case notReady               // 0xE00002D8
    case other(kern_return_t)

    init(_ kr: kern_return_t) {
        switch kr {
        case DextProtocol.krNotPermitted: self = .notPermitted
        case DextProtocol.krExclusiveAccess: self = .exclusiveAccess
        case DextProtocol.krBadArgument: self = .badArgument
        case DextProtocol.krBusy: self = .busy
        case DextProtocol.krUnsupported: self = .unsupported
        case DextProtocol.krNotReady: self = .notReady
        default: self = .other(kr)
        }
    }

    var code: kern_return_t {
        switch self {
        case .notPermitted: return DextProtocol.krNotPermitted
        case .exclusiveAccess: return DextProtocol.krExclusiveAccess
        case .badArgument: return DextProtocol.krBadArgument
        case .busy: return DextProtocol.krBusy
        case .unsupported: return DextProtocol.krUnsupported
        case .notReady: return DextProtocol.krNotReady
        case .other(let kr): return kr
        }
    }

    var description: String {
        let hex = "0x" + String(UInt32(bitPattern: code), radix: 16, uppercase: true)
        switch self {
        case .notPermitted: return "not permitted (\(hex))"
        case .exclusiveAccess: return "already owned by another client (\(hex))"
        case .badArgument: return "bad argument (\(hex))"
        case .busy: return "busy (\(hex))"
        case .unsupported: return "unsupported (\(hex))"
        case .notReady: return "not ready (\(hex))"
        case .other: return "error \(hex)"
        }
    }
}

/// `getStatus` scalar outputs.
struct DextStatus: Equatable {
    var deviceMask: UInt64
    var postCount: UInt64
    var watchdogFires: UInt64
    var outputCount: UInt64
    var outputDrops: UInt64
    static let scalarCount = 5

    init(words: [UInt64]) {
        let w = words + [UInt64](repeating: 0, count: Self.scalarCount)
        deviceMask = w[0]; postCount = w[1]; watchdogFires = w[2]; outputCount = w[3]; outputDrops = w[4]
    }
}

/// `hello` scalar outputs.
struct DextHello: Equatable {
    var protocolVersion: UInt64
    var dextBuild: UInt64
    var capabilities: UInt64
    static let scalarCount = 3

    var hasRootPad: Bool { capabilities & DextProtocol.Capability.rootPad != 0 }
}

/// One output report delivered through the `registerOutput` completion (design §3.8).
/// args[0] = slot | type<<8 | reportID<<16 | length<<24 | truncated<<40, args[1...8] = payload (8 bytes per word,
/// little-endian, max 64), args[9] = sequence.
struct OutputReport: Equatable {
    var slot: UInt8
    var type: UInt8
    var reportID: UInt8
    var truncated: Bool
    var bytes: [UInt8]
    var sequence: UInt64

    init?(words w: [UInt64]) {
        guard w.count >= DextProtocol.outputArgCount else { return nil }
        slot = UInt8(w[0] & 0xFF)
        type = UInt8((w[0] >> 8) & 0xFF)
        reportID = UInt8((w[0] >> 16) & 0xFF)
        let len = min(Int((w[0] >> 24) & 0xFFFF), DextProtocol.Limit.maxReport)
        truncated = (w[0] >> 40) & 1 != 0
        var out = [UInt8](); out.reserveCapacity(len)
        for i in 0..<len { out.append(UInt8((w[1 + i / 8] >> UInt64(8 * (i % 8))) & 0xFF)) }
        bytes = out
        sequence = w[9]
    }
}

// MARK: - DeviceSpec (design §5.3)

enum DeviceSpecError: Error, Equatable, CustomStringConvertible {
    case descriptorSize(Int)
    case inputReports(Int)
    case reportLength(id: UInt8, length: Int)
    case sendLengthNotInput(UInt8)
    case sendLengthOutOfRange(id: UInt8, send: Int)
    case reportIDZeroWithMultipleInputs
    case neutralCount(expected: Int, got: Int)
    case neutralLength(id: UInt8, expected: Int, got: Int)
    case neutralMissingID(UInt8)
    case neutralTotal(Int)
    case stringTooLong(field: String, max: Int)
    case emptyTransport

    var description: String {
        switch self {
        case .descriptorSize(let n): return "descriptor size \(n) not in 1...\(DextProtocol.Limit.maxDescriptor)"
        case .inputReports(let n): return "\(n) input reports (need 1...\(DextProtocol.Limit.maxInputReports))"
        case .reportLength(let id, let l): return "input report 0x\(String(id, radix: 16)) length \(l) not in 1...\(DextProtocol.Limit.maxReport)"
        case .sendLengthNotInput(let id): return "send length for 0x\(String(id, radix: 16)), which is not an input report"
        case .sendLengthOutOfRange(let id, let s): return "send length \(s) for 0x\(String(id, radix: 16)) outside its declared length...largest input"
        case .reportIDZeroWithMultipleInputs: return "report ID 0 with more than one input report"
        case .neutralCount(let e, let g): return "\(g) neutral reports, expected \(e)"
        case .neutralLength(let id, let e, let g): return "neutral report 0x\(String(id, radix: 16)) is \(g) bytes, expected its send length \(e)"
        case .neutralMissingID(let id): return "neutral report does not start with 0x\(String(id, radix: 16))"
        case .neutralTotal(let n): return "neutral blob \(n) bytes exceeds \(DextProtocol.Limit.maxNeutral)"
        case .stringTooLong(let f, let m): return "\(f) must be shorter than \(m) bytes"
        case .emptyTransport: return "Transport must not be empty"
        }
    }
}

/// Everything the dext needs to publish one HID device. `encoded()` produces the createDevice blob and enforces
/// the same rules as `GDHubSpecValidate` (design §3.6).
struct DeviceSpec: Equatable {
    var slot: DextProtocol.Slot
    var flags: UInt8 = 0
    var vendorID: UInt32, productID: UInt32, versionNumber: UInt32
    var countryCode: UInt32 = 0, locationID: UInt32 = 0, reportIntervalUs: UInt32 = 4000
    var primaryUsagePage: UInt32 = 1, primaryUsage: UInt32 = 5
    var transport: String, manufacturer: String, product: String, serialNumber: String
    var descriptor: [UInt8]
    /// reportID → padded send length; only `xbox-pr208` ([0x01: 25]).
    var sendLengths: [UInt8: Int] = [:]
    /// One per `HIDReportSizer` input report, same order, each at its send length.
    var neutralReports: [[UInt8]]

    func encoded() throws -> [UInt8] {
        typealias O = DextProtocol.Offset
        typealias L = DextProtocol.Length
        guard (1...DextProtocol.Limit.maxDescriptor).contains(descriptor.count) else {
            throw DeviceSpecError.descriptorSize(descriptor.count)
        }
        let inputs = try HIDReportSizer.inputs(descriptor)
        guard (1...DextProtocol.Limit.maxInputReports).contains(inputs.count) else {
            throw DeviceSpecError.inputReports(inputs.count)
        }
        for r in inputs where !(1...DextProtocol.Limit.maxReport).contains(r.length) {
            throw DeviceSpecError.reportLength(id: r.id, length: r.length)
        }
        if inputs.contains(where: { $0.id == 0 }) && inputs.count != 1 { throw DeviceSpecError.reportIDZeroWithMultipleInputs }
        let maxLen = inputs.map(\.length).max() ?? 0
        for (id, send) in sendLengths {
            guard let r = inputs.first(where: { $0.id == id }) else { throw DeviceSpecError.sendLengthNotInput(id) }
            guard send >= r.length, send <= maxLen, send <= 255 else { throw DeviceSpecError.sendLengthOutOfRange(id: id, send: send) }
        }
        func send(_ r: HIDReportSizer.ReportSize) -> Int { sendLengths[r.id] ?? r.length }
        guard neutralReports.count == inputs.count else {
            throw DeviceSpecError.neutralCount(expected: inputs.count, got: neutralReports.count)
        }
        var neutralBlob: [UInt8] = []
        for (r, n) in zip(inputs, neutralReports) {
            guard n.count == send(r) else { throw DeviceSpecError.neutralLength(id: r.id, expected: send(r), got: n.count) }
            if r.id != 0 && n.first != r.id { throw DeviceSpecError.neutralMissingID(r.id) }
            neutralBlob += n
        }
        guard neutralBlob.count <= DextProtocol.Limit.maxNeutral else { throw DeviceSpecError.neutralTotal(neutralBlob.count) }
        guard !transport.isEmpty else { throw DeviceSpecError.emptyTransport }

        var out = [UInt8](repeating: 0, count: DextProtocol.Spec.headerSize)
        func put32(_ off: Int, _ v: UInt32) { for i in 0..<4 { out[off + i] = UInt8((v >> UInt32(8 * i)) & 0xFF) } }
        func put16(_ off: Int, _ v: Int) { out[off] = UInt8(v & 0xFF); out[off + 1] = UInt8((v >> 8) & 0xFF) }
        func putString(_ off: Int, _ len: Int, _ s: String, _ field: String) throws {
            let u = Array(s.utf8)
            guard u.count < len else { throw DeviceSpecError.stringTooLong(field: field, max: len) }
            for (i, b) in u.enumerated() { out[off + i] = b }
        }
        put32(O.magic, DextProtocol.Spec.magic)
        put16(O.version, DextProtocol.specVersion)
        put16(O.headerSize, DextProtocol.Spec.headerSize)
        out[O.slot] = slot.rawValue
        out[O.flags] = flags
        out[O.inputCount] = UInt8(inputs.count)
        put32(O.vendor, vendorID); put32(O.product, productID); put32(O.versionNumber, versionNumber)
        put32(O.country, countryCode); put32(O.location, locationID); put32(O.intervalUs, reportIntervalUs)
        put32(O.usagePage, primaryUsagePage); put32(O.usage, primaryUsage)
        put16(O.descLen, descriptor.count)
        put16(O.neutralLen, neutralBlob.count)
        for (i, r) in inputs.enumerated() {
            let base = O.inputTable + i * L.inputTableEntry
            out[base] = r.id
            out[base + 1] = UInt8(sendLengths[r.id] ?? 0)
            put16(base + 2, r.length)
        }
        try putString(O.transport, L.transport, transport, "Transport")
        try putString(O.manufacturer, L.manufacturer, manufacturer, "Manufacturer")
        try putString(O.productName, L.productName, product, "Product")
        try putString(O.serial, L.serial, serialNumber, "SerialNumber")
        return out + descriptor + neutralBlob
    }
}

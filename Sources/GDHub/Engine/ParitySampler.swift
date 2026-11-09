import Foundation
#if canImport(GDHubXlate)
import GDHubXlate
#endif

/// A ring of the engine's most recent controller frames, keyed by their kernel timestamp, so the parity sampler can find the
/// frame the dext's tap recorded. The reader's HID callback and the sampler both run on the engine's `vhidQueue`, so the ring
/// needs no lock. Recording is two stores and a 16-byte copy into preallocated memory (no allocation, nothing logged); it only
/// happens while `enabled` (SHADOW is armed).
final class FrameRing: @unchecked Sendable {
    /// 256 frames: at the receiver's ~1 kHz that is a quarter of a second, far more than the read latency of the dext's record.
    static let capacity = 256

    private let stamps: UnsafeMutablePointer<UInt64>
    private let bytes: UnsafeMutablePointer<UInt8>
    private var head = 0
    private var filled = 0
    /// Read by the hot path; written by the supervisor, both on `vhidQueue`.
    var enabled = false

    init() {
        stamps = .allocate(capacity: Self.capacity)
        stamps.initialize(repeating: 0, count: Self.capacity)
        bytes = .allocate(capacity: Self.capacity * 16)
        bytes.initialize(repeating: 0, count: Self.capacity * 16)
    }

    deinit { stamps.deallocate(); bytes.deallocate() }

    /// Hot path: a report 0x06 with its ID byte (16 bytes) and the kernel timestamp of the HID callback.
    @inline(__always)
    func record(timestamp: UInt64, report: UnsafePointer<UInt8>, length: Int) {
        guard length == 16 else { return }
        stamps[head] = timestamp
        (bytes + head * 16).update(from: report, count: 16)
        head = head + 1 == Self.capacity ? 0 : head + 1
        if filled < Self.capacity { filled += 1 }
    }

    /// The 16 bytes recorded with exactly this timestamp, newest first. nil when the frame is not (or no longer) in the ring.
    func find(timestamp: UInt64) -> [UInt8]? {
        guard timestamp != 0 else { return nil }
        var i = head
        for _ in 0..<filled {
            i = i == 0 ? Self.capacity - 1 : i - 1
            if stamps[i] == timestamp { return Array(UnsafeBufferPointer(start: bytes + i * 16, count: 16)) }
        }
        return nil
    }

    func reset() { head = 0; filled = 0 }
}

/// Compares the dext's parity record (what its tap translated for one frame) with what the engine's own C core gives for the
/// same frame. Exact byte equality of the stateless `gdx_eval` + `gdx_build` outputs, report by report.
///
/// How frames are matched: the dext records the kernel timestamp it was handed with the frame (ReportAvailable's argument); the
/// engine's HID callback receives the same kernel timestamp for the same report. A record is compared only if its timestamp is
/// in the ring. Frames that cannot be matched: the one the dext recorded after the engine's last callback (the engine read the
/// record microseconds before it saw that frame), and any frame the engine's reader did not receive (the sampler counts these
/// as `noMatch`, not as mismatches). A record translated with another mapping revision than the one in effect is `stale`.
final class ParitySampler {
    /// Parity counts as CHECKED only after this many exact matches; below it the line says so. A sampler that finds none of the
    /// driver's frames shows `ok=0 mismatch=0`, which must never read as "all good".
    static let checkedThreshold = 1000
    /// The no-match warning: more than 90 % of at least 40 comparisons found no frame in the ring.
    static let noMatchWarnAfter = 40

    struct Stats: Equatable {
        var matched = 0, mismatched = 0, noMatch = 0, stale = 0, frameDiffers = 0, unchangedRecord = 0, skipped = 0
        /// True once enough frames were compared exactly for "0 mismatches" to mean something.
        var isChecked: Bool { matched >= ParitySampler.checkedThreshold }
        var text: String {
            "parity: ok=\(matched) mismatch=\(mismatched) noMatch=\(noMatch) stale=\(stale) frameDiffers=\(frameDiffers) skipped=\(skipped)"
                + (isChecked ? " (checked)" : " (NOT checked: needs ok>=\(ParitySampler.checkedThreshold))")
        }
    }

    enum Outcome: Equatable {
        case matched
        case mismatch(engine: [UInt8], dext: [UInt8], frame: [UInt8], revision: UInt32)
        case noMatch
        case stale
        case unchanged           // the record has not moved since the last sample
        case frameDiffers(engine: [UInt8], dext: [UInt8])
        case skipped             // the pad identity's reports are not 16 and 2 bytes: the dext's record cannot be compared
    }

    let ring: FrameRing
    private(set) var stats = Stats()
    private var lastCount: UInt32?
    private var lastLogNs: UInt64 = 0
    private var loggedFirstMatch = false
    private var warnedNoMatch = false
    private var loggedSkip = false
    private let clock: () -> UInt64
    private let log: (String) -> Void
    /// Tests only: a stand-in for `core.reports(_:)`, to reach the identities the factory cannot produce.
    var reportsHook: ((XlateCore, gdx_pad) -> [PadReport])?

    init(ring: FrameRing = FrameRing(), clock: @escaping () -> UInt64 = LatencyMeter.nowNs, log: @escaping (String) -> Void = { _ in }) {
        self.ring = ring
        self.clock = clock
        self.log = log
    }

    func reset() {
        stats = Stats(); lastCount = nil; ring.reset()
        loggedFirstMatch = false; warnedNoMatch = false; loggedSkip = false
    }

    /// What the dext records for the reports of a map: the first 16 bytes of report 0 and the first 2 of report 1, zero padded
    /// (GDHubReceiverTap.cpp shadowFrame). Compared byte for byte with the same shape of the engine's reports.
    static func dextShape(_ reports: [PadReport]) -> (out01: [UInt8], out02: [UInt8]) {
        func fit(_ b: [UInt8]?, _ n: Int) -> [UInt8] { Array((b ?? []).prefix(n)) + [UInt8](repeating: 0, count: max(0, n - (b?.count ?? 0))) }
        return (fit(reports.count > 0 ? reports[0].bytes : nil, 16), fit(reports.count > 1 ? reports[1].bytes : nil, 2))
    }

    /// `core` is the engine's own core for the mapping revision `revision` that the dext was given.
    @discardableResult
    func sample(_ rec: DextParityRecord, core: XlateCore, revision: UInt32) -> Outcome {
        if lastCount == rec.count { stats.unchangedRecord += 1; return .unchanged }
        lastCount = rec.count
        guard rec.revision == revision else { stats.stale += 1; return .stale }
        guard let raw = ring.find(timestamp: rec.timestamp) else { stats.noMatch += 1; checkNoMatchRatio(); return .noMatch }
        guard raw == rec.frame else {
            stats.frameDiffers += 1
            report("parity: the frame at kernel time \(rec.timestamp) differs: engine \(Self.hex(raw)) dext \(Self.hex(rec.frame))")
            return .frameDiffers(engine: raw, dext: rec.frame)
        }
        guard let pad = core.eval(raw: raw) else { stats.noMatch += 1; checkNoMatchRatio(); return .noMatch }
        let reports = reportsHook?(core, pad) ?? core.reports(pad)
        guard reports.count >= 2, reports[0].bytes.count == 16, reports[1].bytes.count == 2 else {
            stats.skipped += 1
            if !loggedSkip { loggedSkip = true; log("parity: this pad identity's reports are not 16 and 2 bytes; the driver's record cannot be compared, parity is NOT being checked") }
            return .skipped
        }
        let shaped = Self.dextShape(reports)
        let engineOut = shaped.out01 + shaped.out02
        let dextOut = rec.out01 + rec.out02
        if engineOut == dextOut {
            stats.matched += 1
            if !loggedFirstMatch { loggedFirstMatch = true; log("parity: first match, ts=\(rec.timestamp) (the engine's frame has the driver's kernel timestamp)") }
            return .matched
        }
        stats.mismatched += 1
        report("parity MISMATCH rev=\(rec.revision) frame \(Self.hex(raw)): engine \(Self.hex(engineOut)) dext \(Self.hex(dextOut))")
        return .mismatch(engine: engineOut, dext: dextOut, frame: raw, revision: rec.revision)
    }

    /// One warning, not a stream: if the driver's frames are mostly not found, the two kernel timestamps probably differ and
    /// nothing is being compared.
    private func checkNoMatchRatio() {
        let compared = stats.matched + stats.mismatched + stats.noMatch + stats.frameDiffers
        guard !warnedNoMatch, compared >= Self.noMatchWarnAfter, stats.noMatch * 10 > compared * 9 else { return }
        warnedNoMatch = true
        log("parity: the driver's frames are not found in the engine's ring (timestamps differ?) \u{2014} parity is NOT being checked")
    }

    /// At most one line per second; every mismatch is still counted.
    private func report(_ line: String) {
        let now = clock()
        guard lastLogNs == 0 || now &- lastLogNs >= 1_000_000_000 else { return }
        lastLogNs = now
        log(line)
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

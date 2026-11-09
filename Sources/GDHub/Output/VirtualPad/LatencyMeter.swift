import Foundation
import Darwin

/// Per-frame timestamps that travel from the HID callback to the sink (docs/plans/latency-plan.md §3). All values are
/// nanoseconds on the `CLOCK_UPTIME_RAW` timeline (= `mach_absolute_time`). 0 means "not stamped".
struct LatencyStamp {
    var tK: UInt64 = 0          // IOHID kernel timestamp of the report
    var tC: UInt64 = 0          // HID callback entry
    var tD: UInt64 = 0          // sink `drainMailbox` entry (set by the sink)
}

/// The numbers shown in the Driver menu and written to the `latency` log, computed over the last 10 s.
struct LatencySnapshot: Equatable, Sendable {
    struct Percentiles: Equatable, Sendable {
        var p50 = 0.0, p95 = 0.0, p99 = 0.0, max = 0.0      // milliseconds
    }
    var samples = 0                 // posted frames in the window
    var everSeen = false            // at least one frame has been posted since the meter was created
    var total = Percentiles()       // tR − tK (kernel timestamp to IOConnect return)
    var kernelToCallback = Percentiles()    // tC − tK
    var kernelToDrain = Percentiles()       // tD − tK (the gate for fix 3b)
    var cap = Percentiles()         // tS − tD (rate cap and trailing flush)
    var ioconnect = Percentiles()   // tR − tS
    var postsHz = 0.0
    var coalescedPercent = 0.0
    var framesInHz = 0.0
    var napped = false
    /// Worst `total` among frames whose `tD` fell within 2 ms after a status-poller tick; nil if none did.
    var pollerWorstMs: Double?

    static func fmt(_ v: Double) -> String { String(format: v < 10 ? "%.2f" : "%.1f", v) }

    /// Driver menu lines (disabled items).
    var menuLines: [String] {
        guard samples > 0 else {
            return [everSeen ? "Latency: no input in the last 10 s" : "Latency: no input yet"]
        }
        let f = Self.fmt
        return [
            "Latency (10 s): total p50 \(f(total.p50)) · p95 \(f(total.p95)) · max \(f(total.max)) ms",
            "HID→cb / →drain / cap / IOConnect: p50 \(f(kernelToCallback.p50)) / \(f(kernelToDrain.p50)) / \(f(cap.p50)) / \(f(ioconnect.p50))"
                + " · p99 \(f(kernelToCallback.p99)) / \(f(kernelToDrain.p99)) / \(f(cap.p99)) / \(f(ioconnect.p99)) ms",
            "Posts \(Int(postsHz.rounded())) Hz · coalesced \(Int(coalescedPercent.rounded())) % · App Nap: \(napped ? "YES" : "no")",
        ]
    }

    /// One `os_log` line (subsystem com.interlinked.gdhub, category latency).
    var logLine: String {
        let f = Self.fmt
        return "total \(f(total.p50))/\(f(total.p95))/\(f(total.p99))/\(f(total.max)) ms"
            + " drain \(f(kernelToDrain.p50))/\(f(kernelToDrain.p99))/\(f(kernelToDrain.max))"
            + " cb \(f(kernelToCallback.p50))/\(f(kernelToCallback.p99))"
            + " cap \(f(cap.p50))/\(f(cap.p99))/\(f(cap.max))"
            + " io \(f(ioconnect.p50))/\(f(ioconnect.p99))/\(f(ioconnect.max))"
            + " n=\(samples) posts=\(Int(postsHz.rounded()))Hz coalesced=\(Int(coalescedPercent.rounded()))%"
            + " frames=\(Int(framesInHz.rounded()))Hz nap=\(napped ? "yes" : "no")"
            + " pollerWorst=\(pollerWorstMs.map(f) ?? "-")"
    }
}

/// A copy of the meter's last 10 s, taken on the sink's queue and turned into a snapshot elsewhere.
struct LatencyWindow {
    var entries: [UInt64] = []      // 5 words per posted frame: tK, tC, tD, tS, tR
    var ticks: [UInt64] = []        // status-poller tick times
    var everSeen = false
    var spanSeconds = 0.0           // length of the counter window (0 until two collections exist)
    var changed: UInt64 = 0, coalesced: UInt64 = 0, flushes: UInt64 = 0, frames: UInt64 = 0
    var napped = false
}

/// Latency meter for the virtual-pad path (plan §3). Written only on the sink's queue: `record` costs five stores into
/// a preallocated ring (no allocation, no lock). The status poller calls `collect` once a second on the same queue;
/// the sorting happens elsewhere (`snapshot(from:)`).
final class LatencyMeter: @unchecked Sendable {
    static let ringCapacity = 4096
    static let windowNs: UInt64 = 10_000_000_000
    static let pollerWindowNs: UInt64 = 2_000_000
    private static let wordsPerEntry = 5
    private static let tickSlots = 16
    private static let historySlots = 12

    struct Entry: Equatable { var tK, tC, tD, tS, tR: UInt64 }

    private let clock: () -> UInt64
    private let ring: UnsafeMutablePointer<UInt64>
    private var head = 0                // next slot to write
    private var filled = 0
    private var ticks = [UInt64](repeating: 0, count: LatencyMeter.tickSlots)
    private var tickHead = 0

    // Cumulative counters (queue-confined) and their once-a-second history.
    private(set) var changed: UInt64 = 0        // distinct states that passed the deadband
    private(set) var coalesced: UInt64 = 0      // pending states replaced before they were sent
    private(set) var flushes: UInt64 = 0        // flushes that posted
    private struct Mark { var t: UInt64; var changed, coalesced, flushes, frames: UInt64 }
    private var history: [Mark] = []

    init(clock: @escaping () -> UInt64 = LatencyMeter.nowNs) {
        self.clock = clock
        ring = .allocate(capacity: Self.ringCapacity * Self.wordsPerEntry)
        ring.initialize(repeating: 0, count: Self.ringCapacity * Self.wordsPerEntry)
        history.reserveCapacity(Self.historySlots + 1)
    }

    deinit { ring.deallocate() }

    // MARK: Clock

    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
    }()

    /// Converts a `mach_absolute_time` value (the IOHID report timestamp) to nanoseconds.
    static func nanos(fromMach ticks: UInt64) -> UInt64 {
        let tb = timebase
        return tb.numer == tb.denom ? ticks : ticks * UInt64(tb.numer) / UInt64(tb.denom)
    }

    // MARK: Write path (sink queue)

    func noteChanged() { changed &+= 1 }
    func noteCoalesced() { coalesced &+= 1 }

    /// Records one posted frame.
    func record(tK: UInt64, tC: UInt64, tD: UInt64, tS: UInt64, tR: UInt64) {
        let p = ring + head * Self.wordsPerEntry
        p[0] = tK; p[1] = tC; p[2] = tD; p[3] = tS; p[4] = tR
        head = head + 1 == Self.ringCapacity ? 0 : head + 1
        if filled < Self.ringCapacity { filled += 1 }
        flushes &+= 1
    }

    /// The status poller is about to run: frames drained within 2 ms after this are checked for added jitter.
    func markPollerTick() {
        ticks[tickHead] = clock()
        tickHead = (tickHead + 1) % Self.tickSlots
    }

    /// Recorded frames, oldest first (tests).
    func entries() -> [Entry] {
        (0..<filled).map { i in
            let slot = (head - filled + i + Self.ringCapacity) % Self.ringCapacity
            let p = ring + slot * Self.wordsPerEntry
            return Entry(tK: p[0], tC: p[1], tD: p[2], tS: p[3], tR: p[4])
        }
    }

    // MARK: Collect (sink queue, once a second)

    func collect(framesReceived: Int, napped: Bool) -> LatencyWindow {
        let now = clock()
        var w = LatencyWindow()
        w.napped = napped
        w.everSeen = flushes > 0
        // Entries whose tR is within the last 10 s, newest first from the ring, copied oldest first.
        var n = 0
        while n < filled {
            let slot = (head - 1 - n + Self.ringCapacity) % Self.ringCapacity
            let tR = ring[slot * Self.wordsPerEntry + 4]
            if now > tR, now - tR > Self.windowNs { break }
            n += 1
        }
        w.entries.reserveCapacity(n * Self.wordsPerEntry)
        for i in 0..<n {
            let slot = (head - n + i + Self.ringCapacity) % Self.ringCapacity
            w.entries.append(contentsOf: UnsafeBufferPointer(start: ring + slot * Self.wordsPerEntry, count: Self.wordsPerEntry))
        }
        w.ticks = ticks.filter { $0 != 0 && (now < $0 || now - $0 <= Self.windowNs + Self.pollerWindowNs) }

        // Counters: delta against the oldest mark that is at most 10 s old.
        let mark = Mark(t: now, changed: changed, coalesced: coalesced, flushes: flushes, frames: UInt64(framesReceived))
        if let base = history.first(where: { now - $0.t <= Self.windowNs + 500_000_000 }), now > base.t {
            w.spanSeconds = Double(now - base.t) / 1e9
            w.changed = mark.changed &- base.changed
            w.coalesced = mark.coalesced &- base.coalesced
            w.flushes = mark.flushes &- base.flushes
            w.frames = mark.frames &- base.frames
        }
        history.append(mark)
        if history.count > Self.historySlots { history.removeFirst(history.count - Self.historySlots) }
        return w
    }

    // MARK: Compute (any queue)

    /// Nearest-rank percentile of an ascending array: the smallest value with at least `p` percent of samples at or
    /// below it.
    static func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    static func snapshot(from w: LatencyWindow) -> LatencySnapshot {
        var s = LatencySnapshot()
        s.napped = w.napped
        s.everSeen = w.everSeen
        let n = w.entries.count / wordsPerEntry
        s.samples = n
        if w.spanSeconds > 0 {
            s.postsHz = Double(w.flushes) / w.spanSeconds
            s.framesInHz = Double(w.frames) / w.spanSeconds
            s.coalescedPercent = w.changed > 0 ? 100 * Double(w.coalesced) / Double(w.changed) : 0
        }
        guard n > 0 else { return s }

        var total = [UInt64](), cb = [UInt64](), drain = [UInt64](), cap = [UInt64](), io = [UInt64]()
        total.reserveCapacity(n); cb.reserveCapacity(n); drain.reserveCapacity(n); cap.reserveCapacity(n); io.reserveCapacity(n)
        func d(_ a: UInt64, _ b: UInt64) -> UInt64 { b > a ? b - a : 0 }
        var worst: UInt64?
        for i in 0..<n {
            let tK = w.entries[i * 5], tC = w.entries[i * 5 + 1], tD = w.entries[i * 5 + 2]
            let tS = w.entries[i * 5 + 3], tR = w.entries[i * 5 + 4]
            let t = d(tK, tR)
            total.append(t); cb.append(d(tK, tC)); drain.append(d(tK, tD)); cap.append(d(tD, tS)); io.append(d(tS, tR))
            if w.ticks.contains(where: { tD >= $0 && tD - $0 < pollerWindowNs }) { worst = max(worst ?? 0, t) }
        }
        func pct(_ v: [UInt64]) -> LatencySnapshot.Percentiles {
            let sorted = v.sorted()
            func ms(_ x: UInt64) -> Double { Double(x) / 1e6 }
            return .init(p50: ms(percentile(sorted, 50)), p95: ms(percentile(sorted, 95)),
                         p99: ms(percentile(sorted, 99)), max: ms(sorted[sorted.count - 1]))
        }
        s.total = pct(total); s.kernelToCallback = pct(cb); s.kernelToDrain = pct(drain)
        s.cap = pct(cap); s.ioconnect = pct(io)
        s.pollerWorstMs = worst.map { Double($0) / 1e6 }
        return s
    }

    // MARK: App Nap probe

    /// True when the calling thread's base priority is 4 (App Nap / darwinbg), which is what `napwatch` reports.
    /// Call it from a thread that normally runs at user-interactive QoS (the sink's queue).
    static func currentThreadIsNapped() -> Bool {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        var info = proc_threadinfo()
        let r = proc_pidinfo(getpid(), PROC_PIDTHREADINFO, tid, &info, Int32(MemoryLayout<proc_threadinfo>.size))
        return r > 0 && info.pth_priority <= 4
    }
}

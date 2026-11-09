import Foundation

/// Kernel-to-callback delay of EVERY controller report (not only the ones that change the pad), plus the largest gap
/// between two callbacks. The 960 Hz idle stream makes this the number that shows how the HID callback is scheduled,
/// whatever the player does. `record` runs in the HID callback: two stores into a preallocated ring, no allocation.
/// Written on one queue; `collect` runs on the same queue and copies the window for sorting elsewhere.
final class CallbackStat: @unchecked Sendable {
    static let capacity = 32_768            // 30 s of 1 kHz

    struct Window {
        var delaysNs: [UInt32] = []
        var frames: UInt64 = 0
        var maxGapNs: UInt64 = 0
        var spanNs: UInt64 = 0
    }

    struct Summary: Equatable {
        var frames: UInt64 = 0
        var hz = 0.0
        var p50 = 0.0, p95 = 0.0, p99 = 0.0, max = 0.0      // milliseconds
        var maxGapMs = 0.0

        var logText: String {
            let f = LatencySnapshot.fmt
            return "cb(all frames) n=\(frames) \(Int(hz.rounded()))Hz p50/p95/p99/max \(f(p50))/\(f(p95))/\(f(p99))/\(f(max)) ms maxGap \(f(maxGapMs)) ms"
        }
    }

    private let ring: UnsafeMutablePointer<UInt32>
    private var head = 0
    private var filled = 0
    private var frames: UInt64 = 0
    private var lastC: UInt64 = 0
    private var maxGap: UInt64 = 0
    private var sinceFrames: UInt64 = 0
    private var sinceAt: UInt64

    init(now: UInt64 = LatencyMeter.nowNs()) {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: 0, count: Self.capacity)
        sinceAt = now
    }

    deinit { ring.deallocate() }

    /// One report: `tK` kernel timestamp, `tC` callback entry (both ns on the uptime timeline).
    @inline(__always)
    func record(tK: UInt64, tC: UInt64) {
        let d = tC > tK ? tC &- tK : 0
        ring[head] = d > UInt64(UInt32.max) ? UInt32.max : UInt32(truncatingIfNeeded: d)
        head = head + 1 == Self.capacity ? 0 : head + 1
        if filled < Self.capacity { filled += 1 }
        frames &+= 1
        if lastC != 0, tC > lastC { maxGap = Swift.max(maxGap, tC &- lastC) }
        lastC = tC
    }

    /// Copies everything recorded since the previous `collect` (at most `capacity` delays) and resets the window.
    func collect(now: UInt64 = LatencyMeter.nowNs()) -> Window {
        var w = Window()
        let newFrames = frames &- sinceFrames
        let n = Int(Swift.min(newFrames, UInt64(filled)))
        w.delaysNs.reserveCapacity(n)
        for i in 0..<n {
            let slot = (head - n + i + Self.capacity) % Self.capacity
            w.delaysNs.append(ring[slot])
        }
        w.frames = newFrames
        w.maxGapNs = maxGap
        w.spanNs = now > sinceAt ? now - sinceAt : 0
        sinceFrames = frames
        sinceAt = now
        maxGap = 0
        return w
    }

    /// Sorting and percentiles (any queue).
    static func summary(of w: Window) -> Summary {
        var s = Summary()
        s.frames = w.frames
        if w.spanNs > 0 { s.hz = Double(w.frames) / (Double(w.spanNs) / 1e9) }
        s.maxGapMs = Double(w.maxGapNs) / 1e6
        guard !w.delaysNs.isEmpty else { return s }
        let sorted = w.delaysNs.map { UInt64($0) }.sorted()
        func ms(_ p: Double) -> Double { Double(LatencyMeter.percentile(sorted, p)) / 1e6 }
        s.p50 = ms(50); s.p95 = ms(95); s.p99 = ms(99)
        s.max = Double(sorted[sorted.count - 1]) / 1e6
        return s
    }
}

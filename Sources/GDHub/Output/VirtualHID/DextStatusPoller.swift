import Foundation
import os

/// What the Driver menu shows about live traffic.
struct PadStats: Equatable {
    var totalPosts: UInt64          // dext `postCount` (getStatus)
    var postsPerSecond: Double      // change of `postCount` since the previous poll
    var watchdogFires: UInt64
    var framesPerSecond: Double     // controller frames reaching the sink
}

/// Polls `getStatus` once a second while the dext connection is up (design §5.4: the menu shows the post rate and the
/// total from `getStatus`). Confined to `queue`; `onUpdate` is called on `queue`.
final class DextStatusPoller: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
    private static let latencyLog = Logger(subsystem: "com.interlinked.gdhub", category: "latency")
    private let queue: DispatchQueue
    private let dext: DextStatusSource
    private let sink: VirtualPadSink
    private var timer: DispatchSourceTimer?
    private var last: (posts: UInt64, frames: Int, at: UInt64)?
    var onUpdate: ((PadStats?) -> Void)?
    /// Latency snapshot of the last 10 s, once a second (called on a utility queue, not on `queue`); nil when polling stops.
    var onLatency: ((LatencySnapshot?) -> Void)?

    /// Sorting and formatting the latency window happens here, so the sink's queue only copies it.
    private let latencyQueue = DispatchQueue(label: "com.interlinked.gdhub.latency", qos: .utility)
    private let latencyLogEvery: Int        // polls (seconds) between `latency` log lines
    private var polls = 0

    init(queue: DispatchQueue, dext: DextStatusSource, sink: VirtualPadSink, latencyLogEvery: Int = 10) {
        self.queue = queue
        self.dext = dext
        self.sink = sink
        self.latencyLogEvery = max(latencyLogEvery, 1)
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard timer == nil else { return }
        last = nil
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        poll()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel(); timer = nil
        last = nil
        onUpdate?(nil)
        onLatency?(nil)
    }

    private func poll() {
        // The tick is marked first: frames drained just after it show whether this poll adds jitter (`pollerWorst`).
        sink.meter.markPollerTick()
        publishLatency()
        guard let s = dext.status() else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let frames = sink.framesReceived
        var pps = 0.0, fps = 0.0
        if let l = last, now > l.at {
            let dt = Double(now - l.at) / 1e9
            pps = Double(s.postCount &- l.posts) / dt
            fps = Double(frames - l.frames) / dt
        }
        last = (s.postCount, frames, now)
        Self.log.debug("traffic: \(Int(fps.rounded())) frames/s in, \(Int(pps.rounded())) posts/s out, total posts \(s.postCount), watchdog fires \(s.watchdogFires), mask \(s.deviceMask)")
        onUpdate?(PadStats(totalPosts: s.postCount, postsPerSecond: pps, watchdogFires: s.watchdogFires, framesPerSecond: fps))
    }
}

extension DextStatusPoller {
    /// Copies the meter's last 10 s on the sink's queue and hands the sorting to the utility queue.
    fileprivate func publishLatency() {
        let window = sink.meter.collect(framesReceived: sink.framesReceived, napped: LatencyMeter.currentThreadIsNapped())
        polls += 1
        let logNow = polls % latencyLogEvery == 0
        latencyQueue.async { [weak self] in
            let snapshot = LatencyMeter.snapshot(from: window)
            self?.onLatency?(snapshot)
            if logNow, snapshot.samples > 0 { Self.latencyLog.info("\(snapshot.logLine, privacy: .public)") }
        }
    }
}

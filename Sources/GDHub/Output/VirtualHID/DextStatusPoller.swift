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
    private let queue: DispatchQueue
    private let dext: DextClient
    private let sink: VirtualPadSink
    private var timer: DispatchSourceTimer?
    private var last: (posts: UInt64, frames: Int, at: UInt64)?
    var onUpdate: ((PadStats?) -> Void)?

    init(queue: DispatchQueue, dext: DextClient, sink: VirtualPadSink) {
        self.queue = queue
        self.dext = dext
        self.sink = sink
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
    }

    private func poll() {
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

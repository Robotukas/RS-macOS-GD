import Foundation
import Darwin
import os

/// Once a second, on the engine's vhidQueue: is this process being throttled (darwin background role, or a clamped
/// thread priority)? E1 only logs, at `.error`, on each transition. Reads `getpriority(PRIO_DARWIN_PROCESS)` and the
/// calling thread's base priority (`thread_info`), which is what `napwatch` reports.
final class ThrottleCheck: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private(set) var throttled = false
    private(set) var lastBasePriority: Int32 = 0

    /// Throttled when PRIO_DARWIN_BG is set or the thread's base priority is 4 or lower.
    static func isThrottled(backgroundFlag: Bool, basePriority: Int32) -> Bool {
        backgroundFlag || basePriority <= 4
    }

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// vhidQueue.
    func check() {
        let bg = getpriority(PRIO_DARWIN_PROCESS, 0) == 1
        let base: Int32 = LatencyMeter.currentThreadBasePriority() ?? 31
        lastBasePriority = base
        let now = Self.isThrottled(backgroundFlag: bg, basePriority: base)
        guard now != throttled else { return }
        throttled = now
        if now {
            Self.log.error("THROTTLED: darwin background=\(bg) base priority=\(base)")
        } else {
            Self.log.error("throttle cleared: base priority=\(base)")
        }
    }
}

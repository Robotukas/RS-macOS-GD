import Foundation

/// Tracks whether the SCUF is connected, asleep or streaming, from interface matching and report arrival. It mirrors
/// `EnvisionProDevice`: the first report makes the controller active, two seconds without reports make it asleep.
/// Confined to `queue`. The clock is injectable (nanoseconds); the production timer calls `tick()` every 0.5 s.
final class ControllerPresence: @unchecked Sendable {
    static let asleepAfterNs: UInt64 = 2_000_000_000

    private let queue: DispatchQueue?
    private let clock: () -> UInt64
    private var interfaces = 0
    private var timer: DispatchSourceTimer?
    private(set) var status: ControllerStatus = .disconnected
    private(set) var lastReportAt: UInt64?

    /// Called on `queue` whenever `status` changes.
    var onChange: ((ControllerStatus) -> Void)?
    /// Called on `queue` when the first matching interface appears (true) and when the last one goes away (false).
    var onInterface: ((Bool) -> Void)?

    init(queue: DispatchQueue? = nil, clock: @escaping () -> UInt64 = LatencyMeter.nowNs) {
        self.queue = queue
        self.clock = clock
    }

    private func set(_ new: ControllerStatus) {
        guard new != status else { return }
        status = new
        onChange?(new)
    }

    /// A matching HID interface appeared.
    func interfaceUp() {
        interfaces += 1
        if interfaces == 1 { onInterface?(true) }
        if status == .disconnected || status == .receiverIdle { set(.asleep) }
    }

    /// A matching HID interface went away. With the last one gone the controller is disconnected.
    func interfaceDown() {
        let before = interfaces
        interfaces = max(interfaces - 1, 0)
        if before > 0, interfaces == 0 { onInterface?(false) }
        if interfaces == 0 {
            lastReportAt = nil
            set(.disconnected)
        }
    }

    /// A report 0x06 arrived at `ns` (hot path: two stores, and a status change only on the first report).
    func report(atNs ns: UInt64) {
        lastReportAt = ns
        if status != .active { set(.active) }
    }

    /// Asleep after two seconds without a report.
    func tick() {
        guard status == .active, let last = lastReportAt else { return }
        let now = clock()
        if now > last, now - last >= Self.asleepAfterNs { set(.asleep) }
    }

    /// The Mac woke up: the pad stays neutral until real reports arrive.
    func didWake() {
        lastReportAt = nil
        if status == .active { set(.asleep) }
    }

    func startTimer() {
        guard let queue, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// System sleep and wake for the engine: the pad must be neutral before the Mac sleeps, and after wake it stays
/// neutral until real reports arrive. Notifications are delivered on `powerQueue` (plan §2); `powerQueue` may `sync`
/// onto `vhidQueue`, never the other way round.
final class PowerObserver: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")
    // iokit_common_msg(x) = 0xE0000000 | x; the macros are not imported into Swift.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300
    static let willSleepWait: TimeInterval = 1.0

    private let powerQueue = DispatchQueue(label: "com.interlinked.gdhub.power", qos: .userInitiated)
    private let vhidQueue: DispatchQueue
    private let willSleep: () -> Void           // runs on vhidQueue
    private let didWake: () -> Void             // runs on vhidQueue
    private var rootPort: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(vhidQueue: DispatchQueue, willSleep: @escaping () -> Void, didWake: @escaping () -> Void) {
        self.vhidQueue = vhidQueue
        self.willSleep = willSleep
        self.didWake = didWake
    }

    func start() {
        guard rootPort == 0 else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue()
                .handle(messageType: UInt32(messageType), argument: messageArgument)
        }, &notifier)
        guard rootPort != 0, let port else {
            Self.log.error("IORegisterForSystemPower failed")
            return
        }
        IONotificationPortSetDispatchQueue(port, powerQueue)
    }

    /// Runs `work` on `queue` asynchronously and waits at most `seconds` for it. True: it finished in time. False: the queue was busy
    /// or blocked (a driver call in flight); the caller goes on and `work` still runs when the queue gets to it.
    static func runWithin(_ seconds: TimeInterval, on queue: DispatchQueue, work: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { work(); done.signal() }
        return done.wait(timeout: .now() + seconds) == .success
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let arg = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, arg)
        case Self.systemWillSleep:
            // The neutral (and, in LIVE, the driver's hold) is asked for on vhidQueue with a wait of at most 1 s: a queue that is busy
            // or blocked in a driver call must not hold the sleep up. The driver's own SetPowerState(Off) neutral is the backstop.
            let timedOut = !Self.runWithin(Self.willSleepWait, on: vhidQueue, work: willSleep)
            Self.log.notice("will sleep: \(timedOut ? "neutral not confirmed within 1 s (the driver's SetPowerState neutral covers it)" : "pad neutral, hold", privacy: .public)")
            IOAllowPowerChange(rootPort, arg)
        case Self.systemHasPoweredOn:
            Self.log.notice("woke")
            vhidQueue.async { [didWake] in didWake() }
        default:
            break
        }
    }
}

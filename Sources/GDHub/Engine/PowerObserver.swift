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

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let arg = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, arg)
        case Self.systemWillSleep:
            vhidQueue.sync { willSleep() }
            Self.log.notice("will sleep: pad neutral")
            IOAllowPowerChange(rootPort, arg)
        case Self.systemHasPoweredOn:
            Self.log.notice("woke")
            vhidQueue.async { [didWake] in didWake() }
        default:
            break
        }
    }
}

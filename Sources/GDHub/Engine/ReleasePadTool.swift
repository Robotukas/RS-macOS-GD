import Foundation
import os

/// `GDHub --engine --engine-foreground --release-pad` (T7): says hello to the driver, sends `setForwarding(INERT, RELEASE_PAD)` and
/// exits. It is what `engine-agent.sh uninstall` runs after the engine job is gone, so a pad that the driver pinned (LIVE, owner
/// killed) is removed at once instead of after the 30 s orphan timer. It owns nothing afterwards: the hello's claim ends with the process.
///
/// The marker string below is how the script finds out, without running the app, that this build knows `--release-pad` (an older app
/// would start a full engine on that command line and never return).
enum ReleasePadTool {
    static let featureMarker = "gdhub-feature:release-pad-v1"
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")

    enum Outcome: Equatable {
        case released               // a pinned, unowned pad was there and is gone: exit 0
        case nonePinned             // the driver has none: exit 0
        case oldDriver              // no CAP_LIVE: there is nothing it could pin and nothing to release with: exit 1
        case noConnection           // exit 1
        case failed(Int32)          // the call failed: exit 1

        var exitCode: Int32 { switch self { case .released, .nonePinned: return 0; default: return 1 } }
        var message: String {
            switch self {
            case .released: return "release-pad: the pinned pad was removed"
            case .nonePinned: return "release-pad: no pinned pad (nothing to release)"
            case .oldDriver: return "release-pad: this driver has no pinned pads (older build), nothing released"
            case .noConnection: return "release-pad: no connection to the driver within the time allowed"
            case .failed(let kr): return "release-pad: the driver answered 0x\(String(UInt32(bitPattern: kr), radix: 16))"
            }
        }
    }

    /// What happened, from what the driver says before and after: `pinned` is the orphaned-pad flag of status2 before the call.
    static func outcome(hasLive: Bool, pinnedBefore: Bool, kr: kern_return_t) -> Outcome {
        guard hasLive else { return .oldDriver }
        guard kr == KERN_SUCCESS else { return .failed(kr) }
        return pinnedBefore ? .released : .nonePinned
    }

    static func run(timeout: TimeInterval = 5) -> Int32 {
        let queue = DispatchQueue(label: "com.interlinked.gdhub.releasepad", qos: .userInitiated)
        let client = DextClient(queue: queue, supervised: true)
        let connected = DispatchSemaphore(value: 0)
        queue.sync {
            client.onState = { state in if case .connected = state { connected.signal() } }
            client.start()
        }
        var result = Outcome.noConnection
        if connected.wait(timeout: .now() + timeout) == .success {
            result = queue.sync {
                let hasLive = client.hasLive
                let pinned = hasLive ? (client.status2()?.padOrphaned ?? false) : false
                let kr: kern_return_t = hasLive ? client.releasePad() : KERN_SUCCESS
                return outcome(hasLive: hasLive, pinnedBefore: pinned, kr: kr)
            }
        }
        log.notice("\(result.message, privacy: .public) [\(featureMarker, privacy: .public)]")
        print(result.message)                                   // the script shows this line
        queue.sync { client.stop() }
        return result.exitCode
    }
}

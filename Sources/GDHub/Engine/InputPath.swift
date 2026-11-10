import Foundation

/// The `inputPath` defaults key (`defaults write com.interlinked.gdhub inputPath -string count`): where the controller's
/// reports are read. `driver` (the default since T8, 2026-11-10: the dext's tap drives the pad, LIVE), `engine` (the engine
/// reads and posts, the dext's tap stays INERT), `count` (T4: the dext's tap
/// opens interface 3 and only counts frames) and `shadow` (T5: the tap also translates every report with the mapping the engine
/// pushed and records a parity sample; nothing is posted). The engine posts in all three, so nothing changes for games.
/// `driver` is the value of the later LIVE phase (T7): until the dext reports a LIVE capability it runs exactly as `shadow`, the
/// engine says so once in its log and the Driver menu says "live mode not available in this driver". Every other value is `engine`.
enum InputPath: String, Equatable, CaseIterable {
    case engine, count, shadow, driver

    static let defaultsKey = "inputPath"
    /// T6: `defaults write com.interlinked.gdhub tapDrill -string pause5` (read once per second, deleted when read).
    static let drillKey = "tapDrill"
    /// T6: set by the engine when the breaker or the fallback limiter stops the driver path (Double, epoch seconds). The Driver
    /// menu removes it when the owner picks the driver path again; `defaults delete com.interlinked.gdhub tapBreakerTrippedAt`
    /// does the same.
    static let breakerKey = "tapBreakerTrippedAt"
    static let breakerReasonKey = "tapBreakerReason"
    /// T6 review: a counter the Driver menu increments on EVERY pick, including the already selected item. The engine folds it
    /// into "the stored path changed", so re-picking Driver clears a trip, a final fallback and the latch even though the
    /// `inputPath` text itself did not change.
    static let choiceKey = "inputPathChoice"

    /// No value at all is the default, `driver` (T8, owner's decision of 2026-11-10 after the gate: faster on every row, the
    /// one miss being the 0.2 ms stick-onset margin). A non-string or an unknown string is `engine`: a value someone wrote
    /// that this build does not understand must not arm the driver. Case and surrounding spaces are ignored.
    init(defaultsValue: Any?) {
        guard let value = defaultsValue else { self = .driver; return }
        let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = raw.flatMap(InputPath.init(rawValue:)) ?? .engine
    }

    /// The `setForwarding` state this path asks of the dext in this build: COUNT for `count`, SHADOW for `shadow` and for `driver`
    /// (no LIVE yet), INERT for everything else.
    var forwardingState: UInt64 {
        switch self {
        case .count: return DextProtocol.Forwarding.count
        case .shadow, .driver: return DextProtocol.Forwarding.shadow
        case .engine: return DextProtocol.Forwarding.inert
        }
    }

    /// `driver` needs a later dext (LIVE); it runs as `shadow`, and the engine says so once in its log.
    var isRecognisedButNotYetSupported: Bool { self == .driver }

    /// The path asks the dext's tap to open the interface (the states that need the arming rules: nonce trip, owner only).
    var arms: Bool { self != .engine }
}

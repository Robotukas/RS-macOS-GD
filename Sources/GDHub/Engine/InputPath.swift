import Foundation

/// The `inputPath` defaults key (`defaults write com.interlinked.gdhub inputPath -string count`): where the controller's
/// reports are read. `engine` (the default: the engine reads and posts, the dext's tap stays INERT), `count` (T4: the dext's tap
/// opens interface 3 and only counts frames) and `shadow` (T5: the tap also translates every report with the mapping the engine
/// pushed and records a parity sample; nothing is posted). The engine posts in all three, so nothing changes for games.
/// `driver` is recognised for a later phase and runs as INERT in this build; every other value is `engine`.
enum InputPath: String, Equatable, CaseIterable {
    case engine, count, shadow, driver

    static let defaultsKey = "inputPath"

    /// nil, a non-string or an unknown string is `engine`. Case and surrounding spaces are ignored.
    init(defaultsValue: Any?) {
        let raw = (defaultsValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = raw.flatMap(InputPath.init(rawValue:)) ?? .engine
    }

    /// The `setForwarding` state this path asks of the dext in this build: COUNT for `count`, SHADOW for `shadow`, INERT for
    /// everything else.
    var forwardingState: UInt64 {
        switch self {
        case .count: return DextProtocol.Forwarding.count
        case .shadow: return DextProtocol.Forwarding.shadow
        case .engine, .driver: return DextProtocol.Forwarding.inert
        }
    }

    /// `driver` needs a later dext; it runs as INERT, and the engine says so once in its log.
    var isRecognisedButNotYetSupported: Bool { self == .driver }

    /// The path asks the dext's tap to open the interface (the states that need the arming rules: nonce trip, owner only).
    var arms: Bool { self == .count || self == .shadow }
}

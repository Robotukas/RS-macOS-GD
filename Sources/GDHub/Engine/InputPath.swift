import Foundation

/// The `inputPath` defaults key (`defaults write com.interlinked.gdhub inputPath -string count`): where the controller's
/// reports are read. T4 knows `engine` (the default: the engine reads and posts, the dext's tap stays INERT) and `count`
/// (the dext's tap opens interface 3 and only counts frames; the engine still posts, so nothing changes for games).
/// `shadow` and `driver` are recognised for later phases and run as INERT in this build; every other value is `engine`.
enum InputPath: String, Equatable, CaseIterable {
    case engine, count, shadow, driver

    static let defaultsKey = "inputPath"

    /// nil, a non-string or an unknown string is `engine`. Case and surrounding spaces are ignored.
    init(defaultsValue: Any?) {
        let raw = (defaultsValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = raw.flatMap(InputPath.init(rawValue:)) ?? .engine
    }

    /// The `setForwarding` state this path asks of the dext in this build: COUNT for `count`, INERT for everything else.
    var forwardingState: UInt64 {
        self == .count ? DextProtocol.Forwarding.count : DextProtocol.Forwarding.inert
    }

    /// `shadow` and `driver` need a later dext; they run as INERT, and the engine says so once in its log.
    var isRecognisedButNotYetSupported: Bool { self == .shadow || self == .driver }
}

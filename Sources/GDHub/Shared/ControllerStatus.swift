import Foundation

/// What the process that reads the SCUF knows about it. Shared by the GUI's `EnvisionProDevice` and the headless engine.
enum ControllerStatus: String, Codable, Sendable {
    case disconnected, receiverIdle, asleep, active

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .receiverIdle: return "Receiver idle (controller off)"
        case .asleep: return "Asleep"
        case .active: return "Connected"
        }
    }
}

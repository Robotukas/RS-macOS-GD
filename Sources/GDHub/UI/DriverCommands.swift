import SwiftUI

/// Driver menu: status line plus the actions that apply to the current state (design §5.1).
struct DriverCommands: View {
    @ObservedObject var driver: DriverManager

    var statusText: String {
        switch driver.state {
        case .checking: return "Checking driver…"
        case .notBundled: return "Driver not bundled (SwiftPM build): run scripts/build-xcode.sh"
        case .wrongLocation: return "Run GDHub from /Applications to install the driver"
        case .notInstalled: return "Driver not installed"
        case .activating: return "Installing…"
        case .updating(let a, let b): return "Updating driver \(a) → \(b)…"
        case .needsApproval: return "Allow \"GDHub Virtual HID\" in System Settings › General › Login Items & Extensions › Driver Extensions"
        case .active(let b): return "Driver active (build \(b))"
        case .rebootRequired: return "Restart the Mac to finish installing the driver"
        case .uninstalling: return "Removing driver…"
        case .failed(let c, let m): return "Driver error \(c): \(m)"
        }
    }

    var connectionText: String? {
        switch driver.connection {
        case .stopped: return nil
        case .waitingForService: return "Waiting for driver"
        case .connected(let build): return "Connected (driver build \(build))"
        case .rejected: return "Driver refused this app: not signed by team 79XF6HYX8A"
        case .exclusive: return "Another GDHub is connected"
        case .protocolMismatch(let dext): return "Driver protocol v\(dext), app v\(DextProtocol.version): update the driver"
        case .failed(let kr) where kr == DextProtocol.krUnsupported:
            return "An older driver build is still running: restart the Mac to finish the update"
        case .failed(let kr): return "Driver connection failed (0x\(String(UInt32(bitPattern: kr), radix: 16, uppercase: true)))"
        }
    }

    var body: some View {
        Text(statusText)
        if let connectionText { Text(connectionText) }
        Divider()
        switch driver.state {
        case .wrongLocation:
            Button("Reveal in Finder") { driver.revealInFinder() }
        case .notInstalled:
            Button("Install Driver") { driver.installOrUpdate() }
        case .needsApproval:
            Button("Open System Settings") { driver.openSystemSettings() }
        case .active:
            Button("Uninstall Driver") { driver.uninstall() }
        case .failed:
            Button("Retry") { driver.retry() }
        default:
            EmptyView()
        }
    }
}

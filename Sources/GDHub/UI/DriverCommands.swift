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

    var body: some View {
        Text(statusText)
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

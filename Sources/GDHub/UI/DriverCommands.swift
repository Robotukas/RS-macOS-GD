import SwiftUI

/// Driver menu: status line plus the actions that apply to the current state (design §5.1).
struct DriverCommands: View {
    @ObservedObject var driver: DriverManager
    /// Developer mode: a run owns the input path while it is on, so the menu is disabled then.
    var device: EnvisionProDevice?

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

    var padText: String {
        switch driver.padState {
        case .off: return "Virtual pad: not published"
        case .publishing(let id): return "Virtual pad: publishing \(id)…"
        case .published(let id): return "Virtual pad: \(id) published"
        case .blockedDuplicate(let d): return "Virtual pad blocked: \(d) already has this ID. Disconnect it or pick another identity"
        case .error(let e): return "Virtual pad error: \(e)"
        }
    }

    /// Live traffic line, shown while the pad is published: "Posts: 1,234 total, 0/s".
    var trafficText: String? {
        guard isPublished, let s = driver.padStats else { return nil }
        let rate = s.postsPerSecond < 10 ? String(format: "%.1f", s.postsPerSecond) : String(Int(s.postsPerSecond.rounded()))
        return "Posts: \(s.totalPosts) total, \(rate)/s (controller frames in: \(Int(s.framesPerSecond.rounded()))/s)"
    }

    /// Warning shown while macOS GameController has made its own Xbox 360 copy of the published pad.
    var syntheticWarning: String? {
        guard isPublished, driver.syntheticPadCount > 0 else { return nil }
        return "macOS made a 2nd pad (Xbox 360) from GDHub — Shadow forwards both"
    }

    /// Latency meter lines (latency plan §3), shown while the pad is published.
    var latencyLines: [String] {
        guard isPublished else { return [] }
        return (driver.latency ?? LatencySnapshot()).menuLines
    }

    var isConnected: Bool { if case .connected = driver.connection { return true } else { return false } }
    var isPublished: Bool { if case .published = driver.padState { return true } else { return false } }
    var connectionNeedsRetry: Bool {
        switch driver.connection {
        case .rejected, .exclusive, .failed, .protocolMismatch: return true
        default: return false
        }
    }

    var body: some View {
        switch driver.mode {
        case .displayOnly:
            Text("Display-only: the background engine owns the pad")
        case .engine:
            engineBody
        case .inApp:
            inAppBody
        }
    }

    // MARK: Engine mode (E1: read-only status, restart, uninstall; the driver items keep working)

    @ViewBuilder private var engineBody: some View {
        Text(driver.engineStatus.menuText)
        Text(driver.inputPathStatusText)
        if let device {
            DevRunWatcher(device: device) { inputPathMenu(devRunActive: $0) }
        } else {
            inputPathMenu(devRunActive: false)
        }
        Text("Pad is controlled by the background engine")
        Button("Restart engine") { driver.restartEngine() }
            .disabled(driver.engineUninstalled)
        Button("Uninstall background engine (relaunch to apply)") { driver.uninstallEngine() }
            .disabled(driver.engineUninstalled)
        if driver.engineUninstalled { Text("Quit and reopen GDHub to use the in-app engine") }
        Divider()
        Text(statusText)
        Divider()
        Toggle("Publish virtual pad when the controller is connected", isOn: .constant(true)).disabled(true)
        Menu("Publish virtual pad") { EmptyView() }.disabled(true)
        Button("Unpublish virtual pad") {}.disabled(true)
        Button("Test pattern") {}.disabled(true)
        Button("Restart driver (dev)") {}.disabled(true)
        Divider()
        driverButtons
    }

    /// T6: the choice writes the `inputPath` key the engine polls (App = engine, Driver (shadow) = the tap translates and is compared, Driver = LIVE once the driver reports it; a driver without LIVE runs it as shadow).
    /// Explicit buttons with a hand-drawn checkmark, not a `Picker`: a click on the item that is already selected must still
    /// reach the engine ("choose Driver to try again" after a fallback), and a Picker is not known to call its setter then.
    @ViewBuilder private func inputPathMenu(devRunActive: Bool) -> some View {
        Menu("Input path") {
            ForEach(Self.inputPathItems, id: \.value) { item in
                Button {
                    driver.chooseInputPath(item.value)
                } label: {
                    if driver.inputPathSelection == item.value { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
        }
        .disabled(driver.runningEnginePid == nil || devRunActive)
    }

    static let inputPathItems: [(value: String, title: String)] = [("engine", "App"), ("shadow", "Driver (shadow)"), ("driver", "Driver")]

    @ViewBuilder private var driverButtons: some View {
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

    // MARK: In-app mode (today's menu; with a header after the engine fallback)

    @ViewBuilder private var inAppBody: some View {
        if driver.engineUnavailable {
            Text("Engine unavailable: using in-app (relaunch GDHub to retry the engine)")
            Divider()
        }
        Text(statusText)
        Text(driver.inputPathStatusText)
        if let connectionText { Text(connectionText) }
        Text(padText)
        if let trafficText { Text(trafficText) }
        if let syntheticWarning { Text(syntheticWarning) }
        ForEach(Array(latencyLines.enumerated()), id: \.offset) { _, line in Text(line) }
        Divider()
        Toggle("Publish virtual pad when the controller is connected", isOn: $driver.autoPublish)
        Menu("Publish virtual pad") {
            ForEach(PadIdentity.all, id: \.id) { identity in
                Button(identity.id) { driver.publishPad(identity) }
            }
        }
        .disabled(!isConnected)
        Button("Unpublish virtual pad") { driver.unpublishPad() }
            .disabled(driver.padState == .off)
        Button(driver.testPatternRunning ? "Stop test pattern" : "Test pattern") {
            if driver.testPatternRunning { driver.stopTestPattern() } else { driver.runTestPattern() }
        }
        .disabled(!isPublished)
        if connectionNeedsRetry { Button("Retry connection") { driver.retryConnection() } }
        Button("Restart driver (dev)") { driver.devTerminateDriver() }       // DEBUG-only experiment
            .disabled(!isConnected)
        Divider()
        driverButtons
    }
}


/// Hands its content whether a Developer run is active, following both the mode being switched on and the run's state.
private struct DevRunWatcher<Content: View>: View {
    @ObservedObject var device: EnvisionProDevice
    let content: (Bool) -> Content

    var body: some View {
        DevObserved(session: device.dev) { content($0?.isRunning == true) }
    }
}

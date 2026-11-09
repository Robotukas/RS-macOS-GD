import SwiftUI
import AppKit
import IOKit.hid
import Combine
import os

/// Owns the HID monitor and device modules and routes reports to them.
@MainActor
final class AppModel: ObservableObject {
    let envision: EnvisionProDevice
    let modules: [DeviceModule]
    let monitor: HIDMonitor
    /// Driver install state, dext connection and the virtual pad sink (design §5.6). In engine and display-only mode it
    /// never touches the dext: the headless engine (engine-agent-plan) owns the pad.
    let driver: DriverManager
    let guiMode: GUIMode
    /// Corsair "Bragi" control channel: battery readout and sleep timer.
    let control = EnvisionProControl()
    private var controlStatusSub: AnyCancellable?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var routes: [ObjectIdentifier: (module: DeviceModule, usagePage: Int)] = [:]

    init() {
        // Decided once, before DriverManager exists: engine (agent installed, /Applications copy), display-only
        // (agent installed, any other copy) or in-app (no agent: today's code path).
        let mode = EngineAgent.guiMode(bundlePath: Bundle.main.bundlePath, installed: EngineAgent().isInstalled)
        guiMode = mode
        driver = DriverManager(mode: mode)
        let layout = ControlLayout.load()
        envision = EnvisionProDevice(layout: layout)
        modules = [envision]
        monitor = HIDMonitor(matchList: modules.flatMap { $0.matchList })

        monitor.onDeviceMatched = { [weak self] device, page in
            guard let self, let info = self.monitor.info(for: device),
                  let module = self.modules.first(where: { $0.matches(vendorId: info.vendorId, productId: info.productId) })
            else { return }
            self.routes[ObjectIdentifier(device)] = (module, page)
            module.interfaceConnected(usagePage: page, productId: info.productId)
        }
        monitor.onDeviceRemoved = { [weak self] device in
            guard let self, let route = self.routes.removeValue(forKey: ObjectIdentifier(device)) else { return }
            route.module.interfaceDisconnected(usagePage: route.usagePage)
        }
        // The gamepad interface (0xFF58, ~1 kHz) is handled synchronously in the HID callback; the Bragi control
        // interface keeps the copying path because its handler can send output reports.
        monitor.synchronousUsagePages = [EnvisionProDevice.gamepadUsagePage]
        monitor.onSynchronousInputReport = { [weak self] _, reportID, report, tK, tC in
            self?.envision.handleGamepadReport(reportID: reportID, report: report, tK: tK, tC: tC)
        }
        monitor.onInputReport = { [weak self] device, reportID, bytes in
            guard let self, let route = self.routes[ObjectIdentifier(device)] else { return }
            if reportID == UInt32(BragiPacket.inputReportID),
               self.monitor.info(for: device)?.hasControlChannel == true,
               self.control.handleInputReport(bytes) { return }
            route.module.handle(reportID: reportID, bytes: bytes, usagePage: route.usagePage)
        }
        control.send = { [weak self] packet in
            guard let self, let dev = self.monitor.controlDevice() else { return false }
            return self.monitor.sendOutputReport(device: dev, reportID: BragiPacket.outputReportID, bytes: packet) == kIOReturnSuccess
        }
        controlStatusSub = envision.$status.sink { [weak self] status in
            // $status emits before the property changes; hop so the control sees settled state.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.control.statusChanged(status) } }
        }
        monitor.start()
        envision.recoverInterruptedEditIfNeeded()
        envision.driverForDeveloper = driver
        // A Developer run that never finished (crash, kill) left the input path switched: put it back.
        if let note = DevInputPathControl().restoreOnLaunchIfNeeded(mode: mode) {
            Logger(subsystem: "com.interlinked.gdhub", category: "devmode").notice("\(note, privacy: .public)")
        }
        // Cmd-Q in the middle of a run: write the report and put the input path back before the process ends, in every
        // mode (the in-app observer below only deals with the pad).
        let devTerminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.envision.dev?.finishForTermination() }
        }
        lifecycleObservers.append(devTerminate)
        if mode == .inApp { wireVirtualPad() }
        // The engine could not start: this session owns the pad itself (E1 fallback).
        driver.onFallbackToInApp = { [weak self] in self?.wireVirtualPad() }
    }

    /// Feeds the virtual pad from the controller and ties it to the app and system lifecycle (design §5.6).
    private func wireVirtualPad() {
        let sink = driver.sink
        let driver = driver
        // One async hop per frame onto vhidQueue; the UI path is unchanged.
        let envision = envision
        envision.onFrame = { frame, mapping, stamp in
            sink.submit(frame: frame, mapping: mapping, revision: envision.mappingRevision, tK: stamp.tK, tC: stamp.tC)
        }
        envision.onStatusChange = { status in driver.controllerStatusChanged(status) }

        // The pad must be neutral before the Mac sleeps, and gone as soon as the app quits.
        let sleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { driver.neutralNow() }
        }
        let terminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { driver.prepareForTermination() }
        }
        lifecycleObservers += [sleep, terminate]
    }
}

struct GDHubApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("GDHub") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 640)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    model.driver.start()
                }
        }
        .defaultSize(width: 1200, height: 860)
        .commands {
            CommandMenu("Layout") { LayoutCommands(device: model.envision, editor: model.envision.editor) }
            CommandMenu("Controller") { ControllerCommands(control: model.control) }
            CommandMenu("Driver") { DriverCommands(driver: model.driver, device: model.envision) }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            // One device for now; becomes a selectable list when more modules exist.
            List {
                Section("Devices") {
                    DeviceRow(device: model.envision)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            EnvisionProScreen(device: model.envision, control: model.control)
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var device: EnvisionProDevice

    var color: Color {
        switch device.status {
        case .active: return .green
        case .asleep: return .yellow
        case .receiverIdle: return .orange
        case .disconnected: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                Text(device.status.label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EnvisionProScreen: View {
    @ObservedObject var device: EnvisionProDevice
    @ObservedObject var control: EnvisionProControl
    @AppStorage("showInputMonitor") private var showMonitor = true

    var body: some View {
        VStack(spacing: 0) {
            ControllerView(device: device, control: control)
                .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button {
                    showMonitor.toggle()
                } label: {
                    Label(showMonitor ? "Hide input monitor" : "Show input monitor",
                          systemImage: showMonitor ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // Developer mode needs the height for the run panel and the drawing; it has its own live strip.
            if showMonitor && device.dev == nil {
                InputMonitorView(device: device)
                    .frame(height: 220)
            }
        }
        .navigationTitle(device.displayName)
    }
}

/// Menu-bar commands for the layout editor; a view so the items follow edit-mode state.
struct LayoutCommands: View {
    @ObservedObject var device: EnvisionProDevice
    @ObservedObject var editor: LayoutEditor

    var body: some View {
        Button(editor.isEditing ? "Done (lock layout)" : "Edit layout") {
            if editor.isEditing { device.lockLayout() } else { device.beginEditingLayout() }
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(device.dev != nil)
        Button("Cancel editing") { device.cancelEditingLayout() }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(!editor.isEditing)
        Menu("Restore layout from backup") {
            let backups = ControlLayout.backups().prefix(15)
            if backups.isEmpty { Text("No backups yet") }
            ForEach(Array(backups), id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { device.restoreLayout(from: url) }
            }
        }
        Divider()
        Button("Select all labels") { device.selectAllLabels() }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(!editor.isEditing)
        Button("Deselect all") { editor.selection = [] }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(!editor.isEditing || editor.selection.isEmpty)
        Divider()
        ForEach(LayoutEditor.AlignAction.allCases, id: \.self) { action in
            Button("Align: \(action.title)") { editor.perform(action) }
                .keyboardShortcut(action.shortcutKey, modifiers: [.command, .option])
                .disabled(!editor.isEditing || editor.selection.count < action.minimumSelection)
        }
    }
}

/// Controller menu: battery readout and the sleep-timer presets (checkmark on the current one).
struct ControllerCommands: View {
    @ObservedObject var control: EnvisionProControl

    var body: some View {
        Text(control.batteryPercent.map { "Battery: \(Int($0.rounded()))%" } ?? "Battery: unknown")
        Divider()
        Text("Sleep after").font(.caption)
        ForEach(SleepSetting.presets, id: \.self) { preset in
            Toggle(preset.presetLabel, isOn: SwiftUI.Binding(
                get: { control.sleepSetting == preset },
                set: { _ in control.apply(preset) }))
                .disabled(control.sleepSetting == nil || control.isBusy)
        }
        if let s = control.sleepSetting, !s.isPreset { Text(s.displayText) }
    }
}

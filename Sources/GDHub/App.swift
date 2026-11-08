import SwiftUI
import AppKit
import IOKit.hid

/// Owns the HID monitor and device modules and routes reports to them.
@MainActor
final class AppModel: ObservableObject {
    let envision: EnvisionProDevice
    let modules: [DeviceModule]
    let monitor: HIDMonitor
    private var routes: [ObjectIdentifier: (module: DeviceModule, usagePage: Int)] = [:]

    init() {
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
        monitor.onInputReport = { [weak self] device, reportID, bytes in
            guard let route = self?.routes[ObjectIdentifier(device)] else { return }
            route.module.handle(reportID: reportID, bytes: bytes, usagePage: route.usagePage)
        }
        monitor.start()
    }
}

@main
struct GDHubApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("GDHub") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 640)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1200, height: 860)
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
            EnvisionProScreen(device: model.envision)
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
    @AppStorage("showInputMonitor") private var showMonitor = true

    var body: some View {
        VStack(spacing: 0) {
            ControllerView(device: device)
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
            if showMonitor {
                InputMonitorView(device: device)
                    .frame(height: 220)
            }
        }
        .navigationTitle(device.displayName)
    }
}

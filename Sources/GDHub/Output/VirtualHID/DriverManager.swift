import Foundation
import AppKit
import SystemExtensions
import os

/// Installs, updates and removes the embedded DriverKit extension (design §5.1).
@MainActor
final class DriverManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case checking
        case notBundled
        case wrongLocation(String)
        case notInstalled
        case activating
        case updating(from: String, to: String)
        case needsApproval
        case active(String)
        case rebootRequired
        case uninstalling
        case failed(code: Int, message: String)
    }

    static let dextID = "com.interlinked.gdhub.VirtualHID"
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")

    @Published private(set) var state: State = .checking {
        didSet { if state != oldValue { Self.log.info("driver state: \(String(describing: self.state), privacy: .public)") } }
    }

    /// Connection to the running dext (design §5.2). Shown in the Driver menu.
    @Published private(set) var connection: DextClient.State = .stopped

    /// Serial queue for every dext call and callback (design §5.2). Later phases share it with the pad sink.
    let vhidQueue = DispatchQueue(label: "com.interlinked.gdhub.vhid")
    let dext: DextClient

    let embeddedDextURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/SystemExtensions/\(DriverManager.dextID).dext")
    let embeddedBuild: String?

    private var pollTask: Task<Void, Never>?
    private var started = false

    override init() {
        embeddedBuild = Bundle(url: embeddedDextURL)?.infoDictionary?["CFBundleVersion"] as? String
        dext = DextClient(queue: vhidQueue)
        super.init()
        dext.onState = { [weak self] new in
            // Called on vhidQueue.
            Task { @MainActor in
                guard let self else { return }
                if new != self.connection { Self.log.info("connection: \(String(describing: new), privacy: .public)") }
                self.connection = new
            }
        }
    }

    // MARK: Launch

    func start() {
        guard !started else { return }
        started = true
        // Always start the client: it waits for the service, which also lets a SwiftPM build be refused by the
        // dext's Team ID check (design §5.1 step 4).
        vhidQueue.async { [dext] in dext.start() }
        guard embeddedBuild != nil else { state = .notBundled; return }
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") else { state = .wrongLocation(path); return }
        queryProperties()
    }

    private func queryProperties() {
        let req = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.dextID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    // MARK: Actions

    func installOrUpdate() {
        guard embeddedBuild != nil else { return }
        // Close the connection first (D3+: destroy the devices too); it reconnects when the new dext matches.
        vhidQueue.sync { dext.stop() }
        let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.dextID, queue: .main)
        req.delegate = self
        if case .updating = state {} else { state = .activating }
        Self.log.info("submitting activation request (bundled build \(self.embeddedBuild ?? "?", privacy: .public))")
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func uninstall() {
        guard embeddedBuild != nil else { return }
        vhidQueue.sync { dext.stop() }
        let req = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.dextID, queue: .main)
        req.delegate = self
        state = .uninstalling
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func retry() {
        if case .failed = state { state = .checking; queryProperties() }
    }

    func openSystemSettings() {
        let urls = ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                    "x-apple.systempreferences:"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: Polling while waiting for approval

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.state == .needsApproval else { return }
                self.queryProperties()
            }
        }
    }

    private func set(_ new: State) {
        state = new
        if new == .needsApproval { startPolling() } else { pollTask?.cancel() }
    }

    // MARK: Errors

    static func describe(_ error: Error) -> (Int, String) {
        let ns = error as NSError
        guard ns.domain == OSSystemExtensionErrorDomain else { return (ns.code, ns.localizedDescription) }
        let text: String
        switch ns.code {
        case 2: text = "App lacks System Extension entitlement"
        case 3: text = "Run from /Applications"
        case 4: text = "Dext not embedded"
        case 7: text = "Dext not recognised (CFBundlePackageType must be DEXT)"
        case 8: text = "Signature/profile mismatch"
        case 9: text = "Validation failed (entitlements vs profile, or CFBundlePackageType)"
        default: text = ns.localizedDescription
        }
        return (ns.code, text)
    }

    // MARK: OSSystemExtensionRequestDelegate

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
            .info("replacing dext \(existing.bundleVersion, privacy: .public) -> \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { self.set(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            Self.log.info("request finished: \(result.rawValue)")
            if result == .willCompleteAfterReboot { self.set(.rebootRequired); return }
            if self.state == .uninstalling { self.set(.notInstalled); return }
            self.queryProperties()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let (code, msg) = Self.describe(error)
            Self.log.error("request failed: \(code) \(msg, privacy: .public)")
            self.set(.failed(code: code, message: msg))
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let infos = properties.map { (v: $0.bundleVersion, enabled: $0.isEnabled, uninstalling: $0.isUninstalling, awaiting: $0.isAwaitingUserApproval) }
        MainActor.assumeIsolated { self.handleProperties(infos) }
    }

    private func handleProperties(_ infos: [(v: String, enabled: Bool, uninstalling: Bool, awaiting: Bool)]) {
        let enabled = infos.filter { $0.enabled && !$0.uninstalling }
        if let match = enabled.first(where: { $0.v == embeddedBuild }) {
            set(.active(match.v))
            vhidQueue.async { [dext] in dext.start() }       // no-op when already running
        } else if let old = enabled.map(\.v).max(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            if case .updating = state { return }   // already replacing
            set(.updating(from: old, to: embeddedBuild ?? "?"))
            installOrUpdate()
        } else if infos.contains(where: { $0.awaiting }) {
            set(.needsApproval)
        } else if state == .activating || state == .uninstalling {
            return   // request in flight
        } else {
            set(.notInstalled)
            // Dev aid: `open -a GDHub --args --install-driver` installs without the menu.
            if CommandLine.arguments.contains("--install-driver") { installOrUpdate() }
        }
    }
}

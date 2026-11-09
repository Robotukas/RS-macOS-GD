import Foundation
import SystemExtensions
import os

/// T0 only (docs/plans/receiver-takeover-plan.md §8.3, deleted in T0.5): `GDHub --dev-probe-dext activate|deactivate`
/// submits an activation or deactivation request for the throwaway probe dext `com.interlinked.gdhub.TapProbe`.
///
/// It is a launch mode like `--engine`: `Entry.main` branches here before any SwiftUI or AppKit object exists, so no GUI,
/// no engine and no `DriverManager` are created, and the delegate below is this type's own. `DriverManager`'s delegate
/// never sees these requests. Exit status: 0 completed, 1 failed, 2 timed out, 3 completes after a reboot, 64 usage.
final class ProbeExtensionRequester: NSObject, OSSystemExtensionRequestDelegate {
    enum Mode: String, Equatable { case activate, deactivate }

    enum Parse: Equatable {
        case notRequested                 // no `--dev-probe-dext`: the normal launch paths go on
        case run(Mode)
        case usage(String)
    }

    static let extensionID = "com.interlinked.gdhub.TapProbe"
    static let timeout: TimeInterval = 5 * 60            // long enough to approve in System Settings
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "probe")
    private static var current: ProbeExtensionRequester?  // strong reference for the process lifetime (the manager keeps the delegate weakly)

    static func parse(arguments: [String]) -> Parse {
        guard let i = arguments.firstIndex(of: "--dev-probe-dext") else { return .notRequested }
        guard i + 1 < arguments.count, let mode = Mode(rawValue: arguments[i + 1]) else {
            return .usage("usage: GDHub --dev-probe-dext activate|deactivate")
        }
        return .run(mode)
    }

    let mode: Mode
    private var finished = false
    private var timeoutTimer: DispatchSourceTimer?

    init(mode: Mode) { self.mode = mode }

    /// Never returns: submits the request and runs the main queue until a delegate callback or the timeout exits.
    static func run(_ mode: Mode) -> Never {
        let r = ProbeExtensionRequester(mode: mode)
        current = r
        r.start()
        dispatchMain()
    }

    static func printUsageAndExit(_ text: String) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(64)
    }

    /// Prints to stdout (flushed, so a pipe sees it at once) and writes the same line to the unified log.
    private func say(_ text: String) {
        fputs("probe: \(text)\n", stdout)
        fflush(stdout)
        Self.log.info("probe: \(text, privacy: .public)")
    }

    private func finish(_ status: Int32, _ text: String) -> Never {
        say(text)
        exit(status)
    }

    private func start() {
        say("\(mode.rawValue) request for \(Self.extensionID) (timeout \(Int(Self.timeout)) s; approve in System Settings > General > Login Items & Extensions > Driver Extensions if asked)")
        let request: OSSystemExtensionRequest
        switch mode {
        case .activate:
            request = .activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        case .deactivate:
            request = .deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        }
        request.delegate = self
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.timeout)
        timer.setEventHandler { [weak self] in
            self?.finish(2, "timed out after \(Int(Self.timeout)) s without a result")
        }
        timer.resume()
        timeoutTimer = timer
        OSSystemExtensionManager.shared.submitRequest(request)
        say("request submitted")
    }

    /// OSSystemExtensionError codes the dext work has met (same wording as DriverManager.describe, which is main-actor bound).
    static func describe(_ ns: NSError) -> String {
        guard ns.domain == OSSystemExtensionErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case 2: return "App lacks System Extension entitlement"
        case 3: return "Run from /Applications"
        case 4: return "Dext not embedded"
        case 7: return "Dext not recognised (CFBundlePackageType must be DEXT)"
        case 8: return "Signature/profile mismatch"
        case 9: return "Validation failed (entitlements vs profile, or CFBundlePackageType)"
        default: return ns.localizedDescription
        }
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Always replace, downgrades included (assumption A23 asks whether sysextd accepts a lower CFBundleVersion).
        say("replacing \(existing.bundleVersion) -> \(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        say("needs user approval: open System Settings > General > Login Items & Extensions > Driver Extensions and allow it")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            finish(0, "\(mode.rawValue) finished: completed")
        case .willCompleteAfterReboot:
            finish(3, "\(mode.rawValue) finished: will complete after reboot")
        @unknown default:
            finish(1, "\(mode.rawValue) finished with unknown result \(result.rawValue)")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        finish(1, "\(mode.rawValue) failed: domain=\(ns.domain) code=\(ns.code) \(Self.describe(ns))")
    }
}

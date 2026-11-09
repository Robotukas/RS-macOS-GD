import Foundation
import os

/// How this GUI process relates to the pad (engine-agent-plan §2).
enum GUIMode: Equatable {
    case engine         // the launchd engine owns the dext; this GUI shows status and never says hello
    case displayOnly    // the agent is installed but this is another copy of the app: read-only, no launchctl at all
    case inApp          // no agent: today's code path, this process owns the dext
}

/// What `launchctl print gui/<uid>/<label>` says about the engine job.
struct AgentStatus: Equatable {
    var loaded = false
    var state: String?          // "running", "not running", "SIGTERMed", …
    var pid: Int32?
    var lastExit: String?       // "0", "(never exited)", "9: …"
    var spawnType: String?      // "interactive (4)"

    var isRunning: Bool { loaded && state == "running" }

    /// The Driver menu's status line.
    var menuText: String {
        guard loaded else { return "Engine: installed but not loaded" }
        if isRunning { return "Engine: running (pid \(pid.map(String.init) ?? "?"), launchd)" }
        return "Engine: loaded, not running (last exit \(lastExit ?? "?"))"
    }

    /// Parses `launchctl print` output. Only top-level keys (exactly one leading tab) count: nested blocks such as
    /// `environment = {` carry their own `state` and `pid` words.
    static func parse(_ output: String, rc: Int32) -> AgentStatus {
        var s = AgentStatus()
        guard rc == 0 else { return s }
        s.loaded = true
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t"), let eq = line.range(of: " = ") else { continue }
            let key = line[line.index(after: line.startIndex)..<eq.lowerBound]
            let value = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "state": s.state = value
            case "pid": s.pid = Int32(value)
            case "last exit code": s.lastExit = value
            case "spawn type": s.spawnType = value
            default: break
            }
        }
        return s
    }
}

/// Everything `EngineAgent` does to the outside world; tests script it.
protocol AgentShell: AnyObject {
    /// Runs `/bin/launchctl` with `args`; returns the exit code and stdout.
    func launchctl(_ args: [String]) -> (rc: Int32, out: String)
    /// `pkill -9 -f` on the engine's command line.
    func killEngine()
    /// True when a process with the engine's command line exists.
    func engineProcessExists() -> Bool
    func sleep(_ seconds: Double)
    func remove(_ url: URL)
}

final class SystemShell: AgentShell {
    func launchctl(_ args: [String]) -> (rc: Int32, out: String) { run("/bin/launchctl", args) }
    func killEngine() { _ = run("/usr/bin/pkill", ["-9", "-f", EngineAgent.processPattern]) }
    func engineProcessExists() -> Bool { run("/usr/bin/pgrep", ["-f", EngineAgent.processPattern]).rc == 0 }
    func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    private func run(_ path: String, _ args: [String]) -> (rc: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Controls the engine's launchd job from the GUI (GUI-only, not MainActor). Every operation must run on `queue`, the
/// one serial queue, so a launch-time `ensureLoaded` and a driver update's bootout can never interleave.
final class EngineAgent: @unchecked Sendable {
    static let label = "com.interlinked.gdhub.engine"
    static let appPath = "/Applications/GDHub.app"
    static let processPattern = "/Applications/GDHub.app/Contents/MacOS/GDHub --engine"
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")

    enum EnsureAction: Equatable { case nothing, bootstrap, kickstart, bootoutThenBootstrap }

    let queue = DispatchQueue(label: "com.interlinked.gdhub.agent", qos: .utility)
    private let shell: AgentShell
    let installedPlistURL: URL
    /// Set while a driver install/update has the engine booted out: `ensureLoaded` does nothing meanwhile. `queue` only.
    var updateInFlight = false

    init(shell: AgentShell = SystemShell(),
         installedPlistURL: URL = EngineAgent.defaultInstalledPlistURL) {
        self.shell = shell
        self.installedPlistURL = installedPlistURL
    }

    static var defaultInstalledPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var bundledPlistURL: URL? { Bundle.main.url(forResource: label, withExtension: "plist") }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: installedPlistURL.path) }
    private var target: String { "gui/\(getuid())/\(Self.label)" }
    private var domain: String { "gui/\(getuid())" }

    /// Runs `work` on the agent queue.
    func perform(_ work: @escaping (EngineAgent) -> Void) { queue.async { work(self) } }

    // MARK: Pure decisions

    /// Which mode a GUI copy runs in (decided once at launch).
    static func guiMode(bundlePath: String, installed: Bool) -> GUIMode {
        guard installed else { return .inApp }
        return bundlePath == appPath ? .engine : .displayOnly
    }

    /// What `ensureLoaded` does for a given job state (plan §2).
    static func decide(_ s: AgentStatus) -> EnsureAction {
        guard s.loaded else { return .bootstrap }
        if s.state == "running" { return .nothing }
        if s.pid != nil { return .bootoutThenBootstrap }      // e.g. SIGTERMed while a bootout is still finishing
        return .kickstart                                     // loaded, not running, no process
    }

    // MARK: launchctl operations (agent queue)

    func status() -> AgentStatus {
        let r = shell.launchctl(["print", target])
        return AgentStatus.parse(r.out, rc: r.rc)
    }

    /// `bootstrap`; rc 5 or 37 retries up to 3 times 200 ms apart, and rc 5 followed by a loaded job counts as success
    /// (launchd loaded it at login in the meantime; a second bootstrap of a loaded job returns 5).
    @discardableResult
    func bootstrap() -> Bool {
        for attempt in 0...3 {
            let rc = shell.launchctl(["bootstrap", domain, installedPlistURL.path]).rc
            if rc == 0 { return true }
            if rc == 5 && status().loaded { return true }
            guard rc == 5 || rc == 37, attempt < 3 else {
                Self.log.error("launchctl bootstrap failed rc=\(rc)")
                return false
            }
            shell.sleep(0.2)
        }
        return false
    }

    /// Boots the job out and waits until launchd no longer knows it (`bootout` returns before the process has exited).
    @discardableResult
    func bootoutAndWait() -> Bool {
        _ = shell.launchctl(["bootout", target])
        if waitUnloaded(polls: 60) { return true }                 // ExitTimeOut + 1 = 6 s
        Self.log.error("engine still loaded 6 s after bootout: killing it")
        shell.killEngine()
        return waitUnloaded(polls: 10)
    }

    private func waitUnloaded(polls: Int) -> Bool {
        for i in 0..<polls {
            if !status().loaded { return true }
            if i < polls - 1 { shell.sleep(0.1) }
        }
        return false
    }

    func restart() { _ = shell.launchctl(["kickstart", "-k", target]) }

    /// Makes sure the job is loaded and running (no-op while a driver update has it booted out).
    func ensureLoaded() {
        guard !updateInFlight, isInstalled else { return }
        let s = status()
        switch Self.decide(s) {
        case .nothing: break
        case .bootstrap: bootstrap()
        case .kickstart: _ = shell.launchctl(["kickstart", target])
        case .bootoutThenBootstrap:
            if bootoutAndWait() { bootstrap() }
        }
    }

    /// E1 fallback: true when the engine provably cannot run. Re-reads the job three times over about 5 s; if it is
    /// never running, boots it out (so a KeepAlive respawn cannot take the dext later) and confirms no engine process
    /// is left. The plist stays installed so the next launch tries the engine again.
    func fallbackCheck() -> Bool {
        for i in 0..<3 {
            if status().isRunning { return false }
            if i < 2 { shell.sleep(2.5) }
        }
        _ = bootoutAndWait()
        if shell.engineProcessExists() {
            shell.killEngine()
            shell.sleep(0.5)
            if shell.engineProcessExists() { return false }         // cannot prove it is gone: do not take the dext
        }
        return true
    }

    /// Menu item "Uninstall background engine": boot out, wait, remove the plist.
    @discardableResult
    func uninstallAgent() -> Bool {
        let ok = bootoutAndWait()
        shell.remove(installedPlistURL)
        return ok
    }
}

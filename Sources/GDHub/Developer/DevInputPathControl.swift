import Foundation
import Darwin

// The input path is the one thing Developer mode changes (docs/plans/developer-mode-plan.md, "Input path: confirm and
// restore"). A run switches it for its own length and has to put back exactly what was there, including a tripped
// breaker, on every exit: finish, Stop, error, Done, Cmd-Q and a crash (the `.inflight` marker covers the last one).

/// The raw defaults keys as they stood before a run. Raw on purpose: `DriverManager.inputPathStored` is already
/// normalised, and a restore that wrote a normalised value back would not be "exactly what was there".
struct DevPathSnapshot: Codable, Equatable {
    /// nil = the key was absent.
    var inputPath: String?
    var inputPathChoice: Int?
    var tapBreakerTrippedAt: Double?
    var tapBreakerReason: String?

    init(inputPath: String? = nil, inputPathChoice: Int? = nil, tapBreakerTrippedAt: Double? = nil, tapBreakerReason: String? = nil) {
        self.inputPath = inputPath; self.inputPathChoice = inputPathChoice
        self.tapBreakerTrippedAt = tapBreakerTrippedAt; self.tapBreakerReason = tapBreakerReason
    }

    /// The breaker (or the limiter) had stopped the driver path.
    var wasLatched: Bool { tapBreakerTrippedAt != nil }

    /// "Driver (stopped by breaker, as before)": what the end text says was put back.
    var restoredDescription: String {
        let name: String
        switch InputPath(defaultsValue: inputPath) {
        case .engine: name = "Engine (App path)"
        case .shadow: name = "Driver (shadow)"
        case .driver: name = "Driver"
        case .count: name = "Driver (count)"
        }
        guard wasLatched else { return name }
        let why = tapBreakerReason.map { ": \($0)" } ?? ""
        return "\(name) (stopped by breaker\(why), as before)"
    }
}

/// Written before the first path write of a run and removed after the restore; a crash leaves it behind and the next
/// launch puts the path back.
struct DevInflightMarker: Codable, Equatable {
    var pid: Int32
    /// Seconds since 1970 at which that process started: tells a reused pid from the process that wrote the marker.
    var processStart: Double?
    var snapshot: DevPathSnapshot
    /// The `inputPath` the run wrote last. A different stored value later means the owner changed it themselves.
    var writtenValue: String
    var startedAt: String
}

protocol DevInputPathControlling {
    func snapshot() -> DevPathSnapshot
    /// The raw stored `inputPath` (nil when absent), for the launch-time check.
    func storedInputPath() -> String?
    /// Same semantics as the Driver menu: bumps the choice counter and, for arming values, clears the breaker keys.
    func write(path: String)
    /// Sets or removes each raw key exactly as in `snapshot`; no choice bump, breaker keys last.
    func restore(_ snapshot: DevPathSnapshot)
    func writeMarker(_ marker: DevInflightMarker) throws
    func readMarker() -> DevInflightMarker?
    func removeMarker()
}

struct DevInputPathControl: DevInputPathControlling {
    let defaults: UserDefaults
    let markerURL: URL

    static var defaultMarkerURL: URL { MappingStore.defaultURL(fileName: "dev-runs/.inflight") }

    init(defaults: UserDefaults = .standard, markerURL: URL = DevInputPathControl.defaultMarkerURL) {
        self.defaults = defaults
        self.markerURL = markerURL
    }

    // MARK: Keys

    func snapshot() -> DevPathSnapshot {
        DevPathSnapshot(
            inputPath: defaults.object(forKey: InputPath.defaultsKey) as? String,
            inputPathChoice: (defaults.object(forKey: InputPath.choiceKey) as? NSNumber)?.intValue,
            tapBreakerTrippedAt: (defaults.object(forKey: InputPath.breakerKey) as? NSNumber)?.doubleValue,
            tapBreakerReason: defaults.object(forKey: InputPath.breakerReasonKey) as? String)
    }

    func storedInputPath() -> String? { defaults.object(forKey: InputPath.defaultsKey) as? String }

    func write(path: String) { DriverManager.writeInputPath(path, defaults: defaults) }

    func restore(_ s: DevPathSnapshot) {
        func put(_ key: String, _ value: Any?) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        put(InputPath.defaultsKey, s.inputPath)
        put(InputPath.choiceKey, s.inputPathChoice)
        // Last, so the engine sees the path first and latches again on its next poll.
        put(InputPath.breakerKey, s.tapBreakerTrippedAt)
        put(InputPath.breakerReasonKey, s.tapBreakerReason)
    }

    // MARK: Marker

    func writeMarker(_ marker: DevInflightMarker) throws {
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(marker).write(to: markerURL, options: .atomic)
    }

    func readMarker() -> DevInflightMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(DevInflightMarker.self, from: data)
    }

    func removeMarker() { try? FileManager.default.removeItem(at: markerURL) }

    // MARK: Launch

    /// A marker is stale when the process that wrote it is gone. A reused pid is told apart by the process start time.
    static func processIsAlive(_ marker: DevInflightMarker) -> Bool {
        guard marker.pid > 0 else { return false }
        if kill(marker.pid, 0) != 0 && errno != EPERM { return false }
        if let written = marker.processStart, let now = processStartTime(pid: marker.pid), abs(now - written) > 2 { return false }
        return true
    }

    /// Seconds since 1970 at which `pid` started, or nil when unknown.
    static func processStartTime(pid: Int32 = getpid()) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }

    /// At launch: puts the path back after a run that never got to (a crash, a kill). The plan's conditions: the GUI is
    /// in engine mode, the marker's process is gone, and the stored `inputPath` still equals what the run wrote. A
    /// marker that fails them is removed without touching anything, except one whose process is still alive: that run
    /// owns its marker. Returns a line for the log, nil when there was no marker.
    @discardableResult
    func restoreOnLaunchIfNeeded(mode: GUIMode, isPidAlive: (DevInflightMarker) -> Bool = DevInputPathControl.processIsAlive) -> String? {
        guard let marker = readMarker() else {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                removeMarker()
                return "Developer mode: removed an unreadable run marker"
            }
            return nil
        }
        if isPidAlive(marker) {
            return "Developer mode: a run (pid \(marker.pid)) is still in progress, its marker is left alone"
        }
        guard mode == .engine else {
            removeMarker()
            return "Developer mode: an interrupted run left a marker, not restoring because this copy is not in engine mode"
        }
        guard storedInputPath() == marker.writtenValue else {
            removeMarker()
            return "Developer mode: an interrupted run left a marker, not restoring because the input path was changed since (now \(storedInputPath() ?? "unset"), the run wrote \(marker.writtenValue))"
        }
        restore(marker.snapshot)
        removeMarker()
        return "Developer mode: put the input path back to \(marker.snapshot.restoredDescription) after an interrupted run"
    }
}

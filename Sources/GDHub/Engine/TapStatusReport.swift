import Foundation

/// What the engine's `TapSupervisor` publishes for the Driver menu (T6). The GUI is a separate process and never talks to the dext
/// for this: the engine owns the connection, writes this small JSON file when the state changes, and the GUI reads it.
///
/// Mechanism (precedent: `MappingStore`, which already shares `~/Library/Application Support/GDHub/` between the two processes,
/// and `MappingWatcher`, the kqueue watch on that directory): the file is `GDHub/state/engine-tap-status.json`, written
/// atomically (rename) by the engine only when the report differs from the one before (state changes, fallbacks, the mapping
/// note, parity crossing a bucket), never per frame and never per poll. The GUI watches the `state` directory (event driven, no
/// polling) and re-reads on its existing 5 s engine refresh. The report carries the engine's pid; the GUI shows it only when that
/// pid is the one launchd says is running, so a file left by a dead engine is never shown as current.
struct TapStatusReport: Codable, Equatable {
    static let schema = 1
    static let fileName = "state/engine-tap-status.json"

    var schema = TapStatusReport.schema
    var pid: Int32 = 0
    /// The `inputPath` value the engine acts on, as the engine understood it: `engine`, `count`, `shadow` or `driver`.
    var path = "engine"
    var connected = false
    /// What the connected dext offers (`CAP_TAP`, `CAP_XLATE`).
    var capTap = false
    var capXlate = false
    var capLive = false
    /// What the engine has asked of the dext and the dext accepted: `inert`, `count`, `shadow` or `live`.
    var armed = "inert"
    /// `path == driver` runs as shadow until the dext reports CAP_LIVE.
    var liveUnavailable = false
    var parityChecked = false
    /// Parity matches, rounded down to a hundred so the file is not rewritten for every sample.
    var parityOkBucket = 0
    var parityMismatches = 0
    /// The fallback in force (`tap stalled`, ...), and whether the engine will try again by itself.
    var fallback: String?
    var fallbackRetrying = false
    /// "breaker" or "limiter" while the driver path is stopped after repeated restarts / fallbacks.
    var latched: String?
    /// The mapping needs more than GDHM v1 (the reason). The engine path keeps posting.
    var mappingNote: String?

    init() {}

    /// Missing keys decode to their defaults: a file written by an older engine (build 23 has no `capLive`) must not make the menu say
    /// "waiting for the engine". Unknown keys are ignored. The schema number still decides whether the file is understood at all.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? TapStatusReport.schema
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "engine"
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        capTap = try c.decodeIfPresent(Bool.self, forKey: .capTap) ?? false
        capXlate = try c.decodeIfPresent(Bool.self, forKey: .capXlate) ?? false
        capLive = try c.decodeIfPresent(Bool.self, forKey: .capLive) ?? false
        armed = try c.decodeIfPresent(String.self, forKey: .armed) ?? "inert"
        liveUnavailable = try c.decodeIfPresent(Bool.self, forKey: .liveUnavailable) ?? false
        parityChecked = try c.decodeIfPresent(Bool.self, forKey: .parityChecked) ?? false
        parityOkBucket = try c.decodeIfPresent(Int.self, forKey: .parityOkBucket) ?? 0
        parityMismatches = try c.decodeIfPresent(Int.self, forKey: .parityMismatches) ?? 0
        fallback = try c.decodeIfPresent(String.self, forKey: .fallback)
        fallbackRetrying = try c.decodeIfPresent(Bool.self, forKey: .fallbackRetrying) ?? false
        latched = try c.decodeIfPresent(String.self, forKey: .latched)
        mappingNote = try c.decodeIfPresent(String.self, forKey: .mappingNote)
    }

    func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    static func decode(_ data: Data) -> TapStatusReport? {
        guard let r = try? JSONDecoder().decode(TapStatusReport.self, from: data), r.schema == schema else { return nil }
        return r
    }
}

/// Reads and writes the report file. Writes are atomic; the directory is created on demand.
struct TapStatusStore {
    let url: URL

    static let standard = TapStatusStore(url: MappingStore.defaultURL(fileName: TapStatusReport.fileName))

    /// True when the file now holds `report`.
    @discardableResult
    func write(_ report: TapStatusReport) -> Bool {
        guard let data = report.encoded() else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func read() -> TapStatusReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return TapStatusReport.decode(data)
    }
}

/// Keeps the report file true (T6 review). Lives on its own queue (the engine's `controlQueue`, never `vhidQueue`). A report is
/// written when it differs from the last one that was written SUCCESSFULLY, retried once after 2 s when a write fails, and every
/// `rewriteEvery` seconds unconditionally, so a deleted file or a lost write heals within that time instead of waiting for the
/// next state change.
final class TapStatusPublisher: @unchecked Sendable {
    static let rewriteEvery: TimeInterval = 30
    private let queue: DispatchQueue
    private let write: (TapStatusReport) -> Bool
    private let retryAfter: TimeInterval
    private var latest: TapStatusReport?
    private var lastWritten: TapStatusReport?
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue, store: TapStatusStore = .standard, retryAfter: TimeInterval = 2, write: ((TapStatusReport) -> Bool)? = nil) {
        self.queue = queue
        self.write = write ?? { store.write($0) }
        self.retryAfter = retryAfter
    }

    /// Any thread: the newest report (written now if it changed).
    func update(_ report: TapStatusReport) {
        queue.async { [self] in latest = report; flush(force: false) }
    }

    func start(every seconds: TimeInterval = TapStatusPublisher.rewriteEvery) {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.flush(force: true) }
            t.resume()
            timer = t
        }
    }

    func stop() { queue.sync { timer?.cancel(); timer = nil } }

    /// On `queue`.
    func flush(force: Bool) {
        guard let r = latest else { return }
        if !force, r == lastWritten { return }
        if write(r) { lastWritten = r }
        else {
            lastWritten = nil                                   // not written: the next update or retry writes it
            queue.asyncAfter(deadline: .now() + retryAfter) { [weak self] in self?.flush(force: false) }
        }
    }
}

/// The Driver menu's "who drives the virtual controller" status line as a pure function of what the GUI knows. Every state has its own wording; the
/// plan's examples are "Driven by: App", "Driven by: App (mapping needs GDHM v2: <reason>)" and "Driven by: Driver (shadow)".
enum InputPathMenu {
    /// - Parameters:
    ///   - mode: how this GUI relates to the pad; only `.engine` has an engine to ask.
    ///   - engineRunningPid: the pid launchd reports for the running engine, nil when it is not running.
    ///   - report: the engine's last report (nil when there is none or it could not be read).
    static func status(mode: GUIMode, engineRunningPid: Int32?, report: TapStatusReport?) -> String {
        switch mode {
        case .inApp: return "Driven by: App (in-app mode: no background engine)"
        case .displayOnly: return "Driven by: unknown (display-only copy)"
        case .engine: break
        }
        guard let pid = engineRunningPid else { return "Driven by: unknown (engine not running)" }
        guard let r = report, r.pid == pid else { return "Driven by: unknown (waiting for the engine)" }
        guard r.connected else { return "Driven by: App (waiting for the driver)" }
        guard r.capTap else { return "Driven by: App (this driver has no receiver tap; update the driver)" }
        if (r.path == "shadow" || r.path == "driver"), !r.capXlate, r.latched == nil {
            return "Driven by: App (this driver cannot run shadow mode; update the driver)"
        }
        if let latched = r.latched {
            let why = latched == "limiter" ? "repeated fallbacks" : "repeated driver restarts"
            return "Driven by: App (driver path stopped after \(why); choose Driver to try again)"
        }
        if let fb = r.fallback {
            return "Driven by: App (fallback: \(fb)\(r.fallbackRetrying ? "; retrying" : "; choose Driver to try again"))"
        }
        if let note = r.mappingNote, r.armed != "inert" || r.path == "shadow" || r.path == "driver" {
            return "Driven by: App (mapping needs GDHM v2: \(note))"
        }
        switch r.armed {
        case "live":
            return "Driven by: Driver"
        case "shadow":
            let live = r.liveUnavailable ? "; live mode not available in this driver" : (r.path == "driver" ? "; going live" : "")
            let parity: String
            if r.parityMismatches > 0 { parity = "\(r.parityMismatches) parity mismatches" }
            else if r.parityChecked { parity = "parity checked" }
            else { parity = "parity not yet checked" }
            return "Driven by: App, with driver check (\(parity)\(live))"
        case "count":
            return "Driven by: App (driver counting frames)"
        default:
            if r.path == "shadow" || r.path == "driver" || r.path == "count" { return "Driven by: App (driver not ready yet)" }
            return "Driven by: App"
        }
    }

    /// Which radio item is on: the engine's own path when it is known, else the stored value.
    static func selection(report: TapStatusReport?, engineRunningPid: Int32?, stored: String?) -> String {
        let raw = (report != nil && report?.pid == engineRunningPid) ? report?.path : stored
        switch InputPath(defaultsValue: raw) {
        case .shadow: return "shadow"
        case .driver: return "driver"
        case .engine: return "engine"
        case .count: return "count"
        }
    }
}

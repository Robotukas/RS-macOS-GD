import Foundation
import os

/// Persists a ControlMapping as JSON under ~/Library/Application Support/GDHub/.
struct MappingStore {
    let url: URL

    static let envisionPro = MappingStore(url: defaultURL(fileName: "envision-pro-mapping.json"))

    static func defaultURL(fileName: String) -> URL {
        // Dev aid for scripted checks: `GDHUB_SUPPORT_DIR=<dir>` replaces ~/Library/Application Support/GDHub.
        if let dir = ProcessInfo.processInfo.environment["GDHUB_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(fileName)
        }
        // Under the unit tests nothing may ever land in the owner's real folder (a test that began a layout edit left a
        // pre-edit snapshot there, and the next app start replaced the owner's layout with it): one throw-away folder
        // per test process.
        if let dir = testSupportDirectory { return dir.appendingPathComponent(fileName) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GDHub", isDirectory: true).appendingPathComponent(fileName)
    }

    private static let log = Logger(subsystem: GDHubID.subsystem, category: "mapping")

    /// Lenient read for the engine: a missing or undecodable file gives defaults (the failure is logged at error level).
    /// Non-nil only inside an XCTest process: a temporary folder that stands in for Application Support/GDHub.
    static let testSupportDirectory: URL? = {
        guard NSClassFromString("XCTestCase") != nil else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func load() -> ControlMapping {
        do {
            return try loadStrict()
        } catch {
            Self.log.error("could not read \(url.path, privacy: .public): \(String(describing: error), privacy: .public). Using defaults.")
            return .default
        }
    }

    /// Missing file gives `.default`; a file that cannot be decoded throws.
    func loadStrict() throws -> ControlMapping {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        return try JSONDecoder().decode(ControlMapping.self, from: Data(contentsOf: url))
    }

    /// GUI start: strict read; an unreadable file is moved aside first, so no later save overwrites the only copy.
    /// `note` receives the event-log line when that happened.
    func loadMovingUnreadableAside(now: Date = Date(), note: (String) -> Void) -> ControlMapping {
        do {
            return try loadStrict()
        } catch {
            let name = moveAside(now: now)
            Self.log.error("mapping file could not be read (\(String(describing: error), privacy: .public)); kept as \(name ?? "(move failed)", privacy: .public)")
            note("Mapping file could not be read; kept as \(name ?? "(move failed)"), using defaults")
            return .default
        }
    }

    /// Moves the file to `<name>.unreadable-<yyyyMMdd-HHmmss>.json` in the same folder; returns the new file name.
    func moveAside(now: Date = Date()) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var name = "\(base).unreadable-\(f.string(from: now)).json"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base).unreadable-\(f.string(from: now))-\(n).json"
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    static let backupsKept = 40

    var backupsDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("mapping-backups", isDirectory: true) }

    func backups() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// True when the file on disk has an `outputs` key and `mapping` would write none, or the other way round.
    static func outputsKeyChanges(existing: Data, saving mapping: ControlMapping) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else { return false }
        let onDisk = obj["outputs"] != nil
        let willWrite = !mapping.outputs.isEmpty          // `encode` omits an empty `outputs`
        return onDisk != willWrite
    }

    /// True when `mapping` holds a remap a step-1 app does not know (a paddle or SAX key, which it would drop at its next
    /// save) and its `outputs` differ from the file on disk in ids or in values. A missing or unreadable file counts as
    /// having no `outputs`.
    static func newBackupNeeded(existing: Data?, saving mapping: ControlMapping) -> Bool {
        guard mapping.outputs.keys.contains(where: { ControlMapping.echoKeyIDs.contains($0) }) else { return false }
        var onDisk: [String: String] = [:]
        if let existing, let obj = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any],
           let o = obj["outputs"] as? [String: String] {
            onDisk = o
        }
        return onDisk != mapping.outputs.mapValues(\.string)
    }

    /// Ends of a backup of the new bytes: `mapping <stamp> new.json` (and `mapping <stamp>-2 new.json` for a second one in
    /// the same second).
    static let newBackupSuffix = " new.json"

    func save(_ mapping: ControlMapping) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(mapping)
            // Remaps are new in file format v2; an older app reading it would drop them, so the previous file is kept
            // (timestamped, last `backupsKept`) whenever a save adds or removes `outputs`. A step-1 app also drops the
            // paddle and SAX entries it does not know, so whenever such an entry is added or changed the new bytes are kept
            // too (`mapping <stamp> new.json`), and the newest of those is never pruned.
            // Best effort: a backup that cannot be written must never cost the save itself.
            let existing = try? Data(contentsOf: url)
            let backUpOld = existing.map { Self.outputsKeyChanges(existing: $0, saving: mapping) } ?? false
            let backUpNew = Self.newBackupNeeded(existing: existing, saving: mapping)
            if backUpOld || backUpNew {
                do {
                    try fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "yyyy-MM-dd HH-mm-ss"
                    let stamp = f.string(from: Date())
                    func free(_ suffix: String) -> URL {
                        var candidate = backupsDirectory.appendingPathComponent("mapping \(stamp)\(suffix)")
                        var n = 2
                        while fm.fileExists(atPath: candidate.path) {      // two changes in one second: keep both
                            candidate = backupsDirectory.appendingPathComponent("mapping \(stamp)-\(n)\(suffix)"); n += 1
                        }
                        return candidate
                    }
                    if backUpOld, let existing { try existing.write(to: free(".json"), options: .atomic) }
                    if backUpNew { try data.write(to: free(Self.newBackupSuffix), options: .atomic) }
                    let newest = backups().first { $0.lastPathComponent.hasSuffix(Self.newBackupSuffix) }
                    for old in backups().dropFirst(Self.backupsKept) where old != newest { try? fm.removeItem(at: old) }
                } catch {
                    Self.log.error("could not back up \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("could not save \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

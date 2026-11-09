import Foundation

/// Persists a ControlMapping as JSON under ~/Library/Application Support/GDHub/.
struct MappingStore {
    let url: URL

    static let envisionPro = MappingStore(url: defaultURL(fileName: "envision-pro-mapping.json"))

    static func defaultURL(fileName: String) -> URL {
        // Dev aid for scripted checks: `GDHUB_SUPPORT_DIR=<dir>` replaces ~/Library/Application Support/GDHub.
        if let dir = ProcessInfo.processInfo.environment["GDHUB_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(fileName)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GDHub", isDirectory: true).appendingPathComponent(fileName)
    }

    func load() -> ControlMapping {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ControlMapping.self, from: data)
        } catch {
            print("MappingStore: could not read \(url.path): \(error). Using defaults.")
            return .default
        }
    }

    func save(_ mapping: ControlMapping) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(mapping).write(to: url, options: .atomic)
        } catch {
            print("MappingStore: could not save \(url.path): \(error)")
        }
    }
}

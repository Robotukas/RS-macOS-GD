import Foundation
import CryptoKit

/// Writes run reports and hashes the things a report is compared by.
enum DevRunReportStore {
    /// Raw reports per attempt: the judge sees the whole stream, the file keeps the first 4000 and the last 2000.
    static let rawHead = 4000
    static let rawTail = 2000

    /// `dev-runs/<yyyy-MM-ddTHH-mm-ss>_<path>_<templateId>.json` under the support directory.
    static func fileName(startedAt: Date, path: String, templateId: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return "\(f.string(from: startedAt))_\(sanitized(path))_\(sanitized(templateId)).json"
    }

    static func url(startedAt: Date, path: String, templateId: String, directory: URL? = nil) -> URL {
        let name = fileName(startedAt: startedAt, path: path, templateId: templateId)
        if let directory { return directory.appendingPathComponent(name) }
        return MappingStore.defaultURL(fileName: "dev-runs/\(name)")
    }

    /// Head 4000 + tail 2000 of `raw`, and how many reports were left out between them.
    static func capped(_ raw: [DevRawReport]) -> (kept: [DevRawReport], dropped: Int) {
        guard raw.count > rawHead + rawTail else { return (raw, 0) }
        return (Array(raw.prefix(rawHead)) + Array(raw.suffix(rawTail)), raw.count - rawHead - rawTail)
    }

    /// The report as it goes to disk: every attempt's raw list capped, `rawDropped` set.
    static func capped(_ report: DevRunReport) -> DevRunReport {
        var r = report
        for s in r.steps.indices {
            for a in r.steps[s].attempts.indices {
                let (kept, dropped) = capped(r.steps[s].attempts[a].raw)
                r.steps[s].attempts[a].raw = kept
                r.steps[s].attempts[a].metrics.rawDropped = dropped
            }
        }
        return r
    }

    /// Atomic write (temp file, then rename), directories created on demand. Returns where it went.
    @discardableResult
    static func write(_ report: DevRunReport, startedAt: Date, directory: URL? = nil) throws -> URL {
        let target = url(startedAt: startedAt, path: report.effectivePath ?? report.requestedPath,
                         templateId: report.header.templateId, directory: directory)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try capped(report).encoded().write(to: target, options: .atomic)
        return target
    }

    // MARK: Hashes

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the mapping as sorted-keys JSON: equal mappings hash equal whatever order they were built in.
    static func mappingHash(_ mapping: ControlMapping) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256Hex((try? e.encode(mapping)) ?? Data())
    }

    /// SHA-256 of the template as compact sorted-keys JSON, so formatting of the file does not matter but any
    /// change to a step does.
    static func templateSha256(_ template: DevTemplate) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256Hex((try? e.encode(template)) ?? Data())
    }

    private static func sanitized(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" ? Character($0) : "-" }
        let out = String(cleaned)
        return out.isEmpty ? "unknown" : out
    }
}

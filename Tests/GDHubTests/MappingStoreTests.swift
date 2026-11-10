import XCTest
@testable import GDHub

final class MappingStoreTests: XCTestCase {
    private var dir: URL!
    private var store: MappingStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-mapstore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MappingStore(url: dir.appendingPathComponent("envision-pro-mapping.json"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func remapped() -> ControlMapping {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        return m
    }

    func testLoadStrictMissingFileIsDefaultAndGarbageThrows() throws {
        XCTAssertEqual(try store.loadStrict(), .default)
        try Data("nope".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.loadStrict())
        XCTAssertEqual(store.load(), .default, "the lenient read still falls back")
    }

    func testBackupWhenOutputsAppearsOrDisappearsOnly() {
        store.save(.default)
        store.save(.default)
        XCTAssertTrue(store.backups().isEmpty, "no outputs either way")
        store.save(remapped())
        XCTAssertEqual(store.backups().count, 1, "outputs appeared")
        var other = remapped()
        other.setOutput(.pad(.x), for: "g5")
        store.save(other)
        XCTAssertEqual(store.backups().count, 1, "outputs changed but the key was already there")
        let before = (try? Data(contentsOf: store.backups()[0])) ?? Data()
        XCTAssertFalse(String(decoding: before, as: UTF8.self).isEmpty)
        store.save(.default)
        // Same second as the first backup is skipped by design (the pattern never overwrites); the file still saved.
        XCTAssertGreaterThanOrEqual(store.backups().count, 1)
        XCTAssertEqual(store.load(), .default)
    }

    func testBackupHoldsThePreviousBytes() throws {
        store.save(remapped())                       // first save: nothing on disk before, no backup
        XCTAssertTrue(store.backups().isEmpty)
        let old = try Data(contentsOf: store.url)
        store.save(.default)                         // outputs disappears
        let b = store.backups()
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(try Data(contentsOf: b[0]), old)
    }

    func testUnreadableFileIsMovedAsideBeforeDefaultsAreUsed() throws {
        try Data("{ broken".utf8).write(to: store.url)
        var notes: [String] = []
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let m = store.loadMovingUnreadableAside(now: now) { notes.append($0) }
        XCTAssertEqual(m, .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("envision-pro-mapping.unreadable-") && names[0].hasSuffix(".json"), names[0])
        XCTAssertEqual(notes, ["Mapping file could not be read; kept as \(names[0]), using defaults"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(names[0])), Data("{ broken".utf8))
        // A readable or missing file is untouched and silent.
        notes = []
        XCTAssertEqual(store.loadMovingUnreadableAside { notes.append($0) }, .default)
        XCTAssertTrue(notes.isEmpty)
    }
}

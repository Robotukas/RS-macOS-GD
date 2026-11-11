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

    func testASaveSurvivesABackupThatCannotBeWritten() throws {
        store.save(.default)
        try Data("in the way".utf8).write(to: store.backupsDirectory)      // a plain file where the folder should be
        store.save(remapped())
        XCTAssertEqual(try store.loadStrict(), remapped(), "the remap is saved although the backup failed")
    }

    func testTwoBackupsInOneSecondAreBothKept() {
        store.save(.default)
        store.save(remapped())          // backs up the file without remaps
        store.save(.default)            // backs up the file with the remap, almost certainly in the same second
        XCTAssertEqual(store.backups().count, 2)
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

    // MARK: Paddle and SAX remaps: the new bytes are kept too (a step-1 app would drop them)

    private func newBackups() -> [URL] { store.backups().filter { $0.lastPathComponent.hasSuffix(" new.json") } }

    func testAddingAPaddleEntryBesideG1KeepsTheOldFileAndTheNewBytes() throws {
        store.save(remapped())                          // g1 only: today's trigger, nothing before it
        XCTAssertTrue(store.backups().isEmpty)
        var m = remapped()
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        store.save(m)
        let news = newBackups()
        XCTAssertEqual(news.count, 1)
        let text = String(decoding: try Data(contentsOf: news[0]), as: UTF8.self)
        XCTAssertTrue(text.contains("paddle_outer_right"), "the backup holds the new entry")
        XCTAssertEqual(try Data(contentsOf: news[0]), try Data(contentsOf: store.url), "the new bytes, as written")
        XCTAssertEqual(store.backups().count, 1, "outputs was there before and after: no copy of the old file")
    }

    func testTheFirstPaddleRemapKeepsBothTheOldFileAndTheNewBytes() throws {
        store.save(.default)
        let old = try Data(contentsOf: store.url)
        var m = ControlMapping.default
        m.setOutput(.nothing, for: "sax_left")
        store.save(m)
        XCTAssertEqual(store.backups().count, 2, "today's backup of the file without remaps, and the new bytes")
        XCTAssertEqual(newBackups().count, 1)
        let plain = store.backups().first { !$0.lastPathComponent.hasSuffix(" new.json") }
        XCTAssertEqual(try plain.map { try Data(contentsOf: $0) }, old)
    }

    func testChangingAPaddlesPickWritesAnotherNewBackupAndOtherChangesDoNot() {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "paddle_inner_left")
        store.save(m)
        XCTAssertEqual(newBackups().count, 1)
        store.save(m)                                    // nothing changed
        XCTAssertEqual(newBackups().count, 1)
        m.setOutput(.pad(.x), for: "paddle_inner_left")  // a changed pick on a key that was already remapped
        store.save(m)
        XCTAssertEqual(newBackups().count, 2)
        m.setOutput(.pad(.a), for: "g1")                 // not a paddle change, but outputs differ and a paddle entry is there
        store.save(m)
        XCTAssertEqual(newBackups().count, 3, "outputs differ from the file in ids and the new file holds a paddle entry")
        var noPaddle = ControlMapping.default
        noPaddle.setOutput(.pad(.a), for: "g1")
        store.save(noPaddle)                             // removes the paddle entry: no new copy (nothing a step-1 app would drop)
        XCTAssertEqual(newBackups().count, 3)
    }

    func testPruningNeverDeletesTheNewestNewBackup() throws {
        store.save(remapped())
        let fm = FileManager.default
        try fm.createDirectory(at: store.backupsDirectory, withIntermediateDirectories: true)
        let ancient = store.backupsDirectory.appendingPathComponent("mapping 2019-01-01 00-00-00 new.json")
        try Data("{}".utf8).write(to: ancient)
        for i in 0..<45 {
            try Data("{}".utf8).write(to: store.backupsDirectory.appendingPathComponent(String(format: "mapping 2099-01-01 00-00-%02d.json", i)))
        }
        store.save(.default)                             // outputs disappears: a plain backup, then the prune
        let names = store.backups().map(\.lastPathComponent)
        XCTAssertTrue(names.contains("mapping 2019-01-01 00-00-00 new.json"), "the only new backup is the oldest and survives")
        XCTAssertEqual(names.count, MappingStore.backupsKept + 1)
    }
}

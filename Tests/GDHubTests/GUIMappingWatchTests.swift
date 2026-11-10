import XCTest
@testable import GDHub

@MainActor
final class GUIMappingWatchTests: XCTestCase {
    private var dir: URL!
    private var store: MappingStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-guiwatch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MappingStore(url: dir.appendingPathComponent("envision-pro-mapping.json"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func wait(_ cond: () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !cond() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testStartMovesAnUnreadableFileAsideAndLogsIt() throws {
        try Data("{ broken".utf8).write(to: store.url)
        let device = EnvisionProDevice(layout: nil, store: store)
        XCTAssertEqual(device.mapping, .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertTrue(device.eventLog.first?.text.hasPrefix("Mapping file could not be read; kept as envision-pro-mapping.unreadable-") == true)
    }

    func testExternalChangeIsAdoptedWithoutLoopingAndOwnSavesAreNotReadopted() async {
        let device = EnvisionProDevice(layout: nil, store: store)
        device.startMappingWatch(debounce: 0.03)
        var external = ControlMapping.default
        external.setOutput(.pad(.y), for: "g1")
        store.save(external)                                  // an outside writer
        await wait { device.mapping == external }
        XCTAssertEqual(device.mapping, external)
        let revision = device.mappingRevision
        let bytes = try? Data(contentsOf: store.url)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(device.mappingRevision, revision, "no echo")
        XCTAssertEqual(try? Data(contentsOf: store.url), bytes, "an adopted mapping is not written back")
        // The GUI's own edit saves once and the watcher does not bounce it back.
        device.mapping.buttons["x"] = .button(9)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(device.mapping.buttons["x"], .button(9))
        XCTAssertEqual(try? store.loadStrict(), device.mapping)
        device.stopMappingWatch()
    }
}

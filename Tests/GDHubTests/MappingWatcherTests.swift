import XCTest
@testable import GDHub

final class MappingWatcherTests: XCTestCase {
    private var dir: URL!
    private var store: MappingStore!
    private let queue = DispatchQueue(label: "test.mapwatch")
    private var delivered: [ControlMapping] = []
    private let lock = NSLock()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-mapwatch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MappingStore(url: dir.appendingPathComponent("envision-pro-mapping.json"))
        delivered = []
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func count() -> Int { lock.lock(); defer { lock.unlock() }; return delivered.count }

    private func waitFor(count n: Int, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if count() >= n { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return count() >= n
    }

    private func mapping(_ n: Int) -> ControlMapping {
        var m = ControlMapping.default
        m.buttons["x"] = .button(n)
        return m
    }

    func testAtomicWritesFireOnceEachAndSurviveTheInodeSwap() {
        let w = MappingWatcher(store: store, initial: .default, queue: queue, debounce: 0.03) { [self] m in
            lock.lock(); delivered.append(m); lock.unlock()
        }
        XCTAssertTrue(w.start())
        store.save(mapping(9))
        XCTAssertTrue(waitFor(count: 1), "first atomic write")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(count(), 1, "one reload for one write")
        store.save(mapping(10))
        XCTAssertTrue(waitFor(count: 2), "the directory watch survived the rename of the first write")
        XCTAssertEqual(delivered.last, mapping(10))
        w.stop()
    }

    func testIdenticalRewriteDoesNotDeliver() {
        let w = MappingWatcher(store: store, initial: .default, queue: queue, debounce: 0.03) { [self] m in
            lock.lock(); delivered.append(m); lock.unlock()
        }
        XCTAssertTrue(w.start())
        store.save(mapping(9))
        XCTAssertTrue(waitFor(count: 1))
        store.save(mapping(9))
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(count(), 1)
        w.stop()
    }

    func testOutputsOnlyChangeDelivers() {
        let w = MappingWatcher(store: store, initial: .default, queue: queue, debounce: 0.03) { [self] m in
            lock.lock(); delivered.append(m); lock.unlock()
        }
        XCTAssertTrue(w.start())
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        store.save(m)
        XCTAssertTrue(waitFor(count: 1))
        XCTAssertEqual(delivered.last?.outputs["g1"], .pad(.y))
        w.stop()
    }

    func testUndecodableFileDeliversNothingAndALaterGoodFileDelivers() throws {
        store.save(mapping(9))
        let w = MappingWatcher(store: store, initial: mapping(9), queue: queue, debounce: 0.03) { [self] m in
            lock.lock(); delivered.append(m); lock.unlock()
        }
        XCTAssertTrue(w.start())
        try Data("{ not json".utf8).write(to: store.url, options: .atomic)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(count(), 0, "a half-written or broken file keeps the last good mapping in force")
        store.save(mapping(10))
        XCTAssertTrue(waitFor(count: 1))
        XCTAssertEqual(delivered.last, mapping(10))
        w.stop()
    }
}

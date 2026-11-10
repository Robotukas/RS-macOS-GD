import XCTest
@testable import GDHub

/// Pins the bytes an un-remapped mapping is saved and hashed as (remap plan R1): adding `outputs` to the model must
/// not change the JSON file, the GDHM blob or `mappingHash` of a mapping that has no remaps.
/// `GDHUB_RECORD_MAPPING_PINS=1 swift test --filter MappingPinTests` rewrites the two JSON fixtures.
final class MappingPinTests: XCTestCase {
    private static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/mapping", isDirectory: true)

    /// Exactly what `MappingStore.save` writes.
    private func saved(_ m: ControlMapping) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mappin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MappingStore(url: dir.appendingPathComponent("m.json"))
        store.save(m)
        return try Data(contentsOf: store.url)
    }

    private func check(_ m: ControlMapping, _ name: String) throws {
        let url = Self.dir.appendingPathComponent(name)
        let now = try saved(m)
        if ProcessInfo.processInfo.environment["GDHUB_RECORD_MAPPING_PINS"] == "1" {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try now.write(to: url)
        }
        XCTAssertEqual(String(decoding: now, as: UTF8.self), String(decoding: try Data(contentsOf: url), as: UTF8.self), name)
        XCTAssertEqual(try JSONDecoder().decode(ControlMapping.self, from: Data(contentsOf: url)), m, "\(name) loads back")
    }

    func testSavedDefaultMappingIsPinned() throws { try check(.default, "default.json") }
    func testSavedEmptyMappingIsPinned() throws { try check(ControlMapping(), "empty.json") }

    func testMappingHashesArePinned() {
        XCTAssertEqual(DevRunReportStore.mappingHash(.default), "b133bdd990d69781b21314b010ff21e4fb33df2dd99654c15957e1cea32e9af1")
        XCTAssertEqual(DevRunReportStore.mappingHash(ControlMapping()), "d328f3c1fc14e0ce8b5f30d48f8e9d081fb329497803b672f20e43d151962d2f")
    }
}

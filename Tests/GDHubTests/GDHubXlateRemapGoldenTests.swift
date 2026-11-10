import XCTest
import GDHubXlate
@testable import GDHub

/// Remapped mappings over the same 64 golden frames as `GDHubXlateGoldenTests`, Swift only: the expected bytes come from
/// the Swift pipeline (the oracle), the C core runs the blob the encoder writes for the mapping. Nothing here is written to
/// `Shared/GDHubDefaults.h`, so the driver's built-in self-test and its checked-in blob do not change with remaps.
final class GDHubXlateRemapGoldenTests: XCTestCase {
    typealias F = XlateFixtures
    typealias G = GDHubXlateGoldenTests

    private static func mapping(_ picks: [(String, ControlOutput)]) -> ControlMapping {
        var m = ControlMapping.default
        for (id, o) in picks { m.setOutput(o, for: id) }
        return m
    }

    /// The fixed remaps: G1 sends Y, A and B swapped, one item with two sources plus a dropped one, LT and RT swapped.
    static let cases: [(String, ControlMapping)] = [
        ("g1 sends Y", mapping([("g1", .pad(.y))])),
        ("A and B swapped", mapping([("a", .pad(.b)), ("b", .pad(.a))])),
        ("two sources on X, Guide and L3 dropped", mapping([("g1", .pad(.x)), ("start", .nothing), ("l3", .nothing)])),
        ("LT and RT swapped", mapping([("lt", .pad(.rt)), ("rt", .pad(.lt))])),
        ("LT sends A", mapping([("lt", .pad(.a))])),
    ]

    private func check(_ name: String, _ m: ControlMapping) throws -> Int {
        let core = try F.core(m)
        let oracle = SwiftOracle(mapping: m, identity: .xboxBT16_02E0)
        let factory = try F.core(.default)
        var differs = 0
        let log = MismatchLog()
        for (n, raw) in G.goldenFrames.enumerated() {
            let want = oracle.reports(oracle.state(raw)!).map(\.bytes)
            let got = core.reports(try XCTUnwrap(core.eval(raw: raw))).map(\.bytes)
            if got != want { log.note("vector \(n): \(hex(raw)) -> C \(got.map { hex($0) }) vs Swift \(want.map { hex($0) })") }
            if factory.reports(try XCTUnwrap(factory.eval(raw: raw))).map(\.bytes) != want { differs += 1 }
            // the same through gdx_step on a fresh state, which posts both reports for the first frame
            var map = core.map; var st = gdx_state(); var out = gdx_out()
            let mask = raw.withUnsafeBufferPointer { gdx_step(&st, &map, $0.baseAddress, 16, &out) }
            if mask != 3 || XlateCore.reports(out).map(\.bytes) != want { log.note("vector \(n): gdx_step differs") }
        }
        log.assertNone("\(name)")
        return differs
    }

    func testRemappedMappingsMatchTheSwiftPipelineOverTheGoldenFrames() throws {
        for (name, m) in Self.cases {
            XCTAssertNil(MapBlobEncoder.remapLimit(m), name)
            let differs = try check(name, m)
            XCTAssertGreaterThan(differs, 0, "\(name) must change the output on at least one golden frame, or it proves nothing")
        }
    }

    /// Spot checks of the expected bytes themselves, so a wrong oracle cannot hide behind agreement.
    func testTheRemapsDoWhatTheyAreCalled() throws {
        func report(_ m: ControlMapping, _ raw: [UInt8]) throws -> [UInt8] {
            let core = try F.core(m)
            return core.reports(try XCTUnwrap(core.eval(raw: raw)))[0].bytes
        }
        func frame(buttons: Int = 0, lt: Int = 0, rt: Int = 0) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 16); b[0] = 6
            F.setTriggers(&b, lt, rt, hat: 8); F.setButtons(&b, buttons, extra: 0)
            return b
        }
        // Report 0x01: byte 14 holds A B X Y LB RB View Menu as bits 0...7; the trigger fields are little-endian at 9...10 / 11...12.
        let g1 = 1 << 11, a = 1 << 0
        XCTAssertEqual(try report(Self.cases[0].1, frame(buttons: g1))[14], 0b1000, "G1 sends Y")
        XCTAssertEqual(try report(Self.cases[0].1, frame(buttons: a))[14], 0b0001, "A still sends A")
        XCTAssertEqual(try report(Self.cases[1].1, frame(buttons: a))[14], 0b0010, "A sends B")
        XCTAssertEqual(try report(.default, frame(buttons: g1))[14], 0, "un-remapped G1 sends nothing")
        let swapped = Self.cases[3].1
        let r = try report(swapped, frame(lt: 1023, rt: 0))
        XCTAssertEqual(UInt16(r[9]) | UInt16(r[10]) << 8, 0, "LT output is quiet when only the physical LT is pulled")
        XCTAssertEqual(UInt16(r[11]) | UInt16(r[12]) << 8, 1023, "the physical LT is the pad's RT")
        let toA = try report(Self.cases[4].1, frame(lt: 1023))
        XCTAssertEqual(toA[14] & 1, 1, "LT sends A")
        XCTAssertEqual(UInt16(toA[9]) | UInt16(toA[10]) << 8, 0)
    }
}

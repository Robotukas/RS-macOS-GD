import XCTest
@testable import GDHub

/// The Start block for a template whose steps would all be skipped for the mapping (remap R4): the words come from the
/// same comparison the runner skips steps with.
final class DevRequirementCheckTests: XCTestCase {
    private let layout = ControlLayout.loadFromBundle()!

    private func builtIn(_ id: String) throws -> DevTemplate {
        try XCTUnwrap(DevBuiltins.generate(layout: layout).first { $0.id == id }, id)
    }

    private func mapping(_ picks: [(String, PadOutput)]) -> ControlMapping {
        var m = ControlMapping.default
        for (cid, out) in picks { m.setOutput(.pad(out), for: cid) }
        return m
    }

    func testAllMetGivesNothingAndNoBlock() throws {
        let t = try builtIn("remap-g1-as-y")
        let m = mapping([("g1", .y)])
        XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: m, layout: layout), [])
        XCTAssertNil(DevRequirementCheck.startBlock(template: t, mapping: m, layout: layout))
        let swap = try builtIn("remap-swap-a-b")
        let both = mapping([("a", .b), ("b", .a)])
        XCTAssertEqual(DevRequirementCheck.unmet(template: swap, mapping: both, layout: layout), [])
        XCTAssertNil(DevRequirementCheck.startBlock(template: swap, mapping: both, layout: layout))
    }

    func testG1AtItsDefaultIsOneOwnerReadableItemAndBlocksStart() throws {
        let t = try builtIn("remap-g1-as-y")
        XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: .default, layout: layout), ["G1 → Y"], "listed once, not once per step")
        XCTAssertTrue(DevRequirementCheck.everyStepUnmet(template: t, mapping: .default))
        XCTAssertEqual(DevRequirementCheck.startBlock(template: t, mapping: .default, layout: layout),
                       "Needs G1 → Y: set it in Mapping first (leave Developer mode, press Mapping, pick, Done)")
        // G1 sent somewhere else is just as unmet
        XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: mapping([("g1", .x)]), layout: layout), ["G1 → Y"])
    }

    func testASwapHalfSetNamesTheMissingHalf() throws {
        let t = try builtIn("remap-swap-a-b")
        XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: mapping([("a", .b)]), layout: layout), ["B → A"])
        XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: mapping([("b", .a)]), layout: layout), ["A → B"])
        XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: .default, layout: layout), ["A → B", "B → A"])
        XCTAssertEqual(DevRequirementCheck.startBlock(template: t, mapping: mapping([("a", .b)]), layout: layout),
                       "Needs B → A: set it in Mapping first (leave Developer mode, press Mapping, pick, Done)")
        XCTAssertEqual(DevRequirementCheck.startBlock(template: t, mapping: .default, layout: layout),
                       "Needs A → B; B → A: set it in Mapping first (leave Developer mode, press Mapping, pick, Done)")
    }

    func testOnlySomeStepsUnmetDoesNotBlock() {
        var needs = DevStep(id: "needs", kind: .digital, controls: ["g1"], title: "t")
        var r = DevRequires(); r.mapping = ["g1": "y"]
        needs.requires = r
        let free = DevStep(id: "free", kind: .digital, controls: ["a"], title: "t")
        let t = DevTemplate(id: "mixed", title: "t", steps: [needs, free])
        XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: .default, layout: layout), ["G1 → Y"], "the item is still listed")
        XCTAssertFalse(DevRequirementCheck.everyStepUnmet(template: t, mapping: .default))
        XCTAssertNil(DevRequirementCheck.startBlock(template: t, mapping: .default, layout: layout), "the other step still runs")
    }

    func testTemplatesWithoutRequirementsAreNeverBlocked() {
        for t in DevBuiltins.generate(layout: layout) where !t.id.hasPrefix("remap-") && t.id != "gkeys-volume" {
            XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: .default, layout: layout), [], t.id)
            XCTAssertNil(DevRequirementCheck.startBlock(template: t, mapping: .default, layout: layout), t.id)
        }
        XCTAssertFalse(DevRequirementCheck.everyStepUnmet(template: DevTemplate(id: "empty", title: "t", steps: []), mapping: .default))
    }

    func testNothingAndBuiltInRequirementsReadInPlainWords() {
        var g2 = DevStep(id: "g2", kind: .digital, controls: ["g2"], title: "t")
        var g4 = DevStep(id: "g4", kind: .digital, controls: ["g4"], title: "t")
        var r2 = DevRequires(); r2.mapping = ["g2": "nothing"]
        var r4 = DevRequires(); r4.mapping = ["g4": "built_in"]
        g2.requires = r2; g4.requires = r4
        let t = DevTemplate(id: "volume", title: "t", steps: [g2, g4])
        var m = ControlMapping.default
        m.setOutput(.nothing, for: "g4")
        XCTAssertEqual(DevRequirementCheck.unmet(template: t, mapping: m, layout: layout), ["G2 → Nothing", "G4 at its built-in function"])
        XCTAssertEqual(DevRequirementCheck.startBlock(template: t, mapping: m, layout: layout),
                       "Needs G2 → Nothing; G4 at its built-in function: set it in Mapping first (leave Developer mode, press Mapping, pick, Done)")
    }
}

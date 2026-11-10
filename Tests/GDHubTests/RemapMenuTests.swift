import XCTest
@testable import GDHub

final class RemapMenuTests: XCTestCase {
    private func menu(_ id: String, _ m: ControlMapping = .default) throws -> RemapMenuModel {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        let c = try XCTUnwrap(layout.control(id: id))
        return RemapMenuModel(controlID: id, label: c.label, kind: c.kind, mapping: m)
    }

    private func titles(_ model: RemapMenuModel) -> [[String]] { model.groups.map { $0.map(\.title) } }
    private func entry(_ model: RemapMenuModel, _ output: ControlOutput) throws -> RemapMenuModel.Entry {
        try XCTUnwrap(model.entries.first { $0.output == output })
    }

    private let padTitles: [[String]] = [
        ["A", "B", "X", "Y"], ["LB", "RB", "LT", "RT"], ["View", "Menu", "L3", "R3"],
        ["D-pad up", "D-pad down", "D-pad left", "D-pad right"], ["Guide (Xbox button)"],
    ]

    // MARK: Contents and order

    func testG1MenuHasTheMockupsGroupsInOrder() throws {
        let m = try menu("g1")
        XCTAssertEqual(m.kind, .remappable)
        XCTAssertEqual(m.header, "G1 sends")
        XCTAssertNil(m.note)
        XCTAssertEqual(titles(m), padTitles + [["Nothing"]])
        XCTAssertEqual(m.relearnTitle, "Re-learn button…")
        XCTAssertEqual(m.reset, RemapMenuModel.Reset(title: "Reset to default", isEnabled: false))
        XCTAssertEqual(m.footnote, RemapMenuModel.footnoteText, "LT and RT are marked on every button's menu")
        XCTAssertEqual(try entry(m, .pad(.guide)).title, "Guide (Xbox button)")
    }

    func testG1DefaultIsNothingAndItIsTicked() throws {
        let m = try menu("g1")
        let nothing = try entry(m, .nothing)
        XCTAssertTrue(nothing.isCurrent)
        XCTAssertTrue(nothing.isDefault)
        XCTAssertEqual(m.entries.filter(\.isCurrent).count, 1)
        XCTAssertEqual(m.entries.filter(\.isDefault).count, 1)
    }

    func testVolumeKeysStartWithTheirBuiltInEntryAsTheDefault() throws {
        for (id, title) in [("g2", "Volume down (built in)"), ("g3", "Volume up (built in)"), ("g4", "Mute (built in)")] {
            let m = try menu(id)
            XCTAssertEqual(titles(m), [[title]] + padTitles + [["Nothing"]], id)
            XCTAssertEqual(m.note, "Mapped: \(id.uppercased()) no longer changes the volume.")
            let builtIn = try entry(m, .builtIn)
            XCTAssertTrue(builtIn.isDefault)
            XCTAssertTrue(builtIn.isCurrent)
            let nothing = try entry(m, .nothing)
            XCTAssertFalse(nothing.isDefault, "Nothing is a real pick on a volume key, not the default")
            XCTAssertFalse(nothing.isCurrent)
        }
    }

    func testNothingOnAVolumeKeyIsDistinctFromBuiltIn() throws {
        var map = ControlMapping.default
        map.setOutput(.nothing, for: "g2")
        let m = try menu("g2", map)
        XCTAssertTrue(try entry(m, .nothing).isCurrent)
        XCTAssertFalse(try entry(m, .builtIn).isCurrent)
        XCTAssertTrue(try entry(m, .builtIn).isDefault)
        XCTAssertTrue(m.reset?.isEnabled == true)
    }

    func testOrdinaryButtonMenuTicksItselfAsDefault() throws {
        let m = try menu("y")
        XCTAssertEqual(m.header, "Y sends")
        XCTAssertNil(m.note)
        XCTAssertTrue(try entry(m, .pad(.y)).isCurrent)
        XCTAssertTrue(try entry(m, .pad(.y)).isDefault)
        XCTAssertFalse(try entry(m, .nothing).isDefault)
    }

    func testTriggerMenuIsTheFullMenu() throws {
        let m = try menu("lt")
        XCTAssertEqual(m.kind, .remappable)
        XCTAssertEqual(m.header, "LT sends")
        XCTAssertEqual(titles(m), padTitles + [["Nothing"]])
        XCTAssertTrue(try entry(m, .pad(.lt)).isCurrent)
        XCTAssertEqual(m.relearnTitle, "Re-learn button…")
    }

    func testStartMenuNoteAndGuideDefault() throws {
        let m = try menu("start")
        XCTAssertEqual(m.note, "Holding Start still switches the controller off.")
        XCTAssertTrue(try entry(m, .pad(.guide)).isDefault)
        XCTAssertTrue(try entry(m, .pad(.guide)).isCurrent)
    }

    func testProfileMenuNote() throws {
        let m = try menu("profile")
        XCTAssertEqual(m.note, "Each press also switches the controller's own profile, which changes what the paddles and SAX keys send.")
        XCTAssertTrue(try entry(m, .nothing).isDefault)
    }

    func testStickMenuHasOnlyTheNoteAndReLearn() throws {
        for id in ["left_stick", "right_stick"] {
            let m = try menu(id)
            XCTAssertEqual(m.kind, .stick)
            XCTAssertEqual(m.note, "Sticks are not remappable in this feature.")
            XCTAssertTrue(m.groups.isEmpty)
            XCTAssertNil(m.reset)
            XCTAssertNil(m.footnote)
            XCTAssertEqual(m.relearnTitle, "Re-learn stick…")
        }
        XCTAssertEqual(try menu("left_stick").header, "Left stick sends")
    }

    func testPaddleAndSaxMenusHaveOnlyTheNoteAndReLearn() throws {
        for id in ["paddle_outer_left", "paddle_inner_right", "sax_left", "sax_right"] {
            let m = try menu(id)
            XCTAssertEqual(m.kind, .deferred, id)
            XCTAssertEqual(m.note, "Remapping paddles and SAX comes next. Until then this key sends the button the controller's profile gives it, and follows that button's remap.")
            XCTAssertTrue(m.groups.isEmpty)
            XCTAssertNil(m.reset)
            XCTAssertEqual(m.relearnTitle, "Re-learn button…")
        }
        XCTAssertEqual(try menu("sax_left").header, "SAX left sends")
    }

    func testEveryRemappableControlGetsAFullMenuAndNothingElseDoes() throws {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        for c in layout.controls {
            let m = RemapMenuModel(controlID: c.id, label: c.label, kind: c.kind, mapping: .default)
            XCTAssertEqual(m.kind == .remappable, ControlMapping.remappableIDs.contains(c.id), c.id)
            if m.kind == .remappable { XCTAssertEqual(m.entries.filter(\.isCurrent).count, 1, c.id) }
        }
    }

    // MARK: Ticks and tags after a pick

    func testTickMovesButTheDefaultTagStays() throws {
        var map = ControlMapping.default
        map = RemapMenuModel.mapping(map, picking: .pad(.y), for: "g1")
        let m = try menu("g1", map)
        XCTAssertTrue(try entry(m, .pad(.y)).isCurrent)
        XCTAssertFalse(try entry(m, .nothing).isCurrent)
        XCTAssertTrue(try entry(m, .nothing).isDefault)
        XCTAssertFalse(try entry(m, .pad(.y)).isDefault)
        XCTAssertEqual(m.reset?.isEnabled, true)
        XCTAssertEqual(map.effectiveOutput("g1"), .pad(.y))
    }

    func testResetIsEnabledOnlyWhileRemapped() throws {
        var map = ControlMapping.default
        XCTAssertEqual(try menu("a", map).reset?.isEnabled, false)
        map.setOutput(.pad(.b), for: "a")
        XCTAssertEqual(try menu("a", map).reset?.isEnabled, true)
        XCTAssertEqual(try menu("b", map).reset?.isEnabled, false, "only the remapped control can be reset")
        map = RemapMenuModel.mappingAfterReset(map, for: "a")
        XCTAssertEqual(try menu("a", map).reset?.isEnabled, false)
        XCTAssertEqual(map, ControlMapping.default)
    }

    func testPickingTheDefaultClearsTheRemap() throws {
        var map = RemapMenuModel.mapping(.default, picking: .nothing, for: "g3")
        XCTAssertTrue(map.isRemapped("g3"))
        map = RemapMenuModel.mapping(map, picking: .builtIn, for: "g3")
        XCTAssertFalse(map.isRemapped("g3"))
    }

    // MARK: Driver limits

    func testOnTheFactoryMappingOnlyTriggerPicksAreMarked() throws {
        for id in ControlMapping.remappableIDs {
            let marked = Set(try menu(id).entries.filter { $0.limit != nil }.map(\.output))
            let expected: Set<ControlOutput>
            switch id {
            case "lt": expected = [.pad(.rt)]
            case "rt": expected = [.pad(.lt)]
            default: expected = [.pad(.lt), .pad(.rt)]       // a button cannot pull a trigger in this driver version
            }
            XCTAssertEqual(marked, expected, id)
        }
    }

    func testTriggersAreMarkedOnG1sMenu() throws {
        let m = try menu("g1")
        XCTAssertNotNil(try entry(m, .pad(.lt)).limit)
        XCTAssertNotNil(try entry(m, .pad(.rt)).limit)
        XCTAssertTrue(try entry(m, .pad(.lt)).limit?.contains("trigger") == true)
        for output in [ControlOutput.nothing, .pad(.y), .pad(.a), .pad(.guide), .pad(.dpad_up)] {
            XCTAssertNil(try entry(m, output).limit, "\(output)")
        }
        XCTAssertEqual(m.footnote, "* With this pick the App drives the controller until the next driver update.")
    }

    func testRTIsMarkedOnLTsMenuWhileRTSendsRTAndUnmarkedAfterRTGoesToA() throws {
        var map = ControlMapping.default
        let before = try menu("lt", map)
        XCTAssertNotNil(try entry(before, .pad(.rt)).limit, "two controls would feed RT")
        XCTAssertNil(try entry(before, .pad(.lt)).limit)
        XCTAssertNil(try entry(before, .pad(.y)).limit)
        XCTAssertNotNil(before.footnote)

        map.setOutput(.pad(.a), for: "rt")
        let after = try menu("lt", map)
        XCTAssertNil(try entry(after, .pad(.rt)).limit, "RT is free now: LT can feed it alone")
        XCTAssertNotNil(try entry(after, .pad(.a)).limit, "but A would now have a, rt and lt")
        XCTAssertNotNil(after.footnote)
    }

    func testYIsMarkedOnG2sMenuWhenYAndG1AlreadySendY() throws {
        var map = ControlMapping.default
        map.setOutput(.pad(.y), for: "g1")
        let m = try menu("g2", map)
        XCTAssertNotNil(try entry(m, .pad(.y)).limit, "y, g1 and g2 would all send Y")
        XCTAssertTrue(try entry(m, .pad(.y)).limit?.contains("Y") == true)
        XCTAssertNil(try entry(m, .pad(.x)).limit)
        XCTAssertNil(try entry(m, .nothing).limit)
        XCTAssertNil(try entry(m, .builtIn).limit)
        XCTAssertNotNil(m.footnote)
        // G2 itself already sends Y? Then picking Y again changes nothing and is not marked.
        map.setOutput(.pad(.y), for: "g2")
        XCTAssertNotNil(RemapHint.limit(of: map))
        let again = try menu("g2", map)
        XCTAssertNil(again.entries.first { $0.limit != nil }, "the mapping already has a limit: nothing new to warn about")
        XCTAssertNil(again.footnote)
    }

    func testNoPickIsMarkedWhenTheMappingAlreadyHasALimit() throws {
        var map = ControlMapping.default
        map.setOutput(.pad(.lt), for: "g1")
        XCTAssertNotNil(RemapHint.limit(of: map))
        for id in ["g2", "a", "rt"] {
            let m = try menu(id, map)
            XCTAssertNil(m.entries.first { $0.limit != nil }, id)
            XCTAssertNil(m.footnote, id)
        }
    }

    func testPickingAnUnmarkedEntryNeverCreatesALimit() throws {
        var map = ControlMapping.default
        map.setOutput(.pad(.y), for: "g1")
        for id in ControlMapping.remappableIDs {
            let m = try menu(id, map)
            for e in m.entries where e.limit == nil {
                let after = RemapMenuModel.mapping(map, picking: e.output, for: id)
                XCTAssertNil(MapBlobEncoder.remapLimit(after), "\(id) -> \(e.title)")
            }
            for e in m.entries where e.limit != nil {
                let after = RemapMenuModel.mapping(map, picking: e.output, for: id)
                XCTAssertEqual(MapBlobEncoder.remapLimit(after), e.limit, "\(id) -> \(e.title)")
            }
        }
    }

    func testMenuEntryIdsAreUniqueWithinAMenu() throws {
        let m = try menu("g2")
        XCTAssertEqual(Set(m.entries.map(\.id)).count, m.entries.count)
        XCTAssertEqual(m.entries.count, 1 + 4 + 4 + 4 + 4 + 1 + 1)
    }
}

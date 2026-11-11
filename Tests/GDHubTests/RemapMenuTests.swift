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
        XCTAssertNil(m.reset, "nothing remapped: no Reset item")
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
        XCTAssertEqual(m.reset, RemapMenuModel.Reset(title: "Reset to default"))
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
        XCTAssertEqual(m.note, "Each press also switches the controller's own profile. Paddles and SAX keys left on Controller's profile change with it; remapped ones keep sending only your pick.")
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

    private let sixIDs = ["paddle_outer_right", "paddle_inner_right", "paddle_inner_left", "paddle_outer_left", "sax_left", "sax_right"]

    func testPaddleAndSaxMenusAreFullMenusStartingOnControllersProfile() throws {
        for id in sixIDs {
            let m = try menu(id)
            XCTAssertEqual(m.kind, .remappable, id)
            XCTAssertEqual(titles(m), [["Controller's profile (built in)"]] + padTitles + [["Nothing"]], id)
            XCTAssertEqual(m.note, "Sends the button the controller's profile gives it, and follows that button's remap.", id)
            let profile = try entry(m, .builtIn)
            XCTAssertTrue(profile.isCurrent, id)
            XCTAssertTrue(profile.isDefault, id)
            XCTAssertEqual(m.entries.filter(\.isCurrent).count, 1, id)
            XCTAssertEqual(m.entries.filter(\.isDefault).count, 1, id)
            XCTAssertFalse(try entry(m, .nothing).isDefault, "Nothing is a pick of its own on these keys")
            XCTAssertNil(m.reset, id)
            XCTAssertEqual(m.relearnTitle, "Re-learn button…", id)
            XCTAssertEqual(m.entries.count, 1 + 4 + 4 + 4 + 4 + 1 + 1, id)
        }
        XCTAssertEqual(try menu("sax_left").header, "SAX left sends")
        XCTAssertEqual(try menu("paddle_outer_left").header, "Paddle outer left sends")
    }

    func testARemappedPaddleTicksItsPickAndHasTheRemappedNote() throws {
        var map = ControlMapping.default
        map.setOutput(.pad(.y), for: "paddle_outer_right")
        let m = try menu("paddle_outer_right", map)
        XCTAssertTrue(try entry(m, .pad(.y)).isCurrent)
        XCTAssertFalse(try entry(m, .builtIn).isCurrent)
        XCTAssertTrue(try entry(m, .builtIn).isDefault, "the default tag stays on Controller's profile")
        XCTAssertEqual(m.note, RemapMenuModel.remappedKeyNote)
        XCTAssertEqual(m.note, "Sends only your pick. The controller's own button for this key is hidden while you hold it, so pressing that same button yourself shows only when you let go.",
                       "mockup v7b NOTE_RM, word for word")
        XCTAssertFalse(m.note?.contains("PLACEHOLDER") ?? true)
        XCTAssertFalse(m.note?.contains("placeholder") ?? true)
        XCTAssertEqual(m.reset, RemapMenuModel.Reset(title: "Reset to default"))
        // Nothing is a remap too, with the same note.
        var none = ControlMapping.default
        none.setOutput(.nothing, for: "sax_left")
        XCTAssertEqual(try menu("sax_left", none).note, RemapMenuModel.remappedKeyNote)
        // Nothing is a pick too.
        map.setOutput(.nothing, for: "paddle_outer_right")
        XCTAssertTrue(try entry(try menu("paddle_outer_right", map), .nothing).isCurrent)
        // A paddle left alone keeps the Controller's-profile note next to a remapped one.
        XCTAssertEqual(try menu("paddle_outer_left", map).note, RemapMenuModel.controllersProfileNote)
        // Picking Controller's profile again clears the remap.
        let back = RemapMenuModel.mapping(map, picking: .builtIn, for: "paddle_outer_right")
        XCTAssertFalse(back.isRemapped("paddle_outer_right"))
        XCTAssertEqual(back, ControlMapping.default)
    }

    func testThereIsNoDeferredKindAnyMore() throws {
        XCTAssertEqual(try menu("left_stick").kind, .stick)
        XCTAssertEqual(try menu("right_stick").kind, .stick)
        for id in sixIDs { XCTAssertEqual(try menu(id).kind, .remappable, id) }
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
        XCTAssertNotNil(m.reset)
        XCTAssertEqual(map.effectiveOutput("g1"), .pad(.y))
    }

    func testResetIsThereOnlyWhileRemapped() throws {
        var map = ControlMapping.default
        XCTAssertNil(try menu("a", map).reset)
        map.setOutput(.pad(.b), for: "a")
        XCTAssertNotNil(try menu("a", map).reset)
        XCTAssertNil(try menu("b", map).reset, "only the remapped control can be reset")
        map = RemapMenuModel.mappingAfterReset(map, for: "a")
        XCTAssertNil(try menu("a", map).reset)
        XCTAssertEqual(map, ControlMapping.default)
        // The same for the six and for a volume key.
        for id in sixIDs + ["g2"] {
            XCTAssertNil(try menu(id).reset, id)
            var m = ControlMapping.default
            m.setOutput(.pad(.y), for: id)
            XCTAssertNotNil(try menu(id, m).reset, id)
        }
    }

    // MARK: The signal-conflict note

    private func menu(_ id: String, _ m: ControlMapping, words: Bool) throws -> RemapMenuModel {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        let c = try XCTUnwrap(layout.control(id: id))
        return RemapMenuModel(controlID: id, label: c.label, kind: c.kind, mapping: m,
                              labelOf: { layout.control(id: $0)?.label ?? $0 })
    }

    func testSignalConflictNoteIsOnTheRemappedKeysMenuInWords() throws {
        var map = ControlMapping.default
        map.physicalBits["dpad_right"] = 1                    // an old learn gave D-pad right paddle outer right's signal
        XCTAssertNil(try menu("paddle_outer_right", map, words: true).conflictNote, "not remapped: nothing hidden, no conflict")
        map.setOutput(.pad(.y), for: "paddle_outer_right")
        let m = try menu("paddle_outer_right", map, words: true)
        XCTAssertEqual(m.conflictNote, "D-pad right was learned with Paddle outer right's signal: re-learn D-pad right.")
        XCTAssertEqual(m.note, RemapMenuModel.remappedKeyNote, "the conflict is a second note, the first stays")
        let text = try XCTUnwrap(m.conflictNote)
        XCTAssertFalse(text.contains("dpad_right"), "never a raw id")
        XCTAssertFalse(text.contains("paddle_outer_right"))
        XCTAssertFalse(text.contains("App drives"))
        XCTAssertFalse(text.contains("driver update"))
        // Only that key's menu, and not the other control's.
        XCTAssertNil(try menu("paddle_inner_right", map, words: true).conflictNote)
        XCTAssertNil(try menu("dpad_right", map, words: true).conflictNote)
        // Without a label lookup the raw id is the fallback, but the menu presenter always passes the layout's.
        XCTAssertEqual(try menu("paddle_outer_right", map).conflictNote,
                       "dpad_right was learned with paddle_outer_right's signal: re-learn dpad_right.")
        // Back on Controller's profile: no conflict note.
        map.setOutput(.builtIn, for: "paddle_outer_right")
        XCTAssertNil(try menu("paddle_outer_right", map, words: true).conflictNote)
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
            // A paddle or SAX key: every pick but Controller's profile needs the echo hidden, which this driver version cannot do.
            case _ where sixIDs.contains(id): expected = Set(PadOutput.allCases.map { ControlOutput.pad($0) } + [.nothing])
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

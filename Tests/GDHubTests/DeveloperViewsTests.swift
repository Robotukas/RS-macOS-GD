import XCTest
@testable import GDHub

final class DeveloperViewsTests: XCTestCase {
    func testRingDrainsFromElapsed() {
        XCTAssertEqual(DevRingMath.remaining(totalNs: 5_000_000_000, elapsedNs: 0, sinceStamp: 0), 1)
        XCTAssertEqual(DevRingMath.remaining(totalNs: 5_000_000_000, elapsedNs: 1_000_000_000, sinceStamp: 1.5)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(DevRingMath.remaining(totalNs: 5_000_000_000, elapsedNs: nil, sinceStamp: 9), 0)
        XCTAssertNil(DevRingMath.remaining(totalNs: nil, elapsedNs: nil, sinceStamp: 1))
    }

    func testSecondsLeftRoundsUp() {
        XCTAssertEqual(DevRingMath.secondsLeft(totalNs: 5_000_000_000, elapsedNs: 0, sinceStamp: 0.2), 5)
        XCTAssertEqual(DevRingMath.secondsLeft(totalNs: 5_000_000_000, elapsedNs: 4_100_000_000, sinceStamp: 0), 1)
        XCTAssertEqual(DevRingMath.secondsLeft(totalNs: 5_000_000_000, elapsedNs: 6_000_000_000, sinceStamp: 0), 0)
    }

    func testPadOverlayMapsStickYDownAndButtons() throws {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        var state = PadDecodedState()
        state.ly = 0.5          // pad: up is positive
        state.rt = 0.75
        state.buttons = [.a, .ls]
        state.hat = 1           // N
        state.guide = true
        func overlay(_ id: String) throws -> DevPadOverlay {
            DevPadOverlay(control: try XCTUnwrap(layout.controls.first { $0.id == id }), state: state)
        }
        XCTAssertEqual(try overlay("left_stick").stick, CGPoint(x: 0, y: -0.5))
        XCTAssertEqual(try overlay("rt").trigger, 0.75)
        XCTAssertTrue(try overlay("a").pressed)
        XCTAssertFalse(try overlay("b").pressed)
        XCTAssertTrue(try overlay("l3").pressed)
        XCTAssertTrue(try overlay("dpad_up").pressed)
        XCTAssertFalse(try overlay("dpad_down").pressed)
        XCTAssertTrue(try overlay("start").pressed)
    }

    func testTemplateGroupsOrderAndLabels() {
        func entry(_ id: String, _ s: DevTemplateSource) -> DevTemplateEntry {
            DevTemplateEntry(id: id, template: nil, source: s, url: URL(fileURLWithPath: "/tmp/\(id).json"))
        }
        let groups = DeveloperBar.groups([entry("l", .local), entry("b", .builtIn), entry("o", .localOverride)])
        XCTAssertEqual(groups.map(\.source.tag), ["built-in", "local override", "local"])
    }

    func testTemplateRowsAreNumberedDownTheListAsDrawn() {
        func entry(_ id: String, _ s: DevTemplateSource) -> DevTemplateEntry {
            DevTemplateEntry(id: id, template: nil, source: s, url: URL(fileURLWithPath: "/tmp/\(id).json"))
        }
        let entries = [entry("l", .local), entry("b1", .builtIn), entry("b2", .builtIn), entry("o", .localOverride)]
        let numbers = DeveloperBar.numbers(entries)
        XCTAssertEqual(numbers, ["b1": 1, "b2": 2, "o": 3, "l": 4])
        XCTAssertEqual(DeveloperBar.rowLabel(entries[1], number: numbers["b1"]), "1. b1 (problem)")
    }

    func testVerdictLabelsAndChipRerun() {
        XCTAssertEqual(DevVerdict.fail("x").label, "Fail")
        XCTAssertTrue(DevChip.Status.failed.canRerun)
        XCTAssertFalse(DevChip.Status.passed.canRerun)
    }

    // MARK: Remap step 2, S4: the record display, the three wordings, the caveat chip

    func testRecordedIsLowerCaseGreyAndHasNoSymbol() {
        XCTAssertEqual(DevVerdict.recorded("x").label, "recorded")
        XCTAssertEqual(DevChip.Status.recorded.symbol, "")
        XCTAssertEqual(DevPalette.color(for: DevVerdict.recorded("x")), DevPalette.skipped)
        XCTAssertEqual(DevPalette.color(for: DevChip.Status.recorded), DevPalette.skipped)
        XCTAssertEqual(DevSession.recordExpected, "—")
        XCTAssertEqual(DevRecorder.kept(frames: 212, dropped: 0), "receiver frames kept: 212")
        XCTAssertEqual(DevRecorder.kept(frames: 4000, dropped: 12), "receiver frames kept: 4000 (12 more did not fit and were left out)")
    }

    func testCannotJudgeHasItsOwnLabelAndOtherInconclusiveKeepsTheOldOne() {
        XCTAssertEqual(DevVerdict.inconclusive("cannot judge: the controller sent no button for this key").label, "Cannot judge")
        XCTAssertEqual(DevVerdict.inconclusive("cannot judge the volume: no key report").label, "Inconclusive")
        XCTAssertEqual(DevVerdict.inconclusive("pad state unknown").label, "Inconclusive")
    }

    func testTheExpectedCellAndTheNoteUnderTheResult() throws {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        var m = ControlMapping.default
        m.setOutput(.pad(.r3), for: "paddle_outer_right")
        let t = DevBuiltins.remapPaddles(layout: layout)
        let resolved = DevResolvedStep.resolve(template: t, mapping: {
            var p = m
            p.setOutput(.pad(.l3), for: "paddle_outer_left"); p.setOutput(.nothing, for: "paddle_inner_left")
            p.setOutput(.pad(.view), for: "sax_left"); p.setOutput(.pad(.menu), for: "sax_right")
            return p
        }(), layout: layout)
        XCTAssertEqual(DevSession.expectedCell(resolved[6], expected: resolved[6].expected).text, "one pad item per press (the controller's profile decides)")
        let held = DevSession.expectedCell(resolved[7], expected: resolved[7].expected)
        XCTAssertEqual(held.text, "D-pad up ×2; R3 held in the background")
        XCTAssertEqual(held.background, "R3")
        XCTAssertEqual(DevSession.expectedCell(resolved[1], expected: resolved[1].expected).text, "R3 ×10")
        XCTAssertEqual(DevSession.expectedCell(resolved[3], expected: resolved[3].expected).text, "nothing on the pad")
        XCTAssertEqual(DevSession.expectedCell(resolved[11], expected: resolved[11].expected).text, "L3, R3 ×2")
        XCTAssertEqual(DevExpectedItems(lt: true).summary(times: 2), "LT ×2 (full pull), RT still")
        XCTAssertEqual(DevExpectedItems(rt: true).summary(times: 2), "RT ×2 (full pull), LT still")
        XCTAssertEqual(DevExpectedItems(hat: "NE").summary, "D-pad up, D-pad right")
        XCTAssertEqual(DevExpectedItems(buttons: ["Y"]).summary(times: 1), "Y")
        let rec = DevStep(id: "r", kind: .record, controls: ["a"], title: "t")
        XCTAssertEqual(DevSession.expectedCell(DevResolvedStep(step: rec, expected: DevExpectedItems(), wanted: ["a"], linked: [], skipReason: nil), expected: DevExpectedItems()).text, "—")
        var att = DevAttempt()
        att.hiding = DevHiding(conclusive: false, line: "controller's own button hidden: not exercised (the controller sent no D-pad right during the hold)", presses: [])
        XCTAssertEqual(DevSession.resultNote(att, background: "D-pad left", verdict: .pass),
                       "D-pad left never dropped: pass. Controller's own button hidden: not exercised (the controller sent no D-pad right during the hold)")
        XCTAssertEqual(DevSession.resultNote(att, background: "", verdict: .pass), att.hiding?.line)
        XCTAssertNil(DevSession.resultNote(DevAttempt(), background: "", verdict: .pass))
        let row = DevResultRow(index: 0, title: "t", expected: "e", seen: "s", loss: "", onset: "", frames: "", verdict: .fail("why"), attempts: 1, note: "n")
        XCTAssertEqual(row.help, "why n")
    }
}

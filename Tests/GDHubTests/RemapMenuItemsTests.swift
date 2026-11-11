import XCTest
import AppKit
@testable import GDHub

@MainActor
final class RemapMenuItemsTests: XCTestCase {
    private func specs(_ id: String, _ m: ControlMapping = .default, relearn: Bool = true) throws -> [RemapMenuItemSpec] {
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        let c = try XCTUnwrap(layout.control(id: id))
        return RemapMenuModel(controlID: id, label: c.label, kind: c.kind, mapping: m).itemSpecs(relearnEnabled: relearn)
    }

    private func kinds(_ s: [RemapMenuItemSpec]) -> [RemapMenuItemSpec.Kind] { s.map(\.kind) }

    func testG1MenuOrder() throws {
        let s = try specs("g1")
        XCTAssertEqual(s.first, RemapMenuItemSpec(kind: .header, title: "G1 sends", isEnabled: false))
        // header, 4 + 4 + 4 + 4 + 1 pad entries in 5 groups with separators, a separator and Nothing, footnote, separator,
        // re-learn (no Reset item: nothing is remapped)
        var expected: [RemapMenuItemSpec.Kind] = [.header]
        for (i, n) in [4, 4, 4, 4, 1].enumerated() {
            if i > 0 { expected.append(.separator) }
            expected += Array(repeating: .entry, count: n)
        }
        expected += [.separator, .entry, .footnote, .separator, .relearn]
        XCTAssertEqual(kinds(s), expected)
        // Remapped: Reset to default appears between two separators, above the re-learn item.
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        XCTAssertEqual(Array(kinds(try specs("g1", m)).suffix(5)), [.footnote, .separator, .reset, .separator, .relearn])
        XCTAssertEqual(s.last?.title, "Re-learn button…")
        XCTAssertEqual(s.last?.pick, .relearn)
    }

    func testTicksTagsAndEnabledFlags() throws {
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g1")
        let s = try specs("g1", m)
        let entries = s.filter { $0.kind == .entry }
        XCTAssertEqual(entries.filter(\.isOn).map(\.title), ["Y"], "one tick, on the current pick")
        let nothing = try XCTUnwrap(entries.first { $0.pick == .output(.nothing) })
        XCTAssertEqual(nothing.tags, ["default"], "Nothing is G1's default")
        let reset = try XCTUnwrap(s.first { $0.kind == .reset })
        XCTAssertTrue(reset.isEnabled, "G1 is remapped")
        XCTAssertEqual(reset.title, "Reset to default")
        XCTAssertEqual(reset.pick, .reset)
        XCTAssertNil(try specs("g1").first { $0.kind == .reset }, "nothing to reset: no item, not a greyed one")
        XCTAssertTrue(entries.allSatisfy(\.isEnabled))
    }

    func testLimitedPicksCarryTheDriverTagAndTheFootnote() throws {
        let s = try specs("g1")
        let lt = try XCTUnwrap(s.first { $0.pick == .output(.pad(.lt)) })
        XCTAssertEqual(lt.tags, [RemapMenuModel.limitTag], "a button cannot pull a trigger on the driver yet")
        let foot = try XCTUnwrap(s.first { $0.kind == .footnote })
        XCTAssertEqual(foot.title, RemapMenuModel.footnoteText)
        XCTAssertFalse(foot.isEnabled)
    }

    func testVolumeKeyMenuStartsWithTheBuiltInEntryAndANote() throws {
        let s = try specs("g3")
        XCTAssertEqual(Array(s.prefix(4).map(\.kind)), [.header, .note, .entry, .separator])
        XCTAssertEqual(s[1].title, "Mapped: G3 no longer changes the volume.")
        XCTAssertFalse(s[1].isEnabled)
        XCTAssertEqual(s[2].title, "Volume up (built in)")
        XCTAssertEqual(s[2].tags, ["default"])
        XCTAssertTrue(s[2].isOn)
        XCTAssertEqual(s[2].pick, .output(.builtIn))
    }

    func testStickMenuIsHeaderNoteSeparatorRelearn() throws {
        let stick = try specs("left_stick")
        XCTAssertEqual(kinds(stick), [.header, .note, .separator, .relearn])
        XCTAssertEqual(stick[1].title, RemapMenuModel.stickNote)
        XCTAssertEqual(stick[3].title, "Re-learn stick…")
    }

    func testPaddleMenuIsAFullMenuWithControllersProfileFirstAndTheNote() throws {
        let paddle = try specs("paddle_outer_left")
        XCTAssertEqual(Array(paddle.prefix(4).map(\.kind)), [.header, .note, .entry, .separator])
        XCTAssertEqual(paddle[0].title, "Paddle outer left sends")
        XCTAssertEqual(paddle[1].title, RemapMenuModel.controllersProfileNote)
        XCTAssertFalse(paddle[1].isEnabled)
        XCTAssertEqual(paddle[2].title, "Controller's profile (built in)")
        XCTAssertEqual(paddle[2].tags, ["default"])
        XCTAssertTrue(paddle[2].isOn)
        XCTAssertEqual(paddle[2].pick, .output(.builtIn))
        // The tail: footnote (the level-1 marks), separator, Re-learn (no Reset item while the key is on Controller's profile).
        let tail = kinds(paddle).suffix(3)
        XCTAssertEqual(Array(tail), [.footnote, .separator, .relearn])
        // Remapped: the tail gains Reset to default, and the second note is the remapped-key one.
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "paddle_outer_left")
        let remapped = try specs("paddle_outer_left", m)
        // (the mapping already has its limit, so no entry is marked and there is no footnote)
        XCTAssertEqual(Array(kinds(remapped).suffix(5)), [.entry, .separator, .reset, .separator, .relearn])
        XCTAssertEqual(remapped[1].title, RemapMenuModel.remappedKeyNote)
        XCTAssertEqual(paddle.last?.title, "Re-learn button…")
        // Every pick but Controller's profile carries the App-drives tag at level 1.
        for spec in paddle where spec.kind == .entry && spec.pick != .output(.builtIn) {
            XCTAssertTrue(spec.tags.contains(RemapMenuModel.limitTag), spec.title)
        }
    }

    func testRelearnFollowsTheGate() throws {
        XCTAssertFalse(try XCTUnwrap(specs("g1", relearn: false).last).isEnabled)
        XCTAssertTrue(try XCTUnwrap(specs("g1").last).isEnabled)
    }

    // MARK: The native menu

    func testNativeMenuMirrorsTheSpecs() throws {
        var picks: [RemapPick] = []
        let target = RemapMenuTarget { picks.append($0) }
        var m = ControlMapping.default
        m.setOutput(.pad(.y), for: "g2")
        let list = try specs("g2", m)
        let menu = RemapNSMenuBuilder.menu(for: list, target: target)
        XCTAssertFalse(menu.autoenablesItems, "the header, notes and Reset have their own enabled flags")
        XCTAssertEqual(menu.items.count, list.count)
        for (item, spec) in zip(menu.items, list) {
            switch spec.kind {
            case .separator:
                XCTAssertTrue(item.isSeparatorItem)
            case .header, .note, .conflict, .footnote:
                XCTAssertFalse(item.isEnabled, spec.title)
                if spec.kind != .header { XCTAssertNotNil(item.view, "a note wraps in its own view") }
            case .entry, .reset, .relearn:
                XCTAssertEqual(item.isEnabled, spec.isEnabled, spec.title)
                XCTAssertEqual(item.state == .on, spec.isOn, spec.title)
                XCTAssertTrue(item.target === target)
                XCTAssertEqual((item.representedObject as? RemapPickBox)?.pick, spec.pick, "each item carries its pick")
                if spec.tags.isEmpty { XCTAssertEqual(item.title, spec.title) }
                if !spec.tags.isEmpty {
                    let shown = try XCTUnwrap(item.attributedTitle?.string)
                    XCTAssertTrue(shown.hasPrefix(spec.title))
                    for tag in spec.tags { XCTAssertTrue(shown.contains(tag), shown) }
                }
            }
        }
        // Choosing an item delivers its pick to the target.
        let y = try XCTUnwrap(menu.items.first { ($0.representedObject as? RemapPickBox)?.pick == .output(.pad(.y)) })
        _ = target.perform(#selector(RemapMenuTarget.choose(_:)), with: y)
        let reset = try XCTUnwrap(menu.items.first { ($0.representedObject as? RemapPickBox)?.pick == .reset })
        _ = target.perform(#selector(RemapMenuTarget.choose(_:)), with: reset)
        XCTAssertEqual(picks, [.output(.pad(.y)), .reset])
        // The tick is on Y.
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Y"])
    }

    func testConflictNoteIsASecondDisabledNoteInTheWarningColour() throws {
        var m = ControlMapping.default
        m.physicalBits["dpad_right"] = 1
        m.setOutput(.pad(.y), for: "paddle_outer_right")
        let layout = try XCTUnwrap(ControlLayout.loadFromBundle())
        let c = try XCTUnwrap(layout.control(id: "paddle_outer_right"))
        let model = RemapMenuModel(controlID: c.id, label: c.label, kind: c.kind, mapping: m,
                                   labelOf: { layout.control(id: $0)?.label ?? $0 })
        let list = model.itemSpecs()
        XCTAssertEqual(Array(list.prefix(3).map(\.kind)), [.header, .note, .conflict])
        XCTAssertEqual(list[1].title, RemapMenuModel.remappedKeyNote)
        XCTAssertEqual(list[2].title, "D-pad right was learned with Paddle outer right's signal: re-learn D-pad right.")
        XCTAssertFalse(list[2].isEnabled)
        XCTAssertTrue(list[2].tags.isEmpty, "no limit tag on the conflict note")
        let menu = RemapNSMenuBuilder.menu(for: list, target: RemapMenuTarget { _ in })
        let item = menu.items[2]
        XCTAssertFalse(item.isEnabled)
        let label = try XCTUnwrap(item.view?.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.stringValue, list[2].title)
        XCTAssertEqual(label.textColor?.usingColorSpace(.sRGB), RemapNSMenuBuilder.warningColor.usingColorSpace(.sRGB))
        // The ordinary note keeps its own colour.
        let note = try XCTUnwrap(menu.items[1].view?.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(note.textColor, .systemOrange)
    }

    func testPresenterPopsNothingWithoutAnAnchorAndTheModeOff() throws {
        let d = EnvisionProDevice(layout: try XCTUnwrap(ControlLayout.loadFromBundle()), store: MappingStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-presenter-\(UUID().uuidString).json")))
        let presenter = RemapMenuPresenter()
        presenter.present(controlID: "g1", side: .front, at: .zero, device: d)      // not in Mapping: refused at once
        XCTAssertFalse(presenter.isOpen)
        XCTAssertNil(presenter.anchor(for: .front))
        let anchor = RemapAnchorView()
        presenter.register(anchor, side: .front)
        XCTAssertTrue(presenter.anchor(for: .front) === anchor)
        XCTAssertTrue(anchor.isFlipped)
        XCTAssertNil(anchor.hitTest(NSPoint(x: 1, y: 1)), "the anchor never takes a click")
    }

    /// The fault of 2026-11-10: a second drawing of the same side (Developer mode's) registered its anchor and went away;
    /// the first drawing's anchor was forgotten, so no menu opened afterwards.
    func testPresenterKeepsTheOlderAnchorWhenANewerOneGoesAway() {
        let presenter = RemapMenuPresenter()
        let first = RemapAnchorView()
        presenter.register(first, side: .front)
        autoreleasepool {
            let second = RemapAnchorView()
            presenter.register(second, side: .front)
            XCTAssertTrue(presenter.anchor(for: .front) === second)
        }
        XCTAssertTrue(presenter.anchor(for: .front) === first, "the older drawing's anchor is still known")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let third = RemapAnchorView()
        presenter.register(third, side: .front)
        window.contentView?.addSubview(first)
        XCTAssertTrue(presenter.anchor(for: .front) === first, "an anchor in a window wins over a newer one that is not")
    }
}

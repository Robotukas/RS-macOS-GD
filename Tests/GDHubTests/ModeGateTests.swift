import XCTest
@testable import GDHub

final class ModeGateTests: XCTestCase {
    /// Every combination of the three exclusive modes (including the impossible ones), a learn and a display-only copy.
    private func allGates() -> [ModeGate] {
        var out: [ModeGate] = []
        for editing in [false, true] {
            for dev in [false, true] {
                for remap in [false, true] {
                    for learning in [ModeGate.Learning.none, .single, .guided] {
                        for display in [false, true] {
                            out.append(ModeGate(isEditing: editing, devOn: dev, remapping: remap, learning: learning, displayOnly: display))
                        }
                    }
                }
            }
        }
        return out
    }

    func testMappingIsRefusedWhileEditingOrDeveloperOrDisplayOnly() {
        for g in allGates() {
            XCTAssertEqual(g.canBeginRemapping, !g.isEditing && !g.devOn && !g.displayOnly, "\(g)")
        }
    }

    func testEditLayoutIsRefusedWhileDeveloperOrMapping() {
        for g in allGates() {
            XCTAssertEqual(g.canBeginEditing, !g.devOn && !g.remapping, "\(g)")
        }
    }

    func testDeveloperIsRefusedWhileEditingOrMapping() {
        for g in allGates() {
            XCTAssertEqual(g.canBeginDeveloper, !g.devOn && !g.isEditing && !g.remapping, "\(g)")
        }
    }

    func testLearnIsRefusedOnlyInDeveloperOrDisplayOnly() {
        for g in allGates() {
            XCTAssertEqual(g.canLearn, !g.devOn && !g.displayOnly, "\(g)")
        }
    }

    func testARunningLearnDoesNotBlockMappingAndMappingDoesNotBlockLearn() {
        for g in allGates() {
            var other = g
            other.learning = .none
            XCTAssertEqual(g.canBeginRemapping, other.canBeginRemapping, "a learn must not change whether Mapping may begin: \(g)")
            XCTAssertEqual(g.canBeginEditing, other.canBeginEditing, "\(g)")
            XCTAssertEqual(g.canBeginDeveloper, other.canBeginDeveloper, "\(g)")
            var mapping = g
            mapping.remapping.toggle()
            XCTAssertEqual(g.canLearn, mapping.canLearn, "Mapping on or off must not change whether a learn may run: \(g)")
        }
    }

    func testLearnAllIsDisabledOnlyWhileGuidedRuns() {
        XCTAssertTrue(ModeGate().learnAllEnabled)
        XCTAssertTrue(ModeGate(learning: .single).learnAllEnabled, "today a single learn does not disable Learn all")
        XCTAssertFalse(ModeGate(learning: .guided).learnAllEnabled)
        XCTAssertFalse(ModeGate(devOn: true).learnAllEnabled)
        XCTAssertFalse(ModeGate(displayOnly: true).learnAllEnabled)
        XCTAssertTrue(ModeGate(isEditing: true).learnAllEnabled)
        XCTAssertTrue(ModeGate(remapping: true).learnAllEnabled)
    }

    func testTheMappingButtonStaysUsableToSwitchMappingOff() {
        XCTAssertTrue(ModeGate().mappingButtonEnabled)
        XCTAssertTrue(ModeGate(remapping: true).mappingButtonEnabled)
        XCTAssertFalse(ModeGate(isEditing: true).mappingButtonEnabled)
        XCTAssertFalse(ModeGate(devOn: true).mappingButtonEnabled)
        XCTAssertFalse(ModeGate(displayOnly: true).mappingButtonEnabled)
    }

    func testClickActions() {
        // Live view: both flash the hint.
        XCTAssertEqual(ModeGate().clickAction(on: .label), .flashHint)
        XCTAssertEqual(ModeGate().clickAction(on: .hotspot), .flashHint)
        // Mapping: both open the menu.
        XCTAssertEqual(ModeGate(remapping: true).clickAction(on: .label), .openMenu)
        XCTAssertEqual(ModeGate(remapping: true).clickAction(on: .hotspot), .openMenu)
        // Edit layout: a label is selected, a drawn button does nothing (no learn from a click any more).
        XCTAssertEqual(ModeGate(isEditing: true).clickAction(on: .label), .selectLabel)
        XCTAssertEqual(ModeGate(isEditing: true).clickAction(on: .hotspot), .none)
        // Developer: nothing.
        XCTAssertEqual(ModeGate(devOn: true).clickAction(on: .label), .none)
        XCTAssertEqual(ModeGate(devOn: true).clickAction(on: .hotspot), .none)
        // A display-only copy cannot map or learn: no hint that points nowhere.
        XCTAssertEqual(ModeGate(displayOnly: true).clickAction(on: .label), .none)
        XCTAssertEqual(ModeGate(displayOnly: true).clickAction(on: .hotspot), .none)
        // ... but it may still edit its layout.
        XCTAssertEqual(ModeGate(isEditing: true, displayOnly: true).clickAction(on: .label), .selectLabel)
    }

    func testAClickNeverDependsOnALearn() {
        for g in allGates() {
            var other = g
            other.learning = .none
            for t in [ModeGate.ClickTarget.label, .hotspot] {
                XCTAssertEqual(g.clickAction(on: t), other.clickAction(on: t), "\(g)")
            }
        }
    }

    func testLabelsAreHitTestableExactlyWhenAClickDoesSomething() {
        XCTAssertTrue(ModeGate().labelsHitTestable)
        XCTAssertTrue(ModeGate(remapping: true).labelsHitTestable)
        XCTAssertTrue(ModeGate(isEditing: true).labelsHitTestable)
        XCTAssertFalse(ModeGate(devOn: true).labelsHitTestable)
        XCTAssertFalse(ModeGate(displayOnly: true).labelsHitTestable)
    }

    func testHintTexts() {
        XCTAssertEqual(RemapHint.text(remapping: true, flashing: false), "Mapping: click a label or a button to choose what it sends.")
        XCTAssertEqual(RemapHint.text(remapping: true, flashing: true), RemapHint.mappingOn, "a flash means nothing while Mapping is on")
        XCTAssertEqual(RemapHint.text(remapping: false, flashing: false), "Live view. Switch Mapping on to change what a button sends.")
        XCTAssertEqual(RemapHint.text(remapping: false, flashing: true), "Switch Mapping on first (button on the left).")
    }

    func testHintExposesTheDriverLimit() {
        var m = ControlMapping.default
        XCTAssertNil(RemapHint.limit(of: m))
        m.setOutput(.pad(.y), for: "g1")
        m.setOutput(.pad(.y), for: "g2")
        XCTAssertEqual(RemapHint.limit(of: m), MapBlobEncoder.remapLimitInWords(m))
        XCTAssertEqual(RemapHint.limit(of: m), "three buttons send Y: Y, G1, G2")
        XCTAssertNotNil(RemapHint.limit(of: m), "y, g1 and g2 all send Y: three sources")
    }
}

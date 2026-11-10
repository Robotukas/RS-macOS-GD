import XCTest
@testable import GDHub

/// Mapping mode on the device: mode transitions through `ModeGate`, saving remaps through the store, and the one click
/// dispatch the views use (no click starts a learn any more).
@MainActor
final class RemapModeTests: XCTestCase {
    private var dir: URL!
    private var store: MappingStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-remapmode-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MappingStore(url: dir.appendingPathComponent("envision-pro-mapping.json"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A device with the built-in layout (needed to start a learn). Never enters Edit layout: that writes the user's files.
    private func device(displayOnly: Bool = false) throws -> EnvisionProDevice {
        let d = EnvisionProDevice(layout: try XCTUnwrap(ControlLayout.loadFromBundle()), store: store)
        d.displayOnly = displayOnly
        return d
    }

    // MARK: Modes

    func testMappingBeginsAndEnds() throws {
        let d = try device()
        XCTAssertFalse(d.isRemapping)
        XCTAssertTrue(d.beginRemapping())
        XCTAssertTrue(d.isRemapping)
        XCTAssertTrue(d.modeGate.remapping)
        XCTAssertFalse(d.beginRemapping(), "already on")
        d.endRemapping()
        XCTAssertFalse(d.isRemapping)
        XCTAssertFalse(d.modeGate.remapping)
    }

    func testMappingIsRefusedWhileEditingAndEditLayoutWhileMapping() {
        let d = EnvisionProDevice(layout: nil, store: store)     // no layout: editing writes no files
        d.beginEditingLayout()
        XCTAssertTrue(d.editor.isEditing)
        XCTAssertFalse(d.beginRemapping())
        XCTAssertFalse(d.isRemapping)
        d.editor.isEditing = false
        XCTAssertTrue(d.beginRemapping())
        d.beginEditingLayout()
        XCTAssertFalse(d.editor.isEditing, "Edit layout is refused while Mapping is on")
        d.endRemapping()
        d.beginEditingLayout()
        XCTAssertTrue(d.editor.isEditing)
    }

    func testDeveloperIsRefusedWhileMapping() throws {
        let d = try device()
        XCTAssertTrue(d.beginRemapping())
        XCTAssertFalse(d.modeGate.canBeginDeveloper)
        XCTAssertFalse(d.beginDeveloper(), "refused while Mapping (and there is no driver manager here)")
        XCTAssertNil(d.dev)
    }

    func testDisplayOnlyCopyCannotMapOrLearn() throws {
        let d = try device(displayOnly: true)
        XCTAssertFalse(d.beginRemapping())
        XCTAssertFalse(d.isRemapping)
        d.startLearn(controlId: "g1")
        d.startGuidedLearn()
        XCTAssertNil(d.learn)
        d.setOutput(.pad(.y), for: "g1")
        XCTAssertTrue(d.mapping.outputs.isEmpty, "a display-only copy changes nothing")
        d.beginEditingLayout()          // it may still edit its layout (as before)
    }

    func testARunningLearnSurvivesEnteringAndLeavingMapping() throws {
        let d = try device()
        d.startLearn(controlId: "g1")
        let session = try XCTUnwrap(d.learn)
        XCTAssertEqual(d.modeGate.learning, .single)
        XCTAssertTrue(d.beginRemapping())
        XCTAssertTrue(d.learn === session, "entering Mapping does not cancel a learn")
        XCTAssertFalse(session.isFinished)
        d.endRemapping()
        XCTAssertTrue(d.learn === session, "leaving Mapping does not cancel it either")
        XCTAssertFalse(session.isFinished)
        d.cancelLearn()
    }

    func testAGuidedLearnShowsInTheGateAndLearnCanStartInsideMapping() throws {
        let d = try device()
        XCTAssertTrue(d.beginRemapping())
        d.startGuidedLearn()
        XCTAssertNotNil(d.learn)
        XCTAssertEqual(d.modeGate.learning, .guided)
        XCTAssertFalse(d.modeGate.learnAllEnabled)
        d.cancelLearn()
    }

    func testMenuControlIsClearedWhenMappingEnds() throws {
        let d = try device()
        d.beginRemapping()
        d.setRemapMenuControl("g1")
        XCTAssertEqual(d.remapMenuControl, "g1")
        d.endRemapping()
        XCTAssertNil(d.remapMenuControl)
    }

    // MARK: Remaps

    func testSetOutputSavesThroughTheStoreAndRefreshesTheCaches() throws {
        let d = try device()
        let revision = d.mappingRevision
        d.setOutput(.pad(.y), for: "g1")
        XCTAssertEqual(d.mapping.outputs["g1"], .pad(.y))
        XCTAssertEqual(try store.loadStrict().outputs["g1"], .pad(.y), "the didSet saved it")
        XCTAssertGreaterThan(d.mappingRevision, revision)
        XCTAssertEqual(d.remapSources, d.mapping.sourcesByOutput())
        XCTAssertEqual(d.remapSources[.y], ["y", "g1"])
        XCTAssertNil(d.remapLimit)

        d.setOutput(.pad(.y), for: "g2")          // three controls send Y: the driver cannot do that yet
        XCTAssertEqual(d.remapLimit, MapBlobEncoder.remapLimit(d.mapping))
        XCTAssertNotNil(d.remapLimit)

        d.setOutput(.nothing, for: "g2")
        XCTAssertNil(d.remapLimit)
        XCTAssertEqual(try store.loadStrict().outputs["g2"], ControlOutput.nothing)
    }

    func testAPickEqualToTheDefaultClearsTheRemap() throws {
        let d = try device()
        d.setOutput(.pad(.b), for: "a")
        XCTAssertTrue(d.mapping.isRemapped("a"))
        d.setOutput(.pad(.a), for: "a")
        XCTAssertFalse(d.mapping.isRemapped("a"))
        XCTAssertTrue(try store.loadStrict().outputs.isEmpty)
    }

    func testResetOutputAndResetAllRemaps() throws {
        let d = try device()
        d.setOutput(.pad(.y), for: "g1")
        d.setOutput(.nothing, for: "g2")
        d.setOutput(.pad(.rb), for: "g3")
        d.resetOutput(for: "g1")
        XCTAssertNil(d.mapping.outputs["g1"])
        XCTAssertEqual(d.mapping.outputs.count, 2)
        let learned = d.mapping.buttons
        d.resetAllRemaps()
        XCTAssertTrue(d.mapping.outputs.isEmpty)
        XCTAssertEqual(d.mapping.buttons, learned, "never touches learned buttons")
        XCTAssertTrue(try store.loadStrict().outputs.isEmpty)
        XCTAssertEqual(d.remapSources, ControlMapping.default.sourcesByOutput())
    }

    // MARK: Clicks

    func testALiveViewClickFlashesTheHintAndStartsNoLearnAndNoMenu() throws {
        let d = try device()
        var opened = 0
        for target in [ModeGate.ClickTarget.hotspot, .label] {
            XCTAssertEqual(d.handleClick(on: target, controlID: "g1") { opened += 1 }, .flashHint)
        }
        XCTAssertEqual(opened, 0)
        XCTAssertNil(d.learn, "a click in the live view starts no learn")
        XCTAssertTrue(d.remapHintFlashing)
        XCTAssertTrue(d.mapping.outputs.isEmpty)
        d.beginRemapping()
        XCTAssertFalse(d.remapHintFlashing, "the flash ends when Mapping begins")
    }

    func testAClickInMappingOpensTheMenuAndStartsNoLearn() throws {
        let d = try device()
        d.beginRemapping()
        var opened = 0
        for target in [ModeGate.ClickTarget.hotspot, .label] {
            XCTAssertEqual(d.handleClick(on: target, controlID: "g1") { opened += 1 }, .openMenu)
        }
        XCTAssertEqual(opened, 2)
        XCTAssertNil(d.learn)
        XCTAssertFalse(d.remapHintFlashing)
    }

    func testEditLayoutClickSelectsALabelAndAHotspotDoesNothing() {
        let d = EnvisionProDevice(layout: nil, store: store)
        d.beginEditingLayout()
        var opened = 0
        XCTAssertEqual(d.handleClick(on: .hotspot, controlID: "a") { opened += 1 }, .none)
        XCTAssertTrue(d.editor.selection.isEmpty)
        XCTAssertEqual(d.handleClick(on: .label, controlID: "a") { opened += 1 }, .selectLabel)
        XCTAssertEqual(d.editor.selection, ["a"])
        XCTAssertEqual(opened, 0)
        XCTAssertNil(d.learn)
    }

    func testADisplayOnlyCopyIgnoresClicks() throws {
        let d = try device(displayOnly: true)
        var opened = 0
        XCTAssertEqual(d.handleClick(on: .hotspot, controlID: "g1") { opened += 1 }, .none)
        XCTAssertEqual(d.handleClick(on: .label, controlID: "g1") { opened += 1 }, .none)
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(d.remapHintFlashing)
        XCTAssertNil(d.learn)
    }

    func testNoClickStartsALearnInAnyMode() throws {
        for remapping in [false, true] {
            let d = try device()
            if remapping { d.beginRemapping() }
            for target in [ModeGate.ClickTarget.hotspot, .label] {
                for id in ["g1", "a", "left_stick", "lt"] {
                    d.handleClick(on: target, controlID: id) {}
                    XCTAssertNil(d.learn, "\(target) \(id) remapping=\(remapping)")
                }
            }
        }
    }
}

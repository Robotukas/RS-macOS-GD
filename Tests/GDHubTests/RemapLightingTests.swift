import XCTest
@testable import GDHub

final class RemapLightingTests: XCTestCase {
    private var controls: [ControlLayout.Control] = []

    override func setUpWithError() throws {
        controls = try XCTUnwrap(ControlLayout.loadFromBundle()).controls
    }

    private func frame(buttons: [Int] = [], hat: UInt8 = 8, lt: UInt16 = 0, rt: UInt16 = 0, extra: UInt16 = 0) -> GamepadFrame {
        var f = GamepadFrame()
        for n in buttons { f.buttons |= 1 << UInt32(n - 1) }
        f.hat = hat
        f.lt = lt
        f.rt = rt
        f.extra = extra
        return f
    }

    private func levels(_ f: GamepadFrame, _ m: ControlMapping) -> [String: RemapLighting.Level] {
        RemapLighting.levels(frame: f, mapping: m, controls: controls)
    }

    private func mapped(_ pairs: [(String, ControlOutput)]) -> ControlMapping {
        var m = ControlMapping.default
        for (id, o) in pairs { m.setOutput(o, for: id) }
        return m
    }

    func testPressedIsIsActiveForEveryControl() {
        let m = ControlMapping.default
        for f in [frame(buttons: [1]), frame(buttons: [12, 16]), frame(hat: 1), frame(lt: 500), frame(extra: 0b10001)] {
            let l = levels(f, m)
            for c in controls {
                XCTAssertEqual(l[c.id] == .pressed, m.isActive(c.id, f), c.id)
            }
            XCTAssertFalse(l.values.contains(.linked), "nothing is linked without remaps")
        }
    }

    func testIdleFrameLightsNothing() {
        XCTAssertTrue(levels(.idle, mapped([("g1", .pad(.y))])).isEmpty)
    }

    func testG1ToYLightsG1PressedAndYLinked() {
        let m = mapped([("g1", .pad(.y))])
        XCTAssertEqual(levels(frame(buttons: [12]), m), ["g1": .pressed, "y": .linked])
    }

    func testPressingYLightsOnlyY() {
        let m = mapped([("g1", .pad(.y))])
        XCTAssertEqual(levels(frame(buttons: [4]), m), ["y": .pressed])
    }

    func testBothPressedIsPressedNotLinked() {
        let m = mapped([("g1", .pad(.y))])
        XCTAssertEqual(levels(frame(buttons: [12, 4]), m), ["g1": .pressed, "y": .pressed])
    }

    func testSwapOfAAndBLightsThePressedButtonOnly() {
        let m = mapped([("a", .pad(.b)), ("b", .pad(.a))])
        XCTAssertEqual(levels(frame(buttons: [1]), m), ["a": .pressed], "A sends B, but B's drawing is mapped away from B")
        XCTAssertEqual(levels(frame(buttons: [2]), m), ["b": .pressed])
        XCTAssertEqual(levels(frame(buttons: [1, 2]), m), ["a": .pressed, "b": .pressed])
    }

    func testNothingNeverLinks() {
        let m = mapped([("g1", .nothing), ("g2", .nothing), ("view", .nothing)])
        XCTAssertEqual(levels(frame(buttons: [12]), m), ["g1": .pressed])
        XCTAssertEqual(levels(frame(buttons: [7]), m), ["view": .pressed], "a button set to Nothing lights when pressed")
        XCTAssertEqual(levels(frame(buttons: [13]), m), ["g2": .pressed])
    }

    func testBuiltInNeverLinks() {
        XCTAssertEqual(levels(frame(buttons: [14]), mapped([("g1", .pad(.y))])), ["g3": .pressed])
    }

    func testAControlMappedAwayFromItsItemIsNotLinkedToIt() {
        let m = mapped([("g1", .pad(.y)), ("y", .nothing)])
        XCTAssertEqual(levels(frame(buttons: [12]), m), ["g1": .pressed], "Y sends Nothing now, so its drawing is not Y's")
    }

    func testG5ToDpadDownWithHatUpLinksNothing() {
        let m = mapped([("g5", .pad(.dpad_down))])
        XCTAssertEqual(levels(frame(hat: 0), m), ["dpad_up": .pressed])
    }

    func testCancelledOppositeDirectionsAreNotLinked() {
        let m = mapped([("g5", .pad(.dpad_down))])
        // Hat up and G5 together: the pad reports up and down, which cancel.
        XCTAssertEqual(levels(frame(buttons: [16], hat: 0), m), ["g5": .pressed, "dpad_up": .pressed])
        // G5 alone: down is sent and nothing cancels it.
        XCTAssertEqual(levels(frame(buttons: [16]), m), ["g5": .pressed, "dpad_down": .linked])
        let left = mapped([("g5", .pad(.dpad_left))])
        XCTAssertEqual(levels(frame(buttons: [16], hat: 2), left), ["g5": .pressed, "dpad_right": .pressed])
    }

    func testG5ToGuideLinksStartOnlyWhileStartSendsGuide() {
        var m = mapped([("g5", .pad(.guide))])
        XCTAssertEqual(levels(frame(buttons: [16]), m), ["g5": .pressed, "start": .linked])
        XCTAssertEqual(levels(frame(buttons: [11]), m), ["start": .pressed])
        m.setOutput(.pad(.x), for: "start")
        XCTAssertEqual(levels(frame(buttons: [16]), m), ["g5": .pressed], "Start sends X now, not Guide")
        XCTAssertEqual(levels(frame(buttons: [11]), m), ["start": .pressed, "x": .linked], "Start pressed sends X, whose drawing links")
    }

    func testAButtonSentToATriggerLinksTheTriggerDrawing() {
        let m = mapped([("g1", .pad(.lt))])
        XCTAssertEqual(levels(frame(buttons: [12]), m), ["g1": .pressed, "lt": .linked])
    }

    func testTriggerPressedIsStillTheRawThreshold() {
        let m = mapped([("g1", .pad(.rt))])
        XCTAssertEqual(levels(frame(lt: 100), m)["lt"], nil)
        XCTAssertEqual(levels(frame(lt: 101), m)["lt"], .pressed)
    }

    func testTriggerThresholdMatchesIsActive() {
        let m = ControlMapping.default
        for raw: UInt16 in [0, 99, 100, 101, 102, 1023] {
            let f = frame(lt: raw)
            XCTAssertEqual(Double(raw) / 1023.0 > RemapLighting.triggerThreshold, m.isActive("lt", f), "raw \(raw)")
        }
    }

    func testTriggerFedByAButtonLinksItsDrawing() {
        let m = mapped([("g2", .pad(.rt))])
        XCTAssertEqual(levels(frame(buttons: [13]), m), ["g2": .pressed, "rt": .linked])
    }

    func testATriggerFeedingAnotherTriggerLinksOnlyAboveTheThreshold() {
        // LT feeds RT while RT still sends RT: RT sends max(rt, lt).
        let m = mapped([("lt", .pad(.rt))])
        XCTAssertEqual(levels(frame(lt: 100), m), [:], "100 of 1023 is not pressed, and RT gets exactly the threshold")
        XCTAssertEqual(levels(frame(lt: 600), m), ["lt": .pressed, "rt": .linked])
    }

    func testPaddleEchoIsCountedThroughTheDpadItFollows() {
        // Paddle outer right is the D-pad right echo (hat 2, extra bit 1). With G1 sending D-pad right, pressing G1 links
        // the D-pad right drawing; pressing the paddle presses the paddle and (via the echo) the D-pad right drawing.
        let m = mapped([("g1", .pad(.dpad_right))])
        XCTAssertEqual(levels(frame(buttons: [12]), m), ["g1": .pressed, "dpad_right": .linked])
        XCTAssertEqual(levels(frame(hat: 2, extra: 1), m), ["paddle_outer_right": .pressed, "dpad_right": .pressed])
    }

    func testPrecomputedSourcesGiveTheSameAnswer() {
        let m = mapped([("g1", .pad(.y)), ("g5", .pad(.guide))])
        let table = m.sourcesByOutput()
        for f in [frame(buttons: [12]), frame(buttons: [16]), frame(buttons: [4, 12]), .idle] {
            XCTAssertEqual(RemapLighting.levels(frame: f, mapping: m, controls: controls, sources: table), levels(f, m))
        }
    }

    func testTwoControlsOnOneItemLinkTheItemsDrawingFromEither() {
        let m = mapped([("g1", .pad(.y)), ("g2", .pad(.y))])
        XCTAssertEqual(levels(frame(buttons: [13]), m), ["g2": .pressed, "y": .linked])
        XCTAssertEqual(levels(frame(buttons: [12, 13]), m), ["g1": .pressed, "g2": .pressed, "y": .linked])
    }
}

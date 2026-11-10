import XCTest
@testable import GDHub

final class PassthroughPadMapperTests: XCTestCase {
    private let m = ControlMapping.default

    private func state(_ f: GamepadFrame) -> PadState { PassthroughPadMapper.padState(f, m) }
    private func frame(button n: Int, hat: UInt8 = 8, extra: UInt16 = 0) -> GamepadFrame {
        var f = GamepadFrame()
        f.buttons = 1 << UInt32(n - 1)
        f.hat = hat
        f.extra = extra
        return f
    }

    func testIdleFrameIsNeutral() {
        XCTAssertEqual(state(GamepadFrame()), .neutral)
        XCTAssertEqual(state(.idle), .neutral)
    }

    func testEveryFactoryButtonMapsToItsPadButton() {
        let expected: [(Int, PadButtons)] = [
            (1, .a), (2, .b), (3, .x), (4, .y), (5, .lb), (6, .rb), (7, .view), (8, .menu),
            (9, .ls), (10, .rs), (11, .guide),
        ]
        for (n, b) in expected {
            XCTAssertEqual(state(frame(button: n)).buttons, b, "button \(n)")
        }
    }

    func testButtonsCombine() {
        var f = GamepadFrame()
        f.buttons = 0b101   // buttons 1 and 3
        XCTAssertEqual(state(f).buttons, [.a, .x])
    }

    func testGearAndProfileButtonsAreNotForwarded() {
        // G1…G5 are buttons 12…16, Profile is 17 (no XInput equivalent; design §5.5).
        for n in 12...19 {
            XCTAssertEqual(state(frame(button: n)), .neutral, "button \(n)")
        }
    }

    func testHatToDpad() {
        let expected: [(UInt8, PadButtons)] = [
            (0, .dpadUp), (1, [.dpadUp, .dpadRight]), (2, .dpadRight), (3, [.dpadRight, .dpadDown]),
            (4, .dpadDown), (5, [.dpadDown, .dpadLeft]), (6, .dpadLeft), (7, [.dpadLeft, .dpadUp]),
            (8, []),
        ]
        for (h, b) in expected {
            var f = GamepadFrame(); f.hat = h
            XCTAssertEqual(state(f).buttons, b, "hat \(h)")
        }
    }

    func testSticksUseTheDocumentedSignConvention() {
        var f = GamepadFrame()
        f.x = 32767
        XCTAssertEqual(state(f).lx, 1, accuracy: 1e-9)
        f.x = -32768
        XCTAssertEqual(state(f).lx, -1, accuracy: 1e-4)

        f = GamepadFrame(); f.y = 32767      // stick pushed down
        XCTAssertEqual(state(f).ly, -1, accuracy: 1e-9)
        f.y = -32768                          // pushed up
        XCTAssertEqual(state(f).ly, 1, accuracy: 1e-4)

        f = GamepadFrame(); f.z = 32767; f.rz = 32767
        XCTAssertEqual(state(f).rx, 1, accuracy: 1e-9)
        XCTAssertEqual(state(f).ry, -1, accuracy: 1e-9)
        XCTAssertEqual(state(f).lx, 0)
        XCTAssertEqual(state(f).ly, 0)
    }

    func testLearnedStickRangesScalePosition() {
        var mapping = ControlMapping.default
        mapping.sticks["left_stick"]?.ranges = ["x": AxisRange(min: -20000, max: 20000),
                                                "y": AxisRange(min: -20000, max: 20000)]
        var f = GamepadFrame(); f.x = 10000; f.y = -20000
        let s = PassthroughPadMapper.padState(f, mapping)
        XCTAssertEqual(s.lx, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.ly, 1, accuracy: 1e-9)
    }

    func testTriggersScaleTo01() {
        var f = GamepadFrame(); f.lt = 1023; f.rt = 0
        XCTAssertEqual(state(f).lt, 1.0, accuracy: 1e-9)
        XCTAssertEqual(state(f).rt, 0)
        f.lt = 0; f.rt = 512
        XCTAssertEqual(state(f).rt, 512.0 / 1023.0, accuracy: 1e-9)
        XCTAssertEqual(state(f).lt, 0)
    }

    func testPaddleArrivesOnceThroughTheFactoryEcho() {
        // Outer-right paddle: extra bit 0 plus hat 2 (right). Exactly D-pad right, nothing else.
        var f = GamepadFrame(); f.extra = 1; f.hat = 2
        XCTAssertEqual(state(f), PadState(buttons: .dpadRight))
        // Inner-left paddle: extra bit 2 plus hat 0 (up).
        f = GamepadFrame(); f.extra = 4; f.hat = 0
        XCTAssertEqual(state(f), PadState(buttons: .dpadUp))
        // The extra bits alone (a re-mapped paddle) add nothing.
        f = GamepadFrame(); f.extra = 0b1111
        XCTAssertEqual(state(f), .neutral)
    }

    func testSaxArrivesOnceThroughTheFactoryEcho() {
        // SAX left: extra bit 4 plus button 1 (A). SAX right: extra bit 5 plus button 2 (B).
        XCTAssertEqual(state(frame(button: 1, extra: 16)), PadState(buttons: .a))
        XCTAssertEqual(state(frame(button: 2, extra: 32)), PadState(buttons: .b))
    }

    func testPaddleAndRealDpadPressTogetherStayASingleDirection() {
        // A paddle echoing "right" while the frame already says right is still one D-pad bit.
        var f = GamepadFrame(); f.hat = 2; f.extra = 1
        XCTAssertEqual(state(f).buttons, .dpadRight)
    }

    // MARK: Remaps (outputs)

    private func remapped(_ picks: [(String, ControlOutput)]) -> ControlMapping {
        var r = ControlMapping.default
        for (id, out) in picks { r.setOutput(out, for: id) }
        return r
    }

    private func down(_ buttons: Int...) -> GamepadFrame {
        var f = GamepadFrame()
        for n in buttons { f.buttons |= 1 << UInt32(n - 1) }
        return f
    }

    func testG1SendsYAsAnOrWithY() {
        let r = remapped([("g1", .pad(.y))])
        XCTAssertEqual(PassthroughPadMapper.padState(down(12), r).buttons, .y)
        XCTAssertEqual(PassthroughPadMapper.padState(down(4), r).buttons, .y)
        XCTAssertEqual(PassthroughPadMapper.padState(down(4, 12), r).buttons, .y)
        // Hold both, release G1: Y stays.
        XCTAssertEqual(PassthroughPadMapper.padState(down(4), r).buttons, .y)
        XCTAssertEqual(PassthroughPadMapper.padState(down(), r), .neutral)
    }

    func testSwapOfAAndB() {
        let r = remapped([("a", .pad(.b)), ("b", .pad(.a))])
        XCTAssertEqual(PassthroughPadMapper.padState(down(1), r).buttons, .b)
        XCTAssertEqual(PassthroughPadMapper.padState(down(2), r).buttons, .a)
        XCTAssertEqual(PassthroughPadMapper.padState(down(1, 2), r).buttons, [.a, .b])
    }

    func testControlSetToNothingAndBuiltInSendNothing() {
        var r = remapped([("a", .nothing), ("g2", .nothing)])
        XCTAssertEqual(PassthroughPadMapper.padState(down(1), r), .neutral)
        XCTAssertEqual(PassthroughPadMapper.padState(down(13), r), .neutral)
        r = ControlMapping.default                                  // g2 is built in by default
        XCTAssertEqual(r.effectiveOutput("g2"), .builtIn)
        XCTAssertEqual(PassthroughPadMapper.padState(down(13, 14, 15), r), .neutral)
        // A built-in key whose binding is a pad button still feeds nothing.
        r.buttons["g3"] = .button(1)
        XCTAssertEqual(PassthroughPadMapper.padState(down(1), r).buttons, .a)
        XCTAssertEqual(PassthroughPadMapper.padState(down(14), r), .neutral)
    }

    func testStartSentToYLeavesGuideOffAndG5CanSendGuide() {
        var r = remapped([("start", .pad(.y))])
        XCTAssertEqual(PassthroughPadMapper.padState(down(11), r).buttons, .y)
        r = remapped([("g5", .pad(.guide))])
        XCTAssertEqual(PassthroughPadMapper.padState(down(16), r).buttons, .guide)
        XCTAssertEqual(PassthroughPadMapper.padState(down(11), r).buttons, .guide, "start still sends Guide")
    }

    func testAButtonSentToATriggerGivesFullScale() {
        let r = remapped([("g1", .pad(.lt))])
        var f = down(12)
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).lt, 1.0)
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).rt, 0)
        f.lt = 400                                                  // the real LT still sends itself: max of the two
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).lt, 1.0)
        f.buttons = 0
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).lt, 400.0 / 1023.0, accuracy: 1e-12)
        XCTAssertEqual(PassthroughPadMapper.padState(down(), r).lt, 0)
    }

    func testTriggerSentToAButtonPressesItWhilePulled() {
        let r = remapped([("lt", .pad(.a))])
        var f = GamepadFrame(); f.lt = 101
        var s = PassthroughPadMapper.padState(f, r)
        XCTAssertEqual(s.buttons, .a)
        XCTAssertEqual(s.lt, 0, "LT itself is gone")
        f.lt = 100                                                  // the same threshold as ControlMapping.isActive
        s = PassthroughPadMapper.padState(f, r)
        XCTAssertEqual(s.buttons, [])
        XCTAssertEqual(s.lt, 0)
    }

    func testLTSentToRTAloneIsTheMaxOfBothAndLTGoesQuiet() {
        let r = remapped([("lt", .pad(.rt))])
        var f = GamepadFrame(); f.lt = 1023; f.rt = 200
        var s = PassthroughPadMapper.padState(f, r)
        XCTAssertEqual(s.rt, 1.0); XCTAssertEqual(s.lt, 0)
        f.lt = 100; f.rt = 512
        s = PassthroughPadMapper.padState(f, r)
        XCTAssertEqual(s.rt, 512.0 / 1023.0, accuracy: 1e-12)
        f.rt = 0
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).rt, 100.0 / 1023.0, accuracy: 1e-12)
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).lt, 0)
    }

    func testLTAndRTSwap() {
        let r = remapped([("lt", .pad(.rt)), ("rt", .pad(.lt))])
        var f = GamepadFrame(); f.lt = 1023; f.rt = 300
        let s = PassthroughPadMapper.padState(f, r)
        XCTAssertEqual(s.rt, 1.0); XCTAssertEqual(s.lt, 300.0 / 1023.0, accuracy: 1e-12)
    }

    func testAnUnRemappedLtLearnedAsAButtonSendsNoTrigger() {
        var r = ControlMapping.default
        r.buttons["lt"] = .button(5)                                // as the default mapping did for a learned button
        XCTAssertEqual(PassthroughPadMapper.padState(down(5), r).lt, 0)
        XCTAssertEqual(PassthroughPadMapper.padState(down(5), r).buttons, .lb, "button 5 is still LB's")
        var f = GamepadFrame(); f.lt = 1023
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).lt, 0)
    }

    func testTriggerValuesWithoutRemapsAreExactlyWhatTheyWere() {
        var f = GamepadFrame(); f.lt = 777; f.rt = 33
        let s = PassthroughPadMapper.padState(f, .default)
        XCTAssertEqual(s.lt, 777.0 / 1023.0); XCTAssertEqual(s.rt, 33.0 / 1023.0)
    }

    func testG5SentToDpadDownWhileTheHatSaysUpGivesNoDirection() {
        let r = remapped([("g5", .pad(.dpad_down))])
        var f = down(16); f.hat = 0
        let s = PassthroughPadMapper.padState(f, r)
        XCTAssertEqual(s.buttons, [.dpadUp, .dpadDown], "the mapper reports both; the report builder cancels them")
        let hat = PadIdentity.default.reports(for: s)[0].bytes[13]
        XCTAssertEqual(hat, 0, "opposite directions cancel in the report: no hat direction")
        f.hat = 8
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).buttons, .dpadDown)
    }

    func testControlsOutsideTheRemappableListNeverRemap() {
        var r = ControlMapping.default
        r.outputs["paddle_inner_left"] = .pad(.y)                   // hand-written, as a stray file entry
        XCTAssertEqual(PassthroughPadMapper.padState(down(), r), .neutral)
        var f = GamepadFrame(); f.extra = 4
        XCTAssertEqual(PassthroughPadMapper.padState(f, r).buttons, [], "the paddle sends nothing of its own")
    }
}

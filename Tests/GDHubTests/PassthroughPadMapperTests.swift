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
}

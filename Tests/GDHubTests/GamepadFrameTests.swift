import XCTest
@testable import GDHub

final class GamepadFrameTests: XCTestCase {
    /// Idle frame captured from the real receiver.
    let idle: [UInt8] = [0x06, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0]

    func testParsesIdleFrame() {
        let f = GamepadFrame.parse(idle)
        XCTAssertNotNil(f)
        XCTAssertEqual(f, GamepadFrame.idle)
        XCTAssertEqual(f?.hat, 8)
    }

    func testRejectsWrongLengthOrID() {
        XCTAssertNil(GamepadFrame.parse(Array(idle.dropLast())))
        var other = idle; other[0] = 0x58
        XCTAssertNil(GamepadFrame.parse(other))
    }

    func testParsesAxesTriggersHatButtonsAndExtra() {
        // x = 0x7fff, y = -32768, z = 0x1234, rz = -2; lt = 1023, rt = 512, hat = 2 (E);
        // buttons 1 and 19; extra bits 0 and 5.
        var b = idle
        b[1] = 0xff; b[2] = 0x7f
        b[3] = 0x00; b[4] = 0x80
        b[5] = 0x34; b[6] = 0x12
        b[7] = 0xfe; b[8] = 0xff
        let t: UInt32 = 1023 | (512 << 10) | (2 << 20)
        b[9] = UInt8(t & 0xff); b[10] = UInt8((t >> 8) & 0xff); b[11] = UInt8((t >> 16) & 0xff)
        let btn: UInt32 = (1 << 0) | (1 << 18) | ((1 | (1 << 5)) << 19)
        b[12] = UInt8(btn & 0xff); b[13] = UInt8((btn >> 8) & 0xff); b[14] = UInt8((btn >> 16) & 0xff); b[15] = UInt8((btn >> 24) & 0xff)
        guard let f = GamepadFrame.parse(b) else { return XCTFail("parse failed") }
        XCTAssertEqual(f.x, 32767)
        XCTAssertEqual(f.y, -32768)
        XCTAssertEqual(f.z, 0x1234)
        XCTAssertEqual(f.rz, -2)
        XCTAssertEqual(f.lt, 1023)
        XCTAssertEqual(f.rt, 512)
        XCTAssertEqual(f.hat, 2)
        XCTAssertTrue(f.isButtonDown(1))
        XCTAssertTrue(f.isButtonDown(19))
        XCTAssertFalse(f.isButtonDown(2))
        XCTAssertEqual(f.extra, 1 | (1 << 5))
    }

    func testDiffReportsButtonAndHatChanges() {
        var pressed = GamepadFrame.idle
        pressed.buttons = 1 << 6   // button 7 (Menu)
        pressed.hat = 4
        let events = pressed.diff(from: .idle)
        XCTAssertTrue(events.contains(.buttonDown(7)))
        XCTAssertTrue(events.contains(.hat(4)))
        let released = GamepadFrame.idle.diff(from: pressed)
        XCTAssertTrue(released.contains(.buttonUp(7)))
    }
}

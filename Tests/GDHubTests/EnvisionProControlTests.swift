import XCTest
@testable import GDHub

final class EnvisionProControlTests: XCTestCase {
    func testGetPacket() {
        let p = BragiPacket.get(target: 0x09, property: 0x0E)
        XCTAssertEqual(p.count, 64)
        XCTAssertEqual(Array(p.prefix(5)), [0x02, 0x09, 0x02, 0x0E, 0x00])
        XCTAssertTrue(p.dropFirst(4).allSatisfy { $0 == 0 })
    }

    func testSetPacketLittleEndian() {
        let p = BragiPacket.set(target: 0x09, property: 0x0E, value: 1_800_000)
        XCTAssertEqual(Array(p.prefix(9)), [0x02, 0x09, 0x01, 0x0E, 0x00, 0x40, 0x77, 0x1B, 0x00])
        XCTAssertEqual(Array(BragiPacket.set(target: 9, property: 3, value: 2).prefix(8)), [2, 9, 1, 3, 0, 2, 0, 0])
    }

    func testDecodeOK() {
        var bytes: [UInt8] = [0x01, 0x01, 0x02, 0x00, 0x80, 0xEE, 0x36, 0x00]
        bytes += [UInt8](repeating: 0, count: 56)
        let r = BragiPacket.decode(bytes)
        XCTAssertEqual(r, BragiPacket.Reply(fromController: true, echo: 2, status: 0, value: 3_600_000))
        XCTAssertEqual(r?.isOK, true)
    }

    func testDecodeRejected() {
        let r = BragiPacket.decode([0x01, 0x01, 0x01, 0x09, 0, 0, 0, 0])
        XCTAssertEqual(r?.status, 9)
        XCTAssertEqual(r?.isOK, false)
    }

    func testDecodeRejectsOtherReports() {
        XCTAssertNil(BragiPacket.decode([0x06, 0x01, 0x02, 0x00]))
        XCTAssertNil(BragiPacket.decode([0x01, 0x05, 0x02, 0x00]))
        XCTAssertNil(BragiPacket.decode([0x01, 0x01]))
    }

    func testReplyMatching() {
        let fromController = BragiPacket.Reply(fromController: true, echo: 2, status: 0, value: 0)
        XCTAssertTrue(BragiPacket.matches(fromController, target: 0x09, command: 2))
        XCTAssertFalse(BragiPacket.matches(fromController, target: 0x08, command: 2))
        XCTAssertFalse(BragiPacket.matches(fromController, target: 0x09, command: 1))
    }

    func testPresetToWrites() {
        let off = SleepSetting.off.propertyWrites
        XCTAssertEqual(off.count, 1)
        XCTAssertEqual(off[0].property, 0x0D); XCTAssertEqual(off[0].value, 0)
        let w = SleepSetting.minutes(30).propertyWrites
        XCTAssertEqual(w.map(\.property), [0x0D, 0x0E])
        XCTAssertEqual(w.map(\.value), [1, 1_800_000])
        XCTAssertEqual(SleepSetting.minutes(60).propertyWrites[1].value, 3_600_000)
    }

    func testPropertiesToPreset() {
        XCTAssertEqual(SleepSetting.from(enabled: 0, timerMs: 3_600_000), .off)
        XCTAssertEqual(SleepSetting.from(enabled: 1, timerMs: 300_000), .minutes(5))
        for p in SleepSetting.presets {
            let w = p.propertyWrites
            let back = SleepSetting.from(enabled: w[0].value, timerMs: w.count > 1 ? w[1].value : 0)
            XCTAssertEqual(back, p)
        }
    }

    func testLabelsAndCustom() {
        XCTAssertEqual(SleepSetting.presets.map(\.presetLabel), ["Off", "5 min", "10 min", "15 min", "30 min", "60 min"])
        XCTAssertTrue(SleepSetting.minutes(10).isPreset)
        let custom = SleepSetting.from(enabled: 1, timerMs: 7 * 60_000)
        XCTAssertFalse(custom.isPreset)
        XCTAssertEqual(custom.displayText, "Custom (7 min)")
        XCTAssertEqual(SleepSetting.minutes(15).displayText, "15 min")
    }
}

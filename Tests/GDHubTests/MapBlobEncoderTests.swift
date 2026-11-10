import XCTest
import GDHubXlate
@testable import GDHub

final class MapBlobEncoderTests: XCTestCase {
    typealias F = XlateFixtures

    private func blob(_ m: ControlMapping, revision: UInt32 = 1) -> [UInt8]? {
        if case .blob(let b) = MapBlobEncoder.encode(m, identity: F.identity, spec: F.spec, revision: revision) { return b }
        return nil
    }

    private func reason(_ m: ControlMapping, identity: PadIdentity = F.identity, axis: Double = 0.002, trigger: Double = 0.002) -> String? {
        if case .unsupported(let why) = MapBlobEncoder.encode(m, identity: identity, spec: F.spec, revision: 1, axisDeadband: axis, triggerDeadband: trigger) { return why }
        return nil
    }

    /// The accepted blob read back through the C validator and turned into a table again.
    private func decoded(_ blob: [UInt8]) throws -> (table: GDHMTable, map: gdx_map) {
        var m = gdx_map()
        let rc = blob.withUnsafeBufferPointer { b in F.spec.withUnsafeBufferPointer { s in gdx_validate(b.baseAddress, b.count, s.baseAddress, s.count, &m) } }
        XCTAssertEqual(rc, GDX_OK)
        func array<T, U>(_ t: T, _ count: Int, _ type: U.Type) -> [U] {
            var t = t
            return withUnsafeBytes(of: &t) { raw in (0..<count).map { raw.load(fromByteOffset: $0 * MemoryLayout<U>.stride, as: U.self) } }
        }
        var t = GDHMTable()
        t.revision = m.revision; t.specCRC32 = m.specCRC; t.silenceNeutralMs = m.silenceNeutralMs
        t.deadband = m.deadband; t.hysteresis = m.hysteresis; t.stickActive = m.stickActive
        t.triggerActiveRaw = m.triggerActiveRaw; t.axisActiveRaw = m.axisActiveRaw
        t.reports = (0..<Int(m.nReports)).map { GDHMTable.Report(id: array(m.reportID, 4, UInt8.self)[$0], length: array(m.reportLen, 4, UInt8.self)[$0]) }
        t.buttons = array(m.buttons, Int(m.nButtons), gdx_button_rule.self).map {
            GDHMTable.Button(item: $0.item, kind: $0.kind, arg: $0.arg, sign: $0.sign, physMask: $0.physMask, stickRef: $0.stickRef, outSlot: $0.outSlot) }
        t.axes = array(m.axes, Int(m.nAxes), gdx_axis_rule.self).map {
            GDHMTable.Axis(stick: $0.stick, component: $0.component, field: $0.field, sign: $0.sign, hasRange: $0.hasRange != 0, min: $0.min, max: $0.max) }
        t.triggers = array(m.triggers, Int(m.nTriggers), gdx_trigger_rule.self).map { GDHMTable.Trigger(item: $0.item, field: $0.field) }
        t.placements = array(m.placements, Int(m.nPlacements), gdx_placement.self).map {
            GDHMTable.Placement(reportIndex: $0.reportIndex, item: $0.item, bitOffset: $0.bitOffset, bits: $0.bits, encoding: $0.encoding) }
        return (t, m)
    }

    // MARK: Round trips

    func testFactoryMappingRoundTripsThroughTheValidator() throws {
        let t = try MapBlobEncoder.table(.default, identity: F.identity, spec: F.spec, revision: 42)
        let b = try XCTUnwrap(blob(.default, revision: 42))
        XCTAssertEqual(b, t.serialize())
        let (back, map) = try decoded(b)
        XCTAssertEqual(back, t)
        XCTAssertEqual(map.revision, 42)
        XCTAssertEqual(back.specCRC32, GDHMTable.crc32(F.spec))
        XCTAssertEqual(back.silenceNeutralMs, 250)
        XCTAssertEqual(back.deadband, 0.002); XCTAssertEqual(back.hysteresis, 0.002); XCTAssertEqual(back.stickActive, 0.5)
        XCTAssertEqual(back.triggerActiveRaw, 100); XCTAssertEqual(back.axisActiveRaw, 16000)
        XCTAssertEqual(back.reports, [.init(id: 1, length: 16), .init(id: 2, length: 2)])
        XCTAssertEqual(back.placements.count, 18)
        XCTAssertEqual(back.buttons.count, 15)
    }

    func testFactoryRulesAreWhatTheLearnedLayoutSays() throws {
        let t = try decoded(try XCTUnwrap(blob(.default))).table
        func rule(_ item: Int) -> GDHMTable.Button { t.buttons.first { Int($0.item) == item }! }
        XCTAssertEqual(rule(GDX_ITEM_A), .init(item: 0, kind: UInt8(GDX_KIND_BUTTON), arg: 0))            // button 1
        XCTAssertEqual(rule(GDX_ITEM_MENU), .init(item: 7, kind: UInt8(GDX_KIND_BUTTON), arg: 7))         // button 8
        XCTAssertEqual(rule(GDX_ITEM_GUIDE), .init(item: 10, kind: UInt8(GDX_KIND_BUTTON), arg: 10))      // "start" -> Guide
        XCTAssertEqual(rule(GDX_ITEM_DPAD_UP), .init(item: 11, kind: UInt8(GDX_KIND_HAT), arg: 0))
        XCTAssertEqual(rule(GDX_ITEM_DPAD_RIGHT), .init(item: 12, kind: UInt8(GDX_KIND_HAT), arg: 2))
        XCTAssertEqual(rule(GDX_ITEM_DPAD_DOWN), .init(item: 13, kind: UInt8(GDX_KIND_HAT), arg: 4))
        XCTAssertEqual(rule(GDX_ITEM_DPAD_LEFT), .init(item: 14, kind: UInt8(GDX_KIND_HAT), arg: 6))
        XCTAssertEqual(t.axes, [.init(stick: 0, component: 0, field: 0, sign: 1), .init(stick: 0, component: 1, field: 1, sign: 1),
                                .init(stick: 1, component: 0, field: 2, sign: 1), .init(stick: 1, component: 1, field: 3, sign: 1)])
        XCTAssertEqual(t.triggers, [.init(item: 20, field: 0), .init(item: 21, field: 1)])
        // Paddles, SAX, G1...G5 and Profile are not pad items: v1 has no rule for them (plan 5.2).
        XCTAssertFalse(t.buttons.contains { $0.physMask != 0 })
    }

    func testLearnedMappingWithAsymmetricRangesAndPhysicalMasksRoundTrips() throws {
        var m = ControlMapping.default
        m.sticks["left_stick"] = StickBinding(horizontal: .axis("rz", sign: -1), vertical: .axis("x", sign: 1),
                                              ranges: ["rz": AxisRange(min: -28000, max: 31000), "x": AxisRange(min: -32768, max: 20000)])
        m.sticks["right_stick"] = StickBinding(horizontal: .axis("y", sign: 2), vertical: nil, ranges: ["y": AxisRange(min: -1, max: 1)])
        m.buttons["a"] = .axis("z", sign: -1); m.physicalBits["a"] = 0b101; m.buttons["lt"] = .trigger("rt")
        m.buttons["b"] = .trigger("lt"); m.sticks["x"] = m.sticks["left_stick"]; m.buttons["x"] = nil
        let t = try decoded(try XCTUnwrap(blob(m))).table
        XCTAssertEqual(t.axes[0], .init(stick: 0, component: 0, field: 3, sign: -1, hasRange: true, min: -28000, max: 31000))
        XCTAssertEqual(t.axes[1], .init(stick: 0, component: 1, field: 0, sign: 1, hasRange: true, min: -32768, max: 20000))
        XCTAssertEqual(t.axes[2], .init(stick: 1, component: 0, field: 1, sign: 2, hasRange: true, min: -1, max: 1))
        XCTAssertEqual(t.axes[3], .init(stick: 1, component: 1, field: UInt8(GDX_FIELD_NONE)))
        XCTAssertEqual(t.buttons[0], .init(item: 0, kind: UInt8(GDX_KIND_AXIS_GT), arg: 2, sign: -1, physMask: 0b101))
        XCTAssertEqual(t.buttons[1], .init(item: 1, kind: UInt8(GDX_KIND_TRIGGER_GT), arg: 0))
        XCTAssertEqual(t.buttons[2], .init(item: 2, kind: UInt8(GDX_KIND_STICK_MAG), stickRef: 0))
        XCTAssertEqual(t.triggers[0], .init(item: 20, field: 1))
    }

    func testLiveShapedMappingEncodes() throws {
        let t = try decoded(try XCTUnwrap(blob(F.liveShaped))).table
        XCTAssertTrue(t.axes.allSatisfy { $0.hasRange && $0.min == -32768 && $0.max == 32767 })
    }

    func testEveryRandomLearnedMappingEncodesAndValidates() throws {
        var rng = SplitMix64(seed: 0xE9C0DE)
        for i in 0..<500 {
            let m = F.randomMapping(&rng)
            let b = try XCTUnwrap(blob(m), "random mapping \(i) must be expressible")
            XCTAssertEqual(F.validate(b), GDX_OK, "random mapping \(i)")
            XCTAssertLessThanOrEqual(b.count, 1024)
            XCTAssertEqual(try decoded(b).table, try MapBlobEncoder.table(m, identity: F.identity, spec: F.spec, revision: 1))
        }
    }

    func testEncodingIsDeterministicAndTracksRevisionAndSpec() throws {
        XCTAssertEqual(blob(.default), blob(.default))
        XCTAssertNotEqual(blob(.default, revision: 1), blob(.default, revision: 2))
        var other = F.spec; other[16] ^= 1
        guard case .blob(let b2) = MapBlobEncoder.encode(.default, identity: F.identity, spec: other, revision: 1) else { return XCTFail() }
        XCTAssertNotEqual(b2, blob(.default))
        XCTAssertEqual(F.validate(b2, spec: other), GDX_OK)
        XCTAssertEqual(F.validate(b2), GDX_E_SPEC_CRC, "a blob compiled for another spec is refused by this one")
    }

    func testControlsThatAreNotPadItemsDoNotChangeTheBlob() throws {
        var m = ControlMapping.default
        m.buttons["g1"] = .hat(3); m.buttons["profile"] = .button(1); m.buttons["paddle_inner_left"] = .axis("x", sign: 9999)
        m.physicalBits["paddle_outer_left"] = 0x1fff; m.buttons["sax_left"] = .axis("x", sign: -77777)
        m.sticks["not_a_control"] = StickBinding(horizontal: .axis("x", sign: 1), vertical: nil, ranges: nil)
        XCTAssertEqual(blob(m), blob(.default), "the Swift mapper never reads them either")
    }

    // MARK: Expressible but odd

    func testDegenerateBindingsEncodeAsNeverActive() throws {
        var m = ControlMapping.default
        m.buttons["a"] = .button(0); m.buttons["b"] = .button(20); m.buttons["x"] = .trigger("zz"); m.buttons["y"] = .axis("w", sign: 1)
        m.buttons["lb"] = .hat(200)
        let t = try decoded(try XCTUnwrap(blob(m))).table
        for i in 0..<4 { XCTAssertEqual(t.buttons[i].kind, UInt8(GDX_KIND_NONE), "item \(i)") }
        XCTAssertEqual(t.buttons[4], .init(item: 4, kind: UInt8(GDX_KIND_HAT), arg: 200))
    }

    func testAPhysicalMaskReplacesAnInexpressibleBinding() throws {
        var m = ControlMapping.default
        m.buttons["a"] = .axis("x", sign: 100_000)
        XCTAssertNotNil(reason(m))
        m.physicalBits["a"] = 4                       // ControlMapping.isActive never looks at the binding then
        let b = try XCTUnwrap(blob(m))
        XCTAssertEqual(try decoded(b).table.buttons[0], .init(item: 0, kind: UInt8(GDX_KIND_NONE), physMask: 4))
    }

    // MARK: .unsupported

    func testUnsupportedReasons() {
        var m = ControlMapping.default
        m.buttons["a"] = .axis("x", sign: 200)
        XCTAssertTrue(reason(m)?.contains("a: axis sign 200") == true, reason(m) ?? "nil")

        m = .default
        m.sticks["left_stick"]?.horizontal = .axis("x", sign: -1000)
        XCTAssertTrue(reason(m)?.contains("left_stick: axis sign -1000") == true, reason(m) ?? "nil")

        m = .default
        m.sticks["right_stick"]?.ranges = ["z": AxisRange(min: -3_000_000_000, max: 5)]
        XCTAssertTrue(reason(m)?.contains("right_stick: learned range") == true, reason(m) ?? "nil")
        m.sticks["right_stick"]?.ranges = ["z": AxisRange(min: -5, max: Int(Int32.max) + 1)]
        XCTAssertNotNil(reason(m))

        m = .default
        m.sticks["view"] = StickBinding(horizontal: .axis("x", sign: 1), vertical: nil, ranges: nil)   // not the left or right stick
        m.buttons["view"] = nil
        XCTAssertTrue(reason(m)?.contains("view: a stick binding") == true, reason(m) ?? "nil")

        XCTAssertNotNil(reason(.default, axis: 0.002, trigger: 0.004))
        XCTAssertNotNil(reason(.default, axis: 1.5, trigger: 1.5))
        XCTAssertNotNil(reason(.default, axis: -0.1, trigger: -0.1))
        XCTAssertNil(reason(.default, axis: 0.01, trigger: 0.01))

        let other = PadIdentity(id: "other-layout", title: "x", vendorID: 1, productID: 2, versionNumber: 0, transport: "t", manufacturer: "m",
                                product: "p", serialNumber: "s", locationID: 0, reportIntervalUs: 1000, descriptor: PadDescriptors.xboxBT16,
                                sendLengths: [:], builder: PadReportBuilders.xboxBT16)
        XCTAssertTrue(reason(.default, identity: other)?.contains("other-layout") == true)
        XCTAssertNil(reason(.default, identity: .xboxBT16), "both Xbox identities share the layout")
    }

    func testAnEmptyStickBindingOnAButtonControlIsNeverActive() throws {
        var m = ControlMapping.default
        m.sticks["a"] = StickBinding(horizontal: nil, vertical: nil, ranges: nil); m.buttons["a"] = nil
        XCTAssertEqual(try decoded(try XCTUnwrap(blob(m))).table.buttons[0].kind, UInt8(GDX_KIND_NONE))
    }

    // MARK: Remaps (outputs)

    private func remapped(_ picks: [(String, ControlOutput)]) -> ControlMapping { remapped(.default, picks) }

    private func remapped(_ base: ControlMapping, _ picks: [(String, ControlOutput)]) -> ControlMapping {
        var m = base
        for (id, o) in picks { m.setOutput(o, for: id) }
        return m
    }

    func testTwoSourcesOnOnePadButtonEncodeAndValidate() throws {
        let m = remapped([("g1", .pad(.y))])
        XCTAssertNil(MapBlobEncoder.remapLimit(m))
        let b = try XCTUnwrap(blob(m))
        XCTAssertEqual(F.validate(b), GDX_OK)
        let t = try decoded(b).table
        XCTAssertEqual(t.buttons.filter { $0.item == 3 }, [.init(item: 3, kind: UInt8(GDX_KIND_BUTTON), arg: 3),
                                                         .init(item: 3, kind: UInt8(GDX_KIND_BUTTON), arg: 11)], "Y by Y, then G1 (button 12)")
        XCTAssertEqual(t.buttons.count, 16)
        XCTAssertEqual(t.triggers, [.init(item: 20, field: 0), .init(item: 21, field: 1)])
    }

    func testAControlSentNowhereLeavesItsItemWithoutARule() throws {
        let m = remapped([("a", .nothing), ("start", .pad(.y))])
        let t = try decoded(try XCTUnwrap(blob(m))).table
        XCTAssertFalse(t.buttons.contains { $0.item == 0 }, "A has no source")
        XCTAssertFalse(t.buttons.contains { $0.item == 10 }, "Guide has no source")
        XCTAssertEqual(t.buttons.filter { $0.item == 3 }.map(\.arg), [3, 10], "Y by Y, then Start (button 11)")
    }

    func testThreeSourcesAreUnsupportedWithTheirNames() {
        let m = remapped([("g1", .pad(.y)), ("g2", .pad(.y))])
        XCTAssertEqual(MapBlobEncoder.remapLimit(m), "three buttons send Y: y, g1, g2")
        XCTAssertEqual(reason(m), "three buttons send Y: y, g1, g2")
        // Moving the original owner away makes it two again.
        XCTAssertNil(MapBlobEncoder.remapLimit(remapped(m, [("y", .nothing)])))
    }

    func testAButtonSentToATriggerIsUnsupported() {
        let m = remapped([("g1", .pad(.lt))])
        XCTAssertEqual(reason(m), "g1 sends LT: a button cannot pull a trigger in this driver version")
        // Also when LT itself is gone: the button is the only source and still cannot pull a trigger.
        XCTAssertEqual(reason(remapped([("lt", .nothing), ("g1", .pad(.lt))])),
                       "g1 sends LT: a button cannot pull a trigger in this driver version")
    }

    func testLTSentToRTAloneIsUnsupportedButTheSwapAndTheMoveAwayAreFine() throws {
        XCTAssertEqual(reason(remapped([("lt", .pad(.rt))])), "two controls send RT: rt, lt")
        let swap = remapped([("lt", .pad(.rt)), ("rt", .pad(.lt))])
        XCTAssertNil(MapBlobEncoder.remapLimit(swap))
        let b = try XCTUnwrap(blob(swap))
        XCTAssertEqual(F.validate(b), GDX_OK)
        XCTAssertEqual(try decoded(b).table.triggers, [.init(item: 20, field: 1), .init(item: 21, field: 0)], "LT reads rt, RT reads lt")
        let moved = remapped([("lt", .pad(.rt)), ("rt", .nothing)])
        let t = try decoded(try XCTUnwrap(blob(moved))).table
        XCTAssertEqual(t.triggers, [.init(item: 20, field: UInt8(GDX_FIELD_NONE)), .init(item: 21, field: 0)])
    }

    func testATriggerSentToAButtonOrToNothingEncodes() throws {
        let toA = remapped([("lt", .pad(.a))])
        let t = try decoded(try XCTUnwrap(blob(toA))).table
        XCTAssertEqual(t.buttons.filter { $0.item == 0 }, [.init(item: 0, kind: UInt8(GDX_KIND_BUTTON), arg: 0),
                                                         .init(item: 0, kind: UInt8(GDX_KIND_TRIGGER_GT), arg: 0)])
        XCTAssertEqual(t.triggers[0], .init(item: 20, field: UInt8(GDX_FIELD_NONE)))
        XCTAssertNotNil(blob(remapped([("lt", .nothing)])))
    }

    func testNoRemapLimitWithoutRemaps() {
        XCTAssertNil(MapBlobEncoder.remapLimit(.default))
        XCTAssertNil(MapBlobEncoder.remapLimit(ControlMapping()))
        var rng = SplitMix64(seed: 0x11AA)
        for _ in 0..<200 { XCTAssertNil(MapBlobEncoder.remapLimit(F.randomMapping(&rng))) }
    }

    func testRemapLimitIsNilExactlyWhenEncodingSucceeds() throws {
        var accepted = 0, refused = 0
        var reasons = Set<String>()
        for i in 0..<600 {
            let base = i % 2 == 0 ? ControlMapping.default : F.liveShaped
            let m = F.randomOutputs(base, 0xA11C_E000 + UInt64(i), expressibleOnly: false)
            let limit = MapBlobEncoder.remapLimit(m)
            switch MapBlobEncoder.encode(m, identity: F.identity, spec: F.spec, revision: 1) {
            case .blob(let b):
                XCTAssertNil(limit, "mapping \(i)")
                XCTAssertEqual(F.validate(b), GDX_OK, "mapping \(i)")
                accepted += 1
            case .unsupported(let why):
                XCTAssertEqual(limit, why, "mapping \(i)")
                for kind in ["buttons send", "cannot pull a trigger", "controls send"] where why.contains(kind) { reasons.insert(kind) }
                refused += 1
            }
        }
        XCTAssertGreaterThan(accepted, 100); XCTAssertGreaterThan(refused, 30)
        XCTAssertEqual(reasons.count, 3, "several kinds of limit were hit: \(reasons)")
    }

    func testExpressibleRandomOutputsAlwaysEncode() throws {
        var remappedCount = 0
        for i in 0..<400 {
            var rng = SplitMix64(seed: 0xB0B0 + UInt64(i))
            let m = F.randomOutputs(F.randomMapping(&rng), 0xC0DE_0000 + UInt64(i))
            let b = try XCTUnwrap(blob(m), "mapping \(i): \(String(describing: MapBlobEncoder.remapLimit(m)))")
            XCTAssertEqual(F.validate(b), GDX_OK)
            if !m.outputs.isEmpty { remappedCount += 1 }
        }
        XCTAssertGreaterThan(remappedCount, 300)
    }

    func testRandomOutputsUseTheirOwnSeedAndLeaveTheMappingStreamAlone() {
        var a = SplitMix64(seed: 99), b = SplitMix64(seed: 99)
        let m1 = F.randomMapping(&a)
        _ = F.randomOutputs(.default, 5); _ = F.randomOutputs(.default, 6)
        XCTAssertEqual(F.randomMapping(&b), m1)
        XCTAssertEqual(F.randomOutputs(.default, 5), F.randomOutputs(.default, 5), "deterministic")
        XCTAssertEqual(a.next(), b.next())
    }

    func testAnUnRemappedMappingWithLtLearnedAsAButtonEncodesLikeBefore() throws {
        var m = ControlMapping.default
        m.buttons["lt"] = .button(5)
        let t = try decoded(try XCTUnwrap(blob(m))).table
        XCTAssertEqual(t.triggers, [.init(item: 20, field: UInt8(GDX_FIELD_NONE)), .init(item: 21, field: 1)], "LT sends nothing, as before")
        XCTAssertEqual(t.buttons.count, 15)
        // Byte-identical to what the pre-remap encoder wrote: its single trigger rule was "field of lt's trigger binding, else none".
        var legacy = try MapBlobEncoder.table(.default, identity: F.identity, spec: F.spec, revision: 1)
        legacy.triggers[0].field = UInt8(GDX_FIELD_NONE)
        XCTAssertEqual(blob(m), legacy.serialize())
        // A stray entry equal to the default changes nothing either.
        var stray = m
        stray.outputs["a"] = .pad(.a)
        XCTAssertEqual(blob(stray), blob(m))
    }

    func testFactoryBlobIsUnchangedByTheRemapSupport() throws {
        // 15 rules, one per item, in item order, each from the item's own control; two triggers.
        let t = try MapBlobEncoder.table(.default, identity: F.identity, spec: F.spec, revision: 1)
        XCTAssertEqual(t.buttons.map(\.item), Array(0..<15).map { UInt8($0) })
        XCTAssertEqual(t.buttons.count, 15)
    }
}

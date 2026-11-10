import XCTest
import GDHubXlate
@testable import GDHub

/// The C core (`gdx_*`) against the Swift pipeline it replaces, on raw 16-byte reports, byte for byte.
/// Oracle: `GamepadFrame.parse` -> `PassthroughPadMapper` -> `VirtualPadSink.snapped` -> `PadReportBuilders`.
final class GDHubXlateParityTests: XCTestCase {
    typealias F = XlateFixtures

    private struct Case { let name: String; let mapping: ControlMapping }

    private func standardMappings() -> [Case] {
        var rng = SplitMix64(seed: 0x6D61_7070_696E_67)         // fixed: the three random learned mappings never change
        return [Case(name: "factory", mapping: .default), Case(name: "live-shaped", mapping: F.liveShaped)]
            + (0..<3).map { Case(name: "random\($0)", mapping: F.randomMapping(&rng)) }
    }

    /// Remapped mappings from their own seeds (the generator that draws them never touches the stream above): the hand-picked
    /// shapes of the plan first, then random expressible ones on top of the factory, the live-shaped and random mappings.
    private func remappedMappings() -> [Case] {
        func r(_ picks: [(String, ControlOutput)]) -> ControlMapping {
            var m = ControlMapping.default
            for (id, o) in picks { m.setOutput(o, for: id) }
            return m
        }
        var rng = SplitMix64(seed: 0x7265_6D61_70)
        var out = [Case(name: "g1->y", mapping: r([("g1", .pad(.y))])),
                   Case(name: "a<->b", mapping: r([("a", .pad(.b)), ("b", .pad(.a))])),
                   Case(name: "lt<->rt", mapping: r([("lt", .pad(.rt)), ("rt", .pad(.lt))])),
                   Case(name: "lt->a,rt->nothing", mapping: r([("lt", .pad(.a)), ("rt", .nothing)])),
                   Case(name: "lt->rt,rt->nothing", mapping: r([("lt", .pad(.rt)), ("rt", .nothing)])),
                   Case(name: "dpad+g5", mapping: r([("g5", .pad(.dpad_down)), ("g4", .pad(.dpad_up)), ("start", .pad(.y))]))]
        for i in 0..<10 {
            let base = [ControlMapping.default, F.liveShaped, F.randomMapping(&rng)][i % 3]
            out.append(Case(name: "remap\(i)", mapping: F.randomOutputs(base, 0x5EED_0000 + UInt64(i))))
        }
        return out
    }

    /// One frame through both pipelines; mismatches go to `log`.
    private func check(_ core: XlateCore, _ oracle: SwiftOracle, _ raw: [UInt8], _ log: MismatchLog, _ tag: @autoclosure () -> String) {
        let want = oracle.state(raw)
        let got = core.eval(raw: raw)
        guard let w = want else {
            if got != nil { log.note("\(tag()): C accepted a frame GamepadFrame.parse rejects: \(hex(raw))") }
            return
        }
        guard let g = got else { log.note("\(tag()): C rejected a valid frame: \(hex(raw))"); return }
        let a = core.reports(g), b = oracle.reports(w)
        if a != b {
            log.note("\(tag()): \(hex(raw)) -> C \(a.map { hex($0.bytes) }) vs Swift \(b.map { hex($0.bytes) })")
        } else if XlateCore.state(from: g) != w {
            log.note("\(tag()): \(hex(raw)) pad differs: C \(XlateCore.state(from: g)) vs Swift \(w)")
        }
    }

    // MARK: Buttons, hat, physical bits

    func testEveryButtonBitAndHatValue() throws {
        try sweepButtonsAndHats(standardMappings())
    }

    func testEveryButtonBitAndHatValueOnRemappedMappings() throws {
        try sweepButtonsAndHats(remappedMappings())
    }

    private func sweepButtonsAndHats(_ cases: [Case]) throws {
        let log = MismatchLog()
        var frames = 0
        for c in cases {
            let core = try F.core(c.mapping), oracle = SwiftOracle(mapping: c.mapping)
            var buttonSets = [0, 0x7ffff] + (0..<19).map { 1 << $0 }
            buttonSets += (0..<18).map { 3 << $0 }                                  // neighbouring pairs
            let extras = [0, 0x1fff] + (0..<13).map { 1 << $0 }
            for hat in 0...15 {
                for buttons in buttonSets {
                    for extra in extras {
                        var b = [UInt8](repeating: 0, count: 16); b[0] = 6
                        F.setTriggers(&b, 0, 0, hat: hat); F.setButtons(&b, buttons, extra: extra)
                        check(core, oracle, b, log, "\(c.name) hat \(hat) buttons \(buttons) extra \(extra)")
                        frames += 1
                    }
                }
            }
            // Extra-bit pairs and triples (two-bit physical masks): all combinations on an otherwise idle frame.
            for a in 0..<13 { for b2 in a..<13 {
                var b = [UInt8](repeating: 0, count: 16); b[0] = 6; F.setTriggers(&b, 0, 0, hat: 8)
                F.setButtons(&b, 0, extra: (1 << a) | (1 << b2)); check(core, oracle, b, log, "\(c.name) extra pair \(a),\(b2)")
                frames += 1
            } }
        }
        log.assertNone("buttons/hat/extra (\(frames) frames)")
    }

    func testPhysicalMaskPrecedenceOnEveryControl() throws {
        let log = MismatchLog()
        var frames = 0
        var masks: [UInt16] = (0..<13).map { UInt16(1) << UInt16($0) }
        for a in 0..<13 { for b in (a + 1)..<13 where (a + b) % 3 == 0 { masks.append((1 << UInt16(a)) | (1 << UInt16(b))) } }
        masks += [0x1fff, 0x8001, 0xffff]
        for cid in MapBlobEncoder.buttonControls {
            for mask in masks {
                var m = ControlMapping.default
                m.physicalBits[cid] = mask
                let core = try F.core(m), oracle = SwiftOracle(mapping: m)
                // The frames: the mask alone, one bit short, the mask plus noise, the bound button/hat alone, everything.
                let extras = [Int(mask) & 0x1fff, (Int(mask) & 0x1fff) & ((Int(mask) & 0x1fff) - 1), (Int(mask) & 0x1fff) | 0x0a05, 0, 0x1fff]
                for extra in extras {
                    for (buttons, hat) in [(0, 8), (0x7ffff, 8), (1, 0), (0x400, 2), (0, 0), (0, 4), (0, 6), (0, 1)] {
                        var b = [UInt8](repeating: 0, count: 16); b[0] = 6
                        F.setTriggers(&b, 0, 0, hat: hat); F.setButtons(&b, buttons, extra: extra)
                        check(core, oracle, b, log, "\(cid) mask \(mask) extra \(extra)")
                        frames += 1
                    }
                }
            }
        }
        log.assertNone("physMask precedence (\(frames) frames)")
    }

    // MARK: Axes

    private let rangeSets: [AxisRange?] = [AxisRange(min: -32768, max: 32767), nil, AxisRange(min: -28000, max: 31000),
                                           AxisRange(min: -32768, max: 20000), AxisRange(min: -100, max: 100), AxisRange(min: -1, max: 1)]

    /// Every int16 value on every axis, for {full range, no range, three asymmetric learned ranges, +-1} x sign +-1.
    func testEveryInt16OnEveryAxisWithLearnedRanges() throws {
        let log = MismatchLog()
        let names = ["x", "y", "z", "rz"]
        let mult = [1, 7, 13, 31], off = [0, 12_345, 777, 40_000]
        var frames = 0
        for k in 0..<12 {
            var m = ControlMapping.default
            for (stickName, fields) in [("left_stick", [0, 1]), ("right_stick", [2, 3])] {
                var s = StickBinding(horizontal: nil, vertical: nil, ranges: [:])
                for (c, f) in fields.enumerated() {
                    let sign = (k < 6 ? 1 : -1) * (f % 2 == 0 ? 1 : -1)
                    let b = Binding.axis(names[f], sign: sign)
                    if c == 0 { s.horizontal = b } else { s.vertical = b }
                    if let r = rangeSets[(f + k) % 6] { s.ranges?[names[f]] = r }
                }
                m.sticks[stickName] = s
            }
            let core = try F.core(m), oracle = SwiftOracle(mapping: m)
            var b = [UInt8](repeating: 0, count: 16); b[0] = 6; F.setTriggers(&b, 0, 0, hat: 8)
            for n in 0..<65536 {
                for a in 0..<4 {
                    let u = UInt16(truncatingIfNeeded: n &* mult[a] &+ off[a])
                    b[1 + 2 * a] = UInt8(u & 0xff); b[2 + 2 * a] = UInt8(u >> 8)
                }
                check(core, oracle, b, log, "sweep \(k)")
                frames += 1
            }
        }
        log.assertNone("axis sweeps (\(frames) frames)")
    }

    /// Axis-as-button rules (|raw| > 16000 with a sign) and the stick-magnitude rule, over the whole int16 range.
    func testAxisAndStickAsButtonThresholds() throws {
        var m = ControlMapping.default
        m.buttons["a"] = .axis("x", sign: 1); m.buttons["b"] = .axis("x", sign: -1)
        m.buttons["x"] = .axis("rz", sign: 1); m.buttons["y"] = .axis("y", sign: -1)
        m.buttons["lb"] = .axis("z", sign: 2); m.buttons["rb"] = .axis("z", sign: -3)
        m.sticks["left_stick"]?.ranges = ["x": AxisRange(min: -28000, max: 31000), "y": AxisRange(min: -32768, max: 20000)]
        m.sticks["view"] = m.sticks["left_stick"]; m.buttons["view"] = nil          // stick magnitude as a button
        m.sticks["menu"] = m.sticks["right_stick"]; m.buttons["menu"] = nil
        let core = try F.core(m), oracle = SwiftOracle(mapping: m)
        let log = MismatchLog()
        var b = [UInt8](repeating: 0, count: 16); b[0] = 6; F.setTriggers(&b, 0, 0, hat: 8)
        for n in 0..<65536 {
            for a in 0..<4 {
                let u = UInt16(truncatingIfNeeded: n &* [1, 5, 11, 17][a] &+ [0, 999, 4321, 20000][a])
                b[1 + 2 * a] = UInt8(u & 0xff); b[2 + 2 * a] = UInt8(u >> 8)
            }
            check(core, oracle, b, log, "axis-as-button")
        }
        log.assertNone("axis/stick as button")
    }

    // MARK: Triggers

    /// Every raw trigger value through remaps that move, swap, drop or re-source LT and RT, on bindings that make a trigger
    /// control analog, digital or unbound.
    func testEveryTriggerRawValueUnderTriggerRemaps() throws {
        let log = MismatchLog()
        let shapes: [[(String, ControlOutput)]] = [
            [("lt", .pad(.rt)), ("rt", .pad(.lt))], [("lt", .pad(.rt)), ("rt", .nothing)], [("lt", .pad(.a))],
            [("rt", .pad(.lt)), ("lt", .pad(.x))], [("lt", .nothing), ("rt", .pad(.y)), ("a", .pad(.b))], [("rt", .pad(.rb))],
        ]
        let bindings: [(Binding?, Binding?)] = [(.trigger("lt"), .trigger("rt")), (.trigger("rt"), .trigger("lt")),
                                                (nil, .trigger("lt")), (.trigger("zz"), .button(2)), (.trigger("lt"), .trigger("lt"))]
        for shape in shapes {
            for (lt, rt) in bindings {
                var m = ControlMapping.default
                m.buttons["lt"] = lt; m.buttons["rt"] = rt
                for (id, o) in shape { m.setOutput(o, for: id) }
                guard MapBlobEncoder.remapLimit(m) == nil else { continue }
                let core = try F.core(m), oracle = SwiftOracle(mapping: m)
                for v in 0...1023 {
                    for w in [v, 1023 - v, (v * 7) % 1024] {
                        var b = [UInt8](repeating: 0, count: 16); b[0] = 6
                        F.setTriggers(&b, v, w, hat: 8)
                        check(core, oracle, b, log, "trigger \(v)/\(w) \(shape.map { "\($0.0)=\($0.1.string)" })")
                    }
                }
            }
        }
        log.assertNone("triggers under remaps")
    }

    func testEveryTriggerRawValueAndBinding() throws {
        let log = MismatchLog()
        let bindings: [(Binding?, Binding?)] = [(.trigger("lt"), .trigger("rt")), (.trigger("rt"), .trigger("lt")),
                                                (nil, .trigger("lt")), (.trigger("zz"), .button(2))]
        for (lt, rt) in bindings {
            var m = ControlMapping.default
            m.buttons["lt"] = lt; m.buttons["rt"] = rt
            m.buttons["a"] = .trigger("lt"); m.buttons["b"] = .trigger("rt")
            let core = try F.core(m), oracle = SwiftOracle(mapping: m)
            for v in 0...1023 {
                for w in [v, 1023 - v, (v * 7) % 1024] {
                    var b = [UInt8](repeating: 0, count: 16); b[0] = 6
                    F.setTriggers(&b, v, w, hat: 8)
                    check(core, oracle, b, log, "trigger \(v)/\(w)")
                }
            }
        }
        log.assertNone("triggers")
    }

    // MARK: Hysteresis and deadband primitives

    func testHysteresisPrimitiveOnBothSidesOfEveryThreshold() throws {
        let core = try F.core(.default)
        let m: [Double] = [0, 0.001, 0.00199, 0.0019999999999999, 0.002, 0.0020000000000001, 0.00201, 0.003, 0.004, 0.0039999, 0.0040001,
                           0.5, 0.9, 0.997, 0.998, 0.9979999, 0.9980001, 0.999, 0.9999999999999999, 1.0, 1.0000000000000002, 2]
        let values = m + m.dropFirst().map { -$0 }
        let log = MismatchLog()
        var pairs = 0
        for ch in 0..<6 {
            for a in values where ch < 4 || a >= 0 {
                for b in values where ch < 4 || b >= 0 {
                    func state(_ v: Double) -> PadState {
                        var s = PadState(buttons: [.a])
                        switch ch { case 0: s.lx = v; case 1: s.ly = v; case 2: s.rx = v; case 3: s.ry = v; case 4: s.lt = v; default: s.rt = v }
                        return s
                    }
                    let (s, last) = (state(a), state(b))
                    let want = VirtualPadSink.unchanged(s, last, axisDeadband: 0.002, triggerDeadband: 0.002)
                    let got = core.unchanged(XlateCore.pad(from: s), XlateCore.pad(from: last))
                    if want != got { log.note("channel \(ch): now \(a) last \(b): C \(got) Swift \(want)") }
                    pairs += 1
                }
            }
        }
        // Buttons differ -> changed, whatever the axes do.
        let a = XlateCore.pad(from: PadState(buttons: [.a])), b = XlateCore.pad(from: PadState(buttons: [.b]))
        XCTAssertFalse(core.unchanged(a, b))
        XCTAssertTrue(core.unchanged(a, a))
        log.assertNone("hysteresis (\(pairs) pairs)")
    }

    func testPadStateConversionIsExact() {
        for raw in 0...UInt16.max {
            let b = PadButtons(rawValue: raw)
            XCTAssertEqual(XlateCore.padButtons(XlateCore.itemBits(b)), b, "buttons \(raw)")
        }
        let s = PadState(buttons: [.a, .dpadLeft, .guide], lx: -0.25, ly: 0.125, rx: 1, ry: -1, lt: 0.5, rt: 1)
        XCTAssertEqual(XlateCore.state(from: XlateCore.pad(from: s)), s)
    }

    // MARK: Two OR'ed sources per item

    func testTwoOrdSourcesPerButtonItem() throws {
        var rng = SplitMix64(seed: 0x4F52_4544)
        let log = MismatchLog()
        var frames = 0
        for _ in 0..<6 {
            let m1 = F.randomMapping(&rng), m2 = F.randomMapping(&rng)
            var t = try MapBlobEncoder.table(m1, identity: F.identity, spec: F.spec, revision: 1)
            let t2 = try MapBlobEncoder.table(m2, identity: F.identity, spec: F.spec, revision: 1)
            t.buttons += t2.buttons                             // both rule sets, per item, OR'ed
            let core = try XlateCore(blob: t.serialize(), spec: F.spec)
            let o1 = SwiftOracle(mapping: m1)
            for _ in 0..<4000 {
                let raw = F.randomRaw(&rng)
                guard let f = GamepadFrame.parse(raw) else { continue }
                var s = PassthroughPadMapper.padState(f, m1)
                s.buttons.formUnion(PassthroughPadMapper.padState(f, m2).buttons)
                let want = VirtualPadSink.snapped(s, axisDeadband: 0.002, triggerDeadband: 0.002)
                let got = core.reports(core.eval(raw: raw)!)
                let wantBytes = o1.reports(want)
                if got != wantBytes { log.note("\(hex(raw)): C \(got.map { hex($0.bytes) }) Swift \(wantBytes.map { hex($0.bytes) })") }
                frames += 1
            }
        }
        log.assertNone("OR'ed sources (\(frames) frames)")
    }

    /// The two-source rule set the encoder now writes itself (not glued from two mappings) against the oracle, with sources
    /// that carry physical masks, hats, triggers and axes.
    func testEncoderWrittenTwoSourceItemsOnRandomBindings() throws {
        var rng = SplitMix64(seed: 0x4F52_4532)
        let log = MismatchLog()
        var frames = 0
        for i in 0..<12 {
            var m = F.randomMapping(&rng)
            for id in ["g1", "g2", "g3", "g4", "g5", "profile"] {            // random bindings on the extra keys too
                m.buttons[id] = [.button(rng.int(0...21)), .hat(UInt8(rng.int(0...9))), .trigger("rt"), .axis("x", sign: -1)][rng.int(0...3)]
                if rng.chance(25) { m.physicalBits[id] = UInt16(1) << UInt16(rng.int(0...12)) }
            }
            m = F.randomOutputs(m, 0xE0E0 + UInt64(i))
            let core = try F.core(m), oracle = SwiftOracle(mapping: m)
            for _ in 0..<20_000 { check(core, oracle, F.randomRaw(&rng), log, "two-source \(i)"); frames += 1 }
        }
        log.assertNone("encoder-written OR'ed sources (\(frames) frames)")
    }

    // MARK: Bad frames

    func testWrongLengthsAndReportIdsAreRejectedLikeParse() throws {
        let core = try F.core(.default)
        var good = [UInt8](repeating: 0, count: 16); good[0] = 6
        XCTAssertNotNil(core.eval(raw: good))
        for len in [0, 1, 2, 15, 17, 18, 31, 63, 64] {
            let b = [UInt8](repeating: 6, count: len)
            XCTAssertNil(GamepadFrame.parse(b), "parse len \(len)")
            XCTAssertNil(core.eval(raw: b), "C len \(len)")
        }
        for id in 0...255 where id != 6 {
            var b = good; b[0] = UInt8(id)
            XCTAssertNil(GamepadFrame.parse(b)); XCTAssertNil(core.eval(raw: b), "id \(id)")
        }
        // The codes, and that *p stays untouched.
        var p = gdx_pad(); p.buttons = 0xABCD
        var m = core.map
        good.withUnsafeBufferPointer {
            XCTAssertEqual(gdx_eval(&m, $0.baseAddress, 15, &p), GDX_BAD_LENGTH)
            XCTAssertEqual(gdx_eval(&m, nil, 16, &p), GDX_BAD_ARG)
            XCTAssertEqual(gdx_eval(nil, $0.baseAddress, 16, &p), GDX_BAD_ARG)
        }
        var wrongID = good; wrongID[0] = 7
        wrongID.withUnsafeBufferPointer { XCTAssertEqual(gdx_eval(&m, $0.baseAddress, 16, &p), GDX_BAD_REPORT_ID) }
        XCTAssertEqual(p.buttons, 0xABCD)
        // gdx_step counts them.
        var st = gdx_state(); var out = gdx_out()
        wrongID.withUnsafeBufferPointer { XCTAssertEqual(gdx_step(&st, &m, $0.baseAddress, 16, &out), 0) }
        good.withUnsafeBufferPointer { XCTAssertEqual(gdx_step(&st, &m, $0.baseAddress, 15, &out), 0) }
        XCTAssertEqual(st.framesBad, 2)
        XCTAssertEqual(st.framesOk, 0)
    }

    // MARK: The "-1 quirk" (plan 5.2)

    func testNegativeAxisValuesWithoutRangesComeOutOneLower() throws {
        // No learned range: scaled = raw / 32767, for both signs. +100 -> 32868.50153 rounds to 32868 (= 32768 + 100); -100 ->
        // 32667.49847 rounds to 32667, one lower than the mirror image 32668. (Raw +-1 is inside the 0.002 deadband.)
        // Reproduced byte for byte, as the plan requires.
        var m = ControlMapping.default
        m.sticks["left_stick"]?.ranges = nil
        let core = try F.core(m), oracle = SwiftOracle(mapping: m)
        func lx(_ v: Int) -> UInt16 {
            var b = [UInt8](repeating: 0, count: 16); b[0] = 6; F.setTriggers(&b, 0, 0, hat: 8)
            let u = UInt16(bitPattern: Int16(v)); b[1] = UInt8(u & 0xff); b[2] = UInt8(u >> 8)
            let r = core.reports(core.eval(raw: b)!)[0].bytes
            XCTAssertEqual(r, oracle.reports(oracle.state(b)!)[0].bytes)
            return UInt16(r[1]) | UInt16(r[2]) << 8
        }
        XCTAssertEqual(lx(0), 0x8000)
        XCTAssertEqual(lx(1), 0x8000, "inside the deadband")
        XCTAssertEqual(lx(100), 0x8064, "+100 -> 32868")
        XCTAssertEqual(lx(-100), 0x7F9B, "-100 -> 32667, the quirk")
        XCTAssertEqual(lx(-32768), 0x0000)
        XCTAssertEqual(lx(32767), 0xFFFF)
        // With the learned full range the same raw values are symmetric.
        var full = F.liveShaped
        full.sticks["left_stick"]?.ranges = ["x": AxisRange(min: -32768, max: 32767), "y": AxisRange(min: -32768, max: 32767)]
        let c2 = try F.core(full)
        func lx2(_ v: Int) -> UInt16 {
            var b = [UInt8](repeating: 0, count: 16); b[0] = 6; F.setTriggers(&b, 0, 0, hat: 8)
            let u = UInt16(bitPattern: Int16(v)); b[1] = UInt8(u & 0xff); b[2] = UInt8(u >> 8)
            let r = c2.reports(c2.eval(raw: b)!)[0].bytes
            return UInt16(r[1]) | UInt16(r[2]) << 8
        }
        XCTAssertEqual(lx2(-100), 0x7F9C, "with the learned range -100 -> 32668, symmetric")
        XCTAssertEqual(lx2(100), 0x8064)
    }

    // MARK: Random frames

    /// 10^6 seeded random frames: 200,000 on each of the factory mapping, the live-shaped one and three random learned
    /// mappings.
    /// 14 remapped mappings from their own seeds, 50,000 seeded random frames each.
    func testSeededRandomFramesOnRemappedMappings() throws {
        let log = MismatchLog()
        var rng = SplitMix64(seed: 0x5EED_0007)
        var frames = 0
        for c in remappedMappings() {
            let core = try F.core(c.mapping), oracle = SwiftOracle(mapping: c.mapping)
            for _ in 0..<50_000 {
                check(core, oracle, F.randomRaw(&rng), log, c.name)
                frames += 1
            }
        }
        log.assertNone("random frames on remapped mappings (\(frames))")
    }

    func testOneMillionSeededRandomFrames() throws {
        let log = MismatchLog()
        var rng = SplitMix64(seed: 0x5EED_0006)
        var frames = 0
        for c in standardMappings() {
            let core = try F.core(c.mapping), oracle = SwiftOracle(mapping: c.mapping)
            for _ in 0..<200_000 {
                check(core, oracle, F.randomRaw(&rng), log, c.name)
                frames += 1
            }
        }
        XCTAssertEqual(frames, 1_000_000)
        log.assertNone("random frames")
    }
}

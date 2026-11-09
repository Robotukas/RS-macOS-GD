import XCTest
import IOKit
import GDHubXlate
@testable import GDHub

/// The same frame sequences through the Swift sink (both translators) and through `gdx_step`: the posted bytes must be
/// identical frame by frame, which pins the hysteresis anchor, the end-stop rule and the per-report dedupe.
/// Frames are spaced 5 ms apart (the sink's cap is 250 Hz = 4 ms here), so the sink never coalesces.
final class GDHubXlateSequenceTests: XCTestCase {
    typealias F = XlateFixtures
    private var queue: DispatchQueue!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        queue = DispatchQueue(label: "test.xlate.seq")
        suite = "gdhub.tests.xlate.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private struct Rig {
        let sink: VirtualPadSink, env: ManualScheduler, transport: FakeTransport, queue: DispatchQueue

        /// Hands one parsed frame to the sink on its queue (the sink's drain body, minus the mailbox).
        func feed(_ frame: GamepadFrame, _ mapping: ControlMapping) {
            queue.sync { sink.handle(frame: frame, mapping: mapping) }
        }
    }

    private func rig(_ core: XlateCoreChoice) -> Rig {
        let env = ManualScheduler(), transport = FakeTransport(env: env)
        var config = VirtualPadSink.Config()
        config.xlateCore = core
        let sink = VirtualPadSink(queue: queue, transport: transport, clock: { env.now }, scheduler: env, config: config,
                                  defaults: defaults, duplicateCheck: { _ in nil })
        queue.sync { sink.transportConnected(); sink.publish(.default, persist: false) }
        transport.clear()
        return Rig(sink: sink, env: env, transport: transport, queue: queue)
    }

    /// A random walk over the report: small axis moves around rest, drifts to the end stops, trigger ramps, button and
    /// hat flips, extra-bit flicker.
    private struct Walker {
        var rng: SplitMix64
        var axis = [0, 0, 0, 0], trig = [0, 0], hat = 8, buttons = 0, extra = 0
        init(seed: UInt64) { rng = SplitMix64(seed: seed) }

        mutating func next() -> [UInt8] {
            if rng.chance(55) {                                    // a frame like the last one
                return bytes()
            }
            let a = rng.int(0...3)
            switch rng.int(0...9) {
            case 0: axis[a] = rng.int(-4...4)                      // back to rest
            case 1: axis[a] = rng.pick([-32768, 32767, 32766, -32767, 0])
            case 2: axis[a] = rng.int(-32768...32767)
            case 3: trig[rng.int(0...1)] = max(0, min(1023, trig[rng.int(0...1)] + rng.int(-6...6)))
            case 4: trig[rng.int(0...1)] = rng.pick([0, 1, 2, 3, 1022, 1023, 512])
            case 5: if rng.chance(30) { buttons ^= 1 << rng.int(0...18) }
            case 6: if rng.chance(30) { hat = rng.int(0...8) }
            case 7: extra = rng.chance(40) ? 0 : rng.int(0...0x1fff)
            default: axis[a] = max(-32768, min(32767, axis[a] + rng.int(-90...90)))
            }
            return bytes()
        }

        func bytes() -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 16); b[0] = 6
            for i in 0..<4 {
                let u = UInt16(bitPattern: Int16(axis[i])); b[1 + 2 * i] = UInt8(u & 0xff); b[2 + 2 * i] = UInt8(u >> 8)
            }
            F.setTriggers(&b, trig[0], trig[1], hat: hat)
            F.setButtons(&b, buttons, extra: extra)
            return b
        }
    }

    /// Runs `frames` walker frames; returns the posts of the Swift sink, of the C sink and of gdx_step.
    private func run(_ mapping: ControlMapping, frames: Int, seed: UInt64) throws -> (swift: [[UInt8]], c: [[UInt8]], step: [[UInt8]], cUsed: Bool) {
        let swiftRig = rig(.swift), cRig = rig(.c)
        let core = try F.core(mapping)
        var map = core.map
        var state = gdx_state(), out = gdx_out()
        var idle = [UInt8](repeating: 0, count: 16); idle[0] = 6; F.setTriggers(&idle, 0, 0, hat: 8)
        idle.withUnsafeBufferPointer { _ = gdx_step(&state, &map, $0.baseAddress, 16, &out) }       // anchor = neutral, as after publish
        var stepPosts: [[UInt8]] = []
        var w = Walker(seed: seed)
        for _ in 0..<frames {
            let raw = w.next()
            let frame = GamepadFrame.parse(raw)!
            for r in [swiftRig, cRig] {
                r.env.advance(by: UInt64(5_000_000))
                r.feed(frame, mapping)
            }
            let mask = raw.withUnsafeBufferPointer { gdx_step(&state, &map, $0.baseAddress, 16, &out) }
            for i in 0..<Int(out.count) where (mask >> UInt32(i)) & 1 == 1 {
                stepPosts.append(XlateCore.reports(out)[i].bytes)
            }
        }
        let cUsed = queue.sync { cRig.sink.xlateStatus == "c" }
        return (swiftRig.transport.posts, cRig.transport.posts, stepPosts, cUsed)
    }

    private func compare(_ mapping: ControlMapping, frames: Int, seed: UInt64, _ name: String) throws {
        let r = try run(mapping, frames: frames, seed: seed)
        XCTAssertTrue(r.cUsed, "\(name): the C core must be the active translator")
        XCTAssertGreaterThan(r.swift.count, frames / 10, "\(name): the walk should produce plenty of posts")
        XCTAssertEqual(r.swift.count, r.step.count, "\(name): number of posts, Swift sink vs gdx_step")
        XCTAssertEqual(r.swift.count, r.c.count, "\(name): number of posts, Swift sink vs C sink")
        let log = MismatchLog()
        for i in 0..<min(r.swift.count, r.step.count, r.c.count) {
            if r.swift[i] != r.step[i] { log.note("post \(i): Swift \(hex(r.swift[i])) vs gdx_step \(hex(r.step[i]))") }
            if r.swift[i] != r.c[i] { log.note("post \(i): Swift \(hex(r.swift[i])) vs C sink \(hex(r.c[i]))") }
        }
        log.assertNone("\(name) (\(r.swift.count) posts)")
    }

    func testHundredThousandFrameRandomWalkOnTheFactoryMapping() throws {
        try compare(.default, frames: 100_000, seed: 0x5E01, "factory")
    }

    func testRandomWalkOnLiveShapedAndLearnedMappings() throws {
        try compare(F.liveShaped, frames: 40_000, seed: 0x5E02, "live-shaped")
        var rng = SplitMix64(seed: 0x6D61_7070_696E_67)
        for i in 0..<3 {
            let m = F.randomMapping(&rng)
            try compare(m, frames: 30_000, seed: 0x5E10 + UInt64(i), "random\(i)")
        }
    }

    /// Hand-built sequences around the hysteresis threshold and the end stop.
    func testHysteresisAndEndStopSequences() throws {
        var m = ControlMapping.default
        m.sticks["left_stick"]?.ranges = ["x": AxisRange(min: -32768, max: 32767), "y": AxisRange(min: -32768, max: 32767)]
        let core = try F.core(m), oracle = SwiftOracle(mapping: m)
        var map = core.map
        var state = gdx_state(), out = gdx_out()
        var anchor: PadState?
        var lastBytes: [UInt8: [UInt8]] = [:]
        func lx(_ v: Int) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 16); b[0] = 6; F.setTriggers(&b, 0, 0, hat: 8)
            let u = UInt16(bitPattern: Int16(v)); b[1] = UInt8(u & 0xff); b[2] = UInt8(u >> 8)
            return b
        }
        // 0 -> 66 (just over 0.002: changes) -> 67 (within a deadband of the last: unchanged) -> 131 (more than one deadband away) ->
        // 32767 (end stop always counts) -> 32766 (leaving the stop: a change smaller than a deadband from the stop is unchanged
        // because |a| < 1 and |a-b| < db) -> 0 -> 65 (inside the deadband: snapped to 0, unchanged).
        let path = [0, 66, 67, 131, 130, 200, 32700, 32766, 32767, 32767, 32766, -32768, -32767, 0, 65, 66, 0, 1, -66, -65]
        for v in path {
            let raw = lx(v)
            let s = oracle.state(raw)!
            var swiftPosts: [[UInt8]] = []
            if anchor == nil || !VirtualPadSink.unchanged(s, anchor!, axisDeadband: 0.002, triggerDeadband: 0.002) {
                for r in oracle.reports(s) where lastBytes[r.id] != r.bytes { swiftPosts.append(r.bytes); lastBytes[r.id] = r.bytes }
                anchor = s
            }
            let mask = raw.withUnsafeBufferPointer { gdx_step(&state, &map, $0.baseAddress, 16, &out) }
            let cPosts = (0..<Int(out.count)).filter { (mask >> UInt32($0)) & 1 == 1 }.map { XlateCore.reports(out)[$0].bytes }
            XCTAssertEqual(cPosts, swiftPosts, "lx \(v)")
        }
    }

    // MARK: Sink behaviour around the translator switch

    func testUnsupportedMappingFallsBackToSwiftAndStillPostsTheSame() throws {
        var m = ControlMapping.default
        m.buttons["a"] = .axis("x", sign: 1000)                      // sign does not fit GDHM v1
        guard case .unsupported = MapBlobEncoder.encode(m, identity: .default, spec: F.spec, revision: 1) else { return XCTFail("expected unsupported") }
        let swiftRig = rig(.swift), cRig = rig(.c)
        var w = Walker(seed: 0xFA11)
        for _ in 0..<3000 {
            let frame = GamepadFrame.parse(w.next())!
            for r in [swiftRig, cRig] { r.env.advance(by: UInt64(5_000_000)); r.feed(frame, m) }
        }
        XCTAssertEqual(swiftRig.transport.posts, cRig.transport.posts)
        XCTAssertGreaterThan(cRig.transport.posts.count, 100)
        let status = queue.sync { cRig.sink.xlateStatus }
        XCTAssertTrue(status.hasPrefix("swift (fallback, mapping not expressible in GDHM v1:"), status)
        // A supported mapping afterwards brings the C core back.
        let frame = GamepadFrame.parse(w.next())!
        cRig.env.advance(by: UInt64(5_000_000)); cRig.feed(frame, .default)
        XCTAssertEqual(queue.sync { cRig.sink.xlateStatus }, "c")
    }

    func testRuntimeKeySelectsTheCore() {
        XCTAssertEqual(VirtualPadSink.runtimeXlateCore(defaults: defaults), .c, "unset: the C core")
        defaults.set("swift", forKey: VirtualPadSink.xlateCoreKey)
        XCTAssertEqual(VirtualPadSink.runtimeXlateCore(defaults: defaults), .swift)
        defaults.set("Swift", forKey: VirtualPadSink.xlateCoreKey)
        XCTAssertEqual(VirtualPadSink.runtimeXlateCore(defaults: defaults), .swift, "case-insensitive")
        defaults.set("c", forKey: VirtualPadSink.xlateCoreKey)
        XCTAssertEqual(VirtualPadSink.runtimeXlateCore(defaults: defaults), .c)
        defaults.set("banana", forKey: VirtualPadSink.xlateCoreKey)
        XCTAssertEqual(VirtualPadSink.runtimeXlateCore(defaults: defaults), .c, "anything else: the default")
        defaults.set(3, forKey: VirtualPadSink.xlateCoreKey)
        XCTAssertEqual(VirtualPadSink.runtimeXlateCore(defaults: defaults), .c)
        let r = rig(.swift)
        XCTAssertEqual(queue.sync { r.sink.xlateStatus }, "swift (xlateCore=swift)")
    }

    func testSwapMappingMidStreamRecompilesTheBlob() throws {
        let r = rig(.c)
        var w = Walker(seed: 0xAB)
        var swapped = ControlMapping.default
        swapped.buttons["a"] = .button(2); swapped.buttons["b"] = .button(1)
        var raw = [UInt8](repeating: 0, count: 16); raw[0] = 6; F.setTriggers(&raw, 0, 0, hat: 8); F.setButtons(&raw, 1, extra: 0)
        func post(_ m: ControlMapping) -> [UInt8] {
            r.transport.clear(); r.env.advance(by: UInt64(5_000_000))
            r.feed(GamepadFrame.parse(raw)!, m)
            return r.transport.posts.first ?? []
        }
        _ = w.next()
        XCTAssertEqual(post(.default)[14], 0x01, "button 1 is A")
        F.setButtons(&raw, 1, extra: 1)                              // a changed frame, same button
        XCTAssertEqual(post(swapped)[14], 0x02, "after the swap button 1 is B")
        XCTAssertEqual(queue.sync { r.sink.xlateStatus }, "c")
    }
}

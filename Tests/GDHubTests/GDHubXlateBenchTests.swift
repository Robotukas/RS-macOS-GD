import XCTest
import GDHubXlate
@testable import GDHub

/// Per-frame cost: the C core against the Swift mapper + builder. Numbers print as `bench:` lines.
/// Run the optimised numbers with `swift test -c release -Xswiftc -enable-testing --filter GDHubXlateBenchTests`.
final class GDHubXlateBenchTests: XCTestCase {
    typealias F = XlateFixtures
    private static let frameCount = 4096
    private let raws: [[UInt8]] = {
        var rng = SplitMix64(seed: 0xBE7C)
        // The mix the engine sees: mostly small stick motion around rest, some everything-moving frames.
        return (0..<frameCount).map { i in i % 4 == 0 ? F.randomRaw(&rng) : { var r = F.randomRaw(&rng); return r.count == 16 ? r : r }() }
    }()
    private lazy var frames: [GamepadFrame] = raws.map { GamepadFrame.parse($0)! }
    private lazy var flat: [UInt8] = raws.flatMap { $0 }
    private let reps = 25

    private func nsPerFrame(_ body: () -> Void) -> Double {
        body()                                                                           // warm up
        var best = Double.infinity
        for _ in 0..<5 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0))
        }
        return best / Double(Self.frameCount * reps)
    }

    /// Swift: PassthroughPadMapper + snapped + PadReportBuilders.xboxBT16 (what the sink does per frame today).
    private func swiftBody() -> UInt64 {
        var acc: UInt64 = 0
        let m = ControlMapping.default
        for _ in 0..<reps {
            for f in frames {
                let s = VirtualPadSink.snapped(PassthroughPadMapper.padState(f, m), axisDeadband: 0.002, triggerDeadband: 0.002)
                let r = PadReportBuilders.xboxBT16(s)
                acc &+= UInt64(r[0].bytes[1]) &+ UInt64(r[1].bytes[1])
            }
        }
        return acc
    }

    /// C, pure: gdx_eval + gdx_build on the raw bytes into stack structs (what the dext will do).
    private func cPureBody(_ core: XlateCore) -> UInt64 {
        var acc: UInt64 = 0
        var m = core.map
        var pad = gdx_pad(), out = gdx_out()
        flat.withUnsafeBufferPointer { fp in
            for _ in 0..<reps {
                for i in 0..<Self.frameCount {
                    _ = gdx_eval(&m, fp.baseAddress! + i * 16, 16, &pad)
                    gdx_build(&m, &pad, &out)
                    acc &+= UInt64(out.r.0.bytes.1)
                }
            }
        }
        return acc
    }

    /// C as the engine uses it: GamepadFrame -> raw -> eval, unchanged against the previous pad, reports as [PadReport].
    private func cEngineBody(_ core: XlateCore) -> UInt64 {
        var acc: UInt64 = 0
        var last = gdx_pad()
        for _ in 0..<reps {
            for f in frames {
                let p = core.eval(f)
                if !core.unchanged(p, last) {
                    let r = core.reports(p)
                    acc &+= UInt64(r[0].bytes[1]) &+ UInt64(r[1].bytes[1])
                    last = p
                }
            }
        }
        return acc
    }

    func testPerFrameMicrobenchmark() throws {
        let core = try F.core(.default)
        // Same answers before timing anything.
        let oracle = SwiftOracle(mapping: .default)
        for (r, f) in zip(raws, frames) {
            XCTAssertEqual(core.reports(core.eval(f)).map(\.bytes), oracle.reports(oracle.state(r)!).map(\.bytes))
        }
        let swift = nsPerFrame { _ = swiftBody() }
        let cPure = nsPerFrame { _ = cPureBody(core) }
        let cEngine = nsPerFrame { _ = cEngineBody(core) }
        print(String(format: "bench: Swift mapper+snap+builder %.0f ns/frame | C core (eval+build, raw bytes, no allocation) %.0f ns/frame | C core as the sink uses it (frame->raw, eval, unchanged, [PadReport]) %.0f ns/frame",
                     swift, cPure, cEngine))
        XCTAssertLessThanOrEqual(cPure, swift, "C core (pure) must not be slower than the Swift mapper + builder")
    }

    // XCTest `measure` blocks: 4096 frames x 25 repetitions each.
    func testMeasureSwiftMapperAndBuilder() { measure { _ = swiftBody() } }
    func testMeasureCCorePure() throws { let core = try F.core(.default); measure { _ = cPureBody(core) } }
    func testMeasureCCoreAsTheSinkUsesIt() throws { let core = try F.core(.default); measure { _ = cEngineBody(core) } }
}

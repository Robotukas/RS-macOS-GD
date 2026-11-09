import XCTest
@testable import GDHub

/// The two sample reports scripts/tools/test_dev_run_compare.py reads. They are produced by the real encoder so the
/// Python tool and the app share one schema. Regenerate with `GDHUB_WRITE_DEV_FIXTURES=1 swift test --filter DevRunReportFixtureTests`.
final class DevRunReportFixtureTests: XCTestCase {
    private static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/dev-runs", isDirectory: true)

    private func attempt(_ verdict: DevVerdict, path: String, reports: Int, changed: Int, expected: Int, onset: Double?,
                         frames: Int, superseded: Bool = false) -> DevAttempt {
        var a = DevAttempt()
        a.startedNs = 1_000_000_000; a.readyNs = 3_000_000_000; a.windowStartNs = 3_500_000_000; a.windowEndNs = 6_500_000_000
        a.superseded = superseded
        a.verdict = verdict
        a.metrics.padReports = reports
        a.metrics.padChanged = changed
        a.metrics.framesSeen = frames
        a.metrics.framesPerSecond = Double(frames) / 3
        a.metrics.movingMs = 1200
        a.metrics.expectedChanges = expected
        a.metrics.lossRatio = expected > 0 ? Double(changed) / Double(expected) : nil  // as DevMetrics documents it: padChanged / expectedChanges
        a.metrics.onsetMs = onset
        a.metrics.values = ["bit.rises": Double(changed / 2), "bit.falls": Double(changed / 2)]
        a.effectivePath = DevEffectivePath(atReady: path, atStart: path, atEnd: path)
        a.raw = [DevRawReport(tMs: -20, id: 1, bytes: [1, 0, 0x80], phase: .ready),
                 DevRawReport(tMs: 310.5, id: 1, bytes: [1, 1, 0x80], phase: .window)]
        return a
    }

    private func report(requested: String, effective: String, started: String, lb: (Int, Double, Int), lbVerdict: DevVerdict,
                        rt: (Int, Double, Int), rtVerdict: DevVerdict, extra: Bool) -> DevRunReport {
        var r = DevRunReport()
        r.startedAt = started
        r.endedAt = String(started.prefix(17)) + "09:40" + started.suffix(6)
        r.t0Ns = 1_000_000_000
        r.complete = true
        r.requestedPath = requested
        r.effectivePath = effective
        r.pathEvents = [DevPathEvent(tMs: 0, armed: effective)]
        r.header.appBuild = "41"; r.header.engineBuild = "41"
        r.header.dextBuild = effective == "live" ? "7" : nil
        r.header.guiMode = "engine"; r.header.padIdentity = "xbox-bt16-02e0"; r.header.readerMatched = 1
        r.header.vpadMaxRateHz = 1000; r.header.xlateCore = "c"
        r.header.mappingHash = String(repeating: "5c", count: 32)
        r.header.templateId = "sample"; r.header.templateVersion = 2
        r.header.templateSha256 = String(repeating: "ab", count: 32)
        var s0 = DevStepResult(index: 0, stepId: "lb", kind: "digital", controls: ["lb"], expected: DevExpectedItems(buttons: ["LB"]))
        s0.attempts = [attempt(lbVerdict, path: effective, reports: lb.0, changed: 4, expected: lb.2, onset: lb.1, frames: 180)]
        var s1 = DevStepResult(index: 1, stepId: "rt", kind: "trigger", controls: ["rt"], expected: DevExpectedItems())
        s1.attempts = [attempt(.inconclusive("first try"), path: effective, reports: 10, changed: 1, expected: 40, onset: nil, frames: 90, superseded: true),
                       attempt(rtVerdict, path: effective, reports: rt.0, changed: 40 - Int(Double(40) * (rt.1 / 100)), expected: rt.2, onset: 4.0, frames: 175)]
        r.steps = [s0, s1]
        if extra {
            var s2 = DevStepResult(index: 2, stepId: "ls", kind: "stick", controls: ["ls"], expected: DevExpectedItems())
            s2.attempts = [attempt(.pass, path: effective, reports: 700, changed: 520, expected: 520, onset: 3.0, frames: 300)]
            r.steps.append(s2)
        }
        r.notes = ["fixture"]
        return r
    }

    private func built() -> (engine: DevRunReport, driver: DevRunReport) {
        let engine = report(requested: "engine", effective: "inert", started: "2026-11-09T14:03:22+01:00",
                            lb: (160, 2.5, 4), lbVerdict: .pass, rt: (330, 0, 40), rtVerdict: .pass, extra: true)
        // Driver run: LB passes with a later onset, RT loses reports and fails; no stick step (the run was shorter).
        let driver = report(requested: "driver", effective: "live", started: "2026-11-09T14:10:05+01:00",
                            lb: (160, 9.0, 4), lbVerdict: .pass, rt: (250, 25, 40), rtVerdict: .fail("trigger peak 0.62 (needs 0.90)"), extra: false)
        return (engine, driver)
    }

    func testFixturesMatchTheEncoder() throws {
        let (engine, driver) = built()
        let files = [("sample-engine.json", engine), ("sample-driver.json", driver)]
        if ProcessInfo.processInfo.environment["GDHUB_WRITE_DEV_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            for (name, r) in files { try r.encoded().write(to: Self.dir.appendingPathComponent(name), options: .atomic) }
        }
        for (name, r) in files {
            let data = try Data(contentsOf: Self.dir.appendingPathComponent(name))
            XCTAssertEqual(DevRunReport.decode(data), r, name)
        }
    }
}

import XCTest
@testable import GDHub

final class DevRunReportTests: XCTestCase {
    private func sampleReport() -> DevRunReport {
        var r = DevRunReport()
        r.startedAt = DevRunReport.iso(Date(timeIntervalSince1970: 1_794_000_000), timeZone: TimeZone(secondsFromGMT: 3600)!)
        r.endedAt = "2026-11-09T14:08:01+01:00"
        r.t0Ns = 123_456_789_012
        r.complete = true
        r.requestedPath = "driver"
        r.effectivePath = "live"
        r.pathEvents = [DevPathEvent(tMs: 0, armed: "shadow"), DevPathEvent(tMs: 2100.5, armed: "live", fallback: nil, latched: nil, liveUnavailable: false, mappingNote: "n")]
        r.header.appBuild = "40"; r.header.engineBuild = "40"; r.header.dextBuild = nil
        r.header.guiMode = "engine"; r.header.padIdentity = "xbox-bt16-02e0"; r.header.readerMatched = 1
        r.header.vpadMaxRateHz = 2000; r.header.xlateCore = "c"
        r.header.mapping = .default
        r.header.mappingHash = DevRunReportStore.mappingHash(.default)
        r.header.templateId = "full"; r.header.templateVersion = 3; r.header.templateSha256 = String(repeating: "ab", count: 32)
        r.header.decodeTable = .current
        var attempt = DevAttempt()
        attempt.startedNs = 1; attempt.readyNs = 2; attempt.windowStartNs = 3; attempt.windowEndNs = 4
        attempt.verdict = .fail("A went down 1 and up 1 times (needs 2)")
        attempt.metrics.padReports = 7; attempt.metrics.lossRatio = 0.5; attempt.metrics.onsetMs = 1.25
        attempt.metrics.values = ["bit.rises": 1, "hat.visited": 129]
        attempt.metrics.detail = "words"
        attempt.entryState = .neutral
        attempt.entryRaw = ["01 00 80"]
        attempt.effectivePath = DevEffectivePath(atReady: "live", atStart: "live", atEnd: "live")
        attempt.raw = [DevRawReport(tMs: -12.5, id: 1, bytes: [1, 2, 255], phase: .ready)]
        var step = DevStepResult(index: 0, stepId: "a", kind: "digital", controls: ["a"], expected: DevExpectedItems(buttons: ["A"]))
        step.attempts = [attempt]
        var passed = attempt; passed.verdict = .pass
        var step2 = DevStepResult(index: 1, stepId: "g1", kind: "digital", controls: ["g1"], expected: DevExpectedItems())
        step2.attempts = [attempt, passed]
        r.steps = [step, step2]
        r.notes = ["Path put back to Driver (stopped by breaker, as before)"]
        return r
    }

    func testRoundTrip() throws {
        let r = sampleReport()
        let back = try JSONDecoder().decode(DevRunReport.self, from: try r.encoded())
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.steps[1].verdict, .pass, "the last attempt carries the verdict")
    }

    func testVerdictJSONShape() throws {
        func json(_ v: DevVerdict) throws -> [String: String] {
            let e = JSONEncoder(); e.outputFormatting = .sortedKeys
            return try JSONDecoder().decode([String: String].self, from: try e.encode(v))
        }
        XCTAssertEqual(try json(.fail("why")), ["verdict": "fail", "reason": "why"])
        XCTAssertEqual(try json(.pass), ["verdict": "pass"])
        XCTAssertEqual(try json(.inconclusive("pad state unknown")), ["verdict": "inconclusive", "reason": "pad state unknown"])
        for v in [DevVerdict.pass, .fail("a"), .skipped("b"), .inconclusive("c"), .invalid("d")] {
            XCTAssertEqual(try JSONDecoder().decode(DevVerdict.self, from: try JSONEncoder().encode(v)), v)
        }
        let future = try JSONDecoder().decode(DevVerdict.self, from: Data(#"{"verdict":"flaky","reason":"x"}"#.utf8))
        XCTAssertEqual(future.tag, "inconclusive", "a verdict from a newer build is shown, not guessed")
    }

    func testTolerantDecodeOfAnOlderOrSparseFile() throws {
        let sparse = #"{"schema":1,"startedAt":"2026-11-09T10:00:00+01:00","steps":[{"stepId":"a","attempts":[{"verdict":{"verdict":"pass"}}]}],"unknownKey":{"x":[1]}}"#
        let r = try XCTUnwrap(DevRunReport.decode(Data(sparse.utf8)))
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.requestedPath, "")
        XCTAssertNil(r.effectivePath)
        XCTAssertEqual(r.pathEvents, [])
        XCTAssertEqual(r.header.templateVersion, 1)
        XCTAssertEqual(r.steps.first?.stepId, "a")
        XCTAssertEqual(r.steps.first?.attempts.first?.verdict, .pass)
        XCTAssertEqual(r.steps.first?.attempts.first?.metrics.values, [:])
        XCTAssertNotNil(DevRunReport.decode(Data("{}".utf8)), "every key is optional")
    }

    func testNewerSchemaAndGarbageAreRefused() {
        XCTAssertNil(DevRunReport.decode(Data(#"{"schema":2}"#.utf8)))
        XCTAssertNil(DevRunReport.decode(Data("nope".utf8)))
        XCTAssertNil(DevRunReport.decode(Data(#"{"schema":1,"complete":"yes"}"#.utf8)), "a key of the wrong type is a broken file")
        XCTAssertThrowsError(try JSONDecoder().decode(DevRunReport.self, from: Data(#"{"schema":9}"#.utf8))) { error in
            XCTAssertEqual(error as? DevSchemaError, DevSchemaError(found: 9, supported: 1))
        }
    }

    func testRawCapKeepsHeadAndTailAndCountsTheRest() {
        let raw = (0..<7000).map { DevRawReport(tMs: Double($0), id: 1, bytes: [1], phase: .window) }
        let (kept, dropped) = DevRunReportStore.capped(raw)
        XCTAssertEqual(kept.count, 6000)
        XCTAssertEqual(dropped, 1000)
        XCTAssertEqual(kept.first?.tMs, 0)
        XCTAssertEqual(kept[3999].tMs, 3999)
        XCTAssertEqual(kept[4000].tMs, 5000, "the tail starts where the head's gap ends")
        XCTAssertEqual(kept.last?.tMs, 6999)
        XCTAssertEqual(DevRunReportStore.capped(Array(raw.prefix(6000))).dropped, 0)

        var report = sampleReport()
        report.steps[0].attempts[0].raw = raw
        let out = DevRunReportStore.capped(report)
        XCTAssertEqual(out.steps[0].attempts[0].raw.count, 6000)
        XCTAssertEqual(out.steps[0].attempts[0].metrics.rawDropped, 1000)
        XCTAssertEqual(report.steps[0].attempts[0].raw.count, 7000, "the in-memory report keeps the full stream")
    }

    func testWriteIsAtomicSortedAndReadsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = sampleReport()
        let url = try DevRunReportStore.write(r, startedAt: Date(timeIntervalSince1970: 1_794_000_000), directory: dir.appendingPathComponent("dev-runs"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_live_full.json"), url.lastPathComponent)
        XCTAssertNotNil(url.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}_live_full\.json$"#, options: .regularExpression))
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\n"), "pretty printed")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"complete\"")).lowerBound, try XCTUnwrap(text.range(of: "\"steps\"")).lowerBound, "sorted keys")
        XCTAssertEqual(DevRunReport.decode(data), r)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, [url.lastPathComponent], "no temp file left behind")
    }

    func testReportPathHonoursTheSupportDirectoryVariableShape() {
        let u = DevRunReportStore.url(startedAt: Date(timeIntervalSince1970: 0), path: "shadow/odd name", templateId: "t7-sleep")
        XCTAssertTrue(u.path.contains("/dev-runs/"))
        XCTAssertTrue(u.lastPathComponent.hasSuffix("_shadow-odd-name_t7-sleep.json"))
    }

    func testHashes() {
        XCTAssertEqual(DevRunReportStore.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(DevRunReportStore.mappingHash(.default), DevRunReportStore.mappingHash(.default))
        var other = ControlMapping.default
        other.buttons["g1"] = .button(4)
        XCTAssertNotEqual(DevRunReportStore.mappingHash(.default), DevRunReportStore.mappingHash(other))
        // built in a different insertion order, same content
        var reordered = ControlMapping()
        for (k, v) in ControlMapping.default.buttons.sorted(by: { $0.key > $1.key }) { reordered.buttons[k] = v }
        reordered.sticks = ControlMapping.default.sticks
        reordered.physicalBits = ControlMapping.default.physicalBits
        XCTAssertEqual(DevRunReportStore.mappingHash(reordered), DevRunReportStore.mappingHash(.default))

        var t = DevBuiltins.generate(layout: ControlLayout.loadFromBundle()!)[0]
        let h = DevRunReportStore.templateSha256(t)
        XCTAssertEqual(h.count, 64)
        XCTAssertEqual(h, DevRunReportStore.templateSha256(t))
        t.steps[1].seconds = 4
        XCTAssertNotEqual(h, DevRunReportStore.templateSha256(t))
    }

    func testISODatesCarryTheOffset() {
        let s = DevRunReport.iso(Date(timeIntervalSince1970: 1_794_000_000), timeZone: TimeZone(secondsFromGMT: 3600)!)
        XCTAssertTrue(s.hasSuffix("+01:00"), s)
        XCTAssertEqual(DevRunReport.date(fromISO: s), Date(timeIntervalSince1970: 1_794_000_000))
    }

    func testDecodeTableMatchesTheEncoderTables() {
        let t = DevDecodeTable.current
        XCTAssertEqual(t.reports.map(\.id), [1, 2])
        XCTAssertEqual(t.placements.count, MapBlobEncoder.xboxBT16Placements.count)
        XCTAssertEqual(t.placements[1].encoding, 2)      // LY is the negated axis
    }
}

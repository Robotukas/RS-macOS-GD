import XCTest
@testable import GDHub

/// The echo rule over the committed fixture made from the survey recording (docs/plans/remap-step2-plan.md, "Tests",
/// `EchoReplayTests`): `Tests/GDHubTests/Fixtures/echo-survey-s2.json` holds controller reports (report index and the 16
/// bytes) and the words of the Python oracle (`scripts/tools/echo_rule.py`) for nine hide sets. A report the recorder
/// left out equals the one before it, and a repeated report changes no state and no cleaned byte (V20), so the replay needs
/// no filling; each attempt starts from a fresh state. The Python test replays the oracle against the truth model (0
/// wrong, 0 ghosts, 0 ambiguous items under all 64 masks); the C half comes with S5.
final class EchoReplayTests: XCTestCase {
    private struct Attempt {
        let stepId: String
        let reports: [[UInt8]]
        let words: [Int: [UInt32]]
    }

    private var storedItems: [UInt8] = []
    private var hideSets: [Int] = []
    private var attempts: [Attempt] = []

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/echo-survey-s2.json")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        storedItems = (obj["storedItems"] as? [Int] ?? []).map { UInt8($0) }
        hideSets = obj["hideSets"] as? [Int] ?? []
        for a in try XCTUnwrap(obj["attempts"] as? [[String: Any]]) {
            let receiver = try XCTUnwrap(a["receiver"] as? [[String: Any]])
            let reports = receiver.map { EchoSim.bytes($0["hex"] as? String ?? "") }
            var words: [Int: [UInt32]] = [:]
            for (k, v) in try XCTUnwrap(a["words"] as? [String: [Int]]) { words[Int(k)!] = v.map { UInt32(truncatingIfNeeded: $0) } }
            attempts.append(Attempt(stepId: a["stepId"] as? String ?? "", reports: reports, words: words))
        }
    }

    func testTheFixtureHoldsTheSurveyAttempts() {
        XCTAssertEqual(attempts.count, 54)
        XCTAssertEqual(attempts.reduce(0) { $0 + $1.reports.count }, 789)
        XCTAssertEqual(storedItems, EchoParams.factoryItems)
        XCTAssertEqual(hideSets, [0, 0x3F, 0x3D, 1, 2, 4, 8, 16, 32])
        for a in attempts { for r in a.reports { XCTAssertEqual(r.count, 16); XCTAssertEqual(r.first, 6) } }
    }

    func testTheNineStoredSetsMatchTheOraclesWordsOnEveryReport() {
        for h in hideSets {
            let params = EchoParams(hideMask: UInt8(h), items: storedItems)
            for a in attempts {
                var s = EchoState()
                let words = a.reports.map { s.step(params, report: $0) }
                XCTAssertEqual(words, a.words[h], "\(a.stepId), hide set \(h)")
            }
        }
    }

    func testNoHiddenKeyLeavesEveryReportUnchanged() {
        for a in attempts {
            var s = EchoState()
            for r in a.reports {
                let w = s.step(.none, report: r)
                XCTAssertEqual(w, 0)
                XCTAssertEqual(EchoFilter.apply(w, to: r), r)
            }
        }
    }

    func testARepeatedReportChangesNeitherStateNorCleanedBytesUnderAll64Masks() {
        for mask in 0..<64 {
            let params = EchoParams(hideMask: UInt8(mask), items: storedItems)
            for a in attempts {
                var s = EchoState()
                for r in a.reports {
                    let w1 = s.step(params, report: r)
                    let after = s
                    let w2 = s.step(params, report: r)
                    XCTAssertEqual(s, after)
                    XCTAssertEqual(w1 & ~EchoFilter.pressFlags, w2 & ~EchoFilter.pressFlags)
                    XCTAssertEqual(EchoFilter.apply(w1, to: r), EchoFilter.apply(w2, to: r))
                }
            }
        }
    }

    func testOnlyBitsOfTheButtonsAndTheHatChangeAndAFrameWithNoHiddenKeyIsBitForBitTheSame() {
        for mask in [0x3F, 0x3D, 0x01, 0x10] {
            let params = EchoParams(hideMask: UInt8(mask), items: storedItems)
            for a in attempts {
                var s = EchoState()
                for r in a.reports {
                    let f = EchoFilter.fields(r)!
                    let w = s.step(params, report: r)
                    let out = EchoFilter.apply(w, to: r)
                    if f.extra & UInt16(mask) == 0 { XCTAssertEqual(out, r) }
                    XCTAssertEqual(Array(out[0..<11]), Array(r[0..<11]))
                    XCTAssertEqual(out[11] & 0x0F, r[11] & 0x0F)
                    XCTAssertEqual(out[13] & 0xFC, r[13] & 0xFC)
                    XCTAssertEqual(out[14], r[14])
                    XCTAssertEqual(out[15], r[15])
                }
            }
        }
    }

    func testTheOppositeCancelsOfTheRecordingComeOutAsTheRealDirectionWithAllSixHidden() {
        let params = EchoParams(hideMask: 0x3F, items: storedItems)
        var found: [Int: String] = [:]
        let wanted: [Int: String] = [203344: "U", 234540: "U", 260104: "L", 260415: "L"]
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/echo-survey-s2.json")
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
              let atts = obj["attempts"] as? [[String: Any]] else { return XCTFail("fixture") }
        for a in atts {
            var s = EchoState()
            for e in a["receiver"] as? [[String: Any]] ?? [] {
                let n = e["n"] as? Int ?? 0
                let r = EchoSim.bytes(e["hex"] as? String ?? "")
                let w = s.step(params, report: r)
                if wanted[n] != nil {
                    found[n] = EchoSim.hatText(EchoSim.padItems(EchoFilter.items(word: w, buttons: 0, hat: 8)))
                    XCTAssertTrue(w & EchoFilter.wordRecovered != 0, "\(n)")
                }
            }
        }
        XCTAssertEqual(found, wanted)
    }

    func testThePressFlagsNeverSetOnTheRecording() {
        for mask in 0..<64 {
            let params = EchoParams(hideMask: UInt8(mask), items: storedItems)
            for a in attempts {
                var s = EchoState()
                for r in a.reports { XCTAssertEqual(s.step(params, report: r) & EchoFilter.pressFlags, 0, "\(a.stepId) mask \(mask)") }
            }
        }
    }
}

import XCTest
@testable import GDHub

/// A stand-in for CoreAudio: tests never register a real listener and never touch the Mac's volume or mute.
final class FakeVolumeObserver: VolumeObserving, @unchecked Sendable {
    var state = VolumeState.device()
    private(set) var starts = 0
    private(set) var stops = 0
    private var handler: (@Sendable (VolumeEvent) -> Void)?

    func currentState() -> VolumeState { state }
    func start(onEvent: @escaping @Sendable (VolumeEvent) -> Void) { starts += 1; handler = onEvent }
    func stop() { stops += 1; handler = nil }
    var isListening: Bool { handler != nil }
    func emit(_ event: VolumeEvent) { handler?(event) }
}

/// The volume check: the tracker that turns listener notifications into change events, the 0x11 report, the judge table
/// ("cannot judge" cases included), how the verdict folds into the pad's, and the report fields.
final class DevVolumeTests: XCTestCase {
    private static let go: UInt64 = 10_000_000_000
    private static func ns(_ ms: Double) -> UInt64 { UInt64(Double(go) + ms * 1e6) }

    // MARK: change tracker

    func testTrackerCountsOnlyRealChanges() {
        var t = VolumeChangeTracker(initial: .device(scalar: 0.5, muted: false))
        XCTAssertNil(t.note(.volume, now: .device(scalar: 0.5, muted: false), tNs: 1), "a notification without a change is not an event")
        XCTAssertNil(t.note(.volume, now: .device(scalar: 0.5 + 1e-9, muted: false), tNs: 2), "float noise is not a change")
        let up = t.note(.volume, now: .device(scalar: 0.5625, muted: false), tNs: 3)
        XCTAssertEqual(up?.kind, .volume)
        XCTAssertEqual(up?.tNs, 3)
        XCTAssertEqual(up?.state.scalar, 0.5625)
        XCTAssertNil(t.note(.volume, now: .device(scalar: 0.5625, muted: false), tNs: 4), "the same value again")
        XCTAssertEqual(t.note(.mute, now: .device(scalar: 0.5625, muted: true), tNs: 5)?.kind, .mute)
        XCTAssertNil(t.note(.mute, now: .device(scalar: 0.5625, muted: true), tNs: 6))
        XCTAssertEqual(t.note(.mute, now: .device(scalar: 0.5625, muted: false), tNs: 7)?.kind, .mute)
    }

    func testTrackerReportsADeviceChangeOnceWhateverListenerSawIt() {
        var t = VolumeChangeTracker(initial: .device(1, scalar: 0.5))
        XCTAssertEqual(t.note(.device, now: .device(2, scalar: 0.9), tNs: 1)?.kind, .device)
        XCTAssertNil(t.note(.device, now: .device(2, scalar: 0.9), tNs: 2), "the same device again")
        // a volume listener that fires for a device that is no longer the remembered one says "device", not "volume"
        XCTAssertEqual(t.note(.volume, now: .device(3, scalar: 0.1), tNs: 3)?.kind, .device)
        XCTAssertEqual(t.note(.mute, now: .device(4, scalar: 0.1), tNs: 4)?.kind, .device)
        var digital = VolumeChangeTracker(initial: VolumeState(deviceID: 4, hasVolume: false, hasMute: false))
        XCTAssertNil(digital.note(.volume, now: VolumeState(deviceID: 4, hasVolume: false, hasMute: false), tNs: 5),
                     "a device without a volume has nothing that can change")
    }

    // MARK: 0x11

    func testConsumerReportBitsAreTheVolumeKeys() {
        func keys(_ bytes: [UInt8]) -> DevConsumerReport.Keys { DevConsumerReport(tNs: 0, bytes: bytes).keys }
        XCTAssertEqual(keys([0x11, 0x01]), .volumeUp)
        XCTAssertEqual(keys([0x11, 0x02]), .volumeDown)
        XCTAssertEqual(keys([0x11, 0x04]), .mute)
        XCTAssertEqual(keys([0x11, 0x00]), [])
        XCTAssertEqual(keys([0x03]), [.volumeUp, .volumeDown], "a buffer without the ID byte reads the same")
        XCTAssertTrue(DevConsumerReport(tNs: 0, bytes: [0x11, 0x02]).isKeyDown)
        XCTAssertFalse(DevConsumerReport(tNs: 0, bytes: [0x11, 0x00]).isKeyDown, "a release is not a key press")
        XCTAssertFalse(DevConsumerReport(tNs: 0, bytes: [0x11]).isKeyDown)
        XCTAssertFalse(DevConsumerReport(tNs: 0, bytes: []).isKeyDown)
    }

    @MainActor
    func testTheDeviceTapsOnlyReport0x11OfTheConsumerInterface() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-voltap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let device = EnvisionProDevice(layout: nil, store: MappingStore(url: dir.appendingPathComponent("m.json")))
        var seen: [[UInt8]] = []
        device.consumerTap = { bytes, _ in seen.append(bytes) }
        device.handle(reportID: 0x11, bytes: [0x11, 0x02], usagePage: EnvisionProDevice.consumerUsagePage)
        device.handle(reportID: 0x11, bytes: [0x11, 0x00], usagePage: EnvisionProDevice.consumerUsagePage)
        device.handle(reportID: 0x01, bytes: [0x01, 0x02], usagePage: EnvisionProDevice.consumerUsagePage)
        device.handle(reportID: 0x11, bytes: [0x11, 0x02], usagePage: 0xFF42)
        XCTAssertEqual(seen, [[0x11, 0x02], [0x11, 0x00]])
        XCTAssertTrue(device.eventLog.contains { $0.text.contains("consumer interface id=0x11") }, "the report is still logged as before")
        device.consumerTap = nil
        device.handle(reportID: 0x11, bytes: [0x11, 0x01], usagePage: EnvisionProDevice.consumerUsagePage)
        XCTAssertEqual(seen.count, 2)
    }

    // MARK: judge table

    private func key(_ ms: Double, _ payload: UInt8) -> DevConsumerReport { .init(tNs: Self.ns(ms), bytes: [0x11, payload]) }
    private func event(_ ms: Double, _ kind: VolumeEventKind, _ state: VolumeState = .device()) -> VolumeEvent {
        .init(tNs: Self.ns(ms), kind: kind, state: state)
    }
    private func obs(go: VolumeState? = .device(scalar: 0.5), end: VolumeState? = nil,
                     events: [VolumeEvent] = [], reports: [DevConsumerReport]) -> DevVolumeObservation {
        DevVolumeObservation(atGo: go, atEnd: end ?? go, events: events, reports: reports)
    }

    func testUnchangedPassesWithAKeyReportAndNoChange() {
        let r = DevVolumeJudge.judge(.unchanged, obs(reports: [key(100, 0x01), key(150, 0x00), key(600, 0x01), key(650, 0x00)]))
        XCTAssertEqual(r.verdict, .pass)
        XCTAssertEqual(r.consumerReports, 4)
        XCTAssertEqual(r.keyReports, 2, "releases are 0x11 reports but not key presses")
        XCTAssertEqual([r.volumeEvents, r.muteEvents, r.deviceEvents], [0, 0, 0])
        XCTAssertEqual(r.startScalar, 0.5); XCTAssertEqual(r.endScalar, 0.5)
        XCTAssertEqual(r.startMuted, false); XCTAssertEqual(r.endMuted, false)
        XCTAssertTrue(r.hasVolume); XCTAssertTrue(r.hasMute)
    }

    func testUnchangedFailsOnAVolumeOrMuteEvent() {
        let volume = DevVolumeJudge.judge(.unchanged, obs(end: .device(scalar: 0.4375), events: [event(120, .volume, .device(scalar: 0.4375))],
                                                          reports: [key(100, 0x02)]))
        guard case .fail(let why) = volume.verdict else { return XCTFail("\(volume.verdict)") }
        XCTAssertTrue(why.contains("1 volume and 0 mute change"), why)
        XCTAssertEqual(volume.endScalar, 0.4375)
        let mute = DevVolumeJudge.judge(.unchanged, obs(events: [event(120, .mute)], reports: [key(100, 0x04)]))
        guard case .fail(let why2) = mute.verdict else { return XCTFail("\(mute.verdict)") }
        XCTAssertTrue(why2.contains("0 volume and 1 mute change"), why2)
    }

    func testChangesPassesOnAVolumeOrMuteEventAndFailsWithout() {
        XCTAssertEqual(DevVolumeJudge.judge(.changes, obs(events: [event(120, .mute, .device(scalar: 0.5, muted: true))], reports: [key(100, 0x04)])).verdict, .pass)
        XCTAssertEqual(DevVolumeJudge.judge(.changes, obs(events: [event(120, .volume)], reports: [key(100, 0x02)])).verdict, .pass)
        let none = DevVolumeJudge.judge(.changes, obs(reports: [key(100, 0x04), key(150, 0x00)]))
        guard case .fail(let why) = none.verdict else { return XCTFail("\(none.verdict)") }
        XCTAssertTrue(why.contains("neither the volume nor the mute changed"), why)
    }

    private func assertCannotJudge(_ r: DevVolumeResult, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .inconclusive(let why) = r.verdict else { return XCTFail("expected cannot judge, got \(r.verdict)", file: file, line: line) }
        XCTAssertTrue(why.contains(text), "\"\(why)\" lacks \"\(text)\"", file: file, line: line)
    }

    func testNoKeyReportCannotBeJudgedEvenWhenTheVolumeMoved() {
        for want in DevVolumeExpectation.allCases {
            assertCannotJudge(DevVolumeJudge.judge(want, obs(reports: [])), containing: "no volume-key report")
            assertCannotJudge(DevVolumeJudge.judge(want, obs(events: [event(120, .volume)], reports: [key(100, 0x00)])),
                              containing: "no volume-key report")
        }
    }

    func testADeviceWithoutVolumeAndMuteCannotBeJudged() {
        let digital = VolumeState(deviceID: 7, hasVolume: false, hasMute: false)
        for want in DevVolumeExpectation.allCases {
            assertCannotJudge(DevVolumeJudge.judge(want, obs(go: digital, reports: [key(100, 0x02)])), containing: "neither a software volume nor a mute")
        }
        assertCannotJudge(DevVolumeJudge.judge(.unchanged, obs(go: VolumeState(), reports: [key(100, 0x02)])), containing: "no sound output device")
        assertCannotJudge(DevVolumeJudge.judge(.unchanged, obs(go: nil, reports: [key(100, 0x02)])), containing: "no sound output device")
        // Either half is enough to watch.
        let muteOnly = VolumeState(deviceID: 7, hasVolume: false, hasMute: true, scalar: nil, muted: false)
        XCTAssertEqual(DevVolumeJudge.judge(.unchanged, obs(go: muteOnly, reports: [key(100, 0x04)])).verdict, .pass)
        let volumeOnly = VolumeState(deviceID: 7, hasVolume: true, hasMute: false, scalar: 0.5, muted: nil)
        XCTAssertEqual(DevVolumeJudge.judge(.unchanged, obs(go: volumeOnly, reports: [key(100, 0x01)])).verdict, .pass)
    }

    func testVolumeAtItsLimitInTheKeysDirectionCannotBeJudged() {
        // G2 is volume down: at zero it changes nothing, so "unchanged" would pass without proving anything.
        for want in DevVolumeExpectation.allCases {
            assertCannotJudge(DevVolumeJudge.judge(want, obs(go: .device(scalar: 0), reports: [key(100, 0x02)])), containing: "already at its lowest")
            assertCannotJudge(DevVolumeJudge.judge(want, obs(go: .device(scalar: 1), reports: [key(100, 0x01)])), containing: "already at its highest")
        }
        // The same level in the other direction is fine, and so is a mute key at either limit.
        XCTAssertEqual(DevVolumeJudge.judge(.unchanged, obs(go: .device(scalar: 0), reports: [key(100, 0x01)])).verdict, .pass)
        XCTAssertEqual(DevVolumeJudge.judge(.unchanged, obs(go: .device(scalar: 1), reports: [key(100, 0x02)])).verdict, .pass)
        XCTAssertEqual(DevVolumeJudge.judge(.changes, obs(go: .device(scalar: 0), events: [event(120, .mute)], reports: [key(100, 0x04)])).verdict, .pass)
        // Within a hair of the limit is the limit; one step away is not.
        assertCannotJudge(DevVolumeJudge.judge(.unchanged, obs(go: .device(scalar: 0.0001), reports: [key(100, 0x02)])), containing: "lowest")
        XCTAssertEqual(DevVolumeJudge.judge(.unchanged, obs(go: .device(scalar: 0.0625), reports: [key(100, 0x02)])).verdict, .pass)
        // Mute-only device: no scalar to be at a limit.
        let muteOnly = VolumeState(deviceID: 7, hasVolume: false, hasMute: true, scalar: nil, muted: false)
        XCTAssertEqual(DevVolumeJudge.judge(.unchanged, obs(go: muteOnly, reports: [key(100, 0x02)])).verdict, .pass)
    }

    func testAChangedOutputDeviceCannotBeJudged() {
        for want in DevVolumeExpectation.allCases {
            let r = DevVolumeJudge.judge(want, obs(events: [event(200, .device, .device(9, scalar: 0.8)), event(210, .volume)], reports: [key(100, 0x02)]))
            assertCannotJudge(r, containing: "output device changed")
            XCTAssertEqual(r.deviceEvents, 1)
            XCTAssertEqual(r.volumeEvents, 1)
        }
    }

    func testCannotJudgeIsNeverAPassAndNeverAFail() {
        let r = DevVolumeJudge.judge(.unchanged, obs(reports: []))
        XCTAssertNotEqual(r.verdict, .pass)
        guard case .inconclusive = r.verdict else { return XCTFail("\(r.verdict)") }
        XCTAssertEqual(r.verdict.tag, "inconclusive")
    }

    // MARK: what is watched

    func testObservationKeepsOnlyTheSpanAndPicksTheStatesAtItsEnds() {
        let timeline: [(tNs: UInt64, state: VolumeState)] = [
            (Self.ns(-5000), .device(scalar: 0.5)),
            (Self.ns(120), .device(scalar: 0.4375)),
            (Self.ns(2500), .device(scalar: 0.375)),
        ]
        let events = [event(-300, .volume), event(120, .volume), event(2500, .volume)]
        let reports = [key(-200, 0x02), key(100, 0x02), key(2600, 0x02)]
        let o = DevVolumeObservation.make(timeline: timeline, events: events, reports: reports, from: Self.ns(0), to: Self.ns(2000))
        XCTAssertEqual(o.events.map(\.tNs), [Self.ns(120)], "an event before Go or after the tail does not count")
        XCTAssertEqual(o.reports.map(\.tNs), [Self.ns(100)])
        XCTAssertEqual(o.atGo?.scalar, 0.5)
        XCTAssertEqual(o.atEnd?.scalar, 0.4375)
        // Events hop threads, so the timeline can arrive slightly out of order.
        let shuffled = [timeline[2], timeline[0], timeline[1]]
        XCTAssertEqual(DevVolumeObservation.make(timeline: shuffled, events: [], reports: [], from: Self.ns(0), to: Self.ns(3000)).atEnd?.scalar, 0.375)
        XCTAssertNil(DevVolumeObservation.make(timeline: [], events: [], reports: [], from: 0, to: 1).atGo)
    }

    // MARK: folded into the pad's verdict

    private func padRig(rbTwice: Bool) -> [DevJudge.TimedReport] {
        var last: [UInt8: [UInt8]] = [:]
        for r in PadReportBuilders.xboxBT16(PadState()) { last[r.id] = r.bytes }
        var out: [DevJudge.TimedReport] = []
        func set(_ s: PadState, at ms: Double) {
            for r in PadReportBuilders.xboxBT16(s) where last[r.id] != r.bytes {
                out.append(.init(tNs: Self.ns(ms), id: r.id, bytes: r.bytes)); last[r.id] = r.bytes
            }
        }
        guard rbTwice else { return out }
        var rb = PadState(); rb.buttons = [.rb]
        for t in [100.0, 600] { set(rb, at: t); set(PadState(), at: t + 150) }
        return out
    }

    private func g3Step(volume: String?) -> DevStep {
        var s = DevStep(id: "g3-rb", kind: .digital, controls: ["g3"], title: "t", seconds: 5, releaseSeconds: 1)
        var e = DevExpect(); e.items = DevExpectedItems(buttons: ["RB"])
        e.volume = volume
        s.expect = e
        return s
    }

    private func judge(volume: String? = "unchanged", rbTwice: Bool = true, observation: DevVolumeObservation?) -> DevJudge.Outcome {
        var entry = PadDecodedState.neutral
        for r in PadReportBuilders.xboxBT16(PadState()) { PadReportDecoder.xboxBT16.apply(reportID: r.id, bytes: r.bytes, to: &entry) }
        let input = DevJudge.Input(step: g3Step(volume: volume), expected: DevExpectedItems(buttons: ["RB"]), entryState: entry,
                                   reports: padRig(rbTwice: rbTwice), windowStartNs: Self.ns(0), windowEndNs: Self.ns(5000),
                                   endNs: Self.ns(6000), volume: observation)
        return DevJudge.judge(input)
    }

    func testPadAndVolumeBothRightIsAPassWithTheVolumeInTheDetail() {
        let o = judge(observation: obs(reports: [key(90, 0x01), key(240, 0x00), key(590, 0x01), key(740, 0x00)]))
        XCTAssertEqual(o.verdict, .pass, o.metrics.detail)
        XCTAssertEqual(o.volume?.verdict, .pass)
        XCTAssertTrue(o.metrics.detail.contains("The volume stayed as it was"), o.metrics.detail)
    }

    func testPadRightButVolumeCannotBeJudgedIsInconclusiveNotAPass() {
        let o = judge(observation: obs(reports: []))
        guard case .inconclusive(let why) = o.verdict else { return XCTFail("\(o.verdict)") }
        XCTAssertTrue(why.hasPrefix("cannot judge the volume: no volume-key report"), why)
        XCTAssertEqual(o.volume?.verdict.tag, "inconclusive")
        // a step that asks for the volume and was given nothing to look at is the same
        XCTAssertEqual(judge(observation: nil).verdict.tag, "inconclusive")
    }

    func testPadRightButVolumeMovedIsAFailure() {
        let o = judge(observation: obs(events: [event(120, .volume)], reports: [key(90, 0x01)]))
        guard case .fail(let why) = o.verdict else { return XCTFail("\(o.verdict)") }
        XCTAssertTrue(why.contains("volume changed although it should have been left alone"), why)
    }

    func testAPadFailureStaysAFailureWhateverTheVolumeSays() {
        let cannot = judge(rbTwice: false, observation: obs(reports: []))
        guard case .fail(let padWhy) = cannot.verdict else { return XCTFail("\(cannot.verdict)") }
        XCTAssertTrue(padWhy.contains("RB went down 0 and up 0 times"), padWhy)
        XCTAssertFalse(padWhy.contains("volume"), "a volume that cannot be judged adds nothing to a pad failure: \(padWhy)")
        XCTAssertEqual(cannot.volume?.verdict.tag, "inconclusive")
        let both = judge(rbTwice: false, observation: obs(events: [event(120, .volume)], reports: [key(90, 0x01)]))
        guard case .fail(let bothWhy) = both.verdict else { return XCTFail("\(both.verdict)") }
        XCTAssertTrue(bothWhy.contains("RB went down 0") && bothWhy.contains("volume changed"), bothWhy)
        let padOnly = judge(rbTwice: false, observation: obs(reports: [key(90, 0x01)]))
        XCTAssertEqual(padOnly.verdict.tag, "fail")
        XCTAssertEqual(padOnly.volume?.verdict, .pass)
    }

    func testAStepWithoutExpectVolumeIsJudgedAsBefore() {
        let plain = judge(volume: nil, observation: obs(events: [event(120, .volume)], reports: []))
        XCTAssertEqual(plain.verdict, .pass, plain.metrics.detail)
        XCTAssertNil(plain.volume)
        XCTAssertFalse(plain.metrics.detail.contains("olume"), plain.metrics.detail)
        // a word this build does not know is not judged here (template validation rejects it)
        XCTAssertNil(judge(volume: "louder", observation: nil).volume)
    }

    // MARK: the report

    func testResultRoundTripsAndOmitsWhatIsUnknown() throws {
        let r = DevVolumeJudge.judge(.unchanged, obs(reports: [key(100, 0x01)]))
        let back = try JSONDecoder().decode(DevVolumeResult.self, from: try JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        var cannot = DevVolumeJudge.judge(.changes, obs(go: VolumeState(), reports: [key(100, 0x01)]))
        cannot.startScalar = nil
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        let json = String(decoding: try e.encode(cannot), as: UTF8.self)
        XCTAssertFalse(json.contains("startScalar"), json)
        XCTAssertTrue(json.contains("\"expect\":\"changes\""), json)
        XCTAssertTrue(json.contains("\"verdict\":{\"reason\":"), json)
        let sparse = try JSONDecoder().decode(DevVolumeResult.self, from: Data(#"{"expect":"changes","futureKey":1}"#.utf8))
        XCTAssertEqual(sparse.expect, "changes"); XCTAssertEqual(sparse.keyReports, 0)
    }

    func testAnAttemptCarriesTheVolumeOnlyWhenThereIsOne() throws {
        var a = DevAttempt()
        let plain = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertFalse(plain.contains("volume"), "a step without expect.volume leaves the report as it was")
        a.volume = DevVolumeJudge.judge(.unchanged, obs(reports: [key(100, 0x01)]))
        let back = try JSONDecoder().decode(DevAttempt.self, from: try JSONEncoder().encode(a))
        XCTAssertEqual(back.volume, a.volume)
        XCTAssertNil(try JSONDecoder().decode(DevAttempt.self, from: Data("{}".utf8)).volume, "older reports have none")
    }

    func testTheRealObserverFileNeedsNoAppKit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GDHub/Developer", isDirectory: true)
        for name in ["CoreAudioVolumeObserver.swift", "DevVolume.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.components(separatedBy: "//").first ?? ""
                for token in ["import AppKit", "import SwiftUI", "NSApplication", "NSWorkspace", "AudioObjectSetPropertyData"] {
                    XCTAssertFalse(code.contains(token), "\(name) contains \(token)")
                }
            }
        }
    }
}

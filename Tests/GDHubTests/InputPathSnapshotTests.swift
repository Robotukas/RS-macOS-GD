import XCTest
@testable import GDHub

/// The input path is the one thing Developer mode changes, so putting it back exactly is tested against real
/// `UserDefaults` (a private suite) and a real marker file in a temp directory.
final class InputPathSnapshotTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var dir: URL!
    private var control: DevInputPathControl!

    override func setUpWithError() throws {
        suite = "gdhub.test.devpath.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("devpath-\(UUID().uuidString)", isDirectory: true)
        control = DevInputPathControl(defaults: defaults, markerURL: dir.appendingPathComponent("dev-runs/.inflight"))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func raw() -> (path: Any?, choice: Any?, breaker: Any?, reason: Any?) {
        (defaults.object(forKey: InputPath.defaultsKey), defaults.object(forKey: InputPath.choiceKey),
         defaults.object(forKey: InputPath.breakerKey), defaults.object(forKey: InputPath.breakerReasonKey))
    }

    // MARK: Snapshot and restore

    func testAbsentKeysComeBackAbsent() {
        let snap = control.snapshot()
        XCTAssertEqual(snap, DevPathSnapshot())
        control.write(path: "driver")
        XCTAssertEqual(defaults.string(forKey: InputPath.defaultsKey), "driver")
        XCTAssertEqual(defaults.integer(forKey: InputPath.choiceKey), 1, "the menu semantics: every write bumps the choice")
        control.restore(snap)
        let r = raw()
        XCTAssertNil(r.path); XCTAssertNil(r.choice); XCTAssertNil(r.breaker); XCTAssertNil(r.reason)
    }

    func testALatchedBreakerSurvivesARunThatReArmedTheDriver() {
        defaults.set("driver", forKey: InputPath.defaultsKey)
        defaults.set(7, forKey: InputPath.choiceKey)
        defaults.set(1_700_000_000.5, forKey: InputPath.breakerKey)
        defaults.set("limiter", forKey: InputPath.breakerReasonKey)
        let snap = control.snapshot()
        XCTAssertTrue(snap.wasLatched)
        control.write(path: "engine")                       // the engine path does not touch the breaker
        XCTAssertNotNil(defaults.object(forKey: InputPath.breakerKey))
        control.write(path: "driver")                       // an arming value clears it, as the menu does
        XCTAssertNil(defaults.object(forKey: InputPath.breakerKey))
        XCTAssertNil(defaults.object(forKey: InputPath.breakerReasonKey))
        control.restore(snap)
        XCTAssertEqual(defaults.string(forKey: InputPath.defaultsKey), "driver")
        XCTAssertEqual(defaults.integer(forKey: InputPath.choiceKey), 7, "no choice bump on restore")
        XCTAssertEqual(defaults.double(forKey: InputPath.breakerKey), 1_700_000_000.5)
        XCTAssertEqual(defaults.string(forKey: InputPath.breakerReasonKey), "limiter")
        XCTAssertEqual(control.snapshot(), snap, "exactly what was there")
    }

    func testTheRawValueIsKeptNotItsNormalisedForm() {
        defaults.set(" Driver ", forKey: InputPath.defaultsKey)
        let snap = control.snapshot()
        control.write(path: "engine")
        control.restore(snap)
        XCTAssertEqual(defaults.string(forKey: InputPath.defaultsKey), " Driver ")
    }

    func testRestoringOntoAnAbsentKeyRemovesAKeyTheRunAdded() {
        defaults.set("shadow", forKey: InputPath.defaultsKey)
        let snap = control.snapshot()              // choice absent
        control.write(path: "driver")
        XCTAssertNotNil(defaults.object(forKey: InputPath.choiceKey))
        control.restore(snap)
        XCTAssertNil(defaults.object(forKey: InputPath.choiceKey))
        XCTAssertEqual(defaults.string(forKey: InputPath.defaultsKey), "shadow")
    }

    func testTheEndTextNamesWhatWasPutBack() {
        XCTAssertEqual(DevPathSnapshot().restoredDescription, "Engine (App path)")
        XCTAssertEqual(DevPathSnapshot(inputPath: "driver").restoredDescription, "Driver")
        XCTAssertEqual(DevPathSnapshot(inputPath: "driver", tapBreakerTrippedAt: 1, tapBreakerReason: "limiter").restoredDescription,
                       "Driver (stopped by breaker: limiter, as before)")
    }

    // MARK: Marker

    private func marker(written: String = "driver", snapshot: DevPathSnapshot = DevPathSnapshot(inputPath: "shadow", inputPathChoice: 4),
                        pid: Int32 = 999_999) -> DevInflightMarker {
        DevInflightMarker(pid: pid, processStart: nil, snapshot: snapshot, writtenValue: written, startedAt: "2026-11-09T14:00:00+01:00")
    }

    func testTheMarkerRoundTripsAndIsRemoved() throws {
        XCTAssertNil(control.readMarker())
        let m = marker()
        try control.writeMarker(m)
        XCTAssertEqual(control.readMarker(), m)
        control.removeMarker()
        XCTAssertNil(control.readMarker())
    }

    func testAMarkerFromACrashedRunIsRestoredAtLaunchUnderTheConditions() throws {
        let before = DevPathSnapshot(inputPath: "shadow", inputPathChoice: 4, tapBreakerTrippedAt: 12.5, tapBreakerReason: "breaker")
        try control.writeMarker(marker(snapshot: before))
        defaults.set("driver", forKey: InputPath.defaultsKey)             // what the dead run left behind
        defaults.set(5, forKey: InputPath.choiceKey)
        defaults.removeObject(forKey: InputPath.breakerKey)
        let note = control.restoreOnLaunchIfNeeded(mode: .engine, isPidAlive: { _ in false })
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("put the input path back") ?? false, note ?? "nil")
        XCTAssertEqual(control.snapshot(), before)
        XCTAssertNil(control.readMarker())
    }

    func testTheMarkerIsRemovedWithoutRestoringWhenAConditionFails() throws {
        // Not engine mode.
        try control.writeMarker(marker())
        defaults.set("driver", forKey: InputPath.defaultsKey)
        XCTAssertNotNil(control.restoreOnLaunchIfNeeded(mode: .inApp, isPidAlive: { _ in false }))
        XCTAssertEqual(defaults.string(forKey: InputPath.defaultsKey), "driver", "left alone")
        XCTAssertNil(control.readMarker())

        // The owner changed the path since the run wrote it.
        try control.writeMarker(marker())
        defaults.set("engine", forKey: InputPath.defaultsKey)
        let note = control.restoreOnLaunchIfNeeded(mode: .engine, isPidAlive: { _ in false })
        XCTAssertTrue(note?.contains("changed since") ?? false, note ?? "nil")
        XCTAssertEqual(defaults.string(forKey: InputPath.defaultsKey), "engine")
        XCTAssertNil(control.readMarker())
    }

    func testALiveRunKeepsItsMarker() throws {
        try control.writeMarker(marker())
        defaults.set("driver", forKey: InputPath.defaultsKey)
        let note = control.restoreOnLaunchIfNeeded(mode: .engine, isPidAlive: { _ in true })
        XCTAssertTrue(note?.contains("still in progress") ?? false, note ?? "nil")
        XCTAssertNotNil(control.readMarker())
        XCTAssertEqual(defaults.string(forKey: InputPath.defaultsKey), "driver")
    }

    func testNoMarkerIsSilentAndAGarbageMarkerIsRemoved() throws {
        XCTAssertNil(control.restoreOnLaunchIfNeeded(mode: .engine, isPidAlive: { _ in false }))
        try FileManager.default.createDirectory(at: control.markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: control.markerURL)
        XCTAssertNotNil(control.restoreOnLaunchIfNeeded(mode: .engine, isPidAlive: { _ in false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.markerURL.path))
    }

    func testAProcessIsToldFromItsReusedPid() {
        let me = getpid()
        let start = DevInputPathControl.processStartTime(pid: me)
        XCTAssertNotNil(start)
        XCTAssertTrue(DevInputPathControl.processIsAlive(DevInflightMarker(pid: me, processStart: start, snapshot: DevPathSnapshot(), writtenValue: "x", startedAt: "")))
        XCTAssertFalse(DevInputPathControl.processIsAlive(DevInflightMarker(pid: me, processStart: (start ?? 0) - 3600, snapshot: DevPathSnapshot(), writtenValue: "x", startedAt: "")),
                       "same pid, different start time: another process")
        XCTAssertFalse(DevInputPathControl.processIsAlive(DevInflightMarker(pid: 0, processStart: nil, snapshot: DevPathSnapshot(), writtenValue: "x", startedAt: "")))
    }
}

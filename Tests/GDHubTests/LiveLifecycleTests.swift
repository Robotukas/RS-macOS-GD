import XCTest
@testable import GDHub

/// T7 pieces that need no dext: the sleep wait, the options, the uninstall script, and the Driver menu's LIVE states.
final class LiveLifecycleTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func text(_ rel: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8) }

    func testWillSleepWaitsAtMostOneSecondAndNeverOnTheQueue() {
        XCTAssertEqual(PowerObserver.willSleepWait, 1.0)
        let q = DispatchQueue(label: "test.sleep")
        var ran = false
        XCTAssertTrue(PowerObserver.runWithin(1, on: q) { ran = true })
        XCTAssertTrue(ran)
        // a queue that is blocked (a driver call in flight): the wait ends, the sleep goes on
        let blocked = DispatchQueue(label: "test.blocked"); let release = DispatchSemaphore(value: 0)
        blocked.async { release.wait() }
        let t0 = Date()
        XCTAssertFalse(PowerObserver.runWithin(0.2, on: blocked) {})
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.6)
        release.signal()
    }

    func testWillSleepIsAsyncWithASemaphoreNotQueueSync() throws {
        let t = try text("Sources/GDHub/Engine/PowerObserver.swift")
        let s = try XCTUnwrap(t.range(of: "case Self.systemWillSleep:"))
        let body = String(t[s.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("runWithin("))
        XCTAssertFalse(body.contains("vhidQueue.sync"), "the sleep notification must not wait unboundedly on vhidQueue")
        XCTAssertTrue(body.contains("IOAllowPowerChange"))
    }

    /// E10: exit codes and messages of `--release-pad`; the script shows the message.
    func testReleasePadOutcomesExitCodesAndMessages() {
        typealias O = ReleasePadTool.Outcome
        XCTAssertEqual(ReleasePadTool.outcome(hasLive: true, pinnedBefore: true, kr: KERN_SUCCESS), O.released)
        XCTAssertEqual(ReleasePadTool.outcome(hasLive: true, pinnedBefore: false, kr: KERN_SUCCESS), O.nonePinned)
        XCTAssertEqual(ReleasePadTool.outcome(hasLive: false, pinnedBefore: false, kr: KERN_SUCCESS), O.oldDriver, "a driver without CAP_LIVE: the flag would be refused")
        XCTAssertEqual(ReleasePadTool.outcome(hasLive: true, pinnedBefore: true, kr: DextProtocol.krNotPermitted), O.failed(DextProtocol.krNotPermitted))
        XCTAssertEqual(ReleasePadTool.outcome(hasLive: true, pinnedBefore: false, kr: DextProtocol.krBusy), O.failed(DextProtocol.krBusy))
        XCTAssertEqual([O.released, .nonePinned].map(\.exitCode), [0, 0], "nothing to do is not an error")
        XCTAssertEqual([O.oldDriver, .noConnection, .failed(5)].map(\.exitCode), [1, 1, 1])
        for o in [O.released, .nonePinned, .oldDriver, .noConnection, .failed(0x2c8)] { XCTAssertTrue(o.message.hasPrefix("release-pad: "), o.message) }
        XCTAssertEqual(O.failed(Int32(bitPattern: 0xe00002c5)).message, "release-pad: the driver answered 0xe00002c5")
        XCTAssertEqual(Set([O.released, .nonePinned, .oldDriver, .noConnection, .failed(1)].map(\.message)).count, 5, "every outcome says something different")
    }

    func testReleasePadOption() {
        XCTAssertTrue(EngineOptions(arguments: ["GDHub", "--engine", "--engine-foreground", "--release-pad"]).releasePad)
        XCTAssertFalse(EngineOptions(arguments: ["GDHub", "--engine"]).releasePad)
        XCTAssertNotEqual(EngineOptions(arguments: ["--release-pad"]), EngineOptions())
    }

    func testReleasePadRunsOnlyInTheForegroundAndNeverUnderLaunchd() throws {
        let t = try text("Sources/GDHub/Engine/EngineMain.swift")
        let guardAt = try XCTUnwrap(t.range(of: "guard startedByLaunchd")).lowerBound
        let release = try XCTUnwrap(t.range(of: "ReleasePadTool.run()")).lowerBound
        XCTAssertLessThan(guardAt, release, "the foreground / launchd check comes first")
        XCTAssertFalse(try text("Sources/GDHub/Engine/ReleasePadTool.swift").contains("EngineService("), "it never builds the engine")
    }

    func testUninstallReleasesTheDriversPinnedPadAfterTheBootout() throws {
        let t = try text("scripts/engine-agent.sh")
        let u = try XCTUnwrap(t.range(of: "  uninstall)"))
        let body = String(t[u.lowerBound...].prefix(4000))
        let boot = try XCTUnwrap(body.range(of: "bootout_wait")).lowerBound
        let rel = try XCTUnwrap(body.range(of: "--engine --engine-foreground --release-pad")).lowerBound
        XCTAssertLessThan(boot, rel, "release after the engine is gone")
        XCTAssertTrue(body.contains("exit $rc"), "the uninstall's own result is not changed by the release")
    }

    func testEngineServiceOrderIsInertBeforeDestroy() throws {
        let t = try text("Sources/GDHub/Engine/EngineService.swift")
        let s = try XCTUnwrap(t.range(of: "self.vhidQueue.sync {\n                    self.reader.stop()"))
        let body = String(t[s.lowerBound...].prefix(400))
        let inert = try XCTUnwrap(body.range(of: "tapSupervisor.shutdown()")).lowerBound
        let destroy = try XCTUnwrap(body.range(of: "core.shutdown()")).lowerBound
        XCTAssertLessThan(inert, destroy, "INERT (which leaves LIVE: source UC, neutral) before destroyDevice: a clean exit never pins")
    }

    // MARK: Driver menu, LIVE

    private func report(_ edit: (inout TapStatusReport) -> Void = { _ in }) -> TapStatusReport {
        var r = TapStatusReport(); r.pid = 9; r.connected = true; r.capTap = true; r.capXlate = true; r.capLive = true
        edit(&r); return r
    }
    private func status(_ r: TapStatusReport) -> String { InputPathMenu.status(mode: .engine, engineRunningPid: 9, report: r) }

    func testMenuLiveStates() {
        XCTAssertEqual(status(report { $0.path = "driver"; $0.armed = "live" }), "Driven by: Driver")
        XCTAssertEqual(status(report { $0.path = "driver"; $0.armed = "shadow" }), "Driven by: App, with driver check (parity not yet checked; going live)")
        XCTAssertEqual(status(report { $0.path = "driver"; $0.armed = "shadow"; $0.capLive = false; $0.liveUnavailable = true }),
                       "Driven by: App, with driver check (parity not yet checked; live mode not available in this driver)")
        XCTAssertEqual(status(report { $0.path = "driver"; $0.fallback = "tap stalled"; $0.fallbackRetrying = true }), "Driven by: App (fallback: tap stalled; retrying)")
        XCTAssertEqual(status(report { $0.path = "driver"; $0.fallback = "output stalled"; $0.fallbackRetrying = true }), "Driven by: App (fallback: output stalled; retrying)")
        XCTAssertEqual(status(report { $0.path = "driver"; $0.mappingNote = "echo suppression" }), "Driven by: App (mapping needs GDHM v2: echo suppression)")
    }

    func testMenuHasThreeChoicesAndSelectsTheDriverOne() throws {
        let t = try text("Sources/GDHub/UI/DriverCommands.swift")
        XCTAssertTrue(t.contains(#"[("engine", "App"), ("shadow", "App, with driver check"), ("driver", "Driver")]"#))
        XCTAssertEqual(InputPathMenu.selection(report: report { $0.path = "driver" }, engineRunningPid: 9, stored: nil), "driver")
        XCTAssertEqual(InputPathMenu.selection(report: nil, engineRunningPid: nil, stored: "driver"), "driver")
        XCTAssertEqual(InputPath.engine.rawValue, "engine"); XCTAssertEqual(InputPath(defaultsValue: nil), .engine, "the default stays the engine path")
    }
}

import XCTest
@testable import GDHub

/// T6: the Driver menu's input-path line as a pure function of what the GUI knows (every state), the report file the engine
/// writes and the GUI reads, and the menu's write of the `inputPath` key.
final class InputPathMenuTests: XCTestCase {
    private func report(_ edit: (inout TapStatusReport) -> Void = { _ in }) -> TapStatusReport {
        var r = TapStatusReport()
        r.pid = 777; r.connected = true; r.capTap = true; r.capXlate = true
        edit(&r)
        return r
    }
    private func text(_ r: TapStatusReport?, mode: GUIMode = .engine, pid: Int32? = 777) -> String {
        InputPathMenu.status(mode: mode, engineRunningPid: pid, report: r)
    }

    /// E9: a file written by build 23 (no `capLive`), by a newer build (extra keys) or with keys missing decodes; a different
    /// schema number or garbage does not.
    func testTheReportDecodesAFileFromBuild23AndANewerOne() throws {
        let build23 = #"{"armed":"shadow","capTap":true,"capXlate":true,"connected":true,"fallbackRetrying":false,"liveUnavailable":true,"mappingNote":null,"parityChecked":true,"parityMismatches":0,"parityOkBucket":300,"path":"shadow","pid":777,"schema":1}"#
        let r = try XCTUnwrap(TapStatusReport.decode(Data(build23.utf8)))
        XCTAssertFalse(r.capLive, "the key an older engine never wrote"); XCTAssertEqual(r.armed, "shadow"); XCTAssertEqual(r.pid, 777)
        XCTAssertTrue(r.capTap && r.capXlate && r.connected && r.liveUnavailable && r.parityChecked); XCTAssertEqual(r.parityOkBucket, 300)
        XCTAssertEqual(InputPathMenu.status(mode: .engine, engineRunningPid: 777, report: r), InputPathMenu.status(mode: .engine, engineRunningPid: 777, report: {
            var x = TapStatusReport(); x.pid = 777; x.path = "shadow"; x.connected = true; x.capTap = true; x.capXlate = true; x.armed = "shadow"
            x.liveUnavailable = true; x.parityChecked = true; x.parityOkBucket = 300; return x }()))
        XCTAssertNotEqual(text(r), "Driven by: unknown (waiting for the engine)", "build 23's file is understood, not 'waiting'")
        let newer = #"{"schema":1,"pid":5,"path":"driver","connected":true,"capTap":true,"capXlate":true,"capLive":true,"armed":"live","somethingNew":{"a":[1,2]},"futureFlag":true}"#
        let n = try XCTUnwrap(TapStatusReport.decode(Data(newer.utf8)))
        XCTAssertEqual(n.armed, "live"); XCTAssertTrue(n.capLive)
        XCTAssertNotNil(TapStatusReport.decode(Data(#"{"schema":1}"#.utf8)), "every key is optional")
        XCTAssertNil(TapStatusReport.decode(Data(#"{"schema":2,"pid":5}"#.utf8)), "another schema is not understood")
        XCTAssertNil(TapStatusReport.decode(Data("not json".utf8)))
        XCTAssertNil(TapStatusReport.decode(Data(#"{"schema":1,"pid":"x"}"#.utf8)), "a key of the wrong type is a broken file")
        // and what this build writes reads back identically
        var full = report { $0.capLive = true; $0.armed = "live"; $0.fallback = "tap stalled"; $0.fallbackRetrying = true; $0.latched = "breaker"; $0.mappingNote = "n" }
        full.parityChecked = true; full.parityOkBucket = 500; full.parityMismatches = 2; full.liveUnavailable = true
        XCTAssertEqual(TapStatusReport.decode(try XCTUnwrap(full.encoded())), full)
    }

    // MARK: every state of the menu

    func testGuiModesWithoutAnEngineToAsk() {
        XCTAssertEqual(text(nil, mode: .inApp, pid: nil), "Driven by: App (in-app mode: no background engine)")
        XCTAssertEqual(text(report(), mode: .displayOnly), "Driven by: unknown (display-only copy)")
    }

    func testEngineNotRunningOrNotYetReporting() {
        XCTAssertEqual(text(report(), pid: nil), "Driven by: unknown (engine not running)")
        XCTAssertEqual(text(nil), "Driven by: unknown (waiting for the engine)")
        XCTAssertEqual(text(report { $0.pid = 111 }), "Driven by: unknown (waiting for the engine)", "a file left by another (dead) engine is not shown")
    }

    func testNotConnectedAndOldDextWithoutTheTap() {
        XCTAssertEqual(text(report { $0.connected = false }), "Driven by: App (waiting for the driver)")
        XCTAssertEqual(text(report { $0.capTap = false; $0.capXlate = false; $0.path = "shadow" }),
                       "Driven by: App (this driver has no receiver tap; update the driver)")
    }

    func testInertCountAndShadow() {
        XCTAssertEqual(text(report()), "Driven by: App")
        XCTAssertEqual(text(report { $0.path = "count"; $0.armed = "count" }), "Driven by: App (driver counting frames)")
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.armed = "shadow" }), "Driven by: App, with driver check (parity not yet checked)")
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.armed = "shadow"; $0.parityChecked = true; $0.parityOkBucket = 1200 }),
                       "Driven by: App, with driver check (parity checked)")
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.armed = "shadow"; $0.parityMismatches = 2 }),
                       "Driven by: App, with driver check (2 parity mismatches)")
        XCTAssertEqual(text(report { $0.path = "driver"; $0.armed = "shadow"; $0.liveUnavailable = true }),
                       "Driven by: App, with driver check (parity not yet checked; live mode not available in this driver)")
    }

    func testPathAskedForButNotArmedYet() {
        XCTAssertEqual(text(report { $0.path = "shadow" }), "Driven by: App (driver not ready yet)")
    }

    func testFallbackWithAndWithoutAutomaticRetry() {
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.fallback = "tap stalled"; $0.fallbackRetrying = true }),
                       "Driven by: App (fallback: tap stalled; retrying)")
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.fallback = "driver restarted (instance changed since the arming was accepted)" }),
                       "Driven by: App (fallback: driver restarted (instance changed since the arming was accepted); choose Driver to try again)")
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.fallback = "parity mismatch" }),
                       "Driven by: App (fallback: parity mismatch; choose Driver to try again)")
    }

    func testATapWithoutShadowModeSaysSo() {
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.capXlate = false }), "Driven by: App (this driver cannot run shadow mode; update the driver)")
        XCTAssertEqual(text(report { $0.path = "driver"; $0.capXlate = false }), "Driven by: App (this driver cannot run shadow mode; update the driver)")
        XCTAssertEqual(text(report { $0.path = "engine"; $0.capXlate = false }), "Driven by: App", "on the app path there is nothing to explain")
        XCTAssertEqual(text(report { $0.path = "count"; $0.armed = "count"; $0.capXlate = false }), "Driven by: App (driver counting frames)")
    }

    func testBreakerAndLimiter() {
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.latched = "breaker" }),
                       "Driven by: App (driver path stopped after repeated driver restarts; choose Driver to try again)")
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.latched = "limiter"; $0.fallback = "tap absent" }),
                       "Driven by: App (driver path stopped after repeated fallbacks; choose Driver to try again)")
    }

    func testUnsupportedMappingShowsTheReason() {
        XCTAssertEqual(text(report { $0.path = "shadow"; $0.armed = "shadow"; $0.mappingNote = "echo suppression" }),
                       "Driven by: App (mapping needs GDHM v2: echo suppression)")
        XCTAssertEqual(text(report { $0.mappingNote = "echo suppression" }), "Driven by: App",
                       "on the engine path nobody asked for the driver: no note")
    }

    // MARK: radio selection

    func testSelectionFollowsTheEnginesPathWhenKnownElseTheStoredValue() {
        XCTAssertEqual(InputPathMenu.selection(report: report { $0.path = "shadow" }, engineRunningPid: 777, stored: "engine"), "shadow")
        XCTAssertEqual(InputPathMenu.selection(report: report { $0.path = "driver" }, engineRunningPid: 777, stored: "engine"), "driver")
        XCTAssertEqual(InputPathMenu.selection(report: nil, engineRunningPid: 777, stored: "shadow"), "shadow")
        XCTAssertEqual(InputPathMenu.selection(report: report { $0.path = "shadow" }, engineRunningPid: 999, stored: "engine"), "engine", "a stale report is not trusted")
        XCTAssertEqual(InputPathMenu.selection(report: nil, engineRunningPid: nil, stored: nil), "driver", "T8: nothing stored means the driver path")
        XCTAssertEqual(InputPathMenu.selection(report: nil, engineRunningPid: nil, stored: "bogus"), "engine")
        XCTAssertEqual(InputPathMenu.selection(report: nil, engineRunningPid: nil, stored: "count"), "count")
    }

    // MARK: the file

    func testReportRoundTripAndSchema() throws {
        var r = report { $0.path = "shadow"; $0.armed = "shadow"; $0.fallback = "tap stalled"; $0.fallbackRetrying = true; $0.mappingNote = "x" }
        r.parityOkBucket = 300
        XCTAssertEqual(TapStatusReport.decode(try XCTUnwrap(r.encoded())), r)
        var future = r; future.schema = 99
        XCTAssertNil(TapStatusReport.decode(try XCTUnwrap(future.encoded())), "another schema is not guessed at")
        XCTAssertNil(TapStatusReport.decode(Data("not json".utf8)))
    }

    private func tempStore() -> TapStatusStore {
        TapStatusStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-tapstatus-\(UUID().uuidString)/state/engine-tap-status.json"))
    }

    func testStoreWritesAtomicallyIntoItsOwnSubdirectory() throws {
        let store = tempStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertNil(store.read())
        store.write(report())
        XCTAssertEqual(store.read(), report())
        XCTAssertEqual(store.url.deletingLastPathComponent().lastPathComponent, "state",
                       "a sub-directory, so the engine's MappingWatcher on the parent does not wake for its own status writes")
        XCTAssertTrue(TapStatusStore.standard.url.path.hasSuffix("/GDHub/state/engine-tap-status.json") || ProcessInfo.processInfo.environment["GDHUB_SUPPORT_DIR"] != nil)
    }

    func testWatcherDeliversAChangeOnceAndNotAnIdenticalRewrite() throws {
        let store = tempStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent().deletingLastPathComponent()) }
        let lock = NSLock(); var got: [TapStatusReport?] = []
        let w = TapStatusWatcher(store: store, debounce: 0.02) { r in lock.lock(); got.append(r); lock.unlock() }
        XCTAssertTrue(w.start()); defer { w.stop() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return got.count }
        let t00 = Date(); while count() < 1, Date().timeIntervalSince(t00) < 5 { Thread.sleep(forTimeInterval: 0.01) }   // however loaded the machine is
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(count(), 1, "the first read delivers 'no report'")
        store.write(report { $0.path = "shadow" })
        let t0 = Date()
        while count() < 2, Date().timeIntervalSince(t0) < 5 { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(count(), 2); XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "event driven: well inside the 1.2 s of the live check")
        lock.lock(); XCTAssertEqual(got.last??.path, "shadow"); lock.unlock()
        store.write(report { $0.path = "shadow" })                      // identical content
        w.refresh()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(count(), 2, "an identical rewrite delivers nothing")
        store.write(report { $0.path = "engine" })
        let t1 = Date()
        while count() < 3, Date().timeIntervalSince(t1) < 5 { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(count(), 3)
    }

    // MARK: the menu's write

    func testChoosingAnArmingPathWritesTheKeyAndRemovesTheBreaker() throws {
        let suite = "gdhub.test.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { d.removePersistentDomain(forName: suite) }
        d.set(1.0e9, forKey: InputPath.breakerKey); d.set("breaker", forKey: InputPath.breakerReasonKey)
        DriverManager.writeInputPath("engine", defaults: d)
        XCTAssertEqual(d.string(forKey: InputPath.defaultsKey), "engine")
        XCTAssertNotNil(d.object(forKey: InputPath.breakerKey), "going back to the app path does not clear the latch")
        DriverManager.writeInputPath("shadow", defaults: d)
        XCTAssertEqual(d.string(forKey: InputPath.defaultsKey), "shadow", "the very key the engine polls")
        XCTAssertNil(d.object(forKey: InputPath.breakerKey)); XCTAssertNil(d.object(forKey: InputPath.breakerReasonKey))
        // every pick moves the choice counter, the already selected item included
        let c1 = d.integer(forKey: InputPath.choiceKey)
        DriverManager.writeInputPath("shadow", defaults: d)
        DriverManager.writeInputPath("shadow", defaults: d)
        XCTAssertEqual(d.integer(forKey: InputPath.choiceKey), c1 + 2, "the engine sees a pick even when the text did not change")
        XCTAssertEqual(d.string(forKey: InputPath.defaultsKey), "shadow")
        XCTAssertEqual(InputPath(defaultsValue: d.object(forKey: InputPath.defaultsKey)), .shadow)
    }

    /// A Picker is not known to call its setter when the checked item is clicked again, so the menu is explicit buttons.
    func testTheInputPathMenuIsButtonsNotAPicker() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GDHub/UI/DriverCommands.swift")
        let t = try String(contentsOf: src, encoding: .utf8)
        XCTAssertFalse(t.contains("Picker("))
        XCTAssertTrue(t.contains("driver.chooseInputPath(item.value)"))
        XCTAssertTrue(t.contains("systemImage: \"checkmark\""))
    }

    // MARK: the publisher

    func testPublisherWritesChangesRewritesOnTimerAndHealsAFailedWrite() {
        let q = DispatchQueue(label: "test.publisher")
        var writes: [TapStatusReport] = []; var failNext = 0
        let p = TapStatusPublisher(queue: q, retryAfter: 0.05) { r in if failNext > 0 { failNext -= 1; return false }; writes.append(r); return true }
        let a = report { $0.path = "shadow" }
        p.update(a); q.sync {}
        XCTAssertEqual(writes, [a])
        p.update(a); q.sync {}
        XCTAssertEqual(writes.count, 1, "an identical report is not written again on update")
        q.sync { p.flush(force: true) }
        XCTAssertEqual(writes.count, 2, "the timer's rewrite is unconditional (a deleted file comes back)")
        // a failed write is not remembered as written, and is retried
        let b = report { $0.path = "engine" }
        failNext = 1
        p.update(b); q.sync {}
        XCTAssertEqual(writes.count, 2)
        // the retry runs on q: every read of `writes` while it can still run goes through q too (no unsynchronised access)
        let t0 = Date(); while q.sync(execute: { writes.count }) < 3, Date().timeIntervalSince(t0) < 5 { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(q.sync { writes.last }, b)
    }

    func testPublisherRecreatesADeletedFile() throws {
        let store = tempStore(); defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent().deletingLastPathComponent()) }
        let q = DispatchQueue(label: "test.publisher2")
        let p = TapStatusPublisher(queue: q, store: store)
        p.update(report()); q.sync {}
        XCTAssertNotNil(store.read())
        try FileManager.default.removeItem(at: store.url)
        XCTAssertNil(store.read())
        q.sync { p.flush(force: true) }
        XCTAssertNotNil(store.read(), "healed by the periodic rewrite, without a state change")
        XCTAssertEqual(TapStatusPublisher.rewriteEvery, 30)
    }

    func testTheMenuNeverOffersAValueTheEngineWouldNotRead() {
        for v in ["engine", "shadow"] { XCTAssertNotEqual(InputPath(defaultsValue: v).rawValue, "", v); XCTAssertEqual(InputPath(defaultsValue: v).rawValue, v) }
    }
}

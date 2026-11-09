import XCTest
@testable import GDHub

/// Scripted launchd/pkill: `respond` answers every launchctl call; the log records them.
final class FakeShell: AgentShell {
    var log: [[String]] = []
    var respond: ([String]) -> (rc: Int32, out: String) = { _ in (113, "") }
    var killed = 0
    var processExists: () -> Bool = { false }
    var sleeps: [Double] = []
    var removed: [URL] = []

    func launchctl(_ args: [String]) -> (rc: Int32, out: String) { log.append(args); return respond(args) }
    func killEngine() { killed += 1 }
    func engineProcessExists() -> Bool { processExists() }
    func sleep(_ seconds: Double) { sleeps.append(seconds) }
    func remove(_ url: URL) { removed.append(url) }

    func count(_ verb: String) -> Int { log.filter { $0.first == verb }.count }
}

enum LaunchctlSamples {
    static let running = """
    gui/502/com.interlinked.gdhub.engine = {
    \tactive count = 1
    \tpath = /Users/x/Library/LaunchAgents/com.interlinked.gdhub.engine.plist
    \ttype = LaunchAgent
    \tstate = running

    \tprogram = /Applications/GDHub.app/Contents/MacOS/GDHub
    \targuments = {
    \t\t/Applications/GDHub.app/Contents/MacOS/GDHub
    \t\t--engine
    \t}
    \tenvironment = {
    \t\tXPC_SERVICE_NAME => com.interlinked.gdhub.engine
    \t}
    \tdomain = gui/502 [100021]
    \truns = 3
    \tpid = 4321
    \tlast exit code = (never exited)
    \tspawn type = interactive (4)
    \tproperties = keepalive | runatload
    }
    """
    static let notRunning = """
    gui/502/com.interlinked.gdhub.engine = {
    \tstate = not running
    \truns = 2
    \tlast exit code = 64
    \tspawn type = interactive (4)
    }
    """
    static let sigtermed = """
    gui/502/com.interlinked.gdhub.engine = {
    \tstate = SIGTERMed
    \truns = 1
    \tpid = 777
    \tlast exit code = (never exited)
    }
    """
}

final class EngineAgentTests: XCTestCase {
    private var shell: FakeShell!
    private var plist: URL!
    private var agent: EngineAgent!

    override func setUp() {
        shell = FakeShell()
        plist = FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-agent-test-\(UUID().uuidString).plist")
        FileManager.default.createFile(atPath: plist.path, contents: Data("x".utf8))
        agent = EngineAgent(shell: shell, installedPlistURL: plist)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: plist) }

    // MARK: Parsing and decisions

    func testParseRunning() {
        let s = AgentStatus.parse(LaunchctlSamples.running, rc: 0)
        XCTAssertTrue(s.loaded); XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.pid, 4321)
        XCTAssertEqual(s.state, "running")
        XCTAssertEqual(s.spawnType, "interactive (4)")
        XCTAssertEqual(s.lastExit, "(never exited)")
        XCTAssertEqual(s.menuText, "Engine: running (pid 4321, launchd)")
        XCTAssertEqual(EngineAgent.decide(s), .nothing)
    }

    func testParseNotRunningWithoutPid() {
        let s = AgentStatus.parse(LaunchctlSamples.notRunning, rc: 0)
        XCTAssertTrue(s.loaded); XCTAssertFalse(s.isRunning)
        XCTAssertNil(s.pid)
        XCTAssertEqual(s.menuText, "Engine: loaded, not running (last exit 64)")
        XCTAssertEqual(EngineAgent.decide(s), .kickstart)
    }

    func testParseSigtermedWithPid() {
        let s = AgentStatus.parse(LaunchctlSamples.sigtermed, rc: 0)
        XCTAssertEqual(s.state, "SIGTERMed"); XCTAssertEqual(s.pid, 777)
        XCTAssertEqual(EngineAgent.decide(s), .bootoutThenBootstrap)
    }

    func testParseNotLoaded() {
        let s = AgentStatus.parse("Could not find service", rc: 113)
        XCTAssertFalse(s.loaded)
        XCTAssertEqual(s.menuText, "Engine: installed but not loaded")
        XCTAssertEqual(EngineAgent.decide(s), .bootstrap)
    }

    func testNestedBlocksDoNotOverrideTopLevelKeys() {
        let out = "x = {\n\tstate = running\n\tpid = 5\n\tenvironment = {\n\t\tpid = 99\n\t\tstate = bogus\n\t}\n}"
        let s = AgentStatus.parse(out, rc: 0)
        XCTAssertEqual(s.pid, 5); XCTAssertEqual(s.state, "running")
    }

    // MARK: guiMode

    func testGUIModeSelection() {
        XCTAssertEqual(EngineAgent.guiMode(bundlePath: "/Applications/GDHub.app", installed: true), .engine)
        XCTAssertEqual(EngineAgent.guiMode(bundlePath: "/Users/x/macOS GD/.build/GDHub.app", installed: true), .displayOnly)
        XCTAssertEqual(EngineAgent.guiMode(bundlePath: "/Users/x/macOS GD/.xcodebuild/Build/Products/Release/GDHub.app", installed: true), .displayOnly)
        XCTAssertEqual(EngineAgent.guiMode(bundlePath: "/Applications/GDHub 2.app", installed: true), .displayOnly)
        XCTAssertEqual(EngineAgent.guiMode(bundlePath: "/Applications/GDHub.app", installed: false), .inApp)
        XCTAssertEqual(EngineAgent.guiMode(bundlePath: "/anywhere/GDHub.app", installed: false), .inApp)
    }

    // MARK: ensureLoaded

    func testEnsureLoadedBootstrapsWhenNotLoaded() {
        shell.respond = { $0.first == "bootstrap" ? (0, "") : (113, "") }
        agent.ensureLoaded()
        XCTAssertEqual(shell.count("bootstrap"), 1)
        XCTAssertEqual(shell.log.first, ["print", "gui/\(getuid())/com.interlinked.gdhub.engine"])
    }

    func testEnsureLoadedDoesNothingWhenRunning() {
        shell.respond = { _ in (0, LaunchctlSamples.running) }
        agent.ensureLoaded()
        XCTAssertEqual(shell.count("bootstrap"), 0)
        XCTAssertEqual(shell.count("kickstart"), 0)
        XCTAssertEqual(shell.count("bootout"), 0)
    }

    func testEnsureLoadedKickstartsALoadedIdleJob() {
        shell.respond = { _ in (0, LaunchctlSamples.notRunning) }
        agent.ensureLoaded()
        XCTAssertEqual(shell.count("kickstart"), 1)
        XCTAssertEqual(shell.count("bootstrap"), 0)
    }

    func testEnsureLoadedWaitsOutASigtermedJobBeforeBootstrapping() {
        var prints = 0
        shell.respond = { args in
            switch args.first {
            case "print":
                prints += 1
                return prints <= 3 ? (0, LaunchctlSamples.sigtermed) : (113, "")     // initial read + two polls, then gone
            case "bootstrap": return (0, "")
            default: return (0, "")
            }
        }
        agent.ensureLoaded()
        XCTAssertEqual(shell.count("bootout"), 1)
        XCTAssertEqual(shell.count("bootstrap"), 1)
        let order = shell.log.compactMap { $0.first }
        XCTAssertLessThan(order.firstIndex(of: "bootout")!, order.firstIndex(of: "bootstrap")!)
    }

    func testEnsureLoadedIsANoOpWhileADriverUpdateIsInFlight() {
        agent.updateInFlight = true
        agent.ensureLoaded()
        XCTAssertTrue(shell.log.isEmpty)
    }

    func testEnsureLoadedIsANoOpWithoutAnInstalledPlist() {
        try? FileManager.default.removeItem(at: plist)
        agent.ensureLoaded()
        XCTAssertTrue(shell.log.isEmpty)
    }

    func testBootstrapRc5ThenLoadedCountsAsSuccess() {
        shell.respond = { args in
            if args.first == "bootstrap" { return (5, "Bootstrap failed: 5") }
            return (0, LaunchctlSamples.running)                   // launchd loaded it at login in the meantime
        }
        XCTAssertTrue(agent.bootstrap())
        XCTAssertEqual(shell.count("bootstrap"), 1, "no retry once the job is loaded")
    }

    func testBootstrapRetriesRc5WhileNotLoadedAndThenSucceeds() {
        var n = 0
        shell.respond = { args in
            if args.first == "bootstrap" { n += 1; return n < 3 ? (5, "") : (0, "") }
            return (113, "")
        }
        XCTAssertTrue(agent.bootstrap())
        XCTAssertEqual(shell.count("bootstrap"), 3)
        XCTAssertEqual(shell.sleeps, [0.2, 0.2])
    }

    func testBootstrapGivesUpAfterThreeRetriesAndOnOtherErrors() {
        shell.respond = { args in args.first == "bootstrap" ? (37, "") : (113, "") }
        XCTAssertFalse(agent.bootstrap())
        XCTAssertEqual(shell.count("bootstrap"), 4)
        shell = FakeShell(); agent = EngineAgent(shell: shell, installedPlistURL: plist)
        shell.respond = { args in args.first == "bootstrap" ? (1, "") : (113, "") }
        XCTAssertFalse(agent.bootstrap())
        XCTAssertEqual(shell.count("bootstrap"), 1)
    }

    // MARK: bootoutAndWait

    func testBootoutAndWaitReturnsOnlyOnceLaunchctlSaysNotLoaded() {
        var prints = 0
        shell.respond = { args in
            if args.first == "print" { prints += 1; return prints <= 5 ? (0, LaunchctlSamples.sigtermed) : (113, "") }
            return (0, "")
        }
        XCTAssertTrue(agent.bootoutAndWait())
        XCTAssertEqual(prints, 6)
        XCTAssertEqual(shell.killed, 0)
    }

    func testBootoutAndWaitKillsAStuckEngineAfterSixSeconds() {
        shell.respond = { args in args.first == "print" ? (0, LaunchctlSamples.sigtermed) : (0, "") }
        XCTAssertFalse(agent.bootoutAndWait())
        XCTAssertEqual(shell.killed, 1)
        XCTAssertGreaterThanOrEqual(shell.sleeps.reduce(0, +), 6.0)
    }

    // MARK: fallback

    func testFallbackWhenTheEngineIsNeverRunning() {
        var booted = false
        shell.respond = { args in
            if args.first == "bootout" { booted = true; return (0, "") }
            return booted ? (113, "") : (0, LaunchctlSamples.notRunning)
        }
        XCTAssertTrue(agent.fallbackCheck())
        XCTAssertEqual(shell.count("bootout"), 1, "booted out so a KeepAlive respawn cannot grab the dext later")
    }

    func testNoFallbackWhenTheEngineRunsAtAnyRead() {
        var reads = 0
        shell.respond = { args in
            guard args.first == "print" else { return (0, "") }
            reads += 1
            return reads == 2 ? (0, LaunchctlSamples.running) : (0, LaunchctlSamples.notRunning)
        }
        XCTAssertFalse(agent.fallbackCheck())
        XCTAssertEqual(shell.count("bootout"), 0)
    }

    func testNoFallbackIfAnEngineProcessCannotBeProvenGone() {
        var booted = false
        shell.respond = { args in
            if args.first == "bootout" { booted = true; return (0, "") }
            return booted ? (113, "") : (0, LaunchctlSamples.notRunning)
        }
        shell.processExists = { true }
        XCTAssertFalse(agent.fallbackCheck())
        XCTAssertEqual(shell.killed, 1)
    }

    func testUninstallBootsOutAndRemovesThePlist() {
        var booted = false
        shell.respond = { args in
            if args.first == "bootout" { booted = true; return (0, "") }
            return booted ? (113, "") : (0, "")
        }
        XCTAssertTrue(agent.uninstallAgent())
        XCTAssertEqual(shell.removed, [plist])
    }

    // MARK: Template plist

    func testTemplatePlistMatchesThePlan() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Xcode/Engine/com.interlinked.gdhub.engine.plist")
        let data = try Data(contentsOf: url)
        let d = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(d["Label"] as? String, EngineMain.label)
        XCTAssertEqual(d["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(d["ProgramArguments"] as? [String], ["/Applications/GDHub.app/Contents/MacOS/GDHub", "--engine"])
        XCTAssertEqual(d["KeepAlive"] as? Bool, true)
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(d["ThrottleInterval"] as? Int, 2)
        XCTAssertEqual(d["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual((d["MachServices"] as? [String: Any])?.keys.sorted(), ["com.interlinked.gdhub.engine"])
        XCTAssertEqual(EngineAgent.label, EngineMain.label)
    }
}

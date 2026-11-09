import XCTest
import IOKit
import SystemExtensions
@testable import GDHub

/// Records every call `DriverManager` makes to the dext connection.
final class RecordingDext: DextBackend, @unchecked Sendable {
    var onState: ((DextClient.State) -> Void)?
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func rec(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }
    func start() { rec("start") }
    func retry() { rec("retry") }
    func stop() { rec("stop") }
    func devTerminate() -> kern_return_t { rec("devTerminate"); return 0 }
    func status() -> DextStatus? { rec("status"); return nil }
    func createDevice(_ spec: DeviceSpec) -> kern_return_t { rec("create"); return 0 }
    func destroyDevice(slot: UInt8) -> kern_return_t { rec("destroy"); return 0 }
    func post(slot: UInt8, report: [UInt8]) -> kern_return_t { rec("post"); return 0 }
    func postNeutral(slot: UInt8) -> kern_return_t { rec("neutral"); return 0 }
    func heartbeat() -> kern_return_t { rec("heartbeat"); return 0 }
}

@MainActor
final class DriverManagerModeTests: XCTestCase {
    private var shell: FakeShell!
    private var plist: URL!

    override func setUp() {
        shell = FakeShell()
        shell.respond = { _ in (0, LaunchctlSamples.running) }
        plist = FileManager.default.temporaryDirectory.appendingPathComponent("gdhub-dm-test-\(UUID().uuidString).plist")
        FileManager.default.createFile(atPath: plist.path, contents: Data("x".utf8))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: plist) }

    private func make(_ mode: GUIMode, _ fake: RecordingDext,
                      args: [String] = ["--dev-terminate-driver", "--publish-pad", "xbox-bt16-02e0", "--test-pattern"]) -> DriverManager {
        DriverManager(mode: mode, dext: fake, agent: EngineAgent(shell: shell, installedPlistURL: plist),
                      embeddedBuild: "17", arguments: args)
    }

    private func drain(_ m: DriverManager) {
        m.vhidQueue.sync {}
        m.agent.queue.sync {}
    }

    private let active17: [(v: String, enabled: Bool, uninstalling: Bool, awaiting: Bool)] =
        [(v: "17", enabled: true, uninstalling: false, awaiting: false)]

    private func exercise(_ m: DriverManager) {
        let req = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: DriverManager.dextID, queue: .main)
        m.start()
        m.request(req, didFailWithError: NSError(domain: OSSystemExtensionErrorDomain, code: 8))
        m.handleProperties(active17)
        m.handleProperties(active17)
        m.retryConnection()
        m.devTerminateDriver()
        m.publishPad(.default)
        m.unpublishPad()
        m.runTestPattern()
        m.stopTestPattern()
        m.controllerStatusChanged(.active)
        m.neutralNow()
        m.prepareForTermination()
        drain(m)
    }

    func testEngineModeNeverReachesTheDext() {
        let fake = RecordingDext()
        let m = make(.engine, fake)
        exercise(m)
        XCTAssertEqual(fake.calls, [], "no call may reach the injected dext in engine mode")
        XCTAssertFalse(m.devTerminateOutstanding)
        XCTAssertEqual(m.connection, .stopped)
        XCTAssertEqual(m.padState, .off)
    }

    func testDisplayOnlyModeNeverReachesTheDextOrLaunchd() {
        let fake = RecordingDext()
        let m = make(.displayOnly, fake)
        exercise(m)
        XCTAssertEqual(fake.calls, [])
        XCTAssertFalse(m.devTerminateOutstanding)
        XCTAssertTrue(shell.log.isEmpty, "display-only never runs launchctl: \(shell.log)")
    }

    func testEngineModeLoadsTheEngineOnceTheDriverHasSettled() {
        let fake = RecordingDext()
        let m = make(.engine, fake, args: [])
        m.handleProperties(active17)
        drain(m)
        XCTAssertGreaterThanOrEqual(shell.count("print"), 1, "ensureLoaded read the job state")
        XCTAssertEqual(shell.count("bootstrap"), 0, "it was already running")
        XCTAssertEqual(m.state, .active("17"))
    }

    func testInAppModeStillStartsTheRealClient() {
        let fake = RecordingDext()
        let m = make(.inApp, fake, args: [])
        m.start()
        drain(m)
        XCTAssertEqual(fake.calls, ["start"])
        XCTAssertTrue(shell.log.isEmpty)
    }

    func testInAppModeKeepsTheDevAids() {
        let fake = RecordingDext()
        let m = make(.inApp, fake, args: ["--dev-terminate-driver"])
        XCTAssertTrue(m.devTerminateOutstanding)
        drain(m)
        m.retryConnection()
        drain(m)
        XCTAssertEqual(fake.calls, ["retry"])
    }
}

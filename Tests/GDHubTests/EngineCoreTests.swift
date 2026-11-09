import XCTest
import IOKit
@testable import GDHub

/// Records what the engine core asks of the dext connection; tests inject connection states.
final class FakeDext: DextControlling, @unchecked Sendable {
    var onState: ((DextClient.State) -> Void)?
    var calls: [String] = []
    var retryTimes: [UInt64] = []
    var now: () -> UInt64 = { 0 }
    var onRetry: (() -> Void)?
    func start() { calls.append("start") }
    func retry() { calls.append("retry"); retryTimes.append(now()); onRetry?() }
    func stop() { calls.append("stop") }
    func devTerminate() -> kern_return_t { calls.append("devTerminate"); return 0 }
    func emit(_ s: DextClient.State) { onState?(s) }
    var retries: Int { calls.filter { $0 == "retry" }.count }
}

final class EngineCoreTests: XCTestCase {
    private var queue: DispatchQueue!
    private var env: ManualScheduler!
    private var transport: FakeTransport!
    private var dext: FakeDext!
    private var defaults: UserDefaults!
    private var suite = ""
    private var duplicate: String?
    private let connected = DextClient.State.connected(dextBuild: 17)

    override func setUp() {
        queue = DispatchQueue(label: "test.engine")
        env = ManualScheduler()
        transport = FakeTransport(env: env)
        dext = FakeDext()
        dext.now = { [env] in env!.now }
        suite = "gdhub.tests.engine.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        duplicate = nil
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func makeCore(_ options: EngineOptions = EngineOptions(), mapping: ControlMapping = .default) -> EngineCore {
        let sink = VirtualPadSink(queue: queue, transport: transport, clock: { [env] in env!.now }, scheduler: env,
                                  defaults: defaults, duplicateCheck: { [unowned self] _ in self.duplicate })
        return EngineCore(queue: queue, dext: dext, sink: sink, scheduler: env, defaults: defaults,
                          mapping: mapping, options: options)
    }

    private func isPublished(_ core: EngineCore) -> Bool { if case .published = core.padState { return true } else { return false } }

    // MARK: Auto-publish

    func testAutoPublishFiresWhenConnectedAndControllerActive() {
        let core = makeCore()
        queue.sync {
            core.handleDextState(connected)
            XCTAssertEqual(core.padState, .off, "no controller yet")
            core.controllerStatus(.active)
        }
        XCTAssertTrue(isPublished(core))
        XCTAssertEqual(transport.creates.count, 1)
    }

    func testControllerActiveBeforeTheConnectionPublishesOnConnect() {
        let core = makeCore()
        queue.sync {
            core.controllerStatus(.active)
            XCTAssertEqual(core.padState, .off, "not connected yet")
            core.handleDextState(connected)
        }
        XCTAssertTrue(isPublished(core))
    }

    func testNoAutoPublishWhenTurnedOff() {
        defaults.set(false, forKey: EngineCore.autoPublishKey)
        let core = makeCore()
        queue.sync { core.handleDextState(connected); core.controllerStatus(.active) }
        XCTAssertEqual(core.padState, .off)
    }

    func testUnpublishHoldsAutoPublishOffUntilPublish() {
        let core = makeCore()
        queue.sync {
            core.handleDextState(connected)
            core.controllerStatus(.active)
            core.unpublish()
            XCTAssertEqual(core.padState, .off)
            XCTAssertTrue(core.autoPublishHeldOff)
            core.controllerStatus(.asleep)
            core.controllerStatus(.active)
            XCTAssertEqual(core.padState, .off, "held off")
            core.publish(.default)
            XCTAssertFalse(core.autoPublishHeldOff)
        }
        XCTAssertTrue(isPublished(core))
    }

    func testBlockedDuplicateIsRetriedWhenTheControllerBecomesActiveAgain() {
        duplicate = "Xbox Wireless Controller (serial X)"
        let core = makeCore()
        queue.sync { core.handleDextState(connected); core.controllerStatus(.active) }
        XCTAssertEqual(core.padState, .blockedDuplicate("Xbox Wireless Controller (serial X)"))
        duplicate = nil
        queue.sync { core.controllerStatus(.asleep); core.controllerStatus(.active) }
        XCTAssertTrue(isPublished(core))
    }

    // MARK: Neutral, restore

    func testPadGoesNeutralWhenTheControllerSleeps() {
        let core = makeCore()
        queue.sync { core.handleDextState(connected); core.controllerStatus(.active) }
        transport.clear()
        queue.sync { core.controllerStatus(.asleep) }
        XCTAssertEqual(transport.neutrals, 1)
        XCTAssertTrue(isPublished(core), "the pad stays published")
    }

    func testNeutralOnSleepNotification() {
        let core = makeCore()
        queue.sync { core.handleDextState(connected); core.controllerStatus(.active) }
        transport.clear()
        queue.sync { core.neutral() }
        XCTAssertEqual(transport.neutrals, 1)
    }

    func testTransportConnectedRestoresAnEnabledPad() {
        defaults.set(true, forKey: VirtualPadSink.enabledKey)
        defaults.set(PadIdentity.xboxBT16.id, forKey: VirtualPadSink.identityKey)
        let core = makeCore()
        queue.sync { core.handleDextState(connected) }
        XCTAssertEqual(core.padState, .published(PadIdentity.xboxBT16.id))
    }

    func testLosingTheConnectionMakesThePadWaitAndReturnWhenItReconnects() {
        let core = makeCore()
        queue.sync { core.handleDextState(connected); core.controllerStatus(.active) }
        queue.sync { core.handleDextState(.waitingForService) }
        XCTAssertEqual(core.padState, .publishing(PadIdentity.default.id))
        queue.sync { core.handleDextState(connected) }
        XCTAssertTrue(isPublished(core))
    }

    // MARK: Mapping

    func testSetMappingBumpsTheRevisionAndTheSinkRePosts() {
        let core = makeCore()
        queue.sync { core.handleDextState(connected); core.controllerStatus(.active) }
        var frame = GamepadFrame(); frame.buttons = 1                       // button 1 = A in the default mapping
        queue.sync { core.sink.submit(frame: frame, mapping: core.mapping, revision: core.mappingRevision) }
        queue.sync {}
        let before = transport.posts.count
        XCTAssertEqual(before, 1)
        queue.sync { core.sink.submit(frame: frame, mapping: core.mapping, revision: core.mappingRevision) }
        queue.sync {}
        XCTAssertEqual(transport.posts.count, before, "an identical frame under the same revision is dropped")

        var remapped = core.mapping
        remapped.buttons["a"] = .button(5)                                  // A no longer follows button 1
        queue.sync { core.setMapping(remapped) }
        XCTAssertEqual(core.mappingRevision, 1)
        env.advance(by: 20)
        queue.sync { core.sink.submit(frame: frame, mapping: core.mapping, revision: core.mappingRevision) }
        queue.sync {}
        XCTAssertGreaterThan(transport.posts.count, before, "the new revision gets the frame through under the new mapping")
    }

    func testSetMappingWithAnEqualMappingDoesNotBump() {
        let core = makeCore()
        queue.sync { core.setMapping(.default) }
        XCTAssertEqual(core.mappingRevision, 0)
        var m = ControlMapping.default; m.buttons["x"] = .button(9)
        queue.sync { core.setMapping(m); core.setMapping(m) }
        XCTAssertEqual(core.mappingRevision, 1)
    }

    func testPublishingAnUnknownIdentityByNameIsRefused() {
        XCTAssertNil(PadIdentity.named("nope"))
    }

    // MARK: `.exclusive` recovery

    func testExclusiveRetriesAtQuarterHalfOneTwoThenEveryTwoSeconds() {
        let core = makeCore()
        queue.sync { core.handleDextState(.exclusive) }
        let t0 = env.now
        queue.sync { env.advance(by: 249) }
        XCTAssertEqual(dext.retries, 0)
        queue.sync { env.advance(by: 1) }
        XCTAssertEqual(dext.retries, 1)
        queue.sync { env.advance(by: 7500) }                               // t = 7750 ms
        let offsets = dext.retryTimes.map { Int(($0 - t0) / 1_000_000) }
        XCTAssertEqual(offsets, [250, 750, 1750, 3750, 5750, 7750])
    }

    func testRetriesStopWhenConnected() {
        let core = makeCore()
        queue.sync { core.handleDextState(.exclusive) }
        queue.sync { env.advance(by: 800) }
        XCTAssertEqual(dext.retries, 2)
        queue.sync { core.handleDextState(connected) }
        queue.sync { env.advance(by: 20_000) }
        XCTAssertEqual(dext.retries, 2)
    }

    func testRetrySucceedingInsideRetryEndsTheLoop() {
        let core = makeCore()
        dext.onRetry = { [unowned self] in self.dext.emit(self.connected) }
        queue.sync { core.handleDextState(.exclusive) }
        queue.sync { env.advance(by: 20_000) }
        XCTAssertEqual(dext.retries, 1)
        XCTAssertEqual(core.connection, connected)
    }

    func testRetryKeepsGoingWhenTheClientReportsWaitingForService() {
        // DextClient.retry() ends a failed attempt with `.waitingForService`; that must not end the loop.
        let core = makeCore()
        dext.onRetry = { [unowned self] in self.dext.emit(.waitingForService) }
        queue.sync { core.handleDextState(.exclusive) }
        queue.sync { env.advance(by: 3750) }
        XCTAssertEqual(dext.retries, 4)
    }

    func testFailedAlsoRetriesButRejectedAndProtocolMismatchDoNot() {
        var core = makeCore()
        queue.sync { core.handleDextState(.failed(kern_return_t(bitPattern: 0xE000_02C7))) }
        queue.sync { env.advance(by: 300) }
        XCTAssertEqual(dext.retries, 1)

        setUp()
        core = makeCore()
        queue.sync { core.handleDextState(.rejected(kern_return_t(bitPattern: 0xE000_02E2))) }
        queue.sync { env.advance(by: 30_000) }
        XCTAssertEqual(dext.retries, 0, "a signature problem cannot heal by retrying")

        setUp()
        core = makeCore()
        queue.sync { core.handleDextState(.protocolMismatch(dext: 9)) }
        queue.sync { env.advance(by: 30_000) }
        XCTAssertEqual(dext.retries, 0)
    }

    func testShutdownDestroysThePadAndClosesTheConnection() {
        let core = makeCore()
        queue.sync { core.handleDextState(connected); core.controllerStatus(.active) }
        transport.clear()
        queue.sync { core.shutdown() }
        XCTAssertEqual(transport.count(.destroy), 1)
        XCTAssertTrue(dext.calls.contains("stop"))
        XCTAssertEqual(core.padState, .off)
    }

    // MARK: Dev aids

    func testPublishPadDevAidPublishesOnceConnected() {
        let core = makeCore(EngineOptions(arguments: ["--publish-pad", "xbox-bt16"]))
        queue.sync { core.start(); core.handleDextState(connected) }
        XCTAssertEqual(core.padState, .published("xbox-bt16"))
        XCTAssertNil(defaults.object(forKey: VirtualPadSink.enabledKey), "the dev aid does not persist")
        XCTAssertEqual(dext.calls.first, "start")
    }
}

import XCTest
@testable import GDHub

/// The fake stands in for the receiver's Consumer service: no real HID call is made by these tests.
private final class FakeAccess: ConsumerServiceAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var _services: [UInt64]
    private var props: [UInt64: [[String: NSNumber]]] = [:]
    private var _sets: [(id: UInt64, pairs: [[String: NSNumber]])] = []
    private var _setResult = true
    private var _listCalls = 0

    init(services: [UInt64] = [7]) { _services = services }

    var services: [UInt64] { get { lock.withLock { _services } } set { lock.withLock { _services = newValue } } }
    var setResult: Bool { get { lock.withLock { _setResult } } set { lock.withLock { _setResult = newValue } } }
    var sets: [(id: UInt64, pairs: [[String: NSNumber]])] { lock.withLock { _sets } }
    func preset(_ pairs: [[String: NSNumber]], on id: UInt64) { lock.withLock { props[id] = pairs } }
    func property(of id: UInt64) -> [[String: NSNumber]]? { lock.withLock { props[id] } }

    func matchingServiceIDs() -> [UInt64] { lock.withLock { _listCalls += 1; return _services } }
    func userKeyMapping(of id: UInt64) -> [[String: NSNumber]]? { lock.withLock { props[id] } }
    func setUserKeyMapping(_ pairs: [[String: NSNumber]], on id: UInt64) -> Bool {
        lock.withLock {
            guard _services.contains(id) else { return false }
            _sets.append((id, pairs))
            if _setResult { props[id] = pairs }
            return _setResult
        }
    }
}

final class ConsumerKeyMuteTests: XCTestCase {
    private func mapping(_ remaps: [(String, ControlOutput)] = []) -> ControlMapping {
        var m = ControlMapping()
        for (id, out) in remaps { m.setOutput(out, for: id) }
        return m
    }

    private func make(_ fake: FakeAccess) -> ConsumerKeyMute { ConsumerKeyMute(access: fake, watcher: nil) }

    // MARK: Pure parts

    func testDesiredIsEmptyForDefaultMapping() {
        XCTAssertEqual(ConsumerKeyMute.desired(for: ControlMapping()), [])
        XCTAssertEqual(ConsumerKeyMute.desired(for: .default), [])
    }

    func testDesiredPerKey() {
        XCTAssertEqual(ConsumerKeyMute.desired(for: mapping([("g3", .pad(.rb))])), [0xC_0000_00E9])
        XCTAssertEqual(ConsumerKeyMute.desired(for: mapping([("g2", .nothing)])), [0xC_0000_00EA])
        XCTAssertEqual(ConsumerKeyMute.desired(for: mapping([("g4", .pad(.y))])), [0xC_0000_00E2])
    }

    func testDesiredAllThreeAndReset() {
        var m = mapping([("g2", .nothing), ("g3", .pad(.rb)), ("g4", .pad(.y))])
        XCTAssertEqual(ConsumerKeyMute.desired(for: m), [0xC_0000_00EA, 0xC_0000_00E9, 0xC_0000_00E2])
        m.resetAllOutputs()
        XCTAssertEqual(ConsumerKeyMute.desired(for: m), [])
    }

    func testOtherRemapsDoNotSwitchOffVolume() {
        XCTAssertEqual(ConsumerKeyMute.desired(for: mapping([("g1", .pad(.y)), ("a", .pad(.b)), ("g5", .nothing)])), [])
        // an explicit built-in is the default and is dropped by setOutput
        XCTAssertEqual(ConsumerKeyMute.desired(for: mapping([("g3", .builtIn)])), [])
    }

    func testPairsEncoding() {
        XCTAssertEqual(ConsumerKeyMute.pairs(for: []).count, 0)
        let p = ConsumerKeyMute.pairs(for: [0xC_0000_00EA, 0xC_0000_00E2, 0xC_0000_00E9])
        XCTAssertEqual(p.map { $0["HIDKeyboardModifierMappingSrc"]?.int64Value }, [0xC_0000_00E2, 0xC_0000_00E9, 0xC_0000_00EA])
        XCTAssertTrue(p.allSatisfy { $0["HIDKeyboardModifierMappingDst"]?.int64Value == 0 && $0.count == 2 })
        XCTAssertEqual(ConsumerKeyMute.pairs(for: [0xC_0000_00EA, 0xC_0000_00E2]), ConsumerKeyMute.pairs(for: [0xC_0000_00E2, 0xC_0000_00EA]))
        // Int64 numbers, not 32-bit
        XCTAssertEqual(String(cString: p[0]["HIDKeyboardModifierMappingSrc"]!.objCType), "q")
    }

    func testReadBackComparison() {
        let p = ConsumerKeyMute.pairs(for: [0xC_0000_00E9])
        XCTAssertTrue(ConsumerKeyMute.readBack(p, matches: p))
        XCTAssertTrue(ConsumerKeyMute.readBack(nil, matches: []))
        XCTAssertTrue(ConsumerKeyMute.readBack([], matches: []))
        XCTAssertFalse(ConsumerKeyMute.readBack(nil, matches: p))
        XCTAssertFalse(ConsumerKeyMute.readBack(ConsumerKeyMute.pairs(for: [0xC_0000_00EA]), matches: p))
    }

    // MARK: Applying

    func testStartSetsExactlyOnMatchingServices() {
        let fake = FakeAccess(services: [7, 9])
        let mute = make(fake)
        mute.start(mapping: mapping([("g3", .pad(.rb))]))
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.map(\.id), [7, 9])
        XCTAssertTrue(fake.sets.allSatisfy { $0.pairs == ConsumerKeyMute.pairs(for: [0xC_0000_00E9]) })
    }

    func testNothingIsSetWithoutAService() {
        let fake = FakeAccess(services: [])
        let mute = make(fake)
        mute.start(mapping: mapping([("g3", .pad(.rb))]))
        mute.update(mapping([("g2", .nothing)]))
        mute.waitUntilIdle()
        XCTAssertTrue(fake.sets.isEmpty)
    }

    func testDefaultMappingMakesNoSet() {
        let fake = FakeAccess()
        let mute = make(fake)
        mute.start(mapping: ControlMapping())
        mute.waitUntilIdle()
        XCTAssertTrue(fake.sets.isEmpty)
    }

    func testStaleMapLeftBehindIsClearedAtStart() {
        let fake = FakeAccess()
        fake.preset(ConsumerKeyMute.pairs(for: [0xC_0000_00E9]), on: 7)        // an earlier writer died without clearing
        let mute = make(fake)
        mute.start(mapping: ControlMapping())
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, 1)
        XCTAssertEqual(fake.sets.first?.pairs.count, 0)
    }

    func testMappingChangeThatKeepsTheDesiredSetMakesNoCall() {
        let fake = FakeAccess()
        let mute = make(fake)
        mute.start(mapping: mapping([("g3", .pad(.rb))]))
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, 1)
        mute.update(mapping([("g3", .pad(.x)), ("a", .pad(.b))]))              // other output, same desired set
        mute.update(mapping([("g3", .nothing)]))
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, 1)
    }

    func testMappingChangeThatChangesTheSetApplies() {
        let fake = FakeAccess()
        let mute = make(fake)
        mute.start(mapping: mapping([("g3", .pad(.rb))]))
        mute.update(mapping([("g3", .pad(.rb)), ("g2", .nothing)]))
        mute.update(ControlMapping())
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.map(\.pairs.count), [1, 2, 0])
        XCTAssertEqual(fake.property(of: 7)?.count, 0)
    }

    func testServiceReappearingReapplies() {
        let fake = FakeAccess(services: [7])
        let mute = make(fake)
        mute.start(mapping: mapping([("g4", .pad(.y))]))
        mute.waitUntilIdle()
        fake.services = [11]                                                    // the receiver re-enumerated: a new service
        mute.serviceAppeared()
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.map(\.id), [7, 11])
        XCTAssertEqual(fake.sets.last?.pairs, ConsumerKeyMute.pairs(for: [0xC_0000_00E2]))
        mute.serviceAppeared()                                                  // same service again: nothing to do
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, 2)
    }

    func testWakeAppliesAgainOnTheSameService() {
        let fake = FakeAccess()
        let mute = make(fake)
        mute.start(mapping: mapping([("g2", .nothing)]))
        mute.waitUntilIdle()
        mute.didWake()
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.map(\.id), [7, 7])
    }

    func testStopClearsWithEmptyArray() {
        let fake = FakeAccess()
        let mute = make(fake)
        mute.start(mapping: mapping([("g3", .pad(.rb))]))
        mute.waitUntilIdle()
        mute.stop()
        XCTAssertEqual(fake.sets.count, 2)
        XCTAssertEqual(fake.sets.last?.id, 7)
        XCTAssertEqual(fake.sets.last?.pairs.count, 0)
        XCTAssertEqual(fake.property(of: 7)?.count, 0)
    }

    func testStopWithNothingSetMakesNoCall() {
        let fake = FakeAccess()
        let mute = make(fake)
        mute.start(mapping: ControlMapping())
        mute.stop()
        XCTAssertTrue(fake.sets.isEmpty)
    }

    func testNonWriterNeverSetsOrClears() {
        let fake = FakeAccess()
        fake.preset(ConsumerKeyMute.pairs(for: [0xC_0000_00E9]), on: 7)         // someone else's map
        let mute = make(fake)                                                   // never started
        mute.update(mapping([("g3", .pad(.rb))]))
        mute.didWake()
        mute.serviceAppeared()
        mute.stop()
        mute.waitUntilIdle()
        XCTAssertTrue(fake.sets.isEmpty)
        XCTAssertEqual(fake.property(of: 7)?.count, 1)

        let mute2 = make(fake)                                                  // started, stopped, then told things
        mute2.start(mapping: ControlMapping())
        mute2.stop()
        let afterStop = fake.sets.count
        mute2.update(mapping([("g2", .nothing)]))
        mute2.didWake()
        mute2.stop()
        mute2.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, afterStop)
    }

    func testRefusedSetIsRetriedOnNextTriggerNotLooped() {
        let fake = FakeAccess()
        fake.setResult = false
        let mute = make(fake)
        mute.start(mapping: mapping([("g3", .pad(.rb))]))
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, 1)                                      // one refused attempt
        Thread.sleep(forTimeInterval: 0.2)                                      // not looped: no further call without a trigger
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, 1)
        fake.setResult = true
        mute.update(mapping([("g3", .nothing)]))                                // same desired set, but the last apply failed: retry
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, 2)
        XCTAssertEqual(fake.property(of: 7)?.count, 1)                          // the retry went through
        mute.update(mapping([("g3", .pad(.x))]))                                // now applied: no more calls
        mute.waitUntilIdle()
        XCTAssertEqual(fake.sets.count, 2)
    }

    func testRefusedSetCountsOneAttemptPerTrigger() {
        final class Counting: ConsumerServiceAccess, @unchecked Sendable {
            let lock = NSLock(); var attempts = 0
            func matchingServiceIDs() -> [UInt64] { [7] }
            func userKeyMapping(of id: UInt64) -> [[String: NSNumber]]? { nil }
            func setUserKeyMapping(_ pairs: [[String: NSNumber]], on id: UInt64) -> Bool { lock.withLock { attempts += 1 }; return false }
        }
        let c = Counting()
        let mute = ConsumerKeyMute(access: c, watcher: nil)
        mute.start(mapping: mapping([("g3", .pad(.rb))]))
        mute.waitUntilIdle()
        XCTAssertEqual(c.lock.withLock { c.attempts }, 1)
        mute.update(mapping([("g3", .nothing)]))
        mute.waitUntilIdle()
        XCTAssertEqual(c.lock.withLock { c.attempts }, 2)
    }

    // MARK: The real calls stay scoped

    func testRealAccessNeverSetsGloballyAndMatchesExactly() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/GDHub/HID/ConsumerKeyMute.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("IOHIDEventSystemClientSetProperty"))
        XCTAssertEqual(text.components(separatedBy: "IOHIDServiceClientSetProperty(").count - 1, 1)
        XCTAssertEqual(ConsumerKeyMute.vendorID, 0x1B1C)
        XCTAssertEqual(ConsumerKeyMute.productID, 0x3A08)
        XCTAssertEqual(ConsumerKeyMute.usagePage, 0x0C)
    }
}

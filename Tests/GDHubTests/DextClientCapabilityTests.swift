import XCTest
import GDHubDextCore
@testable import GDHub

/// Capability negotiation of `DextClient` against fake dexts: build 17 (hello capabilities == 1, no selector above 8)
/// and a T3 dext (CAP_ROOT_PAD). The fake sits where IOConnectCallMethod would; the client logic above it is the real one.
final class DextClientCapabilityTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.vhid")

    /// Records every call. Behaves like the dext named by `capabilities`.
    private final class FakeDext: @unchecked Sendable {
        var calls: [(selector: UInt32, scalarsIn: [UInt64], outCount: Int, structCap: Int, structIn: [UInt8]?)] = []
        var mapReason: UInt32 = 0
        var adoptNext = false
        let capabilities: UInt64
        var status2Bytes: [UInt8] = []
        init(capabilities: UInt64) { self.capabilities = capabilities }

        func call(_ selector: UInt32, _ scalarsIn: [UInt64], _ outCount: Int, _ structCap: Int, _ structIn: [UInt8]?) -> DextRawResult {
            calls.append((selector, scalarsIn, outCount, structCap, structIn))
            let hasRootPad = capabilities & DextProtocol.Capability.rootPad != 0
            switch selector {
            case DextProtocol.Selector.getStatus:
                return DextRawResult(kr: KERN_SUCCESS, scalars: [1, 100, 0, 0, 0])
            case DextProtocol.Selector.setForwarding where hasRootPad:
                let hasTap = capabilities & DextProtocol.Capability.tap != 0
                let hasXlate = capabilities & DextProtocol.Capability.xlate != 0
                let hasLive = capabilities & DextProtocol.Capability.live != 0
                let ok = (scalarsIn[1] == 0 || hasLive) && (scalarsIn[0] == 0 || (scalarsIn[0] == 1 && hasTap) || (scalarsIn[0] == 2 && hasXlate) || (scalarsIn[0] == 3 && hasLive))
                return ok ? DextRawResult(kr: KERN_SUCCESS, scalars: [0, hasTap ? 1 : 0, 1, 0]) : DextRawResult(kr: DextProtocol.krUnsupported)
            case DextProtocol.Selector.setMapping where capabilities & DextProtocol.Capability.xlate != 0:
                return DextRawResult(kr: KERN_SUCCESS, scalars: [mapReason == 0 ? 7 : 0, UInt64(mapReason)])
            case DextProtocol.Selector.createDevice2 where capabilities & DextProtocol.Capability.live != 0:
                return DextRawResult(kr: KERN_SUCCESS, scalars: [adoptNext ? 1 : 0, adoptNext ? 2 : 1])
            case DextProtocol.Selector.getStatus2 where hasRootPad:
                return DextRawResult(kr: KERN_SUCCESS, bytes: Array(status2Bytes.prefix(structCap)))
            default:
                // build 17: `if (selector >= GDHUB_SEL_COUNT) return kIOReturnBadArgument` with GDHUB_SEL_COUNT == 9
                return DextRawResult(kr: DextProtocol.krBadArgument)
            }
        }
    }

    private func client(_ fake: FakeDext) -> DextClient {
        let c = DextClient(queue: queue)
        queue.sync { c.attachFakeDext(capabilities: fake.capabilities, call: fake.call) }
        return c
    }

    private func status2Bytes() -> [UInt8] {
        var s = gdhr_snap(); s.build = 18; s.pid = 321; s.nonce = 99; s.padSource = UInt32(GDHR_SRC_UC); s.padState = UInt32(GDHR_PAD_LIVE)
        var hop = gdh_summary(count: 5, p50Ns: 25_000, p99Ns: 50_000, maxNs: 60_000, meanNs: 30_000)
        var hr = gdh_summary(count: 5, p50Ns: 50_000, p99Ns: 75_000, maxNs: 80_000, meanNs: 55_000)
        var buf = [UInt8](repeating: 0, count: 512)
        let n = gdh_status2_pack(&buf, 512, &s, &hop, &hr, 2, nil, nil)
        return Array(buf.prefix(n))
    }

    // MARK: T7: CAP_LIVE both ways

    private let build23 = DextProtocol.Capability.pad | DextProtocol.Capability.rootPad | DextProtocol.Capability.tap | DextProtocol.Capability.xlate
    private var buildLive: UInt64 { build23 | DextProtocol.Capability.live }

    func testNewAppWithBuild23DextNeverSendsLiveTheFlagsOrSelector12() {
        let fake = FakeDext(capabilities: build23)
        let c = client(fake)
        queue.sync {
            XCTAssertFalse(c.hasLive); XCTAssertFalse(c.supportsPauseDrill)
            XCTAssertEqual(c.setForwarding(DextProtocol.Forwarding.live).kr, DextProtocol.krUnsupported)
            XCTAssertEqual(c.pauseTap(state: 2, ms: 5000), DextProtocol.krUnsupported)
            XCTAssertEqual(c.releasePad(), DextProtocol.krUnsupported)
            let spec = try! PadIdentity.default.spec()
            let r = c.createDevice2(spec)
            XCTAssertFalse(r.adopted, "without CAP_LIVE it is createDevice and never adopts")
            XCTAssertTrue(fake.calls.allSatisfy { $0.selector != DextProtocol.Selector.createDevice2 && $0.selector != DextProtocol.Selector.setForwarding },
                          "selector 12 and LIVE / flags never reach a build-23 dext: \(fake.calls.map(\.selector))")
            XCTAssertEqual(c.setForwarding(DextProtocol.Forwarding.shadow).kr, KERN_SUCCESS, "SHADOW still works")
        }
    }

    func testNewAppWithALiveDextSendsLiveFlagsAndSelector12() throws {
        let fake = FakeDext(capabilities: buildLive)
        let c = client(fake)
        queue.sync {
            XCTAssertTrue(c.hasLive); XCTAssertTrue(c.supportsPauseDrill)
            XCTAssertEqual(c.setForwarding(DextProtocol.Forwarding.live).kr, KERN_SUCCESS)
            XCTAssertEqual(fake.calls.last?.scalarsIn, [3, 0, 0])
            XCTAssertEqual(c.pauseTap(state: 3, ms: 5000), KERN_SUCCESS)
            XCTAssertEqual(fake.calls.last?.scalarsIn, [3, 0x100, 5000], "the pause flag carries the state the tap is in")
            XCTAssertEqual(c.releasePad(), KERN_SUCCESS)
            XCTAssertEqual(fake.calls.last?.scalarsIn, [0, 0x200, 0])
            XCTAssertEqual(c.setForwarding(4).kr, DextProtocol.krUnsupported)
            fake.adoptNext = true
            let r = c.createDevice2(try! PadIdentity.default.spec())
            XCTAssertEqual(r.kr, KERN_SUCCESS); XCTAssertTrue(r.adopted); XCTAssertEqual(r.padSource, 2)
            let c12 = fake.calls.last { $0.selector == 12 }
            XCTAssertNotNil(c12); XCTAssertNotNil(c12?.structIn)
            XCTAssertEqual(fake.calls.last?.selector, 9, "an unsupervised client that adopted a pad the tap drives asks for INERT again: the one it sent after hello had no effect (it owned nothing)")
            XCTAssertEqual(fake.calls.last?.scalarsIn, [0, 0, 0])
            fake.adoptNext = false
            let r2 = c.createDevice2(try! PadIdentity.default.spec())
            XCTAssertFalse(r2.adopted); XCTAssertEqual(r2.padSource, 1)
        }
    }

    /// A build-23 app against the new dext: it never sets bit 11, sends none of the new selectors or flags and reads the first 480
    /// bytes of status2; every number it relies on is where it was.
    func testBuild23AppContractsAgainstTheLiveDext() {
        XCTAssertEqual(DextProtocol.Capability.live, 1 << 11)
        XCTAssertEqual(build23 & DextProtocol.Capability.live, 0)
        XCTAssertEqual(DextProtocol.Selector.getStatus2, 11); XCTAssertEqual(DextProtocol.Selector.setMapping, 10)
        XCTAssertEqual(DextProtocol.Forwarding.inert, 0); XCTAssertEqual(DextProtocol.Forwarding.count, 1); XCTAssertEqual(DextProtocol.Forwarding.shadow, 2)
        XCTAssertTrue(DextProtocol.Forwarding.isAccepted(state: 2, flags: 0)); XCTAssertEqual(DextStatus2.Offset.parityOut02 + 2, 478)
        XCTAssertEqual(DextProtocol.version, 1)
    }

    // MARK: new app, old dext (build 17)

    func testNewAppWithOldDextNeverCallsTheNewSelectors() {
        let fake = FakeDext(capabilities: DextProtocol.Capability.pad)          // exactly what build 17 reports
        let c = client(fake)
        queue.sync {
            XCTAssertFalse(c.hasRootPad)
            XCTAssertNil(c.status2(), "no CAP_ROOT_PAD: the engine's meter line simply has no dext part")
            let f = c.setForwardingInert()
            XCTAssertEqual(f.kr, DextProtocol.krUnsupported); XCTAssertNil(f.result)
            XCTAssertTrue(fake.calls.isEmpty, "selectors 9 and 11 were not even sent: \(fake.calls.map(\.selector))")
        }
    }

    func testOldSelectorSetStillWorksWithOldAndNewDext() {
        for caps in [DextProtocol.Capability.pad, DextProtocol.Capability.pad | DextProtocol.Capability.rootPad] {
            let fake = FakeDext(capabilities: caps)
            let c = client(fake)
            queue.sync {
                let s = c.status()
                XCTAssertEqual(s?.deviceMask, 1, "getStatus (selector 7, five scalars) is unchanged, caps \(caps)")
                XCTAssertEqual(s?.postCount, 100)
                XCTAssertEqual(fake.calls.last?.selector, 7); XCTAssertEqual(fake.calls.last?.outCount, 5)
            }
        }
    }

    // MARK: new app, new dext

    func testNewAppWithNewDextReadsStatus2() throws {
        let fake = FakeDext(capabilities: DextProtocol.Capability.pad | DextProtocol.Capability.rootPad)
        fake.status2Bytes = status2Bytes()
        let c = client(fake)
        queue.sync {
            XCTAssertTrue(c.hasRootPad)
            let s = c.status2()
            XCTAssertEqual(s?.build, 18); XCTAssertEqual(s?.rootPid, 321); XCTAssertEqual(s?.source, .userClient)
            XCTAssertEqual(s?.hr.p99Ns, 75_000)
            XCTAssertEqual(s?.meterLogText, "dext: hop p50/p99/max/mean 25/50/60/30.0 us hr 50/75/80/55.0 us n=5 win=2")
            XCTAssertEqual(fake.calls.count, 1)
            XCTAssertEqual(fake.calls[0].selector, 11)
            XCTAssertEqual(fake.calls[0].structCap, 1024, "the app offers the maximum; the dext returns what it has")
            XCTAssertEqual(fake.calls[0].outCount, 0)
        }
    }

    func testStatus2ToleratesAShorterReply() {
        let fake = FakeDext(capabilities: DextProtocol.Capability.pad | DextProtocol.Capability.rootPad)
        fake.status2Bytes = Array(status2Bytes().prefix(64))
        let c = client(fake)
        queue.sync {
            let s = c.status2()
            XCTAssertEqual(s?.build, 18); XCTAssertEqual(s?.hr.count, 0)
            XCTAssertNil(s?.meterLogText)
        }
    }

    func testSetForwardingInertSendsStateFlagsAndTime() {
        let fake = FakeDext(capabilities: DextProtocol.Capability.pad | DextProtocol.Capability.rootPad)
        let c = client(fake)
        queue.sync {
            let f = c.setForwardingInert()
            XCTAssertEqual(f.kr, KERN_SUCCESS)
            XCTAssertEqual(f.result, DextForwardingResult(words: [0, 0, 1, 0]))
            XCTAssertEqual(fake.calls.last?.selector, 9)
            XCTAssertEqual(fake.calls.last?.scalarsIn, [0, 0, 0], "state INERT, no flags, argMs 0")
            XCTAssertEqual(fake.calls.last?.outCount, 4)
        }
    }

    func testStatus2ErrorGivesNil() {
        let fake = FakeDext(capabilities: DextProtocol.Capability.pad | DextProtocol.Capability.rootPad)
        let c = DextClient(queue: queue)
        queue.sync {
            c.attachFakeDext(capabilities: fake.capabilities) { _, _, _, _, _ in DextRawResult(kr: DextProtocol.krNotReady) }
            XCTAssertNil(c.status2())
        }
    }

    func testNotConnectedClientDoesNothing() {
        let c = DextClient(queue: queue)
        queue.sync {
            XCTAssertNil(c.status2())
            XCTAssertEqual(c.setForwardingInert().kr, DextProtocol.krNotReady)
            XCTAssertEqual(c.capabilities, 0)
        }
    }

    // MARK: T4: CAP_TAP, COUNT, unsupervised clients

    private let build19 = DextProtocol.Capability.pad | DextProtocol.Capability.rootPad          // 257: what build 19 reports
    private let build20 = DextProtocol.Capability.pad | DextProtocol.Capability.rootPad | DextProtocol.Capability.tap

    func testNewAppWithBuild19DextNeverSendsCount() {
        let fake = FakeDext(capabilities: build19)
        let c = client(fake)
        queue.sync {
            XCTAssertFalse(c.hasTap); XCTAssertTrue(c.hasRootPad)
            let r = c.setForwarding(DextProtocol.Forwarding.count)
            XCTAssertEqual(r.kr, DextProtocol.krUnsupported); XCTAssertNil(r.result)
            XCTAssertTrue(fake.calls.isEmpty, "COUNT is not sent without CAP_TAP")
            XCTAssertEqual(c.setForwarding(DextProtocol.Forwarding.inert).kr, KERN_SUCCESS, "INERT still works on build 19 (selector 9 exists)")
            XCTAssertEqual(fake.calls.last?.scalarsIn, [0, 0, 0])
            XCTAssertEqual(c.setForwarding(2).kr, DextProtocol.krUnsupported, "SHADOW does not exist yet")
            XCTAssertEqual(fake.calls.count, 1)
        }
    }

    func testNewAppWithTapDextSendsCountAndInert() {
        let fake = FakeDext(capabilities: build20)
        let c = client(fake)
        queue.sync {
            XCTAssertTrue(c.hasTap)
            let r = c.setForwarding(DextProtocol.Forwarding.count)
            XCTAssertEqual(r.kr, KERN_SUCCESS)
            XCTAssertEqual(fake.calls.last?.scalarsIn, [1, 0, 0], "state COUNT, no flags, argMs 0")
            XCTAssertEqual(fake.calls.last?.outCount, 4)
            XCTAssertEqual(c.setForwarding(3).kr, DextProtocol.krUnsupported, "LIVE is not sent")
            XCTAssertEqual(fake.calls.count, 1)
        }
    }

    func testSupervisedClientDoesNotSendInertAfterAdoption() {
        let fake = FakeDext(capabilities: buildLive)
        let sup = DextClient(queue: queue, supervised: true)
        queue.sync { sup.attachFakeDext(capabilities: fake.capabilities, call: fake.call) }
        fake.adoptNext = true
        queue.sync {
            let r = sup.createDevice2(try! PadIdentity.default.spec())
            XCTAssertTrue(r.adopted)
        }
        XCTAssertEqual(fake.calls.map(\.selector), [12], "the engine's TapSupervisor decides what state the adopted pad gets")
    }

    func testUnsupervisedClientSendsInertAfterHelloOnlyToATapDext() {
        let tapDext = FakeDext(capabilities: build20)
        let unsup = DextClient(queue: queue, supervised: false)
        queue.sync { unsup.attachFakeDext(capabilities: tapDext.capabilities, call: tapDext.call); unsup.sendInitialForwarding() }
        XCTAssertEqual(tapDext.calls.map(\.selector), [9]); XCTAssertEqual(tapDext.calls.first?.scalarsIn, [0, 0, 0], "INERT")

        let sup = DextClient(queue: queue, supervised: true)
        let tapDext2 = FakeDext(capabilities: build20)
        queue.sync { sup.attachFakeDext(capabilities: tapDext2.capabilities, call: tapDext2.call); sup.sendInitialForwarding() }
        XCTAssertTrue(tapDext2.calls.isEmpty, "the engine's TapSupervisor decides, not the client")

        let old = FakeDext(capabilities: build19)
        let unsup2 = DextClient(queue: queue)
        queue.sync { unsup2.attachFakeDext(capabilities: old.capabilities, call: old.call); unsup2.sendInitialForwarding() }
        XCTAssertTrue(old.calls.isEmpty, "a build-19 dext has no tap: nothing is sent")
        XCTAssertFalse(DextClient(queue: queue).supervised, "unsupervised is the default")
    }

    /// Old app (build 19) against a T4 dext: it calls only selectors 0-9 with INERT and reads the first 172 status2 bytes,
    /// and ignores the capability bit it does not know. Everything it relies on must be where it was.
    func testBuild19AppContractsAreUnchanged() {
        typealias O = DextStatus2.Offset
        XCTAssertEqual([O.version, O.size, O.build, O.nonce, O.rootPid, O.desiredState, O.padSource, O.padLive, O.ownerPresent,
                        O.ucPosts, O.ucRejected, O.neutralPosts, O.postErrors, O.syncViolations, O.padCreates, O.padDestroys,
                        O.createFails, O.outputsSeen, O.outputsNoOwner, O.createEarly, O.padSpecCRC, O.meterWindows],
                       [0, 2, 4, 8, 16, 20, 21, 22, 23, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 116])
        XCTAssertEqual([O.hopCount, O.hopP50, O.hopP99, O.hopMax, O.hopMean, O.hrCount, O.hrP50, O.hrP99, O.hrMax, O.hrMean,
                        O.syncInline, O.topology, O.probeExt, O.probeSubmit], [120, 124, 128, 132, 136, 140, 144, 148, 152, 156, 160, 168, 169, 170])
        XCTAssertEqual(DextProtocol.Capability.pad | DextProtocol.Capability.rootPad, 257)
        XCTAssertEqual(DextProtocol.Capability.tap, 0x200)
        XCTAssertEqual(DextProtocol.Selector.setForwarding, 9); XCTAssertEqual(DextProtocol.Selector.getStatus2, 11)
        XCTAssertEqual(DextProtocol.Forwarding.inert, 0, "an old app's INERT request is still INERT")
        XCTAssertEqual(DextProtocol.version, 1)
    }
}

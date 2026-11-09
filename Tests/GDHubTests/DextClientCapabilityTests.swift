import XCTest
import GDHubDextCore
@testable import GDHub

/// Capability negotiation of `DextClient` against fake dexts: build 17 (hello capabilities == 1, no selector above 8)
/// and a T3 dext (CAP_ROOT_PAD). The fake sits where IOConnectCallMethod would; the client logic above it is the real one.
final class DextClientCapabilityTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.vhid")

    /// Records every call. Behaves like the dext named by `capabilities`.
    private final class FakeDext: @unchecked Sendable {
        var calls: [(selector: UInt32, scalarsIn: [UInt64], outCount: Int, structCap: Int)] = []
        let capabilities: UInt64
        var status2Bytes: [UInt8] = []
        init(capabilities: UInt64) { self.capabilities = capabilities }

        func call(_ selector: UInt32, _ scalarsIn: [UInt64], _ outCount: Int, _ structCap: Int) -> DextRawResult {
            calls.append((selector, scalarsIn, outCount, structCap))
            let hasRootPad = capabilities & DextProtocol.Capability.rootPad != 0
            switch selector {
            case DextProtocol.Selector.getStatus:
                return DextRawResult(kr: KERN_SUCCESS, scalars: [1, 100, 0, 0, 0])
            case DextProtocol.Selector.setForwarding where hasRootPad:
                return scalarsIn[0] == 0 && scalarsIn[1] == 0 ? DextRawResult(kr: KERN_SUCCESS, scalars: [0, 0, 1, 0])
                                                              : DextRawResult(kr: DextProtocol.krUnsupported)
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
        let n = gdh_status2_pack(&buf, 512, &s, &hop, &hr, 2)
        return Array(buf.prefix(n))
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
            XCTAssertEqual(fake.calls[0].structCap, 512, "the app offers the maximum; the dext returns what it has")
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
            c.attachFakeDext(capabilities: fake.capabilities) { _, _, _, _ in DextRawResult(kr: DextProtocol.krNotReady) }
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
}

import Foundation
import IOKit
import os

/// The members of the dext connection that `DriverManager` and the engine drive (design: engine-agent-plan §6.1).
/// `DextClient` conforms; `InertDext` stands in where a process must never say hello to the dext.
protocol DextControlling: AnyObject, Sendable {
    func start()
    func retry()
    func stop()
    @discardableResult func devTerminate() -> kern_return_t
    var onState: ((DextClient.State) -> Void)? { get set }
}

/// What the status poller reads from the connection.
protocol DextStatusSource: AnyObject, Sendable {
    func status() -> DextStatus?
}

/// T3: the dext's own counters and `hop`/`hr` summary (needs `DextProtocol.Capability.rootPad`).
protocol DextStatus2Source: AnyObject {
    func status2() -> DextStatus2?
}

/// Everything a process needs from the dext connection.
typealias DextBackend = DextControlling & PadTransport & DextStatusSource

extension DextClient: DextControlling, DextStatusSource, DextStatus2Source {}

/// No IOKit at all: every call is a no-op and the state stays `.stopped`. Used by the GUI in engine and display-only
/// mode, so none of its code paths can ever open the dext and say hello.
final class InertDext: DextBackend, @unchecked Sendable {
    var onState: ((DextClient.State) -> Void)?
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
    private var logged = false

    private func note(_ what: String) {
        guard !logged else { return }
        logged = true
        Self.log.debug("inert dext: \(what, privacy: .public) ignored (engine owns the driver)")
    }

    func start() { note("start") }
    func retry() { note("retry") }
    func stop() {}
    func devTerminate() -> kern_return_t { note("devTerminate"); return DextProtocol.krNotReady }
    func status() -> DextStatus? { nil }

    func createDevice(_ spec: DeviceSpec) -> kern_return_t { DextProtocol.krNotReady }
    func destroyDevice(slot: UInt8) -> kern_return_t { DextProtocol.krNotReady }
    func post(slot: UInt8, report: [UInt8]) -> kern_return_t { DextProtocol.krNotReady }
    func postNeutral(slot: UInt8) -> kern_return_t { DextProtocol.krNotReady }
    func heartbeat() -> kern_return_t { DextProtocol.krNotReady }
}


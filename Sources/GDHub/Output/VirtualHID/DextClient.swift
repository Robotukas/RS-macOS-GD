import Foundation
import IOKit
import os

/// Talks to the GDHub DriverKit extension through its user client (design §5.2).
/// Every method and every callback runs on `queue` (the app's `vhidQueue`).
final class DextClient: @unchecked Sendable {   // confined to `queue`
    enum State: Equatable {
        case stopped
        case waitingForService
        case connected(dextBuild: UInt64)
        case rejected(kern_return_t)            // 0xE00002E2: caller is not signed by the dext's team
        case exclusive                          // 0xE00002C5: another GDHub owns the dext
        case protocolMismatch(dext: UInt64)
        case failed(kern_return_t)
    }

    static let dextID = "com.interlinked.gdhub.VirtualHID"
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
    private static let heartbeatInterval: DispatchTimeInterval = .milliseconds(500)

    var onState: ((State) -> Void)?             // called on queue
    var onOutput: ((OutputReport) -> Void)?     // called on queue
    private(set) var state: State = .stopped

    private let queue: DispatchQueue
    private let appBuild: UInt64
    private var started = false
    private var port: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var termIterator: io_iterator_t = 0
    private var service: io_service_t = 0
    private var connect: io_connect_t = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastOutputSequence: UInt64?

    init(queue: DispatchQueue) {
        self.queue = queue
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        appBuild = UInt64(v ?? "") ?? 0
    }

    // MARK: Start / stop

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !started else { return }
        started = true
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)
        self.port = port
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let matched: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<DextClient>.fromOpaque(refcon).takeUnretainedValue().handleMatched(iterator)
        }
        let terminated: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<DextClient>.fromOpaque(refcon).takeUnretainedValue().handleTerminated(iterator)
        }
        // IOServiceAddMatchingNotification consumes the dictionary, so build one per call.
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), matched, refcon, &matchIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), terminated, refcon, &termIterator)
        setState(.waitingForService)
        // Draining arms both notifications and handles a service that already exists.
        handleTerminated(termIterator)
        handleMatched(matchIterator)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started else { return }
        started = false
        closeConnection()
        if matchIterator != 0 { IOObjectRelease(matchIterator); matchIterator = 0 }
        if termIterator != 0 { IOObjectRelease(termIterator); termIterator = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        setState(.stopped)
    }

    private static func matching() -> CFDictionary {
        let dict = IOServiceMatching("IOUserService") as NSMutableDictionary
        dict[kIOPropertyMatchKey] = ["IOUserServerName": dextID]
        return dict
    }

    // MARK: Service events

    private func handleMatched(_ iterator: io_iterator_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        while case let svc = IOIteratorNext(iterator), svc != 0 {
            if connect != 0 || service != 0 { IOObjectRelease(svc); continue }   // already connected to one
            open(svc)
        }
    }

    private func handleTerminated(_ iterator: io_iterator_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        while case let svc = IOIteratorNext(iterator), svc != 0 {
            if service != 0, IOObjectIsEqualTo(svc, service) != 0 {
                Self.log.info("dext service terminated; closing connection")
                closeConnection()
                setState(.waitingForService)
            }
            IOObjectRelease(svc)
        }
    }

    private func open(_ svc: io_service_t) {
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(svc, mach_task_self_, DextProtocol.userClientType, &conn)
        guard kr == KERN_SUCCESS else {
            Self.log.error("IOServiceOpen failed: 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
            IOObjectRelease(svc)
            setState(.failed(kr))
            return
        }
        service = svc
        connect = conn
        lastOutputSequence = nil

        var inp: [UInt64] = [UInt64(DextProtocol.version), appBuild]
        var out = [UInt64](repeating: 0, count: DextHello.scalarCount)
        var n = UInt32(DextHello.scalarCount)
        let hr = IOConnectCallScalarMethod(connect, DextProtocol.Selector.hello, &inp, UInt32(inp.count), &out, &n)
        switch hr {
        case KERN_SUCCESS:
            break
        case DextProtocol.krNotPermitted:
            Self.log.error("hello refused: caller is not signed by the driver's team (0xE00002E2)")
            closeConnection(); setState(.rejected(hr)); return
        case DextProtocol.krExclusiveAccess:
            Self.log.error("hello refused: another GDHub owns the driver (0xE00002C5)")
            closeConnection(); setState(.exclusive); return
        default:
            Self.log.error("hello failed: 0x\(String(UInt32(bitPattern: hr), radix: 16), privacy: .public)")
            closeConnection(); setState(.failed(hr)); return
        }
        guard out[0] == UInt64(DextProtocol.version) else {
            Self.log.error("protocol mismatch: dext v\(out[0]) build \(out[1]), app v\(DextProtocol.version)")
            closeConnection(); setState(.protocolMismatch(dext: out[0])); return
        }
        registerOutput()
        startHeartbeat()
        Self.log.info("connected: driver build \(out[1]) protocol \(out[0]) capabilities \(out[2]) (app build \(self.appBuild))")
        setState(.connected(dextBuild: out[1]))
        if let s = status() {
            Self.log.info("status: devices=\(s.deviceMask) posts=\(s.postCount) watchdogFires=\(s.watchdogFires) outputs=\(s.outputCount) drops=\(s.outputDrops)")
        }
    }

    private func closeConnection() {
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        if connect != 0 { IOServiceClose(connect); connect = 0 }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onState?(new)
    }

    // MARK: Calls

    @discardableResult
    func heartbeat() -> kern_return_t {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connect != 0 else { return DextProtocol.krNotReady }
        return IOConnectCallScalarMethod(connect, DextProtocol.Selector.heartbeat, nil, 0, nil, nil)
    }

    func status() -> DextStatus? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connect != 0 else { return nil }
        var out = [UInt64](repeating: 0, count: DextStatus.scalarCount)
        var n = UInt32(DextStatus.scalarCount)
        let kr = IOConnectCallScalarMethod(connect, DextProtocol.Selector.getStatus, nil, 0, &out, &n)
        guard kr == KERN_SUCCESS else {
            Self.log.error("getStatus failed: 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
            return nil
        }
        return DextStatus(words: out)
    }

    // The dext's watchdog neutralises the pad after 2 s without activity (design §3.10). D2 sends heartbeats
    // while connected; from D3 on the sink does this while a device is published.
    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        t.setEventHandler { [weak self] in self?.heartbeat() }
        t.resume()
        heartbeatTimer = t
    }

    // MARK: Async output (rumble, D5 decodes it)

    private static let outputCallback: IOAsyncCallback = { refcon, result, args, numArgs in
        guard let refcon, let args, result == kIOReturnSuccess else { return }
        let words = (0..<Int(numArgs)).map { UInt64(UInt(bitPattern: args[$0])) }
        Unmanaged<DextClient>.fromOpaque(refcon).takeUnretainedValue().handleOutput(words)
    }

    private func registerOutput() {
        guard let port else { return }
        var ref = [io_user_reference_t](repeating: 0, count: Int(kOSAsyncRef64Count))
        ref[Int(kIOAsyncCalloutFuncIndex)] = io_user_reference_t(UInt(bitPattern: unsafeBitCast(Self.outputCallback, to: Int.self)))
        ref[Int(kIOAsyncCalloutRefconIndex)] = io_user_reference_t(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        let kr = IOConnectCallAsyncScalarMethod(connect, DextProtocol.Selector.registerOutput,
                                                IONotificationPortGetMachPort(port), &ref,
                                                UInt32(kOSAsyncRef64Count), nil, 0, nil, nil)
        if kr != KERN_SUCCESS {
            Self.log.error("registerOutput failed: 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
        } else {
            Self.log.info("output completion registered")
        }
    }

    private func handleOutput(_ words: [UInt64]) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let report = OutputReport(words: words) else { return }
        if let last = lastOutputSequence, report.sequence > last + 1 {
            Self.log.error("output reports dropped: sequence \(last) -> \(report.sequence)")
        }
        lastOutputSequence = report.sequence
        onOutput?(report)
    }
}

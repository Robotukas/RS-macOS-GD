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
    private var lastOutputSequence: UInt64?

    // Reconnect back-off. A crashing dext re-publishes its service in a tight loop, and each re-publication would
    // run hello again (~27 ms apart in the bug 2 crash loop). `failures` counts consecutive failed attempts.
    private static let backoff: [Double] = [0.5, 1, 2, 5]          // seconds, capped at the last entry
    private var failures = 0
    private var lastAttempt: DispatchTime = .now()
    private var connectedAt: DispatchTime?
    private var pendingService: io_service_t = 0
    private var retryTimer: DispatchSourceTimer?
    /// Set after a `notPermitted` refusal: no further attempts until `retry()` (Retry menu item, or the installed
    /// driver build changing).
    private(set) var refusalLatched = false

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
        cancelRetry()
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
            if connect != 0 || service != 0 || refusalLatched { IOObjectRelease(svc); continue }   // connected, or refused
            attemptOrDefer(svc)
        }
    }

    /// Opens `svc` now, or after the back-off delay if the previous attempt failed recently. Takes ownership of `svc`.
    private func attemptOrDefer(_ svc: io_service_t) {
        let delay = failures == 0 ? 0 : Self.backoff[min(failures - 1, Self.backoff.count - 1)]
        let due = lastAttempt + delay
        if delay == 0 || DispatchTime.now() >= due {
            cancelRetry()
            lastAttempt = .now()
            open(svc)
            return
        }
        if pendingService != 0 { IOObjectRelease(pendingService) }
        pendingService = svc
        retryTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: due)
        t.setEventHandler { [weak self] in
            guard let self, self.pendingService != 0 else { return }
            let s = self.pendingService; self.pendingService = 0
            self.retryTimer = nil
            if self.connect != 0 || self.service != 0 || self.refusalLatched || !self.started { IOObjectRelease(s); return }
            self.lastAttempt = .now()
            self.open(s)
        }
        t.resume()
        retryTimer = t
        Self.log.info("reconnect deferred \(delay, privacy: .public) s (failures=\(self.failures))")
    }

    private func cancelRetry() {
        retryTimer?.cancel(); retryTimer = nil
        if pendingService != 0 { IOObjectRelease(pendingService); pendingService = 0 }
    }

    /// Clears the back-off and the refusal latch and tries the current service again (Retry menu item; called when the
    /// installed driver build changes).
    func retry() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started, connect == 0 else { return }
        cancelRetry()
        failures = 0
        refusalLatched = false
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, Self.matching(), &it) == KERN_SUCCESS {
            while case let svc = IOIteratorNext(it), svc != 0 {
                if connect != 0 || service != 0 { IOObjectRelease(svc); continue }
                lastAttempt = .now()
                open(svc)
            }
            IOObjectRelease(it)
        }
        if connect == 0 { setState(.waitingForService) }
    }

    private func handleTerminated(_ iterator: io_iterator_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        while case let svc = IOIteratorNext(iterator), svc != 0 {
            // A refusal only holds for the dext instance that refused: when that process goes away (new build, crash),
            // the next instance gets a fresh chance (still subject to the back-off).
            if refusalLatched { refusalLatched = false }
            if service != 0, IOObjectIsEqualTo(svc, service) != 0 {
                Self.log.info("dext service terminated; closing connection")
                // A connection that dies within 2 s counts as a failure, so a crashing dext cannot cause a tight loop.
                if let at = connectedAt, DispatchTime.now() < at + 2.0 { failures += 1 }
                connectedAt = nil
                closeConnection()
                if !refusalLatched { setState(.waitingForService) }
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
            failures += 1
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
            closeConnection(); failures += 1; refusalLatched = true; setState(.rejected(hr)); return
        case DextProtocol.krExclusiveAccess:
            Self.log.error("hello refused: another GDHub owns the driver (0xE00002C5)")
            closeConnection(); failures += 1; setState(.exclusive); return
        default:
            Self.log.error("hello failed: 0x\(String(UInt32(bitPattern: hr), radix: 16), privacy: .public)")
            closeConnection(); failures += 1; setState(.failed(hr)); return
        }
        guard out[0] == UInt64(DextProtocol.version) else {
            Self.log.error("protocol mismatch: dext v\(out[0]) build \(out[1]), app v\(DextProtocol.version)")
            closeConnection(); failures += 1; setState(.protocolMismatch(dext: out[0])); return
        }
        failures = 0
        refusalLatched = false
        connectedAt = .now()
        registerOutput()
        Self.log.info("connected: driver build \(out[1]) protocol \(out[0]) capabilities \(out[2]) (app build \(self.appBuild))")
        setState(.connected(dextBuild: out[1]))
        if let s = status() {
            Self.log.info("status: devices=\(s.deviceMask) posts=\(s.postCount) watchdogFires=\(s.watchdogFires) outputs=\(s.outputCount) drops=\(s.outputDrops)")
        }
    }

    private func closeConnection() {
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

    func createDevice(_ spec: DeviceSpec) -> kern_return_t {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connect != 0 else { return DextProtocol.krNotReady }
        let bytes: [UInt8]
        do { bytes = try spec.encoded() } catch {
            Self.log.error("createDevice: invalid spec: \(String(describing: error), privacy: .public)")
            return DextProtocol.krBadArgument
        }
        return bytes.withUnsafeBytes {
            IOConnectCallStructMethod(connect, DextProtocol.Selector.createDevice, $0.baseAddress, $0.count, nil, nil)
        }
    }

    func destroyDevice(slot: UInt8) -> kern_return_t {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connect != 0 else { return DextProtocol.krNotReady }
        var s: [UInt64] = [UInt64(slot)]
        return IOConnectCallScalarMethod(connect, DextProtocol.Selector.destroyDevice, &s, 1, nil, nil)
    }

    func post(slot: UInt8, report: [UInt8]) -> kern_return_t {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connect != 0 else { return DextProtocol.krNotReady }
        var s: [UInt64] = [UInt64(slot)]
        return report.withUnsafeBytes {
            IOConnectCallMethod(connect, DextProtocol.Selector.postReport, &s, 1, $0.baseAddress, $0.count, nil, nil, nil, nil)
        }
    }

    func postNeutral(slot: UInt8) -> kern_return_t {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connect != 0 else { return DextProtocol.krNotReady }
        var s: [UInt64] = [UInt64(slot)]
        return IOConnectCallScalarMethod(connect, DextProtocol.Selector.postNeutral, &s, 1, nil, nil)
    }

    /// DEBUG-ONLY dev experiment: asks the dext to Terminate(0) its root service so the process can exit and a staged
    /// replacement build can start without a reboot. Not part of the design.
    @discardableResult
    func devTerminate() -> kern_return_t {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connect != 0 else { return DextProtocol.krNotReady }
        let kr = IOConnectCallScalarMethod(connect, DextProtocol.Selector.devTerminate, nil, 0, nil, nil)
        Self.log.info("devTerminate returned 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
        return kr
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

    // The dext's watchdog neutralises the pad after 2 s without activity (design §3.10). The heartbeat is sent by
    // `VirtualPadSink` (every 500 ms while a device is published); the client only offers `heartbeat()`.

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

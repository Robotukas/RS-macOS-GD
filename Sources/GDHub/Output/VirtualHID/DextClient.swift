import Foundation
import IOKit
import os

/// One raw selector call: scalar inputs, expected scalar-output count, structure-output capacity. The result carries the
/// scalars and the structure bytes the dext returned.
struct DextRawResult {
    var kr: kern_return_t
    var scalars: [UInt64] = []
    var bytes: [UInt8] = []
}
typealias DextRawCall = (_ selector: UInt32, _ scalarsIn: [UInt64], _ scalarOutCount: Int, _ structOutCapacity: Int, _ structIn: [UInt8]?) -> DextRawResult

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
    /// `hello` output[2] of the dext this client is connected to (0 while not connected). Features beyond the original
    /// selector set are used only when their bit is set: a dext without `Capability.rootPad` (build 17) answers selectors
    /// 9 and 11 with "bad argument".
    private(set) var capabilities: UInt64 = 0
    var hasRootPad: Bool { capabilities & DextProtocol.Capability.rootPad != 0 }
    /// T4: the dext has the receiver tap (a GDHUB_TAP_DECLINE build and build 19 and earlier do not).
    var hasTap: Bool { capabilities & DextProtocol.Capability.tap != 0 }
    /// T5: the dext has `setMapping` and the SHADOW state.
    var hasXlate: Bool { capabilities & DextProtocol.Capability.xlate != 0 }
    /// A supervised client belongs to the engine's `TapSupervisor`, which decides the forwarding state. Every other client
    /// (the GUI in in-app mode) sends INERT after hello when the dext has a tap, so a tap can never keep counting for it.
    let supervised: Bool
    /// Tests replace the IOKit call with a fake that behaves like a given dext.
    private var testCall: DextRawCall?

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

    init(queue: DispatchQueue, supervised: Bool = false) {
        self.queue = queue
        self.supervised = supervised
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

    /// The property match of the dext's root service. `IOUserServerName` is shared by every service of the dext (the
    /// receiver tap joins in T4), so `IOUserClass` picks the root.
    static var matchingProperties: [String: String] {
        ["IOUserServerName": dextID, "IOUserClass": DextProtocol.rootUserClass]
    }

    static func matching() -> CFDictionary {
        let dict = IOServiceMatching("IOUserService") as NSMutableDictionary
        dict[kIOPropertyMatchKey] = matchingProperties
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
        capabilities = out[2]
        sendInitialForwarding()
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
        capabilities = 0
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
        guard isLinked else { return nil }
        let r = callRaw(DextProtocol.Selector.getStatus, scalarsIn: [], scalarOutCount: DextStatus.scalarCount, structOutCapacity: 0)
        guard r.kr == KERN_SUCCESS else {
            Self.log.error("getStatus failed: 0x\(String(UInt32(bitPattern: r.kr), radix: 16), privacy: .public)")
            return nil
        }
        return DextStatus(words: r.scalars)
    }

    /// GDHubStatus2 (T3): identity, counters, the last 10 s window of the dext's `hop` and `hr`. nil without
    /// `Capability.rootPad`, when not connected, or on an error.
    func status2() -> DextStatus2? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isLinked, hasRootPad else { return nil }
        let r = callRaw(DextProtocol.Selector.getStatus2, scalarsIn: [], scalarOutCount: 0, structOutCapacity: DextStatus2.maxSize)
        guard r.kr == KERN_SUCCESS else {
            Self.log.error("getStatus2 failed: 0x\(String(UInt32(bitPattern: r.kr), radix: 16), privacy: .public)")
            return nil
        }
        return DextStatus2.decode(r.bytes)
    }

    /// Selector 9. INERT needs `Capability.rootPad` (build 18 and later), COUNT needs `Capability.tap`. Without the bit the
    /// call is not sent and the result is `krUnsupported`: a dext that lacks the selector or the state answers BadArgument or
    /// Unsupported anyway, but the app does not rely on that.
    func setForwarding(_ state: UInt64) -> (kr: kern_return_t, result: DextForwardingResult?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isLinked else { return (DextProtocol.krNotReady, nil) }
        guard DextProtocol.Forwarding.isAccepted(state: state, flags: 0) else { return (DextProtocol.krUnsupported, nil) }
        guard hasRootPad else { return (DextProtocol.krUnsupported, nil) }
        switch state {                                 // each state needs the capability that introduced it
        case DextProtocol.Forwarding.inert: break
        case DextProtocol.Forwarding.count: guard hasTap else { return (DextProtocol.krUnsupported, nil) }
        default: guard hasXlate else { return (DextProtocol.krUnsupported, nil) }
        }
        let r = callRaw(DextProtocol.Selector.setForwarding, scalarsIn: [state, 0, 0],
                        scalarOutCount: DextForwardingResult.scalarCount, structOutCapacity: 0)
        return (r.kr, r.kr == KERN_SUCCESS ? DextForwardingResult(words: r.scalars) : nil)
    }

    /// Selector 10 (T5): push a GDHM blob. Not sent without `Capability.xlate` (`krUnsupported`) or with a size the dext would
    /// refuse as a bad argument (`krBadArgument`, a local answer). The dext answers `kIOReturnSuccess` with `reason != 0` for a
    /// refused mapping (the kernel does not return scalar outputs of a failed call), `krNotPermitted` to a non-owner.
    func setMapping(_ blob: [UInt8]) -> (kr: kern_return_t, result: DextMappingResult?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isLinked else { return (DextProtocol.krNotReady, nil) }
        guard hasXlate else { return (DextProtocol.krUnsupported, nil) }
        guard blob.count >= 64, blob.count <= 1024 else { return (DextProtocol.krBadArgument, nil) }
        let r = callRaw(DextProtocol.Selector.setMapping, scalarsIn: [], scalarOutCount: 2, structOutCapacity: 0, structIn: blob)
        return (r.kr, r.kr == KERN_SUCCESS ? DextMappingResult(words: r.scalars) : nil)
    }

    /// After hello: an unsupervised client (the GUI in in-app mode) tells a dext that has a tap to stay INERT. A supervised
    /// client leaves the state to its `TapSupervisor`. A dext without `Capability.tap` is not touched.
    func sendInitialForwarding() {
        guard hasTap, !supervised else { return }
        let r = setForwarding(DextProtocol.Forwarding.inert)
        Self.log.info("unsupervised client: setForwarding(INERT) -> 0x\(String(UInt32(bitPattern: r.kr), radix: 16), privacy: .public)")
    }

    func setForwardingInert() -> (kr: kern_return_t, result: DextForwardingResult?) {
        setForwarding(DextProtocol.Forwarding.inert)
    }

    private var isLinked: Bool { connect != 0 || testCall != nil }

    private func callRaw(_ selector: UInt32, scalarsIn: [UInt64], scalarOutCount: Int, structOutCapacity: Int,
                         structIn: [UInt8]? = nil) -> DextRawResult {
        if let testCall { return testCall(selector, scalarsIn, scalarOutCount, structOutCapacity, structIn) }
        var sIn = scalarsIn
        // Output pointers are passed only when the call has that kind of output; the kernel compares the counts.
        let sOut = UnsafeMutablePointer<UInt64>.allocate(capacity: max(scalarOutCount, 1))
        let nOut = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(structOutCapacity, 1))
        let bufLen = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { sOut.deallocate(); nOut.deallocate(); buf.deallocate(); bufLen.deallocate() }
        sOut.initialize(repeating: 0, count: max(scalarOutCount, 1))
        buf.initialize(repeating: 0, count: max(structOutCapacity, 1))
        nOut.pointee = UInt32(scalarOutCount)
        bufLen.pointee = structOutCapacity
        let inBytes = structIn ?? []
        let kr = inBytes.withUnsafeBytes { raw in
            IOConnectCallMethod(connect, selector, &sIn, UInt32(sIn.count), structIn == nil ? nil : raw.baseAddress, inBytes.count,
                                scalarOutCount > 0 ? sOut : nil, scalarOutCount > 0 ? nOut : nil,
                                structOutCapacity > 0 ? buf : nil, structOutCapacity > 0 ? bufLen : nil)
        }
        guard kr == KERN_SUCCESS else { return DextRawResult(kr: kr) }
        return DextRawResult(kr: kr,
                             scalars: scalarOutCount > 0 ? Array(UnsafeBufferPointer(start: sOut, count: min(Int(nOut.pointee), scalarOutCount))) : [],
                             bytes: structOutCapacity > 0 ? Array(UnsafeBufferPointer(start: buf, count: min(bufLen.pointee, structOutCapacity))) : [])
    }

    /// Test seam: behave as if connected to a dext that answers `call` and reported `capabilities` in `hello`.
    func attachFakeDext(capabilities: UInt64, call: @escaping DextRawCall) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.capabilities = capabilities
        testCall = call
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

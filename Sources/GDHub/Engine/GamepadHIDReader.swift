import Foundation
import IOKit.hid
import os

/// Reads the SCUF's gamepad interface (usage page 0xFF58) straight into the pad sink. The manager's callbacks are
/// delivered on `queue` (the engine's `.userInteractive` vhidQueue): no run loop, no main thread. The device is opened
/// non-exclusively, so the GUI keeps its own read-only open for display and learning.
final class GamepadHIDReader: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")
    static let vendorID = 0x1B1C
    static let productID = 0x3A08
    static let usagePage = 0xFF58

    private let queue: DispatchQueue
    private let presence: ControllerPresence
    private let core: EngineCore
    private let stat: CallbackStat
    private var manager: IOHIDManager?
    private var cancelled = false

    /// T5: the parity sampler's ring of recent frames. Recording happens only while `ring.enabled` (SHADOW armed).
    var ring: FrameRing?

    init(queue: DispatchQueue, presence: ControllerPresence, core: EngineCore, stat: CallbackStat) {
        self.queue = queue
        self.presence = presence
        self.core = core
        self.stat = stat
    }

    /// Must run on `queue`.
    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard manager == nil else { return }
        cancelled = false
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID,
                                            kIOHIDPrimaryUsagePageKey: Self.usagePage] as CFDictionary)
        // The context stays retained until the cancel handler has run.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<GamepadHIDReader>.fromOpaque(ctx).takeUnretainedValue().deviceMatched()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<GamepadHIDReader>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved()
        }, ctx)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(mgr, { ctx, _, _, _, reportID, report, length, timeStamp in
            // First thing: the callback entry time.
            let tC = LatencyMeter.nowNs()
            guard let ctx else { return }
            Unmanaged<GamepadHIDReader>.fromOpaque(ctx).takeUnretainedValue()
                .handle(reportID: reportID, report: report, length: length, timeStamp: timeStamp, tC: tC)
        }, ctx)
        IOHIDManagerSetDispatchQueue(mgr, queue)
        IOHIDManagerSetCancelHandler(mgr) { Unmanaged<GamepadHIDReader>.fromOpaque(ctx).release() }
        let kr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if kr != kIOReturnSuccess {
            Self.log.error("IOHIDManagerOpen failed: 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
        }
        IOHIDManagerActivate(mgr)
        manager = mgr
        Self.log.notice("hid reader started (page 0xFF58, non-exclusive, queue QoS userInteractive)")
    }

    /// Must run on `queue`. Cancels the manager; the report callbacks stop once the cancel handler has run.
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let mgr = manager, !cancelled else { return }
        cancelled = true
        IOHIDManagerCancel(mgr)
        manager = nil
    }

    private func deviceMatched() {
        Self.log.notice("controller interface up")
        presence.interfaceUp()
    }

    private func deviceRemoved() {
        Self.log.notice("controller interface down")
        presence.interfaceDown()
    }

    /// The hot path. Never allocates, never logs, never touches defaults or XPC.
    @inline(__always)
    private func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex, timeStamp: UInt64, tC: UInt64) {
        guard reportID == 6,
              let frame = GamepadFrame.parse(UnsafeBufferPointer(start: report, count: length)) else { return }
        if let ring, ring.enabled { ring.record(timestamp: timeStamp, report: report, length: length) }
        let tK = LatencyMeter.nanos(fromMach: timeStamp)
        stat.record(tK: tK, tC: tC)
        presence.report(atNs: tC)
        core.sink.submit(frame: frame, mapping: core.mapping, revision: core.mappingRevision, tK: tK, tC: tC)
    }
}

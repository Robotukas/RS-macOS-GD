import Foundation
import IOKit.hid

struct HIDDeviceInfo {
    let vendorId: Int
    let productId: Int
    let usagePage: Int
    /// True when the interface's usage pairs include the vendor control page 0xFF42 (Corsair "Bragi").
    var hasControlChannel = false
}

/// Per-device state kept alive for the IOKit callbacks.
private final class HIDDeviceContext {
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferSize = 4096
    let info: HIDDeviceInfo
    weak var monitor: HIDMonitor?
    let device: IOHIDDevice

    init(info: HIDDeviceInfo, device: IOHIDDevice, monitor: HIDMonitor) {
        self.info = info
        self.device = device
        self.monitor = monitor
        buffer = .allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
    }

    deinit { buffer.deallocate() }
}

/// Thin IOHIDManager wrapper. Callbacks are scheduled on the main run loop
/// (common modes, so they keep flowing while the UI is tracking mouse events)
/// and delivered on the main actor.
@MainActor
final class HIDMonitor {
    let matchList: [(vendorId: Int, productId: Int)]

    var onDeviceMatched: ((IOHIDDevice, Int) -> Void)?
    var onDeviceRemoved: ((IOHIDDevice) -> Void)?
    var onInputReport: ((IOHIDDevice, UInt32, [UInt8]) -> Void)?
    /// Interfaces on these usage pages deliver reports synchronously from the IOKit callback (which already runs on
    /// the main run loop): the report buffer is passed as is, valid only during the call, with the kernel timestamp
    /// and the callback entry time, both in nanoseconds on the `CLOCK_UPTIME_RAW` timeline. No copy, no `main.async`.
    /// Set before `start()`. Other interfaces keep the copying path (`onInputReport`).
    var synchronousUsagePages: Set<Int> = []
    var onSynchronousInputReport: ((IOHIDDevice, UInt32, UnsafeBufferPointer<UInt8>, _ tK: UInt64, _ tC: UInt64) -> Void)?
    var onLog: ((String) -> Void)?

    private var manager: IOHIDManager?
    private var contexts: [ObjectIdentifier: HIDDeviceContext] = [:]
    private let runLoopMode = CFRunLoopMode.commonModes.rawValue

    init(matchList: [(vendorId: Int, productId: Int)]) {
        self.matchList = matchList
    }

    /// Cached vendor/product/usage page for a device that has been matched.
    func info(for device: IOHIDDevice) -> HIDDeviceInfo? {
        contexts[ObjectIdentifier(device)]?.info
    }

    func start() {
        guard manager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let dicts: [[String: Any]] = matchList.map {
            [kIOHIDVendorIDKey: $0.vendorId, kIOHIDProductIDKey: $0.productId]
        }
        IOHIDManagerSetDeviceMatchingMultiple(mgr, dicts as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor.handleMatched(device) }
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor.handleRemoved(device) }
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), runLoopMode)
        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            onLog?("IOHIDManagerOpen failed: " + String(format: "0x%08x", r))
        }
        manager = mgr
    }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), runLoopMode)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    private static func hasUsagePage(_ device: IOHIDDevice, _ page: Int) -> Bool {
        let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
        return pairs.contains { ($0[kIOHIDDeviceUsagePageKey] as? Int) == page }
    }

    /// The matched interface that carries the vendor control collection (page 0xFF42), if present.
    func controlDevice() -> IOHIDDevice? {
        for (_, ctx) in contexts where ctx.info.hasControlChannel { return ctx.device }
        return nil
    }

    /// Sends an output report. `bytes` includes the report ID as byte 0 (the on-wire form).
    @discardableResult
    func sendOutputReport(device: IOHIDDevice, reportID: UInt8, bytes: [UInt8]) -> IOReturn {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), bytes, bytes.count)
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
    }

    private func handleMatched(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard contexts[key] == nil else { return }
        let info = HIDDeviceInfo(
            vendorId: intProperty(device, kIOHIDVendorIDKey),
            productId: intProperty(device, kIOHIDProductIDKey),
            usagePage: intProperty(device, kIOHIDPrimaryUsagePageKey),
            hasControlChannel: Self.hasUsagePage(device, 0xFF42)
        )
        let ctx = HIDDeviceContext(info: info, device: device, monitor: self)
        contexts[key] = ctx

        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            onLog?("IOHIDDeviceOpen page 0x" + String(info.usagePage, radix: 16) + " failed: " + String(format: "0x%08x", r))
        }
        if synchronousUsagePages.contains(info.usagePage) {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, ctx.buffer, ctx.bufferSize, { context, _, sender, _, reportID, report, length, timeStamp in
                let tC = LatencyMeter.nowNs()
                guard let context = context, let sender = sender else { return }
                let ctx = Unmanaged<HIDDeviceContext>.fromOpaque(context).takeUnretainedValue()
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                let tK = LatencyMeter.nanos(fromMach: timeStamp)
                // The callback runs on the main run loop (the device is scheduled on it below).
                MainActor.assumeIsolated {
                    ctx.monitor?.onSynchronousInputReport?(device, reportID, UnsafeBufferPointer(start: report, count: length), tK, tC)
                }
            }, Unmanaged.passUnretained(ctx).toOpaque())
        } else {
            IOHIDDeviceRegisterInputReportCallback(device, ctx.buffer, ctx.bufferSize, { context, _, sender, _, reportID, report, length in
                guard let context = context, let sender = sender else { return }
                let ctx = Unmanaged<HIDDeviceContext>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                guard let monitor = ctx.monitor else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { monitor.onInputReport?(device, reportID, bytes) }
                }
            }, Unmanaged.passUnretained(ctx).toOpaque())
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), runLoopMode)

        onDeviceMatched?(device, info.usagePage)
    }

    private func handleRemoved(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard let ctx = contexts[key] else { return }
        onDeviceRemoved?(device)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), runLoopMode)
        contexts[key] = nil
        // Keep the context (and its report buffer) alive: IOKit may still reference
        // it until the device object is released. It is tiny.
        retiredContexts.append(ctx)
    }

    private var retiredContexts: [HIDDeviceContext] = []
}

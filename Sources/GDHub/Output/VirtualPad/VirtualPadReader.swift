import Foundation
import IOKit.hid
import os

/// Reads back what GDHub's own virtual pad sends (Developer mode, docs/plans/developer-mode-plan.md). It matches the
/// pad the sink currently publishes (the active `PadIdentity`'s vendor and product, and the serial `PadIdentity.serial`,
/// so a real Xbox controller with the same IDs is never read) and keeps every input report with its kernel timestamp.
///
/// The lifecycle mirrors `GamepadHIDReader`: the manager's callbacks run on a private serial queue (no run loop, no main
/// thread), the device is opened non-exclusively so games and the engine are not disturbed, and the retained context is
/// released by the manager's cancel handler. Everything below the public API is confined to `queue`.
///
/// The sink posts on change only, so a pad at rest says nothing. To know the state a step starts from, the reader keeps
/// the merged held state of every report it has seen and, right after a pad appears, asks the device for its current
/// input reports once. Whatever that read cannot tell stays unknown, and the judge says so.
final class VirtualPadReader: ObservableObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "devmode")

    struct Entry {
        var seq: UInt64
        var tNs: UInt64
        var id: UInt8
        var bytes: [UInt8]
    }

    /// Reports after a cursor.
    struct Drained {
        var reports: [DevJudge.TimedReport]
        var lastSeq: UInt64
        /// The ring wrapped past the cursor: some reports were lost (more than `capacity` between two drains).
        var lost: Bool
    }

    /// The merged held state, and whether the reader has seen anything from the pad since the pad appeared.
    struct Held: Equatable {
        var state: PadDecodedState?
        var everSeen: Bool
        /// The sequence number of the newest report applied; drain from here to continue without a gap.
        var seq: UInt64
    }

    static let defaultCapacity = 32_768

    /// How many virtual pads the reader matches right now. Published on the main thread.
    @Published private(set) var matchedCount = 0
    /// The identity the manager was opened for (main thread).
    private(set) var openedIdentityID: String?

    private let queue = DispatchQueue(label: "com.interlinked.gdhub.padreader", qos: .userInteractive)
    private let capacity: Int
    private let identityProvider: () -> PadIdentity
    private let decoder: PadReportDecoder

    // Queue-confined.
    private var manager: IOHIDManager?
    private var devices = Set<UnsafeMutableRawPointer>()
    private var ring: [Entry?]
    private var writeSeq: UInt64 = 0
    private var held: PadDecodedState?
    private var everSeen = false
    private var generation = 0

    /// - Parameter identityProvider: which pad to read; production follows the identity the sink publishes.
    init(capacity: Int = VirtualPadReader.defaultCapacity,
         decoder: PadReportDecoder = .xboxBT16,
         identityProvider: @escaping () -> PadIdentity = VirtualPadReader.activeIdentity) {
        self.capacity = max(capacity, 64)
        self.decoder = decoder
        self.identityProvider = identityProvider
        ring = Array(repeating: nil, count: max(capacity, 64))
    }

    /// The identity the sink would publish now (`VirtualPadSink.identityKey`, default 02E0).
    static func activeIdentity() -> PadIdentity {
        PadIdentity.named(UserDefaults.standard.string(forKey: VirtualPadSink.identityKey) ?? "") ?? .default
    }

    // MARK: Lifecycle

    /// Starts matching. Safe to call again; it does nothing while a manager exists for the same identity.
    func open() {
        let identity = identityProvider()
        queue.sync {
            if manager != nil, openedIdentityID == identity.id { return }
            stopLocked()
            startLocked(identity)
        }
        openedIdentityID = identity.id
    }

    /// Re-opens when the sink switched identity since `open()` (the pad was destroyed and made again under new IDs).
    func reopenIfIdentityChanged() {
        if openedIdentityID != nil, identityProvider().id != openedIdentityID { open() }
    }

    func close() {
        queue.sync { stopLocked() }
        openedIdentityID = nil
        publishMatched(0)
    }

    private func startLocked(_ identity: PadIdentity) {
        dispatchPrecondition(condition: .onQueue(queue))
        generation += 1
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: Int(identity.vendorID),
                                            kIOHIDProductIDKey: Int(identity.productID),
                                            kIOHIDSerialNumberKey: PadIdentity.serial] as CFDictionary)
        // The context stays retained until the cancel handler has run.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<VirtualPadReader>.fromOpaque(ctx).takeUnretainedValue().deviceMatched(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<VirtualPadReader>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(mgr, { ctx, _, _, _, reportID, report, length, timeStamp in
            guard let ctx else { return }
            Unmanaged<VirtualPadReader>.fromOpaque(ctx).takeUnretainedValue()
                .handle(reportID: reportID, report: report, length: length, timeStamp: timeStamp)
        }, ctx)
        IOHIDManagerSetDispatchQueue(mgr, queue)
        IOHIDManagerSetCancelHandler(mgr) { Unmanaged<VirtualPadReader>.fromOpaque(ctx).release() }
        let kr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if kr != kIOReturnSuccess {
            Self.log.error("pad reader: IOHIDManagerOpen failed: 0x\(String(UInt32(bitPattern: kr), radix: 16), privacy: .public)")
        }
        IOHIDManagerActivate(mgr)
        manager = mgr
        Self.log.notice("pad reader started for \(identity.id, privacy: .public) serial \(PadIdentity.serial, privacy: .public) (non-exclusive)")
    }

    private func stopLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let mgr = manager else { return }
        IOHIDManagerCancel(mgr)
        manager = nil
        devices.removeAll()
    }

    // MARK: Queue callbacks

    private func deviceMatched(_ device: IOHIDDevice) {
        let key = Unmanaged.passUnretained(device).toOpaque()
        let wasEmpty = devices.isEmpty
        devices.insert(key)
        if wasEmpty {
            // A new pad instance starts from its own neutral state, not from the one that was destroyed.
            held = nil
            everSeen = false
            seedFromDevice(device, generation: generation)
        }
        publishMatched(devices.count)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        devices.remove(Unmanaged.passUnretained(device).toOpaque())
        publishMatched(devices.count)
    }

    private func publishMatched(_ n: Int) {
        DispatchQueue.main.async { [weak self] in
            if self?.matchedCount != n { self?.matchedCount = n }
        }
    }

    /// The hot path: copy, stamp, apply to the held state. No logging.
    private func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex, timeStamp: UInt64) {
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        let t = timeStamp == 0 ? LatencyMeter.nowNs() : LatencyMeter.nanos(fromMach: timeStamp)
        recordLocked(id: UInt8(truncatingIfNeeded: reportID), bytes: bytes, tNs: t)
    }

    private func recordLocked(id: UInt8, bytes: [UInt8], tNs: UInt64) {
        writeSeq &+= 1
        ring[Int(writeSeq % UInt64(capacity))] = Entry(seq: writeSeq, tNs: tNs, id: id, bytes: bytes)
        var s = held ?? .neutral
        decoder.apply(reportID: id, bytes: bytes, to: &s)
        held = s
        everSeen = true
    }

    /// Feeds a report as the HID callback would (tests, and anything that replays a capture).
    func record(id: UInt8, bytes: [UInt8], tNs: UInt64) {
        queue.sync { recordLocked(id: id, bytes: bytes, tNs: tNs) }
    }

    /// One read of the pad's current input reports, off the reader queue because a device that does not implement
    /// `GetReport` can make the call wait for its timeout. Applied only if no real report arrived in the meantime.
    private func seedFromDevice(_ device: IOHIDDevice, generation gen: Int) {
        let reports = decoder.reports.map { (id: UInt8($0.id), length: Int($0.length)) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var got: [(UInt8, [UInt8])] = []
            for r in reports {
                var buf = [UInt8](repeating: 0, count: max(r.length + 1, 8))
                var len = CFIndex(buf.count)
                let kr = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(r.id), &buf, &len)
                guard kr == kIOReturnSuccess, len > 0 else { continue }
                var bytes = Array(buf.prefix(Int(len)))
                if bytes.first != r.id { bytes.insert(r.id, at: 0) }
                if bytes.count >= r.length { got.append((r.id, Array(bytes.prefix(r.length)))) }
            }
            guard !got.isEmpty, let self else { return }
            self.queue.async {
                guard self.generation == gen, !self.everSeen else { return }
                var s = PadDecodedState.neutral
                for (id, bytes) in got { self.decoder.apply(reportID: id, bytes: bytes, to: &s) }
                self.held = s
                self.everSeen = true
                Self.log.notice("pad reader: seeded the held state from GetReport")
            }
        }
    }

    // MARK: Reading

    /// Reports with a sequence number above `cursor`, oldest first.
    func drain(after cursor: UInt64) -> Drained {
        queue.sync {
            let newest = writeSeq
            guard newest > cursor else { return Drained(reports: [], lastSeq: newest, lost: false) }
            let oldestKept = newest > UInt64(capacity) ? newest - UInt64(capacity) + 1 : 1
            let from = max(cursor + 1, oldestKept)
            var out: [DevJudge.TimedReport] = []
            out.reserveCapacity(Int(newest - from + 1))
            var s = from
            while s <= newest {
                if let e = ring[Int(s % UInt64(capacity))], e.seq == s {
                    out.append(DevJudge.TimedReport(tNs: e.tNs, id: e.id, bytes: e.bytes))
                }
                s += 1
            }
            return Drained(reports: out, lastSeq: newest, lost: from > cursor + 1)
        }
    }

    /// Everything still in the ring from `tNs` on (kernel timestamps), oldest first.
    func snapshot(since tNs: UInt64) -> [DevJudge.TimedReport] {
        drain(after: 0).reports.filter { $0.tNs >= tNs }
    }

    /// The held state and the cursor to drain from, taken together so no report is counted twice or missed.
    func heldSnapshot() -> Held {
        queue.sync { Held(state: held, everSeen: everSeen, seq: writeSeq) }
    }

    /// Test and recovery aid: forget everything.
    func reset() {
        queue.sync {
            ring = Array(repeating: nil, count: capacity)
            writeSeq = 0
            held = nil
            everSeen = false
        }
    }
}

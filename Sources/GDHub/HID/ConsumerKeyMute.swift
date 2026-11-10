import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import os

/// The HID calls `ConsumerKeyMute` makes, behind a protocol so the logic is testable with a fake. Services are named by
/// their registry entry ID. Only services of the wireless receiver's Consumer Control interface are ever listed.
protocol ConsumerServiceAccess: AnyObject {
    /// Registry IDs of the services that match VendorID 0x1B1C, ProductID 0x3A08 and PrimaryUsagePage 0x0C exactly.
    func matchingServiceIDs() -> [UInt64]
    /// The service's `UserKeyMapping` property as it reads now; nil when unset.
    func userKeyMapping(of id: UInt64) -> [[String: NSNumber]]?
    /// Sets `UserKeyMapping` on that one service. False when the system refused.
    func setUserKeyMapping(_ pairs: [[String: NSNumber]], on id: UInt64) -> Bool
}

/// Switches off the volume function of a remapped G2 / G3 / G4 (remap plan, "Volume off for a mapped G2-G4").
///
/// The keys also send volume-down / volume-up / mute as HID Consumer keys on a separate HID service of the wireless
/// receiver. The per-service property `UserKeyMapping` on that one service maps those usages to 0 (an empty array
/// restores everything). No driver change, no seize, no entitlement.
///
/// Threading: the object owns one serial utility queue and every IOKit call runs there. The frame queue never calls in
/// synchronously (`start`, `update` and `didWake` only enqueue). `stop()` waits for the clear, at most one second, and must
/// not be called on the frame queue.
///
/// One writer: the engine process in engine mode; the GUI only in in-app mode. A process that is not the writer must not
/// create or start one of these: a stopped or never-started object neither sets nor clears.
final class ConsumerKeyMute: @unchecked Sendable {
    static let log = Logger(subsystem: GDHubID.subsystem, category: "volume-keys")

    static let vendorID = 0x1B1C
    static let productID = 0x3A08
    static let usagePage = 0x0C
    static let propertyName = "UserKeyMapping"
    /// Consumer-page usages (page 0x0C in the high half) of the keys G2-G4 send: volume down, volume up, mute.
    static let usageByControl: [String: UInt64] = ["g2": 0xC_0000_00EA, "g3": 0xC_0000_00E9, "g4": 0xC_0000_00E2]
    /// Delays (seconds) of the applies that follow a service appearing: its HID event service registers a moment later.
    static let appearDelays: [TimeInterval] = [0, 0.1, 0.3, 1.0]
    static let stopWait: TimeInterval = 1.0

    // MARK: Pure parts

    /// The usages to switch off: those of G2-G4 whose effective output is anything other than the built-in function.
    static func desired(for mapping: ControlMapping) -> Set<UInt64> {
        var out = Set<UInt64>()
        for (id, usage) in usageByControl where mapping.effectiveOutput(id) != .builtIn { out.insert(usage) }
        return out
    }

    /// The property value: one `{Src: usage, Dst: 0}` entry per usage, sorted by usage (deterministic), Int64 numbers.
    static func pairs(for usages: Set<UInt64>) -> [[String: NSNumber]] {
        usages.sorted().map { [
            "HIDKeyboardModifierMappingSrc": NSNumber(value: Int64(bitPattern: $0)),
            "HIDKeyboardModifierMappingDst": NSNumber(value: Int64(0)),
        ] }
    }

    /// True when a read-back holds exactly the entries that were set (order does not matter; nil reads as empty).
    static func readBack(_ back: [[String: NSNumber]]?, matches pairs: [[String: NSNumber]]) -> Bool {
        func key(_ d: [String: NSNumber]) -> String {
            "\(d["HIDKeyboardModifierMappingSrc"]?.int64Value ?? -1)>\(d["HIDKeyboardModifierMappingDst"]?.int64Value ?? -1)"
        }
        return Set((back ?? []).map(key)) == Set(pairs.map(key)) && (back ?? []).count == pairs.count
    }

    // MARK: State (queue-confined except `queue` and the dependencies)

    private let queue = DispatchQueue(label: "\(GDHubID.subsystem).volume-keys", qos: .utility)
    private static let onQueue = DispatchSpecificKey<Void>()
    private let access: ConsumerServiceAccess
    private let watcher: ConsumerServiceWatcher?
    private var running = false
    private var desired = Set<UInt64>()
    private var applied: [UInt64: Set<UInt64>] = [:]       // per service: the set last written (or found already right)
    private var failed = false                             // the last apply had a refused set: any trigger retries it

    /// `watcher` nil: no IOKit notification (tests).
    init(access: ConsumerServiceAccess = HIDConsumerServiceAccess(), watcher: ConsumerServiceWatcher? = ConsumerServiceWatcher()) {
        self.access = access
        self.watcher = watcher
        queue.setSpecific(key: Self.onQueue, value: ())
    }

    /// Starts watching for the service and applies the mapping's set. Safe from any thread; returns at once.
    func start(mapping: ControlMapping) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            desired = Self.desired(for: mapping)
            watcher?.start(on: queue) { [weak self] in self?.scheduleApplies(reason: "service appeared", forget: false) }
            apply(reason: "start")
        }
    }

    /// A new mapping: applies when the set of keys to switch off changed (or an earlier set was refused). Returns at once.
    func update(_ mapping: ControlMapping) {
        queue.async { [self] in
            guard running else { return }
            let d = Self.desired(for: mapping)
            guard d != desired || failed else { return }
            desired = d
            apply(reason: "mapping changed")
        }
    }

    /// After system wake: applies again on every matching service, with the retries a new service gets. Returns at once.
    func didWake() {
        queue.async { [self] in
            guard running else { return }
            scheduleApplies(reason: "wake", forget: true)
        }
    }

    /// The receiver's consumer service appeared (the watcher calls this on the queue; tests call it from outside).
    func serviceAppeared() {
        queue.async { [self] in
            guard running else { return }
            scheduleApplies(reason: "service appeared", forget: false)
        }
    }

    /// Returns when everything enqueued so far has run (tests).
    func waitUntilIdle() { queue.sync {} }

    /// Clears what this object set (an empty array on those services), then stops watching. Waits at most one second.
    /// Not for the frame queue.
    func stop() {
        let work = { [self] in
            guard running else { return }
            running = false
            watcher?.stop()
            for id in access.matchingServiceIDs() where !(applied[id] ?? []).isEmpty {
                let ok = access.setUserKeyMapping([], on: id)
                if ok { Self.log.notice("cleared on service \(id) (stop)") }
                else { Self.log.error("clearing on service \(id) was refused (stop)") }
            }
            applied = [:]
            failed = false
        }
        if DispatchQueue.getSpecific(key: Self.onQueue) != nil { work(); return }
        let done = DispatchSemaphore(value: 0)
        queue.async { work(); done.signal() }
        if done.wait(timeout: .now() + Self.stopWait) == .timedOut {
            Self.log.error("stop: the clear did not finish within \(Self.stopWait, privacy: .public) s")
        }
    }

    // MARK: On the queue

    private func scheduleApplies(reason: String, forget: Bool) {
        if forget { applied = [:] }
        for delay in Self.appearDelays {
            if delay == 0 { apply(reason: reason); continue }                // already on the queue
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.running else { return }
                self.apply(reason: reason)
            }
        }
    }

    private func apply(reason: String) {
        let ids = access.matchingServiceIDs()
        applied = applied.filter { ids.contains($0.key) }          // a service that went away is forgotten: a new one is new
        guard !ids.isEmpty else {
            Self.log.debug("no receiver consumer service (\(reason, privacy: .public)); waiting for it")
            return
        }
        let pairs = Self.pairs(for: desired)
        let text = desired.sorted().map { "0x" + String($0, radix: 16, uppercase: true) }.joined(separator: ",")
        var anyFailed = false
        for id in ids where applied[id] != desired {
            // Nothing to switch off and nothing left over from an earlier writer: do not touch the service.
            if desired.isEmpty, Self.readBack(access.userKeyMapping(of: id), matches: []) { applied[id] = []; continue }
            guard access.setUserKeyMapping(pairs, on: id) else {
                Self.log.error("SetProperty(UserKeyMapping) was refused on service \(id) (\(reason, privacy: .public)); retrying at the next trigger")
                anyFailed = true
                continue
            }
            applied[id] = desired
            let matches = Self.readBack(access.userKeyMapping(of: id), matches: pairs)
            Self.log.notice("service \(id): switched off [\(text, privacy: .public)] (\(reason, privacy: .public)); read-back \(matches ? "matches" : "DIFFERS", privacy: .public)")
        }
        failed = anyFailed
    }
}

// MARK: Real HID calls

/// The real calls: an event-system simple client, its service list, `IOHIDServiceClientCopyProperty` / `SetProperty`. Used on
/// `ConsumerKeyMute`'s queue only. Matches the receiver's Consumer service exactly and never touches any other service.
final class HIDConsumerServiceAccess: ConsumerServiceAccess, @unchecked Sendable {
    private var client: IOHIDEventSystemClient?

    private func number(_ s: IOHIDServiceClient, _ key: String) -> Int? {
        (IOHIDServiceClientCopyProperty(s, key as CFString) as? NSNumber)?.intValue
    }

    private func registryID(_ s: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value
    }

    /// Fresh list each call: the services come and go with the receiver.
    private func matching() -> [(id: UInt64, service: IOHIDServiceClient)] {
        if client == nil { client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault) }
        guard let client else { return [] }
        let all = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        return all.compactMap { s in
            guard number(s, "VendorID") == ConsumerKeyMute.vendorID, number(s, "ProductID") == ConsumerKeyMute.productID,
                  number(s, "PrimaryUsagePage") == ConsumerKeyMute.usagePage, let id = registryID(s) else { return nil }
            return (id, s)
        }
    }

    func matchingServiceIDs() -> [UInt64] { matching().map(\.id) }

    func userKeyMapping(of id: UInt64) -> [[String: NSNumber]]? {
        guard let s = matching().first(where: { $0.id == id })?.service,
              let raw = IOHIDServiceClientCopyProperty(s, ConsumerKeyMute.propertyName as CFString) as? [[String: Any]]
        else { return nil }
        return raw.map { entry in entry.compactMapValues { value in value as? NSNumber } }
    }

    func setUserKeyMapping(_ pairs: [[String: NSNumber]], on id: UInt64) -> Bool {
        guard let s = matching().first(where: { $0.id == id })?.service else { return false }
        return IOHIDServiceClientSetProperty(s, ConsumerKeyMute.propertyName as CFString, pairs as CFArray)
    }
}

// MARK: Service arrival

/// Calls `onAppear` (on the given queue) when an HID device of the receiver's Consumer interface appears. The HID event
/// service that carries `UserKeyMapping` registers a moment after the device, which is why `ConsumerKeyMute` retries.
/// The `SyntheticPadWatcher` pattern: an IOKit first-match notification delivered on the owner's queue; nothing polls.
/// All methods are called on that queue.
final class ConsumerServiceWatcher: @unchecked Sendable {
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var onAppear: (() -> Void)?

    func start(on queue: DispatchQueue, onAppear: @escaping () -> Void) {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        guard let match = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { IONotificationPortDestroy(p); return }
        match["IOPropertyMatch"] = ["VendorID": ConsumerKeyMute.vendorID, "ProductID": ConsumerKeyMute.productID,
                                    "PrimaryUsagePage": ConsumerKeyMute.usagePage]
        self.onAppear = onAppear
        port = p
        IONotificationPortSetDispatchQueue(p, queue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, match as CFDictionary, { ref, iter in
            Unmanaged<ConsumerServiceWatcher>.fromOpaque(ref!).takeUnretainedValue().drain(iter, notify: true)
        }, refcon, &iterator)
        guard kr == KERN_SUCCESS else {
            ConsumerKeyMute.log.error("service watcher: IOServiceAddMatchingNotification failed (\(kr))")
            stop()
            return
        }
        drain(iterator, notify: false)               // arming: the devices already there are handled by the start apply
    }

    func stop() {
        if iterator != 0 { IOObjectRelease(iterator); iterator = 0 }
        if let p = port { IONotificationPortSetDispatchQueue(p, nil); IONotificationPortDestroy(p); port = nil }
        onAppear = nil
    }

    /// Always drains completely (an undrained iterator stops notifying).
    private func drain(_ iter: io_iterator_t, notify: Bool) {
        var any = false
        while case let svc = IOIteratorNext(iter), svc != 0 { IOObjectRelease(svc); any = true }
        if any && notify { onAppear?() }
    }
}

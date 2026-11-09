import Foundation
import IOKit
import os

/// Watches for the synthetic pad macOS GameController creates from our virtual pad (latency plan fix #2).
///
/// When GameController adopts the pad it adds an `AppleGCSyntheticDevice` (an Xbox 360 pad, 045E:028E) whose
/// `_GCSyntheticDeviceIdentifier` is `LOGICAL_DEVICE(<our serial>)`. Shadow forwards both pads to the VM, so a game
/// that reads "any pad" may see the later copy too. This only reports the copy; adoption itself is intended.
///
/// Event-driven: IOKit match and terminate notifications are delivered on this object's own utility queue. Nothing
/// runs on the sink's queue and nothing polls.
final class SyntheticPadWatcher: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
    private static let className = "AppleGCSyntheticDevice"
    private static let identifierKey = "_GCSyntheticDeviceIdentifier"

    /// True when a synthetic device's identifier belongs to the pad with this serial.
    static func identifier(_ id: String, belongsTo serial: String) -> Bool { id.contains(serial) }

    private let serial: String
    private let queue = DispatchQueue(label: "com.interlinked.gdhub.synthwatch", qos: .utility)
    private var port: IONotificationPortRef?
    private var matchedIter: io_iterator_t = 0
    private var terminatedIter: io_iterator_t = 0
    private var ids = Set<UInt64>()                 // registry entry IDs of our synthetic devices (queue-confined)
    private var reported = -1

    /// Called on the watcher's queue whenever the number of synthetic copies changes (and once after arming).
    var onCount: ((Int) -> Void)?

    init(serial: String = PadIdentity.serial) { self.serial = serial }

    deinit { stopNow() }

    func start() {
        queue.async { [self] in
            guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
            port = p
            IONotificationPortSetDispatchQueue(p, queue)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            // Each call consumes its matching dictionary, so build one per notification.
            let kr1 = IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, IOServiceMatching(Self.className),
                { ref, iter in Unmanaged<SyntheticPadWatcher>.fromOpaque(ref!).takeUnretainedValue().drain(iter, terminated: false) },
                refcon, &matchedIter)
            let kr2 = IOServiceAddMatchingNotification(p, kIOTerminatedNotification, IOServiceMatching(Self.className),
                { ref, iter in Unmanaged<SyntheticPadWatcher>.fromOpaque(ref!).takeUnretainedValue().drain(iter, terminated: true) },
                refcon, &terminatedIter)
            guard kr1 == KERN_SUCCESS, kr2 == KERN_SUCCESS else {
                Self.log.error("synthetic pad watcher: IOServiceAddMatchingNotification failed (\(kr1), \(kr2))")
                stopLocked()
                return
            }
            // Arming requires draining both iterators once.
            drain(matchedIter, terminated: false)
            drain(terminatedIter, terminated: true)
        }
    }

    func stop() { queue.async { [self] in stopLocked() } }

    private func stopNow() { stopLocked() }

    private func stopLocked() {
        if matchedIter != 0 { IOObjectRelease(matchedIter); matchedIter = 0 }
        if terminatedIter != 0 { IOObjectRelease(terminatedIter); terminatedIter = 0 }
        if let p = port { IONotificationPortSetDispatchQueue(p, nil); IONotificationPortDestroy(p); port = nil }
        ids.removeAll()
    }

    /// Queue-confined. Always drains the iterator completely (an undrained iterator stops notifying).
    private func drain(_ iter: io_iterator_t, terminated: Bool) {
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(svc, &entryID) == KERN_SUCCESS else { continue }
            if terminated { ids.remove(entryID); continue }
            let prop = IORegistryEntryCreateCFProperty(svc, Self.identifierKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if let prop, Self.identifier(prop, belongsTo: serial) { ids.insert(entryID) }
        }
        if ids.count != reported {
            reported = ids.count
            if reported > 0 {
                Self.log.info("macOS made \(self.reported) synthetic pad (Xbox 360, 045E:028E) from \(self.serial, privacy: .public): Shadow forwards both")
            } else {
                Self.log.info("no synthetic pad copy of \(self.serial, privacy: .public)")
            }
            onCount?(reported)
        }
    }
}

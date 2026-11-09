import Foundation
import os

/// Live mapping reload (plan §7). `MappingStore` writes `.atomic`, which renames a new inode into place, so a watch on
/// the file would go deaf after the first save: the watcher watches the directory. On an event it waits `debounce`,
/// loads the file on `queue` (never on the pad's queue: file I/O stays off the hot path) and hands over a mapping that
/// differs from the last one delivered.
final class MappingWatcher: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "engine")
    private let store: MappingStore
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onMapping: (ControlMapping) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var last: ControlMapping

    init(store: MappingStore, initial: ControlMapping, queue: DispatchQueue, debounce: TimeInterval = 0.05,
         onMapping: @escaping (ControlMapping) -> Void) {
        self.store = store
        self.last = initial
        self.queue = queue
        self.debounce = debounce
        self.onMapping = onMapping
    }

    deinit { source?.cancel() }

    @discardableResult
    func start() -> Bool {
        let dir = store.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log.error("mapping watcher: cannot open \(dir.path, privacy: .public)")
            return false
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        return true
    }

    func stop() { source?.cancel(); source = nil; pending?.cancel() }

    /// On `queue`.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func reload() {
        guard FileManager.default.fileExists(atPath: store.url.path) else { return }
        let m = store.load()
        guard m != last else { return }
        last = m
        onMapping(m)
    }
}

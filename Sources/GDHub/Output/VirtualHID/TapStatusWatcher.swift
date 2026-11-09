import Foundation
import os

/// GUI side of the Driver menu's input-path line (T6): tells the GUI when the engine wrote a new `TapStatusReport`. Event driven,
/// like `MappingWatcher`: a kqueue watch on the `state` directory (the engine replaces the file by an atomic rename, so the file
/// itself would go deaf), a short debounce, one small file read on `queue`. `refresh()` reads once on demand (the GUI's existing
/// 5 s engine refresh calls it, which also covers an event lost while the directory did not exist yet). Nothing here talks to the
/// dext: the engine owns that connection.
final class TapStatusWatcher: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interlinked.gdhub", category: "vhid")
    private let store: TapStatusStore
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onReport: (TapStatusReport?) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var last: TapStatusReport??               // nil: nothing delivered yet

    init(store: TapStatusStore = .standard, queue: DispatchQueue = DispatchQueue(label: "com.interlinked.gdhub.tapstatus", qos: .utility),
         debounce: TimeInterval = 0.03, onReport: @escaping (TapStatusReport?) -> Void) {
        self.store = store
        self.queue = queue
        self.debounce = debounce
        self.onReport = onReport
    }

    deinit { source?.cancel() }

    @discardableResult
    func start() -> Bool {
        let dir = store.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log.error("tap status watcher: cannot open \(dir.path, privacy: .public)")
            return false
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        refresh()
        return true
    }

    func stop() { source?.cancel(); source = nil; pending?.cancel() }

    /// Reads now (on `queue`) and delivers the report if it differs from the last one delivered.
    func refresh() { queue.async { [weak self] in self?.deliver() } }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.deliver() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func deliver() {
        let r = store.read()
        if let last, last == r { return }
        last = .some(r)
        onReport(r)
    }
}

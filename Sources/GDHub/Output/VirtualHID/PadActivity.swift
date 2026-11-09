import Foundation

/// Keeps App Nap off while the virtual pad is published (latency plan fix #1).
///
/// Shadow in fullscreen occludes GDHub's window, and macOS then napped every GDHub thread (priority 46 → 4, timers
/// into Tier4). One `ProcessInfo` activity token is held for as long as the pad is published; `setHeld` is idempotent,
/// so there is never more than one token.
@MainActor
final class PadActivity {
    typealias Begin = () -> NSObjectProtocol
    typealias End = (NSObjectProtocol) -> Void

    nonisolated static let options: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
    nonisolated static let reason = "virtual pad passthrough"

    private let begin: Begin
    private let end: End
    private var token: NSObjectProtocol?

    init(begin: @escaping Begin = { ProcessInfo.processInfo.beginActivity(options: PadActivity.options, reason: PadActivity.reason) },
         end: @escaping End = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin
        self.end = end
    }

    var isHeld: Bool { token != nil }

    /// Returns true when this call changed whether the activity is held.
    @discardableResult
    func setHeld(_ held: Bool) -> Bool {
        if held {
            guard token == nil else { return false }
            token = begin()
            return true
        }
        guard let t = token else { return false }
        token = nil
        end(t)
        return true
    }
}

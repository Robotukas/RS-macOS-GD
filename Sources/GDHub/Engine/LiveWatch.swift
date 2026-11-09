import Foundation
#if canImport(GDHubXlate)
import GDHubXlate
#endif

/// The engine's own shadow of what the driver's tap should be posting while it drives the pad (plan 6.6, F6): the same C core fed
/// by the engine's own reader. It runs only while LIVE is applied (`enabled`), on `vhidQueue` (the reader's callback queue, the
/// same queue the supervisor reads it on), so it needs no lock. It counts the reports a step would have posted; the supervisor
/// compares that with the driver's `tapPosts` between two status readings.
final class LiveWatch {
    var enabled = false
    private var core: XlateCore?
    private var state = gdx_state()
    private var out = gdx_out()
    var wouldPostReports: UInt64 = 0                 // internal: tests drive it

    /// The core that matches the mapping the driver holds (nil: nothing to compare with). Resets the delivery state.
    func configure(core: XlateCore?) {
        self.core = core
        gdx_reset(&state)
    }

    /// One raw report 0x06 (hot path: one C call, no allocation).
    @inline(__always)
    func feed(report: UnsafePointer<UInt8>, length: Int) {
        guard enabled, let core, length == 16 else { return }
        let mask = core.step(&state, raw: UnsafeBufferPointer(start: report, count: length), out: &out)
        wouldPostReports &+= UInt64(mask.nonzeroBitCount)
    }
}

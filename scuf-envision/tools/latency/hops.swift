// Measures the latency of the dispatch hops used by GDHub's frame path in an otherwise idle process:
// main-runloop source -> DispatchQueue.main.async, and any-thread -> userInteractive serial queue async,
// and a DispatchSourceTimer one-shot with 100 us leeway (the sink's trailing flush).
import Foundation
import Dispatch

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func stats(_ name: String, _ xs: [Double]) {
    let s = xs.sorted(); let n = s.count
    print(String(format: "%@: n=%d p50=%.1f us p90=%.1f p99=%.1f max=%.1f", name, n, s[n/2], s[n*9/10], s[n*99/100], s[n-1]))
}
let vq = DispatchQueue(label: "vhid", qos: .userInteractive)
var mainLat: [Double] = [], vqLat: [Double] = [], tmLat: [Double] = []
let N = 2000
var i = 0
// Drive from a 1 kHz timer on the main run loop, like HID callbacks.
let t = Timer(timeInterval: 0.001, repeats: true) { tm in
    let t0 = now()
    DispatchQueue.main.async {
        let t1 = now(); mainLat.append(Double(t1 - t0) / 1e3)
        vq.async { vqLat.append(Double(now() - t1) / 1e3) }
    }
    if i % 4 == 0 {
        let s = DispatchSource.makeTimerSource(queue: vq)
        let due = now() + 4_000_000
        s.schedule(deadline: .now() + .nanoseconds(4_000_000), leeway: .microseconds(100))
        s.setEventHandler { tmLat.append(Double(Int64(now()) - Int64(due)) / 1e3); s.cancel() }
        s.resume()
    }
    i += 1
    if i >= N { tm.invalidate(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        stats("main.async from main-runloop timer", mainLat)
        vq.sync { stats("main -> vhidQueue(.userInteractive) async", vqLat); stats("4 ms one-shot timer lateness (leeway 100us)", tmLat) }
        exit(0) } }
}
RunLoop.main.add(t, forMode: .common)
RunLoop.main.run()

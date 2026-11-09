// padlat: read-only latency probe for GDHub.
// Listens (non-seizing) to the SCUF receiver report 0x06 (1B1C:3A08, page 0xFF58) and to the
// GDHub virtual pad (045E:02E0, report 0x01/0x02), on a dedicated user-interactive thread.
// Usage: ./padlat [seconds=10] [absoluteCsvPath]
//   During the run a human must: flick the LEFT stick out and let it snap back ~10 times (stick onset),
//   tap A/B a few times (digital), pull and release a trigger a few times (trigger edge), then circle a stick
//   continuously for a few seconds (xcorr lag). At rest only inter-arrival numbers are meaningful (the pad
//   posts nothing when nothing changes). Run ./napwatch <GDHub pid> <seconds> in parallel to see whether
//   GDHub was App-Napped (all thread base priorities = 4) during the run.
//   Latency lines: "(kernel ts)" = HID-stack timestamps of both reports (excludes this probe's own wakeup);
//   "(callback clock)" = mach_absolute_time in this probe's callbacks.
import Foundation
import IOKit.hid
setvbuf(stdout, nil, _IOLBF, 0)

struct Ev { var t: UInt64; var kt: UInt64; var src: UInt8; var len: Int; var b: [UInt8] } // src 0 = phys, 1 = virt
var events: [Ev] = []
events.reserveCapacity(200_000)
let lock = NSLock()
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ns(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) }

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 10 : 10
let csvPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

final class Ctx { let src: UInt8; let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 512); init(_ s: UInt8) { src = s } }
var ctxs: [Ctx] = []
var opened: [String] = []

func pages(_ d: IOHIDDevice) -> [Int] {
    let pairs = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
    return pairs.compactMap { $0[kIOHIDDeviceUsagePageKey] as? Int }
}
func prop(_ d: IOHIDDevice, _ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? -1 }

let ready = DispatchSemaphore(value: 0)
var hidRL: CFRunLoop!
let th = Thread {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    hidRL = CFRunLoopGetCurrent()
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatchingMultiple(mgr, [
        [kIOHIDVendorIDKey: 0x1B1C, kIOHIDProductIDKey: 0x3A08],
        [kIOHIDVendorIDKey: 0x045E, kIOHIDProductIDKey: 0x02E0],
    ] as CFArray)
    IOHIDManagerScheduleWithRunLoop(mgr, hidRL, CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(mgr, 0)
    if r != kIOReturnSuccess { print(String(format: "IOHIDManagerOpen 0x%08x", r)) }
    let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> ?? []
    for d in set {
        let vid = prop(d, kIOHIDVendorIDKey), pg = pages(d)
        let src: UInt8
        if vid == 0x1B1C { guard pg.contains(0xFF58) else { continue }; src = 0 } else { src = 1 }
        let c = Ctx(src); ctxs.append(c)
        let tr = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? "?"
        opened.append(String(format: "%@ %04x:%04x pages=%@ transport=%@", src == 0 ? "PHYS" : "VIRT", vid, prop(d, kIOHIDProductIDKey), pg.map { String($0, radix: 16) }.joined(separator: ","), tr))
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(d, c.buf, 512, { ctx, _, _, _, rid, rep, len, kts in
            let t = mach_absolute_time()
            let c = Unmanaged<Ctx>.fromOpaque(ctx!).takeUnretainedValue()
            let b = Array(UnsafeBufferPointer(start: rep, count: len))
            lock.lock(); events.append(Ev(t: t, kt: kts, src: c.src, len: len, b: b)); lock.unlock()
        }, Unmanaged.passUnretained(c).toOpaque())
    }
    ready.signal()
    CFRunLoopRun()
}
th.qualityOfService = .userInteractive
th.start()
ready.wait()
for o in opened { print("opened", o) }
let t0 = mach_absolute_time()
Thread.sleep(forTimeInterval: seconds)
lock.lock(); let ev = events; lock.unlock()
print("run \(seconds)s, events \(ev.count)")

// MARK: analysis
func pct(_ a: [Double], _ p: Double) -> Double { if a.isEmpty { return .nan }; let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))] }
func summary(_ name: String, _ a: [Double]) {
    guard !a.isEmpty else { print("\(name): n=0"); return }
    print(String(format: "%@: n=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f min=%.3f mean=%.3f ms", name, a.count, pct(a, 0.5), pct(a, 0.95), pct(a, 0.99), a.max()!, a.min()!, a.reduce(0, +) / Double(a.count)))
}
let phys = ev.filter { $0.src == 0 && $0.len == 16 && $0.b[0] == 6 }
let virt1 = ev.filter { $0.src == 1 && $0.b.first == 1 }
let virtAll = ev.filter { $0.src == 1 }
func ia(_ e: [Ev], kernel: Bool) -> [Double] { zip(e.dropFirst(), e).map { ns(kernel ? $0.kt &- $1.kt : $0.t &- $1.t) / 1e6 } }
summary("PHYS 0x06 inter-arrival (callback clock)", ia(phys, kernel: false))
summary("PHYS 0x06 inter-arrival (kernel ts)", ia(phys, kernel: true))
summary("VIRT all inter-arrival (callback clock)", ia(virtAll, kernel: false))
summary("VIRT 0x01 inter-arrival (kernel ts)", ia(virt1, kernel: true))
summary("probe callback delay VIRT (cb - kernel ts)", virtAll.map { ns($0.t &- $0.kt) / 1e6 })
summary("probe callback delay PHYS (cb - kernel ts)", phys.map { ns($0.t &- $0.kt) / 1e6 })

func s16(_ b: [UInt8], _ i: Int) -> Double { Double(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)) / 32767.0 }
func u16n(_ b: [UInt8], _ i: Int) -> Double { Double(UInt16(b[i]) | UInt16(b[i + 1]) << 8) / 32767.5 - 1 }
func physAxes(_ b: [UInt8]) -> [Double] { [s16(b, 1), s16(b, 3), s16(b, 5), s16(b, 7)] }
func physTrig(_ b: [UInt8]) -> [Int] { let t = Int(b[9]) | Int(b[10]) << 8 | Int(b[11]) << 16; return [t & 0x3ff, (t >> 10) & 0x3ff] }
func physDigital(_ b: [UInt8]) -> UInt64 { let t = UInt64(b[11]) >> 4; let btn = UInt64(b[12]) | UInt64(b[13]) << 8 | UInt64(b[14]) << 16 | UInt64(b[15]) << 24; return t | (btn << 4) }
func virtAxes(_ b: [UInt8]) -> [Double] { [u16n(b, 1), u16n(b, 3), u16n(b, 5), u16n(b, 7)] }
func virtTrig(_ b: [UInt8]) -> [Int] { [Int(b[9]) | Int(b[10]) << 8, Int(b[11]) | Int(b[12]) << 8] }

// Event latency: physical "event" -> first virtual report (time order) that shows the matching kind of change.
// Kinds: digital (buttons/hat) change, trigger crossing 0->>0 or >0->0, stick onset (all axes < 0.12 for >=60 ms, then any > 0.25).
var lat: [String: [Double]] = [:]
func firstVirt(after t: UInt64, kernel: Bool, _ pred: (Ev, Ev?) -> Bool) -> Ev? {
    var prev: Ev? = nil
    for v in virtAll { if (kernel ? v.kt : v.t) <= t { if v.b.first == 1 || v.b.first == 2 { prev = v }; continue }; if pred(v, prev) { return v }; prev = v }
    return nil
}
var lastDig: UInt64? = nil, lastTrig: [Int]? = nil, restSince: UInt64? = nil, armed = true
var vDigPrev: (UInt8, UInt8, UInt8, UInt8)? = nil
for p in phys {
    let dig = physDigital(p.b), tr = physTrig(p.b), ax = physAxes(p.b)
    for useK in [false, true] {
        let tp = useK ? p.kt : p.t
        let tag = useK ? " (kernel ts)" : " (callback clock)"
        if let ld = lastDig, ld != dig {
            if let v = firstVirt(after: tp, kernel: useK, { v, prev in
                guard let pr = prev else { return false }
                if v.b.first == 2 { return true }
                if v.b.first == 1, v.b.count >= 16, pr.b.first == 1 { return v.b[13] != pr.b[13] || v.b[14] != pr.b[14] || v.b[15] != pr.b[15] }
                return false }) {
                lat["digital->virt" + tag, default: []].append(ns((useK ? v.kt : v.t) &- tp) / 1e6)
            }
        }
        if let lt = lastTrig {
            for i in 0..<2 where (lt[i] == 0) != (tr[i] == 0) {
                if let v = firstVirt(after: tp, kernel: useK, { v, _ in v.b.first == 1 && v.b.count >= 16 && ((virtTrig(v.b)[0] == 0 && virtTrig(v.b)[1] == 0) == (tr[0] == 0 && tr[1] == 0)) }) {
                    lat["trigger edge->virt" + tag, default: []].append(ns((useK ? v.kt : v.t) &- tp) / 1e6)
                }
            }
        }
    }
    let mag = ax.map { abs($0) }.max() ?? 0
    if mag < 0.12 { if restSince == nil { restSince = p.t }; if ns(p.t &- restSince!) > 60e6 { armed = true } }
    else { restSince = nil }
    if armed, mag > 0.25 {
        armed = false
        for useK in [false, true] {
            let tp = useK ? p.kt : p.t
            if let v = firstVirt(after: tp, kernel: useK, { v, _ in v.b.first == 1 && v.b.count >= 16 && (virtAxes(v.b).map { abs($0) }.max() ?? 0) > 0.12 }) {
                lat["stick onset->virt" + (useK ? " (kernel ts)" : " (callback clock)"), default: []].append(ns((useK ? v.kt : v.t) &- tp) / 1e6)
            }
        }
    }
    lastDig = dig; lastTrig = tr
}
for k in lat.keys.sorted() { summary(k, lat[k]!) }

// Continuous stick lag: for each phys axis i and virt axis j, find lag (0..60 ms, 0.25 ms step) maximising |corr|
// of phys(t - lag) vs virt(t), sampled every 1 ms over the run (zero-order hold). Reports best pair.
if phys.count > 100, virt1.count > 20 {
    let start = max(phys.first!.kt, virt1.first!.kt), end = min(phys.last!.kt, virt1.last!.kt)
    let step = 1e6 / (Double(tb.numer) / Double(tb.denom)) // 1 ms in ticks
    func hold(_ e: [Ev], _ f: @escaping (Ev) -> Double) -> (UInt64) -> Double {
        var idx = 0
        return { t in while idx + 1 < e.count, e[idx + 1].kt <= t { idx += 1 }; return f(e[idx]) }
    }
    var best = (corr: 0.0, lag: 0.0, i: 0, j: 0)
    let nSamples = Int(Double(end &- start) / step)
    if nSamples > 200 {
        for j in 0..<4 {
            let vh = hold(virt1) { virtAxes($0.b)[j] }
            let vs = (0..<nSamples).map { vh(start + UInt64(Double($0) * step)) }
            let vm = vs.reduce(0, +) / Double(vs.count)
            let vvar = vs.map { ($0 - vm) * ($0 - vm) }.reduce(0, +)
            if vvar < 1e-3 { continue }
            for i in 0..<4 {
                var lagMs = 0.0
                while lagMs <= 60 {
                    let off = UInt64(lagMs * step)
                    let ph = hold(phys) { physAxes($0.b)[i] }
                    let ps = (0..<nSamples).map { k -> Double in let t = start + UInt64(Double(k) * step); return t > start + off ? ph(t - off) : ph(start) }
                    let pm = ps.reduce(0, +) / Double(ps.count)
                    let pvar = ps.map { ($0 - pm) * ($0 - pm) }.reduce(0, +)
                    if pvar > 1e-3 {
                        let cov = zip(ps, vs).map { ($0 - pm) * ($1 - vm) }.reduce(0, +)
                        let c = cov / sqrt(pvar * vvar)
                        if abs(c) > abs(best.corr) + 1e-9 { best = (c, lagMs, i, j) }
                    }
                    lagMs += 0.25
                }
            }
        }
        if best.corr != 0 { print(String(format: "stick xcorr: best phys axis %d -> virt axis %d, corr %.4f at lag %.2f ms (kernel ts)", best.i, best.j, best.corr, best.lag)) }
        else { print("stick xcorr: sticks did not move (no variance)") }
    }
}

if let csvPath {
    var s = "src,cb_ns,kernel_ns,hex\n"
    for e in ev { s += "\(e.src == 0 ? "phys" : "virt"),\(Int(ns(e.t &- t0))),\(Int(ns(e.kt &- t0))),\(e.b.map { String(format: "%02x", $0) }.joined())\n" }
    try? s.write(toFile: csvPath, atomically: true, encoding: .utf8)
    print("csv:", csvPath)
}
exit(0)

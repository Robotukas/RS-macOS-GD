// napwatch <pid> [seconds=10]: read-only. Every 250 ms prints the target's thread priorities (cur/base) and
// whether any of its windows is on screen and which app is frontmost. App Nap / darwinbg shows as base pri 4.
import Foundation
import CoreGraphics
import AppKit

let pid = pid_t(CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) ?? 0 : 0)
let secs = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 10 : 10
setvbuf(stdout, nil, _IOLBF, 0)

func threads() -> [(cur: Int32, base: Int32, name: String)] {
    var ids = [UInt64](repeating: 0, count: 256)
    let n = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &ids, Int32(ids.count * 8)) / 8
    var out: [(Int32, Int32, String)] = []
    for i in 0..<Int(max(n, 0)) {
        var ti = proc_threadinfo()
        let r = proc_pidinfo(pid, PROC_PIDTHREADINFO, ids[i], &ti, Int32(MemoryLayout<proc_threadinfo>.size))
        if r <= 0 { continue }
        let name = withUnsafeBytes(of: ti.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        out.append((ti.pth_curpri, ti.pth_priority, name))
    }
    return out
}
func windowsOnscreen() -> (on: Int, total: Int) {
    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = all.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    return (mine.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }.count, mine.count)
}
let end = Date().addingTimeInterval(secs)
while Date() < end {
    let t = threads().map { "\($0.cur)/\($0.base)\($0.name.isEmpty ? "" : ":" + $0.name)" }.joined(separator: " ")
    let w = windowsOnscreen()
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    print(String(format: "%.2f front=%@ winOnscreen=%d/%d threads[cur/base]=%@", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000), front, w.on, w.total, t))
    Thread.sleep(forTimeInterval: 0.25)
}

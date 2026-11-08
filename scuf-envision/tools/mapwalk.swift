// mapwalk: guided control-by-control mapping of the SCUF Envision Pro receiver (1b1c:3a08).
// Prompts for one control at a time, records which report fields change, writes a Markdown table.
import Foundation
import IOKit.hid

let controls: [String] = [
    "1  View button (small button top-left)",
    "2  Menu button (small button top-right)",
    "3  Start button (centre, power icon)",
    "4  A button", "5  B button", "6  X button", "7  Y button",
    "8  LB bumper", "9  RB bumper",
    "10 LT: pull LEFT trigger fully, hold 1s, release",
    "11 RT: pull RIGHT trigger fully, hold 1s, release",
    "12 LEFT stick: click it in (L3)", "13 RIGHT stick: click it in (R3)",
    "14 D-pad UP", "15 D-pad RIGHT", "16 D-pad DOWN", "17 D-pad LEFT",
    "18 LEFT stick: push fully RIGHT, hold 1s, release",
    "19 LEFT stick: push fully DOWN, hold 1s, release",
    "20 RIGHT stick: push fully RIGHT, hold 1s, release",
    "21 RIGHT stick: push fully DOWN, hold 1s, release",
    "22 SAX button on the LEFT side", "23 SAX button on the RIGHT side",
    "24 G1 key (leftmost)", "25 G2 key", "26 G3 key", "27 G4 key", "28 G5 key (rightmost)",
    "29 Profile button (pill below Start)",
    "30 Paddle: outer LEFT as you look at the back",
    "31 Paddle: inner LEFT as you look at the back",
    "32 Paddle: inner RIGHT as you look at the back",
    "33 Paddle: outer RIGHT as you look at the back",
]


struct Fields: Equatable { var x = 0, y = 0, z = 0, rz = 0, lt = 0, rt = 0, hat = 8, buttons = 0, pad = 0 }
func s16(_ lo: UInt8, _ hi: UInt8) -> Int { let v = Int(lo) | Int(hi) << 8; return v >= 32768 ? v - 65536 : v }
func decode(_ b: [UInt8]) -> Fields {
    var f = Fields()
    f.x = s16(b[1], b[2]); f.y = s16(b[3], b[4]); f.z = s16(b[5], b[6]); f.rz = s16(b[7], b[8])
    let t = Int(b[9]) | Int(b[10]) << 8 | Int(b[11]) << 16
    f.lt = t & 0x3ff; f.rt = (t >> 10) & 0x3ff; f.hat = (t >> 20) & 0xf
    let btn = Int(b[12]) | Int(b[13]) << 8 | Int(b[14]) << 16 | Int(b[15]) << 24
    f.buttons = btn & 0x7ffff; f.pad = btn >> 19
    return f
}
func near(_ a: Fields, _ b: Fields) -> Bool {
    abs(a.x - b.x) < 4000 && abs(a.y - b.y) < 4000 && abs(a.z - b.z) < 4000 && abs(a.rz - b.rz) < 4000 &&
    abs(a.lt - b.lt) < 80 && abs(a.rt - b.rt) < 80 && a.hat == b.hat && a.buttons == b.buttons && a.pad == b.pad
}
let hatName = [0: "UP", 1: "UP-RIGHT", 2: "RIGHT", 3: "DOWN-RIGHT", 4: "DOWN", 5: "DOWN-LEFT", 6: "LEFT", 7: "UP-LEFT", 8: "null"]

var current = Fields()
var inStep = false
var stepFrames: [Fields] = []
var otherReports: [String] = []
var seenAny = false

final class Ctx { let label: String; let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); init(_ l: String) { label = l } }
var ctxs: [Ctx] = []
let inputCB: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
    guard let context = context else { return }
    let ctx = Unmanaged<Ctx>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    if ctx.label == "FF58" && reportID == 6 && length == 16 {
        current = decode(bytes); seenAny = true
        if inStep { stepFrames.append(current) }
    } else if inStep {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let s = "if \(ctx.label) id=0x\(String(format: "%02x", reportID)): \(hex)"
        if !otherReports.contains(s) { otherReports.append(s) }
    }
}
let matchCB: IOHIDDeviceCallback = { _, _, _, device in
    let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
    let ctx = Ctx(String(format: "%04X", page)); ctxs.append(ctx)
    IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDDeviceRegisterInputReportCallback(device, ctx.buf, 4096, inputCB, Unmanaged.passUnretained(ctx).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
}
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x1b1c, kIOHIDProductIDKey: 0x3a08] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCB, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mapping.md"
FileManager.default.createFile(atPath: outPath, contents: nil)
let out = FileHandle(forWritingAtPath: outPath)!
func emit(_ s: String) { print(s); fflush(stdout); out.write((s + "\n").data(using: .utf8)!) }

print("\u{1B}[2J\u{1B}[H")
print("SCUF Envision Pro mapping walk. Press ONLY the control named, then release. 40s per control, unanswered = skipped.\n")
CFRunLoopRunInMode(.defaultMode, 1.0, false)
if !seenAny { print("No report 0x06 seen from the receiver. Is it plugged in and the controller on?") }

print("\u{1B}[1mWhen you are ready, press and release ANY button on the controller to start.\u{1B}[0m"); fflush(stdout)
do {
    let base0 = current
    while near(current, base0) { CFRunLoopRunInMode(.defaultMode, 0.02, false) }
    while !near(current, base0) { CFRunLoopRunInMode(.defaultMode, 0.02, false) }
    print("Starting in 2 seconds...\n"); fflush(stdout)
    CFRunLoopRunInMode(.defaultMode, 2.0, false)
}
emit("| # | Control | Buttons (1-based) | Hat | Extra bits (pad) | Axes / triggers | Other reports |")
emit("|---|---------|-------------------|-----|------------------|-----------------|---------------|")

for (i, name) in controls.enumerated() {
    CFRunLoopRunInMode(.defaultMode, 0.3, false)
    let base = current
    stepFrames = []; otherReports = []; inStep = true
    print("\n\u{1B}[1m[\(i + 1)/\(controls.count)] \(name)\u{1B}[0m"); fflush(stdout)
    let t0 = Date(); var started: Date? = nil; var lastActive = Date()
    while true {
        CFRunLoopRunInMode(.defaultMode, 0.02, false)
        let active = !near(current, base) || (started == nil && !otherReports.isEmpty)
        if active { if started == nil { started = Date(); print("   ...got it, release") ; fflush(stdout) }; lastActive = Date() }
        if let s = started { if Date().timeIntervalSince(lastActive) > 0.5 || Date().timeIntervalSince(s) > 8 { break } }
        else if Date().timeIntervalSince(t0) > 40 { break }
    }
    inStep = false
    if started == nil && otherReports.isEmpty { emit("| \(i + 1) | \(name) | — | — | — | — | (skipped, no input) |"); continue }
    var btns = 0, pad = 0, hats = Set<Int>()
    var peak: [String: Int] = [:]
    for f in stepFrames {
        btns |= f.buttons & ~base.buttons; pad |= f.pad & ~base.pad
        if f.hat != 8 && f.hat != base.hat { hats.insert(f.hat) }
        for (k, v, b, th) in [("X", f.x, base.x, 8000), ("Y", f.y, base.y, 8000), ("Z", f.z, base.z, 8000), ("Rz", f.rz, base.rz, 8000), ("LT", f.lt, base.lt, 200), ("RT", f.rt, base.rt, 200)] {
            if abs(v - b) > th && abs(v - b) > abs((peak[k] ?? b) - b) { peak[k] = v }
        }
    }
    let bl = (0..<19).filter { btns >> $0 & 1 == 1 }.map { String($0 + 1) }.joined(separator: ",")
    let pl = (0..<13).filter { pad >> $0 & 1 == 1 }.map { "bit\($0)" }.joined(separator: ",")
    let hl = hats.sorted().map { hatName[$0] ?? "\($0)" }.joined(separator: ",")
    let al = peak.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    let ol = otherReports.joined(separator: "; ")
    emit("| \(i + 1) | \(name) | \(bl.isEmpty ? "—" : bl) | \(hl.isEmpty ? "—" : hl) | \(pl.isEmpty ? "—" : pl) | \(al.isEmpty ? "—" : al) | \(ol.isEmpty ? "—" : ol) |")
}
emit("\nDone. Baseline idle frame fields: \(current)")
print("\nMapping written to \(outPath). You can close this tab.")

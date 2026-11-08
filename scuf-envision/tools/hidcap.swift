// hidcap: log every HID input report from the SCUF Envision Pro receiver (1b1c:3a08).
// usage: hidcap [seconds]   (default 15). Identical consecutive reports are collapsed.
import Foundation
import IOKit.hid

let vid = 0x1b1c, pid = 0x3a08
let seconds = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "15") ?? 15
let start = Date()
func ts() -> String { String(format: "%7.3f", Date().timeIntervalSince(start)) }

final class Ctx {
    let label: String
    let buf: UnsafeMutablePointer<UInt8>
    var last: [UInt32: [UInt8]] = [:]
    var dup: [UInt32: Int] = [:]
    var total = 0
    init(label: String) { self.label = label; buf = .allocate(capacity: 4096) }
}
var ctxs: [Ctx] = []

let inputCB: IOHIDReportCallback = { context, result, sender, type, reportID, report, length in
    guard let context = context else { return }
    let ctx = Unmanaged<Ctx>.fromOpaque(context).takeUnretainedValue()
    ctx.total += 1
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    if ctx.last[reportID] == bytes { ctx.dup[reportID, default: 0] += 1; return }
    let d = ctx.dup[reportID] ?? 0
    ctx.last[reportID] = bytes; ctx.dup[reportID] = 0
    let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    print("\(ts()) [\(ctx.label)] id=0x\(String(format: "%02x", reportID)) len=\(length)\(d > 0 ? " (+\(d) identical before)" : ""): \(hex)")
    fflush(stdout)
}

let matchCB: IOHIDDeviceCallback = { _, _, _, device in
    let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
    let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
    let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
    let label = String(format: "if page=0x%04X", page)
    let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print("\(ts()) matched \(label) usage=\(usage) open=\(r == kIOReturnSuccess ? "ok" : String(format: "0x%08x", r))")
    if let pairs = pairs { print("        usage pairs: \(pairs)") }
    let ctx = Ctx(label: label); ctxs.append(ctx)
    IOHIDDeviceRegisterInputReportCallback(device, ctx.buf, 4096, inputCB, Unmanaged.passUnretained(ctx).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    fflush(stdout)
}
let removeCB: IOHIDDeviceCallback = { _, _, _, _ in print("\(ts()) device removed"); fflush(stdout) }

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCB, nil)
IOHIDManagerRegisterDeviceRemovalCallback(mgr, removeCB, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("manager open: \(r == kIOReturnSuccess ? "ok" : String(format: "0x%08x", r)); capturing for \(Int(seconds))s")
fflush(stdout)
CFRunLoopRunInMode(.defaultMode, seconds, false)
for c in ctxs {
    print("[\(c.label)] total reports received: \(c.total)")
    for (id, n) in c.dup where n > 0 { print("[\(c.label)] id=0x\(String(format: "%02x", id)) ended with \(n) further identical reports") }
}
print("done")

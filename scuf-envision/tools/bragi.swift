// bragi: send Corsair "Bragi" control packets to the SCUF Envision Pro receiver (1b1c:3a08 / 3a09) and print replies.
// The control channel is the vendor 0xFF42 collection: output report 0x02 (63 bytes) = <target> <command…>,
// reply = input report 0x01. Targets: 08 = receiver, 09 = paired controller.
// usage: bragi <target>:<hex bytes> [...]      e.g.  bragi 09:020e 09:020d 08:0203
//   GET property p   = 02 pp          SET property p = 01 pp 00 <value little-endian>
// Each packet is sent in order; replies are printed as hex. Read-only unless you pass a SET (01 …).
import Foundation
import IOKit.hid

struct Cmd { let target: UInt8; let bytes: [UInt8]; let text: String }
func parse(_ s: String) -> Cmd? {
    let p = s.split(separator: ":"); guard p.count == 2, let t = UInt8(p[0], radix: 16) else { return nil }
    let h = Array(p[1]); guard h.count % 2 == 0 else { return nil }
    var b: [UInt8] = []
    for i in stride(from: 0, to: h.count, by: 2) { guard let v = UInt8(String(h[i...i+1]), radix: 16) else { return nil }; b.append(v) }
    return Cmd(target: t, bytes: b, text: s)
}
let cmds = CommandLine.arguments.dropFirst().compactMap(parse)
guard !cmds.isEmpty, cmds.count == CommandLine.arguments.count - 1 else { print("usage: bragi <target>:<hex> [...]"); exit(2) }

var replies: [[UInt8]] = []
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
let cb: IOHIDReportCallback = { _, _, _, _, reportID, report, length in
    replies.append(Array(UnsafeBufferPointer(start: report, count: length)))
}
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(mgr, [[kIOHIDVendorIDKey: 0x1b1c, kIOHIDProductIDKey: 0x3a08],
                                            [kIOHIDVendorIDKey: 0x1b1c, kIOHIDProductIDKey: 0x3a09]] as CFArray)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { print("receiver not found"); exit(1) }
// The control collections (0xFF42) live on the interface whose usage pairs include page 0xFF42.
func hasFF42(_ d: IOHIDDevice) -> Bool {
    let pairs = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
    return pairs.contains { ($0[kIOHIDDeviceUsagePageKey] as? Int) == 0xFF42 }
}
guard let dev = set.first(where: hasFF42) else { print("no 0xFF42 control interface found"); exit(1) }
let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
print(String(format: "control interface on 1b1c:%04x", pid))
IOHIDDeviceRegisterInputReportCallback(dev, buf, 256, cb, nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

for c in cmds {
    var out = [UInt8](repeating: 0, count: 64)          // report id 0x02 + 63 bytes
    out[0] = 0x02; out[1] = c.target
    for (i, v) in c.bytes.enumerated() where 2 + i < 64 { out[2 + i] = v }
    replies.removeAll()
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, out, out.count)
    if r != kIOReturnSuccess { print("\(c.text): send failed " + String(format: "0x%08x", r)); continue }
    let deadline = Date().addingTimeInterval(0.6)
    while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, true); if !replies.isEmpty { CFRunLoopRunInMode(.defaultMode, 0.05, true); break } }
    if replies.isEmpty { print("\(c.text): no reply") }
    for rep in replies {
        let trimmed = Array(rep.prefix(12))
        var note = ""
        if rep.count >= 8 { let v = UInt32(rep[4]) | UInt32(rep[5]) << 8 | UInt32(rep[6]) << 16 | UInt32(rep[7]) << 24; note = "  value(le32 @4)=\(v) status=\(rep[3])" }
        print("\(c.text): \(hex(trimmed)) …\(note)")
    }
}

// sdlmatch: emulate SDL's macOS joystick matching (Generic Desktop joystick/gamepad/multi-axis)
import Foundation
import IOKit.hid
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let m: [[String: Any]] = [4, 5, 8].map { [kIOHIDDeviceUsagePageKey as String: 1, kIOHIDDeviceUsageKey as String: $0] }
IOHIDManagerSetDeviceMatchingMultiple(mgr, m as CFArray)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> ?? []
print("devices matching GD joystick/gamepad/multiaxis: \(set.count)")
for d in set {
    let vid = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? 0
    let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
    let elems = IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
    var buttons = 0, axes = 0, hats = 0
    for e in elems where IOHIDElementGetType(e).rawValue <= kIOHIDElementTypeInput_ScanCodes.rawValue {
        let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e)
        if page == 9 { buttons += 1 } else if page == 1 && usage == 0x39 { hats += 1 } else if page == 1 && (0x30...0x38).contains(usage) { axes += 1 }
    }
    print(String(format: "  %04x:%04x %@  axes=%d buttons=%d hats=%d (elements=%d)", vid, pid, name, axes, buttons, hats, elems.count))
}

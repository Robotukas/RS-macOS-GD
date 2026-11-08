// gcprobe: does Apple's GameController framework see the receiver as a controller?
import Foundation
import GameController
func describe(_ c: GCController) {
    var s = "  vendor=\(c.vendorName ?? "?") category=\(c.productCategory) extended=\(c.extendedGamepad != nil) micro=\(c.microGamepad != nil)"
    s += " elements=\(c.physicalInputProfile.elements.count)"
    s += " buttons=\(c.physicalInputProfile.buttons.keys.sorted().joined(separator: ","))"
    print(s)
}
print("GCController.controllers() at start: \(GCController.controllers().count)")
GCController.controllers().forEach(describe)
var seen = 0
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
    if let c = n.object as? GCController { seen += 1; print("connect notification:"); describe(c) }
}
GCController.startWirelessControllerDiscovery { print("discovery finished") }
RunLoop.main.run(until: Date().addingTimeInterval(5))
print("after 5s: \(GCController.controllers().count) controllers, \(seen) connect notifications")
GCController.controllers().forEach(describe)

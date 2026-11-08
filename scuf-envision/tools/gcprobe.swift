// gcprobe: does Apple's GameController framework see the receiver as a controller?
import Foundation
import GameController
// Usage: gcprobe            list controllers after 5 s
//        gcprobe --watch    then print extendedGamepad value changes until interrupted (or `--watch <seconds>`)
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

// --watch: print each extendedGamepad element change, e.g. "buttonA pressed value=1.00".
if let i = CommandLine.arguments.firstIndex(of: "--watch") {
    var seconds = 0.0
    if i + 1 < CommandLine.arguments.count, let n = Double(CommandLine.arguments[i + 1]) { seconds = n }
    GCController.shouldMonitorBackgroundEvents = true      // a command-line tool is never the key app
    func name(_ e: GCControllerElement) -> String { e.aliases.sorted().first ?? e.localizedName ?? "?" }
    func attach(_ c: GCController) {
        guard let g = c.extendedGamepad else { print("watch: \(c.vendorName ?? "?") has no extendedGamepad"); return }
        print("watch: attached to \(c.vendorName ?? "?") (\(c.productCategory))")
        g.valueChangedHandler = { _, element in
            let t = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
            if let b = element as? GCControllerButtonInput {
                print("\(t) \(name(b)) \(b.isPressed ? "pressed" : "released") value=\(String(format: "%.2f", b.value))")
            } else if let d = element as? GCControllerDirectionPad {
                print("\(t) \(name(d)) x=\(String(format: "%.2f", d.xAxis.value)) y=\(String(format: "%.2f", d.yAxis.value))")
            } else {
                print("\(t) \(name(element))")
            }
        }
    }
    GCController.controllers().forEach(attach)
    NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
        if let c = n.object as? GCController { attach(c) }
    }
    NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in print("watch: controller disconnected") }
    setvbuf(stdout, nil, _IOLBF, 0)
    if seconds > 0 { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) } else { RunLoop.main.run() }
}

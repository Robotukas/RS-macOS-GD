import AppKit
let args = CommandLine.arguments
let src = args[1], dst = args[2]
guard let img = NSImage(contentsOfFile: src), let tiff = img.tiffRepresentation, let orig = NSBitmapImageRep(data: tiff) else { fatalError("load") }
let W = orig.pixelsWide, H = orig.pixelsHigh
func rgba() -> NSBitmapImageRep { NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)! }
let base = rgba()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: base)!
img.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()
let rep = rgba()
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
img.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
// SCUF's own badges to cover: (x, y) in top-left pixel coords. Radial fill: each pixel inside the disk
// takes the colour of the pixel just outside the disk along the same ray, so edges continue through.
NSGraphicsContext.restoreGraphicsState()
let cover: [(Int, Int)] = [(230,125),(467,133),(340,245),(540,238),(412,235),(476,285),(143,243),(290,330),(412,368),(340,383),(140,323),(100,153),(800,392),(712,462),(517,471),(850,452),(820,175),(364,305),(672,553),(307,383),(372,383),(210,720),(797,612),(455,680),(322,720)]
let R = 24.0
let bp = base.bitmapData!, dp = rep.bitmapData!, bpr = base.bytesPerRow, dbpr = rep.bytesPerRow
// Harmonic inpainting: pixels inside the disk relax to the average of their neighbours, boundary pixels stay fixed.
let S = 30
for (cx, cy) in cover {
    let side = 2 * S + 1
    var v = [Float](repeating: 0, count: side * side * 4)
    var inside = [Bool](repeating: false, count: side * side)
    for j in 0..<side { for i in 0..<side {
        let x = cx - S + i, y = cy - S + j
        let idx = j * side + i
        if x >= 0 && y >= 0 && x < W && y < H {
            let o = y * bpr + x * 4
            for c in 0..<4 { v[idx * 4 + c] = Float(bp[o + c]) }
        }
        let dx = Double(i - S), dy = Double(j - S)
        inside[idx] = (dx * dx + dy * dy).squareRoot() <= R
    } }
    for _ in 0..<600 {
        var nv = v
        for j in 1..<(side - 1) { for i in 1..<(side - 1) {
            let idx = j * side + i
            if !inside[idx] { continue }
            for c in 0..<4 {
                nv[idx * 4 + c] = (v[(idx - 1) * 4 + c] + v[(idx + 1) * 4 + c] + v[(idx - side) * 4 + c] + v[(idx + side) * 4 + c]) / 4
            }
        } }
        v = nv
    }
    for j in 0..<side { for i in 0..<side {
        let idx = j * side + i
        if !inside[idx] { continue }
        let x = cx - S + i, y = cy - S + j
        guard x >= 0 && y >= 0 && x < W && y < H else { continue }
        let o = y * dbpr + x * 4
        for c in 0..<4 { dp[o + c] = UInt8(max(0, min(255, v[idx * 4 + c].rounded()))) }
    } }
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
// our badges: number, x, y (top-left coords)
let badges: [(String, Int, Int)] = [
    ("1",238,160),("2",438,158),("3",340,275),
    ("4",497,240),("5",535,205),("6",462,205),("7",497,165),
    ("8",548,428),("9",805,428),("10",510,472),("11",845,472),
    ("12",268,272),("13",420,272),
    ("14",180,172),("15",213,205),("16",180,238),("17",147,205),
    ("18",308,272),("19",268,312),("20",460,272),("21",420,312),
    ("22",92,165),("23",590,165),
    ("24",237,350),("25",286,350),("26",336,350),("27",386,350),("28",436,350),
    ("29",340,318),
    ("30",548,598),("31",592,632),("32",752,632),("33",800,598),
]
let font = NSFont.boldSystemFont(ofSize: 15)
for (label, x, y) in (args.count > 3 ? [] : badges) {
    let cx = Double(x), cy = Double(H - y)
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 15, y: cy - 15, width: 30, height: 30)).fill()
    NSColor(red: 0.91, green: 0.35, blue: 0.05, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 13, y: cy - 13, width: 26, height: 26)).fill()
    let s = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
    let sz = s.size(); s.draw(at: NSPoint(x: cx - sz.width / 2, y: cy - sz.height / 2))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dst))
print("wrote \(dst) \(W)x\(H)")

import AppKit
let img = NSImage(contentsOfFile: "scuf-anatomy-full.png")!
let W = 1000, H = 834
let base = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: base)!
img.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()
let bp = base.bitmapData!, bpr = base.bytesPerRow
print("bytesPerRow", bpr, "format", base.bitmapFormat.rawValue, "bitsPerPixel", base.bitsPerPixel)
for (x, y, what) in [(30,30,"white bg top-left"),(300,200,"controller body"),(230,125,"SCUF badge 1 (white)"),(455,680,"badge 24 on black grip"),(500,700,"black grip")] {
    let o = y * bpr + x * 4
    print(what, "bytes:", bp[o], bp[o+1], bp[o+2], bp[o+3])
}

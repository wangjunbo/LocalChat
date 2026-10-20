import AppKit
// Derived from the Mac icon drawing; HarmonyOS owns the launcher mask.
let output = CommandLine.arguments[1]
let layer = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "composite"
let size = NSSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
if layer != "foreground" {
let background = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGradient(starting: NSColor(calibratedRed: 0.42, green: 0.68, blue: 0.90, alpha: 1), ending: NSColor(calibratedRed: 0.16, green: 0.39, blue: 0.65, alpha: 1))!.draw(in: background, angle: -65)
}
func bubble(_ rect: NSRect, _ color: NSColor, left: Bool) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 40, yRadius: 40).fill()
    let tail = NSBezierPath()
    let x = left ? rect.minX + 60 : rect.maxX - 60
    tail.move(to: NSPoint(x: x, y: rect.minY + 35))
    tail.line(to: NSPoint(x: x, y: rect.minY - 56))
    tail.line(to: NSPoint(x: x + (left ? 100 : -100), y: rect.minY + 10))
    tail.close(); tail.fill()
}
if layer != "background" {
bubble(NSRect(x: 430, y: 300, width: 360, height: 265), NSColor.white.withAlphaComponent(0.40), left: false)
bubble(NSRect(x: 230, y: 440, width: 420, height: 295), .white, left: true)
NSColor(calibratedRed: 0.16, green: 0.39, blue: 0.65, alpha: 1).setFill()
for x in [330, 425, 520] { NSBezierPath(ovalIn: NSRect(x: x, y: 565, width: 34, height: 34)).fill() }
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))

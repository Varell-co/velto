// Regenerates Branding/Velto.icns from the kit's dark app icon: `swift Branding/make-icon.swift`.
// Drawn on Apple's macOS icon grid (824 pt body in a 1024 pt canvas) so it sits with other Dock icons;
// the kit's SVG fills the whole canvas and would look oversized.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Velto.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    color(0x111319).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Faint light from the top, as on the kit's rendered icon.
    NSGradient(starting: color(0x252832), ending: color(0x111319))!.draw(in: shape, angle: -90)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: 184 * s, yRadius: 184 * s)
    rim.lineWidth = 3 * s
    rim.stroke()

    // The mark's 64-unit artboard at 60% of the body, as in the kit (translate 51,50 · scale 2.406 on 256).
    let unit = 824 * s * 0.6 / 64
    let origin = NSPoint(x: body.midX - 32 * unit, y: body.midY + 32 * unit)
    for (from, to, hex) in [((11.0, 42.0), (41.0, 12.0), UInt32(0x999CFF)), ((31.0, 52.0), (51.0, 32.0), UInt32(0x6259C6))] {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: origin.x + from.0 * unit, y: origin.y - from.1 * unit))
        path.line(to: NSPoint(x: origin.x + to.0 * unit, y: origin.y - to.1 * unit))
        path.lineWidth = 14 * unit
        path.lineCapStyle = .round
        color(hex).setStroke()
        path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Velto.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("velto-icon-1024.png"))
print("Wrote Branding/Velto.icns")

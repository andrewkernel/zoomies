// Draws the Zoomies app icon: a near-black squircle with a coral ASCII swirl.
// Usage: swift scripts/make-icon.swift OUTPUT.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.105, blue: 0.12, alpha: 1), NSColor(red: 0.035, green: 0.038, blue: 0.045, alpha: 1)])!
        .draw(in: shape, angle: -90)
    shape.addClip()
    let ramp = Array(" .·:;-=+*cxzo#%@")
    let cell = rect.width / 22
    let font = NSFont.monospacedSystemFont(ofSize: cell * 1.05, weight: .bold)
    let cx = rect.midX, cy = rect.midY
    let maxR = Double(rect.width) * 0.55
    var row = 0
    var y = rect.minY
    while y < rect.maxY {
        var x = rect.minX
        while x < rect.maxX {
            let dx = Double(x + cell / 2 - cx), dy = Double(y + cell / 2 - cy)
            let r = (dx * dx + dy * dy).squareRoot()
            let theta = atan2(dy, dx)
            let arms = sin(3 * theta + log(r + 6) * 4.6)
            let falloff = max(0, 1 - r / maxR)
            let v = ((arms * 0.5 + 0.5) * falloff + exp(-r / (Double(rect.width) * 0.12)) * 0.6)
            if v > 0.28 {
                let idx = min(ramp.count - 1, Int((v - 0.28) / 0.72 * Double(ramp.count)))
                let warm = min(1, v * 1.25)
                let color = NSColor(red: 0.55 + 0.37 * warm, green: 0.58 - 0.11 * warm, blue: 0.62 - 0.30 * warm, alpha: 0.25 + 0.75 * falloff)
                String(ramp[idx]).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
            }
            x += cell * 0.62
        }
        y += cell
        row += 1
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
print(out.path)

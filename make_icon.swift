import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(srgbRed: 0.27, green: 0.27, blue: 0.30, alpha: 1),
    NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1),
    NSColor(srgbRed: 0.01, green: 0.01, blue: 0.015, alpha: 1),
], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: path, angle: -45)
NSColor(white: 1, alpha: 0.12).setStroke()
path.lineWidth = 5
path.stroke()

let symbolName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "paperplane.fill"
if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 420, weight: .semibold)) {
    let white = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    let s = white.size
    let scale = min(500 / s.width, 500 / s.height)
    let w = s.width * scale, h = s.height * scale
    white.draw(in: NSRect(x: (size - w) / 2 - 8, y: (size - h) / 2 - 8, width: w, height: h))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

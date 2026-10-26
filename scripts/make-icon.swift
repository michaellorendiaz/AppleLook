// Turn free-form icon art into a macOS app icon: the art on a rounded-square tile,
// using Apple's 1024 px grid (824 px tile, 100 px margin) so it sits like other icons.
//   swift scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]) else {
    print("usage: make-icon.swift <art.png> <out.png>")
    exit(2)
}

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Soft drop shadow under the tile
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -8)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// White to pale blue, top to bottom
NSGradient(starting: .white, ending: NSColor(srgbRed: 0.87, green: 0.92, blue: 0.98, alpha: 1))!
    .draw(in: shape, angle: -90)

shape.addClip()
art.draw(in: tile.insetBy(dx: 56, dy: 56), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))

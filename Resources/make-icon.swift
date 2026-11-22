// Draws the app icon at 1024px. Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Standard macOS icon plate: 824pt square on a 1024 canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)
NSGradient(
    starting: NSColor(white: 0.22, alpha: 1),
    ending: NSColor(white: 0.09, alpha: 1)
)!.draw(in: shape, angle: -90)

// A faint top edge so the plate reads against dark backgrounds.
NSColor(white: 1, alpha: 0.10).setStroke()
let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
edge.lineWidth = 4
edge.stroke()

// A page margin line, then the markdown heading mark.
NSColor(red: 0.98, green: 0.36, blue: 0.32, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 270, y: 250, width: 14, height: 524), xRadius: 7, yRadius: 7).fill()

let glyph = NSAttributedString(string: "#", attributes: [
    .font: NSFont.systemFont(ofSize: 430, weight: .bold),
    .foregroundColor: NSColor(white: 0.96, alpha: 1),
])
let bounds = glyph.size()
glyph.draw(at: NSPoint(x: 560 - bounds.width / 2, y: 512 - bounds.height / 2))

NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

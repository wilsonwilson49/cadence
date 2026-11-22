import AppKit

// Cadence icon: a flat navy tile, a book-serif "C", and a small blue tick tucked into its opening.
func render(size: CGFloat, inset: CGFloat, radius: CGFloat, shadow: Bool, out: String) {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = size / 1024
    let tile = NSRect(x: inset * k, y: inset * k, width: size - 2 * inset * k, height: size - 2 * inset * k)
    let path = NSBezierPath(roundedRect: tile, xRadius: radius * k, yRadius: radius * k)
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor(srgbRed: 0.090, green: 0.137, blue: 0.239, alpha: 1).setFill(); path.fill()
        ctx.restoreGState()
    }
    NSColor(srgbRed: 0.090, green: 0.137, blue: 0.239, alpha: 1).setFill(); path.fill()
    if shadow {
        NSColor(srgbRed: 0.20, green: 0.27, blue: 0.40, alpha: 1).setStroke()
        path.lineWidth = 3 * k; path.stroke()
    }
    // The C.
    let scale = (size - 2 * inset * k) / (824 * k)
    let font = NSFont(name: "Georgia-Bold", size: 610 * k * scale)!
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)]
    let c = NSAttributedString(string: "C", attributes: attrs)
    let b = c.size()
    let cx = size / 2 - 44 * k * scale, cy = size / 2
    c.draw(at: NSPoint(x: cx - b.width / 2, y: cy - b.height / 2 - 8 * k * scale))
    // The tick, in the opening of the C.
    let t = NSBezierPath()
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: size / 2 + x * k * scale, y: size / 2 + y * k * scale) }
    t.move(to: p(92, -18)); t.line(to: p(142, -68)); t.line(to: p(248, 52))
    t.lineWidth = 44 * k * scale; t.lineCapStyle = .round; t.lineJoinStyle = .round
    NSColor(srgbRed: 0.090, green: 0.137, blue: 0.239, alpha: 1).setStroke()
    let halo = t.copy() as! NSBezierPath; halo.lineWidth = 78 * k * scale; halo.stroke()
    NSColor(srgbRed: 0.51, green: 0.66, blue: 0.94, alpha: 1).setStroke(); t.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}
let dir = CommandLine.arguments[1]
render(size: 1024, inset: 100, radius: 185, shadow: true, out: dir + "/mac-1024.png")
render(size: 1024, inset: 0, radius: 0, shadow: false, out: dir + "/ios-1024.png")
render(size: 1024, inset: 0, radius: 180, shadow: false, out: dir + "/web-1024.png")

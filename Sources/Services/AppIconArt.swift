import AppKit
import CoreText

/// The Cadence icon: a flat navy tile, a bold "C" in the app's font, and a small blue tick tucked into its opening.
/// The Dock icon is drawn from this at launch (and when the font changes in Settings › Appearance), so it always
/// matches the chosen font. The icon files in the asset catalogs are exported from here too (debug flag -exportIcons).
enum AppIconArt {
    static let navy = NSColor(srgbRed: 0.090, green: 0.137, blue: 0.239, alpha: 1)
    static let paper = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    static let tick = NSColor(srgbRed: 0.51, green: 0.66, blue: 0.94, alpha: 1)

    enum Shape { case mac, square, rounded }

    /// The bold face of a family ("System" = the system font).
    static func boldFont(_ family: String, size: CGFloat) -> NSFont {
        if family == AppFont.system { return .systemFont(ofSize: size, weight: .bold) }
        return NSFontManager.shared.font(withFamily: family, traits: .boldFontMask, weight: 9, size: size)
            ?? NSFont(name: family, size: size) ?? .systemFont(ofSize: size, weight: .bold)
    }

    static func bitmap(size: Int, shape: Shape, family: String = AppFont.family) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGFloat(size), shape: shape, family: family)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func image(size: Int = 512, family: String = AppFont.family) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(bitmap(size: size, shape: .mac, family: family))
        return img
    }

    private static func draw(in size: CGFloat, shape: Shape, family: String) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let k = size / 1024
        // macOS icons sit inside the canvas with room for a shadow; iPhone icons fill it (iOS rounds the corners).
        let inset: CGFloat = shape == .mac ? 100 * k : 0
        let radius: CGFloat = shape == .mac ? 185 * k : shape == .rounded ? 180 * k : 0
        let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        if shape == .mac {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            navy.setFill(); path.fill()
            ctx.restoreGState()
        }
        navy.setFill(); path.fill()
        if shape == .mac {
            NSColor(srgbRed: 0.20, green: 0.27, blue: 0.40, alpha: 1).setStroke()
            path.lineWidth = 3 * k; path.stroke()
        }

        // The C, placed by its ink (not its line box) so every font sits the same way: a little left of centre.
        let side = tile.width
        let font = boldFont(family, size: side * 0.62)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "C", attributes: [.font: font, .foregroundColor: paper]))
        let ink = CTLineGetImageBounds(line, ctx)
        let target = CGPoint(x: tile.midX - side * 0.09, y: tile.midY)
        ctx.textPosition = CGPoint(x: target.x - ink.midX, y: target.y - ink.midY)
        CTLineDraw(line, ctx)
        let g = CGRect(x: target.x - ink.width / 2, y: target.y - ink.height / 2, width: ink.width, height: ink.height)

        // The tick, in the opening of the C, cut out of it by a navy halo.
        let t = NSBezierPath()
        // It starts just inside the C's terminals and rises out past its right edge, the same for every font.
        let u = side * 0.1
        let start = CGPoint(x: g.maxX - u * 0.85, y: g.midY + u * 0.05)
        t.move(to: start)
        t.line(to: CGPoint(x: start.x + u * 0.95, y: start.y - u * 0.95))
        t.line(to: CGPoint(x: start.x + u * 2.75, y: start.y + u * 1.25))
        t.lineCapStyle = .round; t.lineJoinStyle = .round
        let halo = t.copy() as! NSBezierPath
        halo.lineWidth = side * 0.1; navy.setStroke(); halo.stroke()
        t.lineWidth = side * 0.056; tick.setStroke(); t.stroke()
    }

    /// Writes the icon files the asset catalogs and the website use (debug flag `-exportIcons <dir>`).
    static func export(to dir: URL, family: String) throws {
        func png(_ size: Int, _ shape: Shape, _ name: String) throws {
            try bitmap(size: size, shape: shape, family: family).representation(using: .png, properties: [:])!
                .write(to: dir.appendingPathComponent(name))
        }
        try png(1024, .mac, "mac-1024.png")
        try png(1024, .square, "ios-1024.png")
        try png(1024, .rounded, "web-1024.png")
    }

    /// The Dock icon while Cadence runs, in the chosen font.
    @MainActor static func applyToDock() { NSApp.applicationIconImage = image() }
}

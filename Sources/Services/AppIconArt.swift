import AppKit
import CoreText

/// The Cadence icon: a navy metronome, its blue pendulum mid-swing, on a white tile.
/// The Dock icon is drawn from this at launch; the icon files in the asset catalogs are exported from here too
/// (debug flag -exportIcons). (`family` is kept for callers; the metronome has no lettering.)
enum AppIconArt {
    static let navy = NSColor(srgbRed: 0.090, green: 0.137, blue: 0.239, alpha: 1)
    static let face = NSColor(srgbRed: 0.88, green: 0.91, blue: 0.96, alpha: 1)
    static let swing = NSColor(srgbRed: 0.18, green: 0.42, blue: 0.86, alpha: 1)
    static let tile = NSColor.white

    enum Shape { case mac, square, rounded }

    static func bitmap(size: Int, shape: Shape, family: String = AppFont.family) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: CGFloat(size), shape: shape)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func image(size: Int = 512, family: String = AppFont.family) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(bitmap(size: size, shape: .mac))
        return img
    }

    private static func draw(in size: CGFloat, shape: Shape) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let k = size / 1024
        // macOS icons sit inside the canvas with room for a shadow; iPhone icons fill it (iOS rounds the corners).
        let inset: CGFloat = shape == .mac ? 100 * k : 0
        let radius: CGFloat = shape == .mac ? 185 * k : shape == .rounded ? 180 * k : 0
        let box = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        if shape == .mac {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: NSColor.black.withAlphaComponent(0.30).cgColor)
            tile.setFill(); path.fill()
            ctx.restoreGState()
        }
        tile.setFill(); path.fill()
        if shape == .mac {
            NSColor(white: 0.82, alpha: 1).setStroke()
            path.lineWidth = 2 * k; path.stroke()
        }

        // Everything below is in units of the tile's side, from its bottom-left corner.
        let S = box.width
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * S, y: box.minY + y * S) }
        let cx: CGFloat = 0.5

        // Plinth.
        navy.setFill()
        NSBezierPath(roundedRect: NSRect(origin: p(cx - 0.31, 0.13), size: CGSize(width: 0.62 * S, height: 0.065 * S)),
                     xRadius: 0.02 * S, yRadius: 0.02 * S).fill()

        // Body: a tall trapezoid with softened corners, and a small knob on top.
        let body = NSBezierPath()
        body.move(to: p(cx - 0.27, 0.19)); body.line(to: p(cx + 0.27, 0.19))
        body.line(to: p(cx + 0.105, 0.80)); body.line(to: p(cx - 0.105, 0.80)); body.close()
        body.lineJoinStyle = .round; body.lineWidth = 0.05 * S
        navy.setFill(); navy.setStroke(); body.fill(); body.stroke()
        NSBezierPath(ovalIn: NSRect(origin: p(cx - 0.045, 0.80), size: CGSize(width: 0.09 * S, height: 0.06 * S))).fill()

        // Face plate with its tempo scale.
        let face = NSBezierPath()
        face.move(to: p(cx - 0.165, 0.30)); face.line(to: p(cx + 0.165, 0.30))
        face.line(to: p(cx + 0.06, 0.74)); face.line(to: p(cx - 0.06, 0.74)); face.close()
        face.lineJoinStyle = .round; face.lineWidth = 0.02 * S
        Self.face.setFill(); Self.face.setStroke(); face.fill(); face.stroke()
        navy.withAlphaComponent(0.35).setStroke()
        for i in 0..<7 {
            let y = 0.40 + CGFloat(i) * 0.05
            let half = 0.03 - CGFloat(i) * 0.0015
            let tick = NSBezierPath(); tick.move(to: p(cx - half, y)); tick.line(to: p(cx + half, y))
            tick.lineWidth = 0.008 * S; tick.lineCapStyle = .round; tick.stroke()
        }

        // The pendulum, swung to the right, with its sliding weight; drawn rotated about the pivot.
        let pivot = p(cx, 0.27)
        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: -20 * .pi / 180)
        let arm = NSBezierPath(); arm.move(to: .zero); arm.line(to: CGPoint(x: 0, y: 0.60 * S))
        arm.lineWidth = 0.034 * S; arm.lineCapStyle = .round
        // A white halo where the arm crosses the body, so it reads in front of it.
        NSColor.white.setStroke(); let halo = arm.copy() as! NSBezierPath; halo.lineWidth = 0.07 * S; halo.stroke()
        swing.setStroke(); arm.stroke()
        let weight = NSBezierPath()
        weight.move(to: CGPoint(x: -0.065 * S, y: 0.36 * S)); weight.line(to: CGPoint(x: 0.065 * S, y: 0.36 * S))
        weight.line(to: CGPoint(x: 0.045 * S, y: 0.445 * S)); weight.line(to: CGPoint(x: -0.045 * S, y: 0.445 * S)); weight.close()
        weight.lineJoinStyle = .round; weight.lineWidth = 0.02 * S
        NSColor.white.setStroke(); let wHalo = weight.copy() as! NSBezierPath; wHalo.lineWidth = 0.05 * S; wHalo.stroke()
        swing.setFill(); swing.setStroke(); weight.fill(); weight.stroke()
        ctx.restoreGState()
        swing.setFill()
        NSBezierPath(ovalIn: NSRect(x: pivot.x - 0.03 * S, y: pivot.y - 0.03 * S, width: 0.06 * S, height: 0.06 * S)).fill()
    }

    /// The icon for use inside the app (sidebar): the tile edge to edge, without the Dock version's margin,
    /// outline and shadow.
    static func badge(points: Int, family: String = AppFont.family) -> NSImage {
        let img = NSImage(size: NSSize(width: points, height: points))
        img.addRepresentation(bitmap(size: points * 2, shape: .rounded, family: family))
        return img
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

    /// The Dock icon while Cadence runs.
    @MainActor static func applyToDock() { NSApp.applicationIconImage = image() }
}

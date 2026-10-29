import AppKit

// MARK: - Tool cursors

enum Cursors {
    /// Same 18-point gray dot used by the absolute trackpad overlay. Intermediate
    /// frames shrink the dot and reveal the native arrow at its actual hotspot.
    static let canvasToArrow = morph(to: .arrow)
    /// The same dot shrinking into the I-beam shown near text.
    static let canvasToIBeam = morph(to: .iBeam)

    /// A circular outline cursor for the eraser, drawn at `radius` screen points
    /// so the ring matches the eraser disc exactly.
    static func eraser(radius: CGFloat) -> NSCursor {
        let r = max(radius, 2)
        let pad: CGFloat = 2
        let side = r * 2 + pad * 2
        let center = NSPoint(x: side / 2, y: side / 2)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let rect = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: -0.5, dy: -0.5))
            outer.lineWidth = 2
            outer.stroke()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let inner = NSBezierPath(ovalIn: rect)
            inner.lineWidth = 1
            inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }

    private static func morph(to arrow: NSCursor) -> [NSCursor] { (0...12).map { frame in
        let progress = CGFloat(frame) / 12
        let blend = progress * progress * (3 - 2 * progress)
        let hotspot = NSPoint(x: 12, y: 12)
        let size = NSSize(width: max(32, arrow.image.size.width + 12),
                          height: max(32, arrow.image.size.height + 12))
        let image = NSImage(size: size, flipped: true) { _ in
            let diameter = 18 * (1 - 0.65 * blend)
            let dot = NSRect(x: hotspot.x - diameter / 2, y: hotspot.y - diameter / 2,
                             width: diameter, height: diameter)
            NSColor.systemGray.withAlphaComponent(0.5 * (1 - blend)).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.systemGray.withAlphaComponent(0.8 * (1 - blend)).setStroke()
            let outline = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            arrow.image.draw(in: NSRect(x: hotspot.x - arrow.hotSpot.x,
                                        y: hotspot.y - arrow.hotSpot.y,
                                        width: arrow.image.size.width, height: arrow.image.size.height),
                             from: .zero, operation: .sourceOver, fraction: blend,
                             respectFlipped: true, hints: nil)
            return true
        }
        return frame == 12 ? arrow : NSCursor(image: image, hotSpot: hotspot)
    } }
}

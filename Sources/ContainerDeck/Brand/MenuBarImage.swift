import DeckCore
import AppKit

extension Brand {
    /// Monochrome template image of the Container Deck mark for the menu bar (18 x 18 pt).
    /// Three containers stacked on a deck, with ribs cut out, same as LogoGlyph.
    @MainActor
    static func menuBarImage() -> NSImage {
        let points = NSSize(width: 18, height: 18)
        let image = NSImage(size: points)
        for scale in [1, 2] {
            if let rep = menuBarBitmap(scale: scale) {
                rep.size = points
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = AppConfig.appName
        return image
    }

    /// Draws the mark into a bitmap. Coordinates below are points, y pointing down.
    @MainActor
    private static func menuBarBitmap(scale: Int) -> NSBitmapImageRep? {
        let pixels = 18 * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let s = CGFloat(scale)
        // Convert a rect in points (y down) to pixels (y up).
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: (18 - y - h) * s, width: w * s, height: h * s)
        }

        let mark = NSBezierPath()
        mark.windingRule = .evenOdd

        // Deck
        mark.append(NSBezierPath(roundedRect: box(1, 14.4, 16, 1.5), xRadius: 0.75 * s, yRadius: 0.75 * s))

        // Containers: two on the deck, one on top. Each has three ribs cut out.
        let width: CGFloat = 7.6
        let height: CGFloat = 5.2
        let containers: [(CGFloat, CGFloat)] = [(1, 8.3), (9.4, 8.3), (5.2, 2.2)]
        for (x, y) in containers {
            mark.append(NSBezierPath(roundedRect: box(x, y, width, height), xRadius: 1 * s, yRadius: 1 * s))
            for i in 0..<3 {
                let ribX = x + 1.75 + CGFloat(i) * 1.65
                mark.append(NSBezierPath(roundedRect: box(ribX, y + 1.3, 0.8, height - 2.6), xRadius: 0.4 * s, yRadius: 0.4 * s))
            }
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        mark.fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

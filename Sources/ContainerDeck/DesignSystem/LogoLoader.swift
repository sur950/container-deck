import SwiftUI
import DeckCore

/// The app icon, building itself in a loop: the base line drops in, then the two lower
/// containers land on it, then the top one lands on both. It holds, fades and starts again.
/// Used for the first load of the app and for loaders that fill a whole screen.
///
/// The frame comes from the clock (TimelineView), not from a repeating animation, so it never
/// slides on first layout and costs nothing once it leaves the screen.
struct DeckLogoLoader: View {
    var size: CGFloat = 72
    /// Shows the finished logo without motion (Reduce Motion is also honored on its own).
    var isStatic = false
    /// Draws one fixed moment of the loop (previews and checks).
    var fixedTime: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let fixedTime {
                DeckLogoCanvas(size: size, time: fixedTime)
            } else if isStatic || reduceMotion {
                DeckLogoCanvas(size: size, time: LogoTimeline.holdStart)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    DeckLogoCanvas(size: size, time: t.truncatingRemainder(dividingBy: LogoTimeline.period))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A centered logo loader with a short message under it, for empty screens while data loads.
struct DeckLogoLoadingView: View {
    var message: String
    var size: CGFloat = 64

    var body: some View {
        VStack(spacing: 16) {
            DeckLogoLoader(size: size)
            Text(message)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

/// Timing of one loop, in seconds.
enum LogoTimeline {
    static let period: Double = 2.3
    /// The logo is complete from here until `fadeStart`.
    static let holdStart: Double = 1.0
    static let fadeStart: Double = 1.8
    static let fadeEnd: Double = 2.1

    struct Piece {
        let start: Double
        let duration: Double
        /// Drop height in glyph units.
        let drop: Double
    }

    static let line = Piece(start: 0.0, duration: 0.32, drop: 9)
    static let left = Piece(start: 0.24, duration: 0.36, drop: 15)
    static let right = Piece(start: 0.42, duration: 0.36, drop: 15)
    static let top = Piece(start: 0.62, duration: 0.38, drop: 15)

    /// 0 before the piece starts, 1 once it has landed.
    static func progress(_ piece: Piece, at t: Double) -> Double {
        min(1, max(0, (t - piece.start) / piece.duration))
    }

    /// Ease out with a small settle past the target, like a box set down.
    static func land(_ p: Double) -> Double {
        let c1 = 1.2, c3 = c1 + 1
        let x = p - 1
        return 1 + c3 * x * x * x + c1 * x * x
    }

    /// Opacity of the whole glyph: fades out at the end of each loop.
    static func glyphOpacity(at t: Double) -> Double {
        if t < fadeStart { return 1 }
        if t >= fadeEnd { return 0 }
        return 1 - (t - fadeStart) / (fadeEnd - fadeStart)
    }
}

/// Draws one frame. Geometry matches assets/brand/app-icon-1024.svg: a rounded tile
/// with the glyph from the 64 unit logo grid scaled by 12/824 of the tile.
private struct DeckLogoCanvas: View {
    let size: CGFloat
    let time: Double

    private static let tileTop = Color(hex: AppConfig.accentTop)
    private static let tileBottom = Color(hex: AppConfig.accentBottom)
    private static let boxBottom = Color(hex: 0xF7E6E9)

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let tile = CGRect(x: 0, y: 0, width: s, height: s)
            let corner = s * 185 / 824
            let tilePath = Path(roundedRect: tile, cornerRadius: corner, style: .continuous)
            context.fill(tilePath, with: .linearGradient(
                Gradient(colors: [Self.tileTop, Self.tileBottom]),
                startPoint: CGPoint(x: s / 2, y: 0), endPoint: CGPoint(x: s / 2, y: s)))
            context.stroke(tilePath, with: .color(.white.opacity(0.22)), lineWidth: max(0.5, s * 3 / 824))

            let unit = s * 12 / 824
            let origin = CGPoint(x: s * 28 / 824, y: s * 21 / 824)
            func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, dy: Double) -> CGRect {
                CGRect(x: origin.x + x * unit, y: origin.y + (y - dy) * unit, width: w * unit, height: h * unit)
            }

            let t = time
            var glyph = context
            glyph.opacity = LogoTimeline.glyphOpacity(at: t)
            glyph.addFilter(.shadow(color: Color(hex: 0x4A0712).opacity(0.35), radius: unit * 1.1, x: 0, y: unit * 1.2))

            // Base line.
            let lp = LogoTimeline.progress(LogoTimeline.line, at: t)
            if lp > 0 {
                let dy = (1 - LogoTimeline.land(lp)) * LogoTimeline.line.drop
                var layer = glyph
                layer.opacity *= min(1, lp * 2.5)
                let r = rect(13, 45, 38, 3.2, dy: dy)
                layer.fill(Path(roundedRect: r, cornerRadius: 1.6 * unit), with: .color(.white))
            }

            // Containers: left, right, then the top one.
            let boxes: [(LogoTimeline.Piece, Double, Double, [Double])] = [
                (LogoTimeline.left, 13, 31, [18, 22, 26]),
                (LogoTimeline.right, 33, 31, [38, 42, 46]),
                (LogoTimeline.top, 23, 17, [28, 32, 36]),
            ]
            for (piece, x, y, ribs) in boxes {
                let p = LogoTimeline.progress(piece, at: t)
                guard p > 0 else { continue }
                let dy = (1 - LogoTimeline.land(p)) * piece.drop
                var layer = glyph
                layer.opacity *= min(1, p * 3)
                let r = rect(x, y, 18, 12, dy: dy)
                layer.fill(Path(roundedRect: r, cornerRadius: 2.2 * unit),
                           with: .linearGradient(Gradient(colors: [.white, Self.boxBottom]),
                                                 startPoint: CGPoint(x: r.midX, y: r.minY),
                                                 endPoint: CGPoint(x: r.midX, y: r.maxY)))
                var ribPath = Path()
                for rx in ribs {
                    let top = rect(rx, y + 3, 0, 0, dy: dy).origin
                    ribPath.move(to: top)
                    ribPath.addLine(to: CGPoint(x: top.x, y: top.y + 6 * unit))
                }
                layer.stroke(ribPath, with: .color(Self.tileBottom.opacity(0.55)),
                             style: StrokeStyle(lineWidth: 1.4 * unit, lineCap: .round))
            }
        }
        .shadow(color: .black.opacity(0.18), radius: size * 0.08, y: size * 0.04)
    }
}

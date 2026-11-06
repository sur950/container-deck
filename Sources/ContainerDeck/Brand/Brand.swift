import SwiftUI
import DeckCore

/// Brand colors. Values live in AppConfig. See docs/BRAND.md.
enum Brand {
    static let red = Color(hex: AppConfig.accentLight)
    static let redTop = Color(hex: AppConfig.accentTop)
    static let redBottom = Color(hex: AppConfig.accentBottom)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The Container Deck mark: three containers stacked on a deck.
/// Drawn on a 64 point grid, same as assets/brand/logo.svg.
struct LogoGlyph: View {
    var color: Color = .white
    var stripe: Color = Brand.red

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 64
            let dx = (size.width - 64 * s) / 2
            let dy = (size.height - 64 * s) / 2

            func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
                Path(
                    roundedRect: CGRect(x: dx + x * s, y: dy + y * s, width: w * s, height: h * s),
                    cornerRadius: r * s
                )
            }

            context.fill(box(13, 45, 38, 3.2, 1.6), with: .color(color))
            let containers: [(Double, Double)] = [(13, 31), (33, 31), (23, 17)]
            for (x, y) in containers {
                context.fill(box(x, y, 18, 12, 2.2), with: .color(color))
            }

            var stripes = Path()
            for (x, y) in containers {
                for i in 0..<3 {
                    let sx = dx + (x + 5 + Double(i) * 4) * s
                    stripes.move(to: CGPoint(x: sx, y: dy + (y + 3) * s))
                    stripes.addLine(to: CGPoint(x: sx, y: dy + (y + 9) * s))
                }
            }
            context.stroke(
                stripes,
                with: .color(stripe.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round)
            )
        }
    }
}

/// Round red badge with the mark, as used in the lockup.
struct LogoBadge: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Brand.redTop, Brand.redBottom], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: max(0.5, size / 80))
            LogoGlyph()
        }
        .frame(width: size, height: size)
        .accessibilityLabel(AppConfig.appName)
    }
}

/// Rounded square tile with the mark, like the app icon. For welcome and about screens.
struct LogoTile: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Brand.redTop, Brand.redBottom], startPoint: .top, endPoint: .bottom))
                .shadow(color: Brand.redBottom.opacity(0.35), radius: size * 0.12, y: size * 0.05)
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: max(0.5, size / 120))
            LogoGlyph()
                .frame(width: size * 0.93, height: size * 0.93)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(AppConfig.appName)
    }
}

/// Lockup: the app mark and "Container Deck", with the version underneath. Works in light and dark mode.
struct BrandLockup: View {
    var badgeSize: CGFloat = 40
    var titleSize: CGFloat = 17

    var body: some View {
        HStack(spacing: badgeSize * 0.3) {
            LogoBadge(size: badgeSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppConfig.appName)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                Text(Self.versionText)
                    .font(.system(size: titleSize * 0.7))
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Version \($0)" } ?? "Development build"
    }
}

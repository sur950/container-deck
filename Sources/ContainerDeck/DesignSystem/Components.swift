import SwiftUI
import AppKit
import DeckCore

// Shared building blocks for every screen. Keep names and init parameters
// stable, since feature code depends on them. Restyling the insides is fine.

enum DS {
    // Brand. Slightly brighter red in dark mode so it keeps its contrast.
    static let accent = Color.adaptive(light: AppConfig.accentLight, dark: AppConfig.accentDark)
    /// Tinted background for selected rows, pills and badges.
    static let accentSoft = Color.adaptive(light: AppConfig.accentLight, dark: AppConfig.accentDark, lightOpacity: 0.11, darkOpacity: 0.22)
    /// Light fill inside icons.
    static let iconSoft = Color.adaptive(light: AppConfig.accentLight, dark: AppConfig.accentDark, lightOpacity: 0.13, darkOpacity: 0.24)

    // Surfaces and text. Values live in AppConfig.Theme.
    private typealias T = AppConfig.Theme
    static let surface = pair(T.surface)
    static let surfaceRaised = pair(T.surfaceRaised)
    static let surfaceSunken = pair(T.surfaceSunken)
    static let cardTop = pair(T.cardTop)
    static let cardBottom = pair(T.cardBottom)
    static let border = Color.adaptive(light: T.ink.light, dark: T.ink.dark, lightOpacity: 0.09, darkOpacity: 0.08)
    static let borderStrong = Color.adaptive(light: T.ink.light, dark: T.ink.dark, lightOpacity: 0.16, darkOpacity: 0.16)
    static let borderHighlight = Color.adaptive(light: T.ink.light, dark: T.ink.dark, lightOpacity: 0.06, darkOpacity: 0.14)
    static let hover = Color.adaptive(light: T.ink.light, dark: T.ink.dark, lightOpacity: 0.05, darkOpacity: 0.06)
    static let shadow = Color.adaptive(light: T.ink.light, dark: 0x000000, lightOpacity: 0.06, darkOpacity: 0.4)

    // Text
    static let textPrimary = pair(T.ink)
    static let textSecondary = pair(T.textSecondary)
    static let textTertiary = pair(T.textTertiary)

    // Status
    static let running = pair(T.running)
    static let stopped = pair(T.stopped)
    static let warning = pair(T.warning)
    static let danger = pair(T.danger)

    private static func pair(_ p: AppConfig.Pair) -> Color {
        Color.adaptive(light: p.light, dark: p.dark)
    }

    // Spacing and shape
    static let radius: CGFloat = 12
    static let smallRadius: CGFloat = 8
    static let pad: CGFloat = 16

    /// Card fill: white in light mode, the brand card gradient in dark mode.
    static var cardFill: LinearGradient {
        LinearGradient(colors: [cardTop, cardBottom], startPoint: .top, endPoint: .bottom)
    }
}

extension NSColor {
    /// sRGB color from a hex value like 0xB3122E.
    static func deckHex(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// A color that switches with light and dark mode.
    static func adaptive(light: UInt32, dark: UInt32, lightOpacity: CGFloat = 1, darkOpacity: CGFloat = 1) -> Color {
        let color = NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.deckHex(isDark ? dark : light, alpha: isDark ? darkOpacity : lightOpacity)
        })
        return Color(nsColor: color)
    }
}

// MARK: - Surfaces

/// Card background: soft gradient, hairline border and a light shadow.
struct DeckCardBackground: ViewModifier {
    var radius: CGFloat = DS.radius

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DS.cardFill)
                    .shadow(color: DS.shadow, radius: 6, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [DS.borderHighlight, DS.border], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            }
    }
}

extension View {
    /// Puts the view on a card surface.
    func deckCard(radius: CGFloat = DS.radius) -> some View {
        modifier(DeckCardBackground(radius: radius))
    }
}

/// Rounded panel with an optional title row.
struct Card<Content: View>: View {
    var title: String?
    var icon: DeckIconName?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, icon: DeckIconName? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 10) {
                    if let icon { IconBadge(icon, size: 26) }
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                }
            }
            content
        }
        .padding(DS.pad)
        // Fills the height it is offered, so cards in one row line up.
        // Put the row in an HStack with .fixedSize(horizontal: false, vertical: true).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .deckCard()
    }
}

/// Icon on a tinted rounded square.
struct IconBadge: View {
    var icon: DeckIconName
    var tint: Color
    var size: CGFloat

    init(_ icon: DeckIconName, tint: Color = DS.accent, size: CGFloat = 28) {
        self.icon = icon
        self.tint = tint
        self.size = size
    }

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onAccent = prominence == .increased
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(onAccent ? Color.white.opacity(0.18) : tint.opacity(0.12))
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(onAccent ? Color.white.opacity(0.28) : tint.opacity(0.16), lineWidth: 0.75)
            DeckIcon(icon, size: size * 0.6, color: tint)
        }
        .frame(width: size, height: size)
    }
}

/// Number tile for dashboards and stats.
struct MetricTile: View {
    var title: String
    var value: String
    var subtitle: String?
    var icon: DeckIconName
    var tint: Color

    init(title: String, value: String, subtitle: String? = nil, icon: DeckIconName, tint: Color = DS.accent) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                IconBadge(icon, tint: tint, size: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // Always keep the subtitle line, so tiles in a row have the same height.
                Text(subtitle ?? " ")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .accessibilityHidden(subtitle == nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .deckCard()
    }
}

/// Small colored capsule with text.
struct Pill: View {
    var text: String
    var tint: Color

    init(_ text: String, tint: Color = DS.accent) {
        self.text = text
        self.tint = tint
    }

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onAccent = prominence == .increased
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(onAccent ? Color.white : tint)
            .background(Capsule().fill(onAccent ? Color.white.opacity(0.2) : tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(onAccent ? Color.white.opacity(0.3) : tint.opacity(0.22), lineWidth: 0.75))
            .fixedSize()
    }
}

/// Running, stopped and so on, with a dot.
struct StatusPill: View {
    var state: ContainerRunState
    @Environment(\.backgroundProminence) private var prominence

    init(_ state: ContainerRunState) {
        self.state = state
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if state == .running {
                    Circle().fill(color.opacity(0.28)).frame(width: 11, height: 11)
                }
                Circle().fill(color).frame(width: 7, height: 7)
            }
            .frame(width: 11, height: 11)
            Text(state.rawValue.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(prominence == .increased ? Color.white : DS.textPrimary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(prominence == .increased ? Color.white.opacity(0.2) : color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(prominence == .increased ? Color.white.opacity(0.3) : color.opacity(0.2), lineWidth: 0.75))
        .fixedSize()
    }

    private var color: Color {
        switch state {
        case .running: return DS.running
        case .stopping: return DS.warning
        case .stopped: return DS.stopped
        case .unknown: return DS.stopped
        }
    }
}

/// Shown when a list is empty or the platform is not ready.
struct EmptyState: View {
    var icon: DeckIconName
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(icon: DeckIconName, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(DS.accent.opacity(0.14), lineWidth: 1)
                    .frame(width: 112, height: 112)
                Circle()
                    .fill(DS.accentSoft)
                    .frame(width: 84, height: 84)
                DeckIcon(icon, size: 40, color: DS.accent)
            }
            .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                // No fixedSize here. At a zero width proposal it would wrap one word
                // per line and push the whole window layout off screen.
                .frame(minWidth: 240, maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .deckPrimary()
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The CLI command for an action, with a copy button.
struct CommandHint: View {
    var command: String
    @State private var copied = false

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        HStack(spacing: 7) {
            Text("$")
                .fontWeight(.semibold)
                .foregroundStyle(DS.accent)
            Text(command)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                DeckIcon(copied ? .success : .copy, size: 13, color: copied ? DS.running : DS.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy command")
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// Bottom toast for quick feedback. RootView shows AppState.toast with it.
struct ToastView: View {
    var toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                DeckIcon(icon, size: 15, color: tint)
            }
            .frame(width: 26, height: 26)
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(DS.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.borderStrong, lineWidth: 0.75))
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 6)
    }

    private var icon: DeckIconName {
        switch toast.style {
        case .info: return .info
        case .success: return .success
        case .error: return .error
        }
    }

    private var tint: Color {
        switch toast.style {
        case .info: return DS.accent
        case .success: return DS.running
        case .error: return DS.danger
        }
    }
}

// MARK: - Added components

/// Title row for a screen section, with an optional icon and trailing controls.
struct SectionHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var icon: DeckIconName?
    var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, icon: DeckIconName? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon { IconBadge(icon, size: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, icon: DeckIconName? = nil) {
        self.init(title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

/// Brand styled segmented control for list filters, with optional counts.
struct SegmentedFilter<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [Value]
    var label: (Value) -> String
    var count: ((Value) -> Int?)?
    @Namespace private var namespace

    init(selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String, count: ((Value) -> Int?)? = nil) {
        self._selection = selection
        self.options = options
        self.label = label
        self.count = count
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
        .fixedSize()
    }

    private func segment(_ option: Value) -> some View {
        let isOn = option == selection
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { selection = option }
        } label: {
            HStack(spacing: 5) {
                Text(label(option))
                if let value = count?(option) {
                    Text("\(value)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isOn ? DS.accentSoft : DS.hover))
                }
            }
            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? DS.accent : DS.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.surfaceRaised)
                        .shadow(color: DS.shadow, radius: 2, y: 1)
                        .matchedGeometryEffect(id: "segment", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One label and value line for detail panels.
struct KeyValueRow<Value: View>: View {
    var key: String
    var value: Value

    init(_ key: String, @ViewBuilder value: () -> Value) {
        self.key = key
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .foregroundStyle(DS.textSecondary)
                .frame(width: 120, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.vertical, 5)
    }
}

extension KeyValueRow where Value == KeyValueText {
    init(_ key: String, value: String, monospaced: Bool = false, copyable: Bool = false) {
        self.init(key) { KeyValueText(text: value, monospaced: monospaced, copyable: copyable) }
    }
}

/// Value text for KeyValueRow. Selectable, with an optional copy button.
struct KeyValueText: View {
    var text: String
    var monospaced: Bool
    var copyable: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(monospaced ? Font.callout.monospaced() : Font.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    DeckIcon(.copy, size: 12, color: DS.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy")
                .opacity(hovering ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// Branded spinner with a short message, for screens that are loading.
/// Loading placeholder: a shimmering skeleton shaped like the content that is coming.
/// `message` is read by VoiceOver. Use `.list` for tables, `.cards` for card pages,
/// `.detail` for detail panes and inspectors, `.chart` for charts waiting for data.
struct LoadingView: View {
    /// `logo` is for loaders that fill a whole screen or pane (the animated app icon).
    /// The skeleton styles are for loaders inside a card, sheet or chart.
    enum Style { case logo, list, cards, detail, chart }

    var message: String
    var style: Style

    init(_ message: String = "Loading", style: Style = .list) {
        self.message = message
        self.style = style
    }

    var body: some View {
        if style == .logo {
            DeckLogoLoadingView(message: message)
        } else {
            skeleton
        }
    }

    private var skeleton: some View {
        Group {
            switch style {
            case .logo, .list: listSkeleton
            case .cards: cardsSkeleton
            case .detail: detailSkeleton
            case .chart: SkeletonBlock(height: nil, radius: 8)
            }
        }
        .shimmer()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    private var listSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<9, id: \.self) { row in
                HStack(spacing: 14) {
                    SkeletonBlock(width: 18, height: 18, radius: 5)
                    // Flexible blocks, so the skeleton fits any width.
                    SkeletonBlock(height: 11)
                        .frame(maxWidth: [200, 150, 230, 170, 130, 210, 160, 190, 140][row])
                    Spacer(minLength: 12)
                    SkeletonBlock(height: 11).frame(maxWidth: 130)
                    SkeletonBlock(height: 18, radius: 9).frame(maxWidth: 64)
                    SkeletonBlock(height: 11).frame(maxWidth: 72)
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
                Divider().opacity(0.5)
            }
        }
        .padding(.top, 8)
    }

    private var cardsSkeleton: some View {
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
            HStack(spacing: Layout.cardSpacing) {
                ForEach(0..<3, id: \.self) { _ in skeletonCard }
            }
            .frame(maxHeight: 96)
            HStack(spacing: Layout.cardSpacing) {
                skeletonCard
                skeletonCard
            }
            .frame(maxHeight: 220)
        }
        .padding(Layout.pagePadding)
    }

    private var detailSkeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                SkeletonBlock(width: 52, height: 52, radius: 12)
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(height: 16).frame(maxWidth: 220)
                    SkeletonBlock(height: 11).frame(maxWidth: 160)
                }
            }
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(width: 120, height: 13)
                    ForEach(0..<4, id: \.self) { line in
                        HStack(spacing: 24) {
                            SkeletonBlock(height: 10).frame(maxWidth: 90)
                            SkeletonBlock(height: 10).frame(maxWidth: [200, 150, 240, 120][line])
                        }
                    }
                }
                .padding(DS.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .deckCard()
            }
        }
        .padding(Layout.pagePadding)
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(height: 11).frame(maxWidth: 90)
            SkeletonBlock(height: 22).frame(maxWidth: 60)
            Spacer(minLength: 0)
            SkeletonBlock(height: 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .deckCard()
    }
}

/// One grey placeholder shape for skeletons. nil width or height fills the space.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat?
    var radius: CGFloat = 4

    init(width: CGFloat? = nil, height: CGFloat? = nil, radius: CGFloat = 4) {
        self.width = width
        self.height = height
        self.radius = radius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.adaptive(light: AppConfig.Theme.ink.light, dark: AppConfig.Theme.ink.dark, lightOpacity: 0.08, darkOpacity: 0.10))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: height == nil ? .infinity : nil)
    }
}

extension View {
    /// Soft light band sweeping across the view, for skeleton placeholders.
    /// Clock driven, so it never leaves stray animations behind.
    func shimmer(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

private struct ShimmerModifier: ViewModifier {
    var active: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if !active || reduceMotion {
            content
        } else {
            content
                .overlay {
                    TimelineView(.animation) { context in
                        let period = 1.4
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        GeometryReader { geo in
                            let band = max(geo.size.width * 0.35, 120)
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(scheme == .dark ? 0.07 : 0.55), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: -band + (geo.size.width + band * 2) * phase)
                        }
                    }
                    .allowsHitTesting(false)
                    .mask(content)
                }
                .transaction { $0.animation = nil }
        }
    }
}

/// Small keyboard key label, like "esc" or "return".
struct KeyCap: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(DS.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}

extension View {
    /// Main action button in brand red. Icons inside turn single color so they stay visible.
    func deckPrimary() -> some View {
        self.buttonStyle(.borderedProminent)
            .tint(DS.accent)
            .environment(\.deckIconMonochrome, true)
    }

    /// Text link button in brand red. The system link style is always blue, which breaks
    /// the one accent rule, so links use this instead.
    func deckLink() -> some View {
        self.buttonStyle(.borderless)
            .foregroundStyle(DS.accent)
            .environment(\.deckIconMonochrome, true)
    }

    /// Asks before deleting. Shows a red Delete button and a Cancel button.
    func confirmDelete(
        isPresented: Binding<Bool>,
        title: String,
        message: String = "This cannot be undone.",
        actionTitle: String = "Delete",
        perform: @escaping () -> Void
    ) -> some View {
        self.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(actionTitle, role: .destructive, action: perform)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    /// Asks before deleting an item. Set the binding to show the dialog. It clears itself.
    func confirmDelete<Item>(
        _ item: Binding<Item?>,
        title: @escaping (Item) -> String,
        message: String = "This cannot be undone.",
        actionTitle: String = "Delete",
        perform: @escaping (Item) -> Void
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: { item.wrappedValue != nil },
            set: { newValue in if !newValue { item.wrappedValue = nil } }
        )
        let heading = item.wrappedValue.map(title) ?? ""
        return self.confirmationDialog(heading, isPresented: isPresented, titleVisibility: .visible, presenting: item.wrappedValue) { value in
            Button(actionTitle, role: .destructive) { perform(value) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(message)
        }
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        if value == 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "-" }
        return bytes(value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "-" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

// MARK: - Refresh

/// Toolbar refresh button with feedback. Shows a small spinner while the action runs
/// and stays disabled until it finishes. Use it on every screen.
/// Pass `isBusy` when the screen already tracks its own loading state.
struct RefreshButton: View {
    var title: String = "Refresh"
    var help: String = "Refresh"
    var isBusy: Bool = false
    let action: () async -> Void
    @State private var running = false

    init(_ title: String = "Refresh", help: String = "Refresh", isBusy: Bool = false, action: @escaping () async -> Void) {
        self.title = title
        self.help = help
        self.isBusy = isBusy
        self.action = action
    }

    private var busy: Bool { running || isBusy }

    var body: some View {
        Button {
            guard !busy else { return }
            running = true
            Task {
                // Keep the spinner visible long enough to be seen.
                async let minimum: Void = { try? await Task.sleep(for: .milliseconds(450)) }()
                await action()
                _ = await minimum
                running = false
            }
        } label: {
            if busy {
                Label {
                    Text(title)
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                        .frame(width: 16, height: 16)
                }
            } else {
                DeckLabel(title, icon: .refresh)
            }
        }
        .disabled(busy)
        .help(help)
    }
}

// MARK: - Layout standards
// Use these so every screen and sheet has the same rhythm.
// Page: 24 padding, 20 between sections, 16 between cards, content max 1100 wide.

enum Layout {
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cardSpacing: CGFloat = 16
    static let maxContentWidth: CGFloat = 1100
    static let statusBarHeight: CGFloat = 34
}

/// Scrolling page for card based screens (Dashboard, detail panes, settings like pages).
struct DeckPage<Content: View>: View {
    var maxWidth: CGFloat = Layout.maxContentWidth
    @ViewBuilder var content: Content

    init(maxWidth: CGFloat = Layout.maxContentWidth, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                content
            }
            .padding(Layout.pagePadding)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DS.surface)
    }
}

/// A row of cards or tiles that all get the height of the tallest one.
/// Children should fill the offered height (Card and MetricTile do).
struct EqualHeightRow<Content: View>: View {
    var spacing: CGFloat = Layout.cardSpacing
    @ViewBuilder var content: Content

    init(spacing: CGFloat = Layout.cardSpacing, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            content
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Bottom bar under a table: a summary on the left, optional controls (like a CommandHint) on the right.
struct ListStatusBar<Trailing: View>: View {
    var text: String
    @ViewBuilder var trailing: Trailing

    init(_ text: String, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: Layout.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(DS.surfaceSunken)
        .overlay(alignment: .top) { Divider() }
    }
}

extension ListStatusBar where Trailing == EmptyView {
    init(_ text: String) {
        self.init(text) { EmptyView() }
    }
}

/// Standard sheet: header (icon, title, subtitle), scrolling body, footer with buttons on the right.
/// Footer buttons: Cancel first, then the main action with .keyboardShortcut(.defaultAction) and .deckPrimary().
struct SheetScaffold<Content: View, Footer: View>: View {
    var title: String
    var subtitle: String?
    var icon: DeckIconName
    var width: CGFloat
    var scrolls: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(_ title: String, subtitle: String? = nil, icon: DeckIconName, width: CGFloat = 560, scrolls: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.width = width
        self.scrolls = scrolls
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconBadge(icon, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            Divider()
            Group {
                if scrolls {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) { content }
                            .padding(22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) { content }
                        .padding(22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                footer
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: width)
        .background(DS.surface)
    }
}

// MARK: - Text on selected rows

extension View {
    /// Secondary text that stays readable in a selected, focused table or list row
    /// (white on the accent highlight, DS.textSecondary everywhere else).
    func deckSecondaryText() -> some View { modifier(RowAwareText(level: .secondary)) }
    /// Tertiary text, same rule.
    func deckTertiaryText() -> some View { modifier(RowAwareText(level: .tertiary)) }
    /// Primary text, same rule. Use for custom colored text in table cells.
    func deckPrimaryText() -> some View { modifier(RowAwareText(level: .primary)) }
}

private struct RowAwareText: ViewModifier {
    enum Level { case primary, secondary, tertiary }
    let level: Level
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        if prominence == .increased {
            content.foregroundStyle(Color.white.opacity(level == .primary ? 1 : (level == .secondary ? 0.82 : 0.65)))
        } else {
            switch level {
            case .primary: content.foregroundStyle(DS.textPrimary)
            case .secondary: content.foregroundStyle(DS.textSecondary)
            case .tertiary: content.foregroundStyle(DS.textTertiary)
            }
        }
    }
}

import SwiftUI
import AppKit

// Every screen uses DeckIcon instead of raw SF Symbols, so the whole icon set
// can be swapped in this one file. Add cases freely, but keep existing names
// stable because feature code refers to them.
//
// Glyphs are SF Symbols (built into macOS, nothing to bundle). Each case maps
// to one symbol plus a tone that says which symbol layer gets the brand red.
// Only use symbols that exist on macOS 15 (SF Symbols 6). DeckIconTests checks this.

enum DeckIconName: String, CaseIterable {
    // Navigation
    case dashboard, containers, compose, machines, images, explore, volumes, networks, importEngines, settings
    // Actions
    case play, stop, restart, kill, trash, add, refresh, search, filter, more
    case terminal, logs, stats, inspect, files, folder, file, download, upload
    case build, tag, pull, prune, export, link, copy, edit, openExternal, close
    // Status
    case success, warning, error, info, waiting
    // Things
    case cpu, memory, disk, network, port, lock, registry, dns, kernel, rosetta, star, official, shield, layers, clock
    // Added in the custom set
    case pause, power, pending, chevronRight, chevronDown, wand, checklist, sun, moon, bell, command, sparkle
    // About page
    case fork, license, website
    // Builds, Kubernetes, AI and Domains screens
    case builds, kubernetes, aiModels, sandboxes, agents, domains
    case chat, share, key, send
}

/// How the layers of a symbol are colored.
enum DeckIconTone {
    /// One color for every layer.
    case solid
    /// Primary layer in the main color, secondary layer in brand red,
    /// tertiary (fill) layer in a light red tint.
    case accentSecondary
    /// Primary layer in brand red, secondary layer in the main color.
    case accentPrimary
    /// Primary layer in the main color, the tertiary (fill) layer in brand red.
    case accentFill
    /// Filled status symbol: white mark on a disc in the main color.
    case status
}

extension DeckIconName {
    /// SF Symbol name for this icon.
    var symbol: String { Self.glyphs[self]?.symbol ?? "questionmark.square.dashed" }

    /// Which layer gets the brand red.
    var tone: DeckIconTone { Self.glyphs[self]?.tone ?? .solid }

    private static let glyphs: [DeckIconName: (symbol: String, tone: DeckIconTone)] = [
        // Navigation
        .dashboard: ("gauge.with.dots.needle.33percent", .accentPrimary),
        .containers: ("shippingbox", .solid),
        .compose: ("square.grid.2x2", .solid),
        .machines: ("desktopcomputer", .accentSecondary),
        .images: ("square.3.layers.3d.top.filled", .accentSecondary),
        .explore: ("safari", .accentPrimary),
        .volumes: ("externaldrive", .solid),
        .networks: ("point.3.filled.connected.trianglepath.dotted", .accentSecondary),
        .importEngines: ("square.and.arrow.down.on.square", .accentPrimary),
        .settings: ("gearshape", .solid),
        // Actions
        .play: ("play.fill", .solid),
        .stop: ("stop.fill", .solid),
        .restart: ("arrow.clockwise", .solid),
        .kill: ("bolt.fill", .solid),
        .trash: ("trash", .solid),
        .add: ("plus", .solid),
        .refresh: ("arrow.triangle.2.circlepath", .solid),
        .search: ("magnifyingglass", .solid),
        .filter: ("line.3.horizontal.decrease.circle", .accentPrimary),
        .more: ("ellipsis.circle", .accentPrimary),
        .terminal: ("apple.terminal", .solid),
        .logs: ("list.bullet.rectangle", .accentPrimary),
        .stats: ("chart.xyaxis.line", .accentPrimary),
        .inspect: ("curlybraces.square", .accentPrimary),
        .files: ("folder", .solid),
        .folder: ("folder.fill", .solid),
        .file: ("doc.text", .solid),
        .download: ("arrow.down.circle", .accentPrimary),
        .upload: ("arrow.up.circle", .accentPrimary),
        .build: ("hammer", .solid),
        .tag: ("tag", .solid),
        .pull: ("arrow.down.to.line", .solid),
        .prune: ("scissors", .solid),
        .export: ("square.and.arrow.up", .accentPrimary),
        .link: ("link", .solid),
        .copy: ("square.on.square", .solid),
        .edit: ("square.and.pencil", .accentPrimary),
        .openExternal: ("arrow.up.forward.app", .accentPrimary),
        .close: ("xmark", .solid),
        // Status
        .success: ("checkmark.circle.fill", .status),
        .warning: ("exclamationmark.triangle.fill", .status),
        .error: ("xmark.octagon.fill", .status),
        .info: ("info.circle", .solid),
        .waiting: ("hourglass", .accentFill),
        // Things
        .cpu: ("cpu", .solid),
        .memory: ("memorychip", .solid),
        .disk: ("internaldrive", .solid),
        .network: ("arrow.up.arrow.down", .accentSecondary),
        .port: ("cable.connector", .accentPrimary),
        .lock: ("lock.fill", .solid),
        .registry: ("server.rack", .solid),
        .dns: ("globe", .solid),
        .kernel: ("cube", .solid),
        .rosetta: ("arrow.triangle.swap", .solid),
        .star: ("star.fill", .solid),
        .official: ("checkmark.seal.fill", .status),
        .shield: ("checkmark.shield", .accentPrimary),
        .layers: ("square.3.layers.3d.down.right", .accentSecondary),
        .clock: ("clock", .accentPrimary),
        // Added in the custom set
        .pause: ("pause.fill", .solid),
        .power: ("power", .solid),
        .pending: ("circle.dashed", .solid),
        .chevronRight: ("chevron.right", .solid),
        .chevronDown: ("chevron.down", .solid),
        .wand: ("wand.and.stars", .accentSecondary),
        .checklist: ("checklist", .accentPrimary),
        .sun: ("sun.max", .solid),
        .moon: ("moon", .solid),
        .bell: ("bell", .solid),
        .command: ("command", .solid),
        .sparkle: ("sparkles", .solid),
        .fork: ("arrow.triangle.branch", .solid),
        .license: ("checkmark.seal", .solid),
        .website: ("safari.fill", .solid),
        .builds: ("wrench.and.screwdriver", .solid),
        .kubernetes: ("helm", .solid),
        .aiModels: ("brain", .solid),
        .sandboxes: ("shield.lefthalf.filled", .solid),
        .agents: ("person.2", .solid),
        .domains: ("network.badge.shield.half.filled", .solid),
        .chat: ("bubble.left.and.bubble.right", .solid),
        .share: ("globe.badge.chevron.backward", .solid),
        .key: ("key.horizontal", .solid),
        .send: ("arrow.up", .solid)
    ]
}

/// Container Deck icon. Two tones: the main color (or the current
/// foreground style) plus a brand red detail layer.
struct DeckIcon: View {
    let name: DeckIconName
    var size: CGFloat = 16
    var color: Color?
    @Environment(\.deckIconMonochrome) private var monochrome
    /// `.increased` inside a selected, focused list row (solid accent background).
    @Environment(\.backgroundProminence) private var prominence

    init(_ name: DeckIconName, size: CGFloat = 16, color: Color? = nil) {
        self.name = name
        self.size = size
        self.color = color
    }

    var body: some View {
        let styles = layerStyles
        Image(systemName: name.symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(styles.0, styles.1, styles.2)
            .font(.system(size: DeckIconMetrics.pointSize(name.symbol, box: size), weight: .medium))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Colors for the primary, secondary and tertiary symbol layers.
    private var layerStyles: (AnyShapeStyle, AnyShapeStyle, AnyShapeStyle) {
        if prominence == .increased {
            // Selected row: white like native list icons, so nothing disappears on the accent.
            let white = AnyShapeStyle(Color.white)
            return (white, white, AnyShapeStyle(Color.white.opacity(0.3)))
        }
        let main = mainStyle
        if monochrome { return (main, main, main) }
        switch name.tone {
        case .solid:
            return (main, main, main)
        case .accentSecondary:
            return (main, accentStyle, softStyle)
        case .accentPrimary:
            return (accentStyle, main, softStyle)
        case .accentFill:
            return (main, accentStyle, accentStyle)
        case .status:
            let mark = AnyShapeStyle(Color.white)
            return (mark, main, main)
        }
    }

    /// The given color, or the current foreground style.
    private var mainStyle: AnyShapeStyle {
        if let color { return AnyShapeStyle(color) }
        return AnyShapeStyle(HierarchicalShapeStyle.primary)
    }

    /// Brand red. When the main color is already brand red (badges), the
    /// detail is a lighter red so the two layers stay apart.
    private var accentStyle: AnyShapeStyle {
        if color == DS.accent { return AnyShapeStyle(DS.accent.opacity(0.6)) }
        return AnyShapeStyle(DS.accent)
    }

    private var softStyle: AnyShapeStyle {
        if let color { return AnyShapeStyle(color.opacity(0.18)) }
        return AnyShapeStyle(DS.iconSoft)
    }
}

/// Label with a DeckIcon, for buttons, menus, toolbars and tabs.
/// Uses a single color template image so it works inside menus and
/// takes the button's text color (for example white on a red button).
struct DeckLabel: View {
    let title: String
    let icon: DeckIconName

    init(_ title: String, icon: DeckIconName) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image.deck(icon)
        }
    }
}

extension Image {
    /// Single color template image of a DeckIcon. Use it where SwiftUI only
    /// shows images: menus, context menus, tab items and the menu bar.
    @MainActor
    static func deck(_ name: DeckIconName, size: CGFloat = 15) -> Image {
        if let image = DeckIconImageCache.image(name, size: size) {
            return Image(nsImage: image).renderingMode(.template)
        }
        return Image(systemName: name.symbol)
    }
}

// MARK: - Environment

private struct DeckIconMonochromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true, DeckIcon draws every layer in the main color. Set by deckPrimary().
    var deckIconMonochrome: Bool {
        get { self[DeckIconMonochromeKey.self] }
        set { self[DeckIconMonochromeKey.self] = newValue }
    }
}

// MARK: - Sizing

@MainActor
enum DeckIconMetrics {
    /// Symbol point size for a square box. Symbols are drawn at 82% of the box,
    /// so a circle symbol nearly fills it. Wide or tall symbols are made smaller
    /// so they overflow the box by at most 15%.
    static func pointSize(_ symbol: String, box: CGFloat) -> CGFloat {
        let extent = extentRatio(symbol)
        return min(box * 0.82, box * 1.15 / extent)
    }

    private static var extents: [String: CGFloat] = [:]

    /// Largest side of the symbol image divided by its point size.
    static func extentRatio(_ symbol: String) -> CGFloat {
        if let cached = extents[symbol] { return cached }
        var ratio: CGFloat = 1.18
        let config = NSImage.SymbolConfiguration(pointSize: 100, weight: .medium)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            ratio = max(image.size.width, image.size.height) / 100
        }
        extents[symbol] = ratio
        return ratio
    }
}

@MainActor
enum DeckIconImageCache {
    private static var images: [String: NSImage] = [:]

    /// Template symbol image of an icon sized for a square box of `size` points.
    static func image(_ name: DeckIconName, size: CGFloat) -> NSImage? {
        let key = "\(name.rawValue)@\(size)"
        if let cached = images[key] { return cached }
        let config = NSImage.SymbolConfiguration(
            pointSize: DeckIconMetrics.pointSize(name.symbol, box: size),
            weight: .medium
        )
        guard let image = NSImage(systemSymbolName: name.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = true
        images[key] = image
        return image
    }
}

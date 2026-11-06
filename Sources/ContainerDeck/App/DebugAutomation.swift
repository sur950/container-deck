import SwiftUI
import AppKit
import DeckCore

/// Test hook for driving the app from scripts. Only active when the app is started
/// with DECK_AUTOMATION=1. Commands arrive as distributed notifications named
/// "ContainerDeckDebug" with the command in `object`:
///   select:<sidebar item raw value>   appearance:<system|light|dark>
///   snap:<png path>                    settings   palette   close-sheets   run   build
///   window                             (open or bring forward the main window)
///   settings-tab:<general|platform|registries|dns|updates|about>   compose-open:<path>   menubar   menubar-close
@MainActor
final class DebugAutomation {
    static let shared = DebugAutomation()
    /// Debug builds only. Release builds never listen for commands.
    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DECK_AUTOMATION"] == "1"
        #else
        return false
        #endif
    }

    /// Prints a timestamped line to stderr when automation is on. Used to check pollers.
    nonisolated static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["DECK_AUTOMATION"] == "1" else { return }
        FileHandle.standardError.write(Data("[deck \(String(format: "%.2f", Date().timeIntervalSince1970))] \(message())\n".utf8))
        #endif
    }

    private weak var state: AppState?
    private var observer: NSObjectProtocol?
    var openWindow: ((String) -> Void)?
    var openSettings: (() -> Void)?

    func attach(_ state: AppState) {
        guard Self.isEnabled else { return }
        self.state = state
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ContainerDeckDebug" + (ProcessInfo.processInfo.environment["DECK_AUTOMATION_ID"] ?? "")), object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { DebugAutomation.shared.handle(command) }
        }
    }

    private func handle(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        switch name {
        case "select":
            if let item = SidebarItem(rawValue: value) { state?.selection = item }
        case "appearance":
            // Only this process. Writing the preference would switch every running copy.
            Appearance.apply(value)
        case "snap":
            snapshot(to: value)
        case "settings":
            NSApp.activate()
            openSettings?()
        case "palette":
            state?.showPalette = true
        case "run":
            state?.runRequest = RunRequest(options: RunOptions(image: "nginx:alpine"))
        case "build":
            state?.buildRequest = BuildRequest()
        case "setup":
            state?.showSetup = true
        case "close-sheets":
            state?.showPalette = false
            state?.showSetup = false
            state?.runRequest = nil
            state?.buildRequest = nil
            for window in NSApp.windows where window.sheetParent != nil {
                window.sheetParent?.endSheet(window)
            }
        case "activate":
            // Bring the app to the front so snapshots show the active window look.
            NSApp.activate(ignoringOtherApps: true)
            (MainWindow.existing ?? NSApp.windows.first { $0.isVisible })?.makeKeyAndOrderFront(nil)
        case "window":
            if !MainWindow.bringForward() { openWindow?("main") }
        case "close-window":
            MainWindow.existing?.performClose(nil)
        case "size":
            let wh = value.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2, let window = MainWindow.existing {
                var frame = window.frame
                frame.size = NSSize(width: wh[0], height: wh[1])
                window.setFrame(frame, display: true)
            }
        case "link":
            if let url = URL(string: value), let state { DeepLinkRouter.handle(url, state: state) }
        case "key":
            // return, escape, tab, or a single character, optionally prefixed "cmd+".
            pressKey(value)
        case "logo-frames":
            // Renders moments of the logo loader loop side by side into a PNG, Light and Dark rows.
            let times: [Double] = [0.08, 0.2, 0.32, 0.45, 0.58, 0.72, 0.86, 1.3, 1.95]
            let content = VStack(spacing: 0) {
                ForEach(["light", "dark"], id: \.self) { mode in
                    HStack(spacing: 24) {
                        ForEach(times, id: \.self) { t in
                            VStack(spacing: 6) {
                                DeckLogoLoader(size: 88, fixedTime: t)
                                Text(String(format: "%.2fs", t)).font(.caption).foregroundStyle(DS.textSecondary)
                            }
                        }
                    }
                    .padding(24)
                    .background(DS.surface)
                    .environment(\.colorScheme, mode == "dark" ? .dark : .light)
                }
            }
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: value))
            }
        case "preview-loading":
            let content = HStack(alignment: .top, spacing: 12) {
                LoadingView("List").frame(width: 520, height: 360).deckCard()
                VStack(spacing: 12) {
                    LoadingView("Detail", style: .detail).frame(width: 460, height: 360).deckCard()
                }
                VStack(spacing: 12) {
                    LoadingView("Cards", style: .cards).frame(width: 520, height: 300).deckCard()
                    LoadingView("Chart", style: .chart).frame(width: 520, height: 48)
                }
            }
            .padding(20)
            .background(DS.surface)
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1560, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Loading preview"
            window.contentView = NSHostingView(rootView: content)
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
        case "dump":
            var out = ""
            if let root = (NSApp.keyWindow ?? MainWindow.existing)?.contentView?.superview {
                dumpTree(root, depth: 0, into: &out)
            }
            snapshotText(out, to: value)
        case "ctab":
            // Container detail tab: overview, logs, stats, inspect, files.
            NotificationCenter.default.post(name: .deckDebugContainerTab, object: value)
        case "recreate":
            if let state { Task { await ContainerOps.editAndRecreate(value, state: state) } }
        case "settings-tab":
            // General, Platform, Registries, DNS, Updates or About (lowercase).
            NotificationCenter.default.post(name: .deckDebugSettingsTab, object: value)
        case "compose-open":
            NotificationCenter.default.post(name: .deckDebugComposeOpen, object: value)
        case "sheet":
            // volume-create, volume-browse:<name>, network-create
            NotificationCenter.default.post(name: .deckDebugOpenSheet, object: value)
        case "menubar":
            showMenuBarPanel()
        case "menubar-close":
            menuBarPanel?.close()
            menuBarPanel = nil
        case "policy":
            snapshotText("\(NSApp.activationPolicy().rawValue)", to: value)
        default:
            // Feature screens can listen for their own commands (for example "explore-search:redis").
            NotificationCenter.default.post(name: .deckDebugCommand, object: nil, userInfo: ["name": name, "value": value])
        }
    }

    private var menuBarPanel: NSPanel?

    /// Shows the menu bar panel content in a plain window so it can be snapped.
    private func showMenuBarPanel() {
        guard let state else { return }
        menuBarPanel?.close()
        let host = NSHostingView(rootView: MenuBarContent().environment(state).tint(DS.accent))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor, constant: 28),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        panel.setContentSize(NSSize(width: 340, height: host.fittingSize.height + 28))
        panel.center()
        panel.orderFrontRegardless()
        menuBarPanel = panel
    }

    private func pressKey(_ spec: String) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        var flags: NSEvent.ModifierFlags = []
        var key = spec
        if key.hasPrefix("cmd+") { flags.insert(.command); key.removeFirst(4) }
        let (chars, code): (String, UInt16) = {
            switch key {
            case "return": return ("\r", 36)
            case "escape": return ("\u{1b}", 53)
            case "tab": return ("\t", 48)
            case "space": return (" ", 49)
            case "delete": return ("\u{7f}", 51)
            case "down": return (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
            case "up": return (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126)
            default: return (key, 0)
            }
        }()
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private func dumpTree(_ view: NSView, depth: Int, into out: inout String) {
        guard depth < 40 else { return }
        var line = String(repeating: " ", count: depth) + String(describing: type(of: view))
        line += " frame=\(Int(view.frame.minX)),\(Int(view.frame.minY)),\(Int(view.frame.width))x\(Int(view.frame.height))"
        if view.isHidden { line += " HIDDEN" }
        if view.alphaValue < 1 { line += " alpha=\(view.alphaValue)" }
        if let table = view as? NSTableView { line += " rows=\(table.numberOfRows)" }
        out += line + "\n"
        for sub in view.subviews { dumpTree(sub, depth: depth + 1, into: &out) }
    }

    private func snapshotText(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Writes every visible app window to PNG files: <path> for the key or main window,
    /// <path>-<n>.png for the rest (sheets, settings, menu bar panel).
    private func snapshot(to path: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 50 }
        let primary = NSApp.keyWindow ?? MainWindow.existing ?? windows.first
        var index = 1
        for window in windows {
            let target = window == primary ? path : path.replacingOccurrences(of: ".png", with: "-\(index).png")
            if window != primary { index += 1 }
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: target))
            }
        }
    }
}

extension Notification.Name {
    /// Automation commands that DebugAutomation does not handle itself. userInfo has "name" and "value".
    static let deckDebugCommand = Notification.Name("DeckDebugCommand")
}

extension Notification.Name {
    /// Debug only: switch the Settings window to a tab.
    static let deckDebugSettingsTab = Notification.Name("deckDebugSettingsTab")
    /// Debug only: open a compose file on the Compose screen.
    static let deckDebugComposeOpen = Notification.Name("deckDebugComposeOpen")
    /// Debug only: open a sheet on the current screen.
    static let deckDebugOpenSheet = Notification.Name("deckDebugOpenSheet")
}

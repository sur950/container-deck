import SwiftUI
import DeckCore
import AppKit

@main
struct ContainerDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()
    @AppStorage(PrefKey.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(PrefKey.appearance) private var appearance = AppearanceMode.system.rawValue

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        WindowGroup(AppConfig.appName, id: "main") {
            RootView()
                .environment(state)
                .tint(DS.accent)
                .frame(minWidth: AppConfig.minimumWindowWidth, minHeight: AppConfig.minimumWindowHeight)
                .onAppear { Appearance.apply(appearance) }
                .onChange(of: appearance) { _, newValue in Appearance.apply(newValue) }
        }
        .handlesExternalEvents(matching: ["*"])
        // Open at the smallest size that fits every screen. MainWindowSize also resets a restored
        // frame on the first window of each launch, so it never opens filling the screen.
        .defaultSize(width: AppConfig.minimumWindowWidth, height: AppConfig.minimumWindowHeight)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand()
            }
            CommandGroup(after: .help) {
                Button("Diagnostics…") { DiagnosticsWindow.show(state: state) }
                    .keyboardShortcut("d", modifiers: [.command, .option])
            }
            CommandGroup(after: .sidebar) {
                Button("Command Palette…") { state.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Run Setup Checks") { Task { await state.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(state)
                .tint(DS.accent)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environment(state)
                .tint(DS.accent)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Applies Light, Dark or Match System to every window, menus and the menu bar panel.
enum Appearance {
    @MainActor
    static func apply(_ raw: String) {
        switch AppearanceMode(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false
    private var observers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        if SingleInstance.anotherIsRunning() {
            SingleInstance.handOffAndExit()
        }
        MainWindowSize.forgetSavedFrame()
        // Login items are opened with an "open application" event marked as a login launch.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAtLogin = true
        }
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.applyIfNeeded()
        InstallMover.check()

        let menuBarOn = UserDefaults.standard.bool(forKey: PrefKey.showMenuBarExtra)
        if launchedAtLogin && menuBarOn {
            // Start quietly in the menu bar.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                for window in NSApp.windows where AppWindows.isRegular(window) {
                    window.close()
                }
            }
        } else {
            NSApp.setActivationPolicy(AppWindows.wantsDockIcon ? .regular : .accessory)
            NSApp.activate(ignoringOtherApps: true)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if AppWindows.isRegular(window) { AppWindows.updatePolicy() }
                MainWindowSize.applyOnceIfNeeded(window)
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard AppWindows.isRegular(window) else { return }
                // Wait until the window is gone, then decide.
                DispatchQueue.main.async { AppWindows.updatePolicy() }
            }
        })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar when that is turned on.
        !UserDefaults.standard.bool(forKey: PrefKey.showMenuBarExtra)
    }
}

/// Tracks the app's own windows (main and Settings), not the menu bar panel.
@MainActor
enum AppWindows {
    static func isRegular(_ window: NSWindow) -> Bool {
        if window is NSPanel { return false }
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "main" || raw.hasPrefix("main-") || raw == "deck-logs" || raw.contains("Settings")
    }

    static var hasVisibleWindow: Bool {
        NSApp.windows.contains { isRegular($0) && ($0.isVisible || $0.isMiniaturized) }
    }

    /// Dock icon only while a window is open, unless the person hid it in Settings.
    static var wantsDockIcon: Bool {
        !UserDefaults.standard.bool(forKey: PrefKey.hideDockIcon)
    }

    static func updatePolicy() {
        let menuBarOn = UserDefaults.standard.bool(forKey: PrefKey.showMenuBarExtra)
        let regular = wantsDockIcon && (hasVisibleWindow || !menuBarOn)
        let target: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
            if target == .regular {
                DockIcon.applyIfNeeded()
                NSApp.activate()
            }
        }
    }
}

/// Dock and Cmd-Tab icon. The bundled app uses AppIcon.icns. With `swift run`
/// there is no bundle, so load the brand icon from the source tree or draw it.
@MainActor
enum DockIcon {
    static func applyIfNeeded() {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil { return }
        NSApp.applicationIconImage = image
    }

    private static let image: NSImage? = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // ContainerDeck
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        let png = repo.appendingPathComponent(AppConfig.appIconFile)
        if let image = NSImage(contentsOf: png) { return image }
        // Fallback: draw the tile with the standard macOS icon margin.
        let renderer = ImageRenderer(content: LogoTile(size: 824).padding(100).frame(width: 1024, height: 1024))
        renderer.scale = 1
        return renderer.nsImage
    }()
}

/// Only one Container Deck may run at a time. Info.plist sets LSMultipleInstancesProhibited,
/// and this check also covers a second copy in another folder, `open -n` or starting the binary directly.
/// Debug builds started with DECK_AUTOMATION_ID (visual test copies) are allowed to run side by side.
enum SingleInstance {
    static func anotherIsRunning() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DECK_AUTOMATION_ID"] != nil { return false }
        #endif
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Bring the running copy forward, then quit this one before any window opens.
    static func handOffAndExit() {
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            // Opening the app URL makes the running copy show its window (menu bar mode included).
            if let url = DeepLink.show.url {
                NSWorkspace.shared.open(url)
            }
            other.activate()
        }
        exit(0)
    }
}

/// The first main window of each launch opens at the minimum size, centered, whatever frame
/// macOS restored. Later windows and resizes during the session are left alone.
@MainActor
enum MainWindowSize {
    private static var applied = false

    /// Drops the main window frame macOS saved at the last quit, before any window exists, so
    /// the first window opens at the default (minimum) size instead of opening large and then
    /// shrinking. Other windows (Logs, Settings) keep their saved frames.
    nonisolated static func forgetSavedFrame(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame main") || key.hasPrefix("NSSplitView Subview Frames main") {
            defaults.removeObject(forKey: key)
        }
    }

    static func applyOnceIfNeeded(_ window: NSWindow) {
        guard !applied, let id = window.identifier?.rawValue, id == "main" || id.hasPrefix("main-") else { return }
        applied = true
        guard window.styleMask.contains(.fullScreen) == false else { return }
        // macOS applies a restored frame right after the window appears, so wait a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if window.isZoomed { window.zoom(nil) }
            let size = NSSize(width: AppConfig.minimumWindowWidth, height: AppConfig.minimumWindowHeight)
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            window.setFrame(NSRect(origin: window.frame.origin, size: frame.size), display: true, animate: false)
            window.center()
        }
    }
}

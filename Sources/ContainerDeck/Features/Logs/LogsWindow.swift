import SwiftUI
import AppKit
import DeckCore

/// The Logs window. One for the app: opening it again brings it forward and adds the
/// asked for containers as panes. Usable from the palette, deep links and the menu bar:
/// `LogsWindow.open(state: state, containerIDs: ["web", "db"])`.
@MainActor
enum LogsWindow {
    static let identifier = "deck-logs"
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static var isOpen: Bool { window?.isVisible ?? false }

    static func open(state: AppState, containerIDs: [String] = []) {
        NSApp.activate()
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            if !containerIDs.isEmpty {
                NotificationCenter.default.post(name: .deckLogsAdd, object: nil, userInfo: ["ids": containerIDs])
            }
            return
        }
        let root = LogsScreen(containerIDs: containerIDs)
            .environment(state)
            .tint(DS.accent)
            .frame(minWidth: 640, minHeight: 360)
        let host = NSHostingController(rootView: root)
        let next = NSWindow(contentViewController: host)
        next.identifier = NSUserInterfaceItemIdentifier(identifier)
        next.title = "Logs"
        next.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        next.titlebarAppearsTransparent = false
        next.toolbarStyle = .unifiedCompact
        next.isReleasedWhenClosed = false
        next.tabbingMode = .disallowed
        next.setContentSize(NSSize(width: 1100, height: 680))
        next.setFrameAutosaveName("DeckLogsWindow")
        if next.frame.origin == .zero { next.center() }
        next.makeKeyAndOrderFront(nil)
        window = next
        // Closing ends every log stream: the view goes away with the window.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: next, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let observer = LogsWindow.closeObserver { NotificationCenter.default.removeObserver(observer) }
                LogsWindow.closeObserver = nil
                let closing = LogsWindow.window
                LogsWindow.window = nil
                DispatchQueue.main.async { closing?.contentViewController = nil }
            }
        }
    }

    static func close() {
        window?.close()
    }
}

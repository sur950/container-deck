import SwiftUI
import AppKit

/// Is anybody looking? Tracks the main window (visible, not minimised, not covered,
/// app not hidden) and the menu bar panel. Pollers use this to slow down or pause.
@MainActor
@Observable
final class AppActivity {
    static let shared = AppActivity()

    enum Mode: Equatable {
        /// A main window is on screen.
        case foreground
        /// Only the menu bar panel is open.
        case panel
        /// Nothing of ours is on screen.
        case background
    }

    private(set) var windowVisible = false
    private(set) var isActive = false
    private(set) var panelOpen = false

    var mode: Mode {
        if windowVisible { return .foreground }
        if panelOpen { return .panel }
        return .background
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var listeners: [() -> Void] = []
    @ObservationIgnored private var pendingRecompute = false

    private init() {}

    /// Safe to call more than once.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSApplication.didChangeOcclusionStateNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppActivity.shared.scheduleRecompute() }
            })
        }
        recompute()
        // The first window may settle after these observers are in place without posting anything.
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { AppActivity.shared.recompute() }
            }
        }
    }

    /// Called whenever the mode may have changed.
    func onChange(_ listener: @escaping () -> Void) {
        listeners.append(listener)
    }

    func setPanelOpen(_ open: Bool) {
        guard panelOpen != open else { return }
        panelOpen = open
        DebugAutomation.log("activity: panel \(open)")
        notify()
    }

    /// Window state settles after the notification (a closing window is still visible), so look a moment later.
    private func scheduleRecompute() {
        guard !pendingRecompute else { return }
        pendingRecompute = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                AppActivity.shared.pendingRecompute = false
                AppActivity.shared.recompute()
            }
        }
    }

    func recompute() {
        var visible = !NSApp.isHidden && NSApp.windows.contains { window in
            guard let raw = window.identifier?.rawValue, raw == "main" || raw.hasPrefix("main-") || raw == "deck-logs" else { return false }
            return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
        #if DEBUG
        // Screenshot runs: keep sampling while other windows cover this one.
        if ProcessInfo.processInfo.environment["DECK_AUTOMATION_KEEP_LIVE"] == "1" { visible = true }
        #endif
        let active = NSApp.isActive
        let changed = visible != windowVisible || active != isActive
        if visible != windowVisible { windowVisible = visible }
        if active != isActive { isActive = active }
        if changed {
            DebugAutomation.log("activity: window \(visible) active \(active) panel \(panelOpen)")
            notify()
        }
    }

    private func notify() {
        for listener in listeners { listener() }
    }
}

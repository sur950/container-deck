import SwiftUI
import AppKit
import DeckCore

/// Covers the whole main window while a compulsory update is pending (AppUpdates.required).
/// No way past it: install, view the release, or quit. RootView hides the toolbar and
/// disables everything underneath.
struct RequiredUpdateView: View {
    let update: RequiredUpdate
    private let updates = AppUpdates.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 22)
            versions
                .padding(.bottom, 22)
            notesCard
            statusArea
                .padding(.top, 16)
            actions
                .padding(.top, 16)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.surface.ignoresSafeArea())
        .background(WindowChromeHider())
        .accessibilityElement(children: .contain)
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: 12) {
            LogoTile(size: 64)
                .padding(.bottom, 4)
            Text("Update required")
                .font(.title.weight(.semibold))
                .foregroundStyle(DS.textPrimary)
            Text(reasonLine)
                .font(.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reasonLine: String {
        switch update.reason {
        case .breaking:
            return "Version \(update.version) has breaking changes. Update to keep using \(AppConfig.appName)."
        case .critical:
            return "Version \(update.version) has a critical fix. Update to keep using \(AppConfig.appName)."
        }
    }

    private var versions: some View {
        HStack(spacing: 14) {
            versionTile("This version", updates.currentVersion ?? "Development build", tint: DS.textPrimary)
            DeckIcon(.chevronRight, size: 14, color: DS.textTertiary)
            versionTile("New version", update.version, tint: DS.accent)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func versionTile(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(DS.textSecondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 180)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 12)
        .deckCard()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What is new")
                .font(.headline)
                .foregroundStyle(DS.textPrimary)
                .padding(.horizontal, DS.pad)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            // Short notes keep the card short. Long notes scroll inside it.
            ViewThatFits(in: .vertical) {
                notesBody
                ScrollView { notesBody }
                    .frame(minHeight: 90, maxHeight: 380)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .deckCard()
    }

    private var notesBody: some View {
        ReleaseNotesView(notes: notes)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.pad)
    }

    /// Notes of the release to install. After an offline launch, the remembered notes.
    private var notes: String {
        updates.latest.map { $0.version.description == update.version ? $0.notes : update.notes } ?? update.notes
    }

    @ViewBuilder
    private var statusArea: some View {
        switch updates.install {
        case .idle:
            EmptyView()
        case .failed(let message, _):
            HStack(alignment: .top, spacing: 8) {
                DeckIcon(.warning, size: 13, color: DS.warning)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(DS.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        default:
            UpdateInstallStatus(compact: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Quit \(AppConfig.appName)") { NSApp.terminate(nil) }
            Spacer(minLength: 12)
            Button {
                updates.openRequiredReleasePage()
            } label: {
                DeckLabel("View on GitHub", icon: .openExternal)
            }
            primaryButton
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if !updates.canInstallInPlace {
            Button {
                updates.openRequiredReleasePage()
            } label: {
                DeckLabel("Download", icon: .download)
            }
            .keyboardShortcut(.defaultAction)
            .deckPrimary()
        } else if case .failed(_, let manual) = updates.install, manual {
            Button {
                updates.dismissInstallError()
                updates.openDiskImageInstead(showPanel: false)
            } label: {
                DeckLabel("Open Disk Image", icon: .download)
            }
            .keyboardShortcut(.defaultAction)
            .deckPrimary()
        } else if case .failed = updates.install {
            Button {
                updates.dismissInstallError()
                updates.installRequired()
            } label: {
                DeckLabel("Try Again", icon: .refresh)
            }
            .keyboardShortcut(.defaultAction)
            .deckPrimary()
        } else {
            Button {
                updates.installRequired()
            } label: {
                DeckLabel("Install and Relaunch", icon: .download)
            }
            .keyboardShortcut(.defaultAction)
            .deckPrimary()
            .disabled(updates.isInstalling)
        }
    }

    private var footnote: String {
        if updates.canInstallInPlace {
            return "\(AppConfig.appName) checks the download, replaces itself and opens again. Your containers keep running."
        }
        return "This copy cannot update itself. Download the new version and move it to Applications. Your containers keep running."
    }
}

/// Hides the toolbar (so no sidebar button) and the screen title of the window it is in,
/// while keeping the close and minimize buttons. SwiftUI's .toolbar(.hidden) would hide the
/// whole title bar, and SwiftUI puts the title back when a screen updates, so this watches it.
/// Everything comes back when the view goes away.
private struct WindowChromeHider: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.apply() }
    static func dismantleNSView(_ view: ChromeView, coordinator: ()) { view.restore() }

    final class ChromeView: NSView {
        private weak var hiddenIn: NSWindow?
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { restore() } else { apply() }
        }

        func apply() {
            guard let window, hiddenIn !== window else { return }
            restore()
            hiddenIn = window
            hide(window)
            observations = [
                window.observe(\.titleVisibility) { window, _ in
                    DispatchQueue.main.async { [weak self] in self?.hideIfShown(window) }
                },
                window.observe(\.title) { window, _ in
                    DispatchQueue.main.async { [weak self] in self?.hideIfShown(window) }
                },
            ]
        }

        func restore() {
            observations = []
            guard let window = hiddenIn else { return }
            hiddenIn = nil
            window.toolbar?.isVisible = true
            window.titleVisibility = .visible
        }

        private func hideIfShown(_ window: NSWindow) {
            guard hiddenIn === window else { return }
            hide(window)
        }

        private func hide(_ window: NSWindow) {
            if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        }
    }
}

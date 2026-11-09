import SwiftUI
import AppKit
import DeckCore

struct UpdatesSettings: View {
    @AppStorage(PrefKey.checkForUpdates) private var checkForUpdates = true

    private let updates = AppUpdates.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("This version", value: updates.currentVersion ?? "Development build")
                LabeledContent("Latest version") {
                    latestText
                }
                LabeledContent("Last checked") {
                    HStack(spacing: 10) {
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                        }
                        Text(updates.lastChecked.map { Format.relative($0) } ?? "Not yet")
                            .foregroundStyle(DS.textSecondary)
                        Button {
                            Task { await updates.check() }
                        } label: {
                            DeckLabel("Check Now", icon: .refresh)
                        }
                        .disabled(updates.isChecking || updates.isInstalling)
                    }
                }

                if updates.isUpdateAvailable, let latest = updates.latest {
                    LabeledContent("Update") {
                        updateControls(latest)
                    }
                }

                if updates.install != .idle {
                    UpdateInstallStatus(compact: false)
                }

                if case .failed(let message) = updates.phase, !noReleaseYet {
                    HStack(spacing: 6) {
                        DeckIcon(.warning, size: 12, color: DS.warning)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Check for updates automatically", isOn: $checkForUpdates)
            } header: {
                Text("Version")
            } footer: {
                Text(updates.canInstallInPlace
                     ? "Updates come from GitHub releases. \(AppConfig.appName) downloads the new version, checks its signature, replaces itself and opens again."
                     : "Updates come from GitHub releases. This build has no update key, so you download new versions from the release page.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let latest = updates.latest {
                Section("What is new in \(latest.version.description)") {
                    ScrollView {
                        ReleaseNotesView(notes: latest.notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                    .frame(minHeight: 80, maxHeight: 240)

                    HStack {
                        if let published = latest.publishedAt {
                            Text("Released \(Format.relative(published))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            updates.openReleasePage()
                        } label: {
                            DeckLabel("View on GitHub", icon: .openExternal)
                        }
                        .deckLink()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .task {
            if updates.result == nil && updates.lastChecked == nil && !updates.isChecking {
                await updates.check()
            }
        }
    }

    @ViewBuilder
    private func updateControls(_ latest: AppRelease) -> some View {
        HStack(spacing: 8) {
            if updates.isLatestSkipped {
                Pill("Skipped", tint: DS.textSecondary)
            } else {
                Button("Later") { updates.skipLatest() }
                    .disabled(updates.isInstalling)
            }
            if updates.canInstallInPlace {
                Button {
                    updates.installAndRelaunch(showPanel: false)
                } label: {
                    DeckLabel("Install and Relaunch", icon: .download)
                }
                .deckPrimary()
                .disabled(updates.isInstalling)
            } else {
                Button {
                    updates.openReleasePage()
                } label: {
                    DeckLabel("Open Download Page", icon: .openExternal)
                }
                .deckPrimary()
            }
        }
    }

    @ViewBuilder
    private var latestText: some View {
        if let latest = updates.latest {
            HStack(spacing: 6) {
                Text(latest.version.description)
                if updates.isUpdateAvailable {
                    Pill("New", tint: DS.accent)
                } else if updates.result?.current != nil {
                    Pill("Up to date", tint: DS.running)
                }
            }
        } else if updates.isChecking {
            Text("Checking…").foregroundStyle(.secondary)
        } else if noReleaseYet {
            Text("None published yet").foregroundStyle(.secondary)
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }

    /// GitHub answers 404 when the repository has no published release yet.
    /// That is a normal state, not an error.
    private var noReleaseYet: Bool {
        if case .failed(let message) = updates.phase {
            return message == UpdateCheckError.noRelease.errorDescription
        }
        return false
    }
}

// MARK: - Release notes

/// Release notes from GitHub (Markdown) drawn as headings and lists, instead of raw Markdown.
struct ReleaseNotesView: View {
    let notes: String

    var body: some View {
        // Marker lines (<!-- deck-update: required -->) are for the updater, not for people.
        let blocks = ChatMarkdown.blocks(UpdateMarker.strip(notes).trimmingCharacters(in: .whitespacesAndNewlines))
        if blocks.isEmpty {
            Text("No release notes.")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    blockView(block, first: index == 0)
                }
            }
            .textSelection(.enabled)
            .tint(DS.accent)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        ChatMarkdown.inline(text, codeBackground: DS.hover)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block, first: Bool) -> some View {
        switch block {
        case .heading(_, let text):
            Text(inline(text))
                .font(.callout.weight(.semibold))
                .foregroundStyle(DS.textPrimary)
                .padding(.top, first ? 0 : 6)
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(DS.accent)
                            .frame(minWidth: 10, alignment: .trailing)
                        paragraph(item.text)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .paragraph(let text):
            paragraph(text)
        case .code(let language, let code):
            ChatCodeBlock(language: language, code: code)
        case .quote(let text):
            paragraph(text)
                .foregroundStyle(DS.textSecondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(DS.borderStrong).frame(width: 3) }
        case .table(let rows):
            ChatMarkdownTable(rows: rows, inline: inline)
        case .rule:
            Divider()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(inline(text))
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(DS.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Install progress

/// Progress bar, step and errors of a running install. Used in Settings, the progress panel and the menu bar.
struct UpdateInstallStatus: View {
    /// Compact: one line for the menu bar panel.
    var compact: Bool
    private let updates = AppUpdates.shared

    var body: some View {
        switch updates.install {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            progressRow(fraction.map { "Downloading \(Int(($0 * 100).rounded()))%" } ?? "Downloading", fraction: fraction)
        case .verifying(let step):
            progressRow(step, fraction: nil)
        case .relaunching:
            progressRow("Installing. \(AppConfig.appName) opens again in a moment.", fraction: 1)
        case .failed(let message, let manual):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    DeckIcon(.warning, size: 12, color: DS.warning)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !compact {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Dismiss") { updates.dismissInstallError() }
                        if manual {
                            Button {
                                updates.openDiskImageInstead(showPanel: false)
                            } label: {
                                DeckLabel("Open Disk Image", icon: .download)
                            }
                        } else {
                            Button("Try Again") { updates.installAndRelaunch(showPanel: false) }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func progressRow(_ text: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(text)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(DS.textSecondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if !compact, updates.install != .relaunching {
                    Button("Cancel") { updates.cancelInstall() }
                        .controlSize(.small)
                }
            }
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(DS.accent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DS.accent)
            }
        }
    }
}

/// Small window that shows install progress when the update starts from an alert,
/// a notification or the menu bar panel.
struct UpdateProgressView: View {
    private let updates = AppUpdates.shared

    var body: some View {
        SheetScaffold(title, subtitle: subtitle, icon: .download, width: 440, scrolls: false) {
            UpdateInstallStatus(compact: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        if case .failed = updates.install { return "Update did not finish" }
        return "Updating \(AppConfig.appName)"
    }

    private var subtitle: String {
        guard let latest = updates.latest else { return "" }
        return "Version \(latest.version.description). Your containers keep running."
    }

    @ViewBuilder
    private var footer: some View {
        switch updates.install {
        case .failed(_, let manual):
            Button("Close") {
                updates.dismissInstallError()
                UpdateProgressPanel.close()
            }
            .keyboardShortcut(.cancelAction)
            if manual {
                Button {
                    updates.dismissInstallError()
                    updates.openDiskImageInstead()
                } label: {
                    DeckLabel("Open Disk Image", icon: .download)
                }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
            } else {
                Button("Try Again") { updates.installAndRelaunch() }
                    .keyboardShortcut(.defaultAction)
                    .deckPrimary()
            }
        case .relaunching:
            Button("Cancel") {}
                .disabled(true)
        case .idle:
            Button("Close") { UpdateProgressPanel.close() }
                .keyboardShortcut(.cancelAction)
        default:
            Button("Cancel") {
                updates.cancelInstall()
                UpdateProgressPanel.close()
            }
            .keyboardShortcut(.cancelAction)
        }
    }
}

@MainActor
enum UpdateProgressPanel {
    private static var panel: NSPanel?

    static func show() {
        NSApp.activate()
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: UpdateProgressView().tint(DS.accent))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}

/// "Check for Updates…" in the app menu.
struct CheckForUpdatesCommand: View {
    private let updates = AppUpdates.shared

    var body: some View {
        Button("Check for Updates…") {
            Task { await updates.checkAndReport() }
        }
        // Enabled while a check runs: the click waits for that check and then shows the result.
        .disabled(updates.isInstalling)
    }
}

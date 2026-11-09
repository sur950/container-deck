import SwiftUI
import AppKit
import DeckCore

/// Full screen shown when the installed container tool is too old, or the command
/// and the running service are different versions. Clear steps to fix it.
struct VersionMismatchView: View {
    @Environment(AppState.self) private var state
    let compatibility: VersionCompatibility
    /// nil hides "Continue Anyway".
    var onContinue: (() -> Void)?

    @State private var working: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    IconBadge(compatibility.needsScreen ? .error : .warning,
                              tint: compatibility.needsScreen ? DS.danger : DS.warning, size: 56)
                    Text(compatibility.title)
                        .font(.title2.weight(.semibold))
                    Text(compatibility.message)
                        .font(.body)
                        .foregroundStyle(DS.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520)
                }
                EqualHeightRow {
                    MetricTile(title: "Installed", value: compatibility.cliVersion.map { "\($0)" } ?? "Unknown",
                               subtitle: "container command", icon: .terminal,
                               tint: compatibility.needsScreen ? DS.danger : DS.warning)
                    MetricTile(title: "Service", value: compatibility.daemonVersion.map { "\($0)" } ?? "Unknown",
                               subtitle: "running now", icon: .power)
                    MetricTile(title: "Tested", value: compatibility.testedRangeText, subtitle: "minimum \(compatibility.minimum)", icon: .success)
                }
                .frame(maxWidth: 640)
                VersionStepsCard(compatibility: compatibility)
                    .frame(maxWidth: 640)
                actions
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let working {
                ProgressView().controlSize(.small)
                Text(working).foregroundStyle(DS.textSecondary)
            }
            if compatibility.verdict == .serviceMismatch {
                Button {
                    restartService()
                } label: {
                    DeckLabel("Restart Service", icon: .restart)
                }
                .deckPrimary()
                .disabled(working != nil || state.client == nil)
            } else {
                Button {
                    NSWorkspace.shared.open(VersionCompatibility.releasesURL)
                } label: {
                    DeckLabel("Open Releases Page", icon: .openExternal)
                }
                .deckPrimary()
            }
            Button {
                Task {
                    working = "Checking"
                    await state.refresh()
                    working = nil
                }
            } label: {
                DeckLabel("Check Again", icon: .refresh)
            }
            .disabled(working != nil)
            if let onContinue {
                Button("Continue Anyway", action: onContinue)
                    .disabled(working != nil)
                    .help("Some screens may not work with this version.")
            }
        }
        .controlSize(.large)
    }

    private func restartService() {
        guard let client = state.client else { return }
        working = "Restarting the service"
        Task {
            do {
                try await client.restartSystemService()
                await state.refresh()
                state.showToast("The container service restarted.", style: .success)
            } catch {
                state.showError(error)
                DiagnosticsLog.shared.record(error, source: "Version check")
            }
            working = nil
        }
    }
}

/// Numbered steps, each with its command or link.
struct VersionStepsCard: View {
    let compatibility: VersionCompatibility

    var body: some View {
        Card("How to fix it", icon: .checklist) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(compatibility.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(DS.accent)
                            .frame(width: 22, height: 22)
                            .background(DS.iconSoft, in: Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            if let command = step.command {
                                CommandHint(command)
                            }
                            if let link = step.link {
                                Button {
                                    NSWorkspace.shared.open(link)
                                } label: {
                                    DeckLabel("Releases page", icon: .openExternal)
                                }
                                .buttonStyle(SoftAccentButtonStyle())
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// The same screen in a sheet, from Diagnostics.
struct VersionMismatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let compatibility: VersionCompatibility

    var body: some View {
        VStack(spacing: 0) {
            VersionMismatchView(compatibility: compatibility)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 720, height: 680)
        .background(DS.surface)
    }
}

/// A slim banner above the screens when the command and the running service are different
/// versions, or the tool is older than the app expects. Never blocks the app: everything keeps
/// working through whatever the platform answers. Restart Service fixes a mismatch, Details
/// opens the full steps, and closing it hides it until the versions change.
struct VersionNoticeBanner: View {
    @Environment(AppState.self) private var state
    @State private var daemonVersion: SemanticVersion?
    @State private var dismissedFor: String?
    @State private var showDetails = false
    @State private var restarting = false
    /// Automation only: shows the banner for a made up version.
    @State private var preview: VersionCompatibility?

    var body: some View {
        Group {
            if let shown = preview ?? (compatibility.needsScreen && dismissedFor != key ? compatibility : nil) {
                banner(shown)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: state.report.cliVersion.map { "\($0)" } ?? "") {
            let status = await state.router?.status()
            daemonVersion = status?.daemonVersion.flatMap { SemanticVersion.firstMatch(in: $0) }
        }
        .sheet(isPresented: $showDetails) {
            VersionMismatchSheet(compatibility: preview ?? compatibility)
                .environment(state)
                .tint(DS.accent)
        }
        .onDeckDebugCommand { name, value in
            guard name == "version-preview" else { return }
            if value == "off" {
                preview = nil
                return
            }
            let parts = value.split(separator: ",").map { SemanticVersion.firstMatch(in: String($0)) }
            preview = VersionCompatibility(cliVersion: parts.first ?? nil, daemonVersion: parts.count > 1 ? parts[1] : parts.first ?? nil)
        }
    }

    private func banner(_ shown: VersionCompatibility) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(DS.warning.opacity(0.16))
                DeckIcon(.warning, size: 16, color: DS.warning)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(shown.title)
                    .font(.callout.weight(.semibold))
                Text(shown.message)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            if restarting {
                ProgressView().controlSize(.small)
            } else if shown.verdict == .serviceMismatch {
                Button("Restart Service") { restartService() }
                    .deckPrimary()
                    .disabled(state.client == nil)
            }
            Button("Details") { showDetails = true }
            Button {
                withAnimation { dismissedFor = key; preview = nil }
            } label: {
                DeckIcon(.close, size: 11, color: DS.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide until the versions change")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(DS.warning.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.warning.opacity(0.25)).frame(height: 1)
        }
    }

    private func restartService() {
        guard let client = state.client else { return }
        restarting = true
        Task {
            do {
                try await client.restartSystemService()
                await state.refresh()
                let status = await state.router?.status()
                daemonVersion = status?.daemonVersion.flatMap { SemanticVersion.firstMatch(in: $0) }
                state.showToast("The container service restarted.", style: .success)
            } catch {
                state.showError(error)
                DiagnosticsLog.shared.record(error, source: "Version check")
            }
            restarting = false
        }
    }

    private var compatibility: VersionCompatibility {
        // Only judge once the setup checks have read the version.
        guard state.report.cliVersion != nil else {
            return VersionCompatibility(cliVersion: nil, daemonVersion: nil)
        }
        return VersionCompatibility(cliVersion: state.report.cliVersion, daemonVersion: daemonVersion)
    }

    private var key: String {
        "\(compatibility.cliVersion.map { "\($0)" } ?? "")|\(compatibility.daemonVersion.map { "\($0)" } ?? "")"
    }
}

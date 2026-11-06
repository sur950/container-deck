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

/// Covers the window with the mismatch screen when the tool is too old or the
/// service runs another version. Apply once on the root view:
/// `.versionMismatchGate()`. "Continue Anyway" hides it until the version changes.
struct VersionMismatchGate: ViewModifier {
    @Environment(AppState.self) private var state
    @State private var daemonVersion: SemanticVersion?
    @State private var dismissedFor: String?
    /// Automation only: shows the screen for a made up version.
    @State private var preview: VersionCompatibility?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let shown = preview ?? (compatibility.needsScreen && dismissedFor != key ? compatibility : nil) {
                    VersionMismatchView(compatibility: shown) {
                        dismissedFor = key
                        preview = nil
                    }
                    .transition(.opacity)
                }
            }
            .task(id: state.report.cliVersion.map { "\($0)" } ?? "") {
                let status = await state.router?.status()
                daemonVersion = status?.daemonVersion.flatMap { SemanticVersion.firstMatch(in: $0) }
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

extension View {
    /// See `VersionMismatchGate`.
    func versionMismatchGate() -> some View {
        modifier(VersionMismatchGate())
    }
}

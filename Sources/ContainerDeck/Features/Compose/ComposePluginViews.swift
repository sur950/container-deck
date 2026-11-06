import SwiftUI
import DeckCore

/// Offers the `container compose` terminal command. One admin prompt, never automatic.
struct ComposePluginCard: View {
    @Environment(AppState.self) private var state
    let store: ComposeStore

    var body: some View {
        Card("Compose in the terminal", icon: .terminal) {
            // At most two lines. Unbounded text here would set the window's minimum height.
            Text("Run the same compose files from the terminal and in scripts with container compose.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                statusPill
                Spacer(minLength: 8)
                if store.pluginWorking {
                    ProgressView().controlSize(.small)
                }
                actionButton
            }
            if store.pluginStatus == .installed {
                CommandHint("container compose up -d")
            }
        }
        .frame(height: store.pluginStatus == .installed ? 190 : 150)
        .onAppear { store.refreshPluginStatus() }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch store.pluginStatus {
        case .installed: Pill("Installed", tint: DS.running)
        case .outdated: Pill("Update ready", tint: DS.warning)
        case .removedByUpgrade: Pill("Removed by a container update", tint: DS.warning)
        case .notInstalled: Pill("Not installed", tint: DS.stopped)
        case .notBundled: Pill("Not in this build", tint: DS.stopped)
        case nil: Pill("Checking", tint: DS.stopped)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch store.pluginStatus {
        case .notInstalled, .removedByUpgrade, .outdated:
            Button {
                if let client = state.client { store.installPlugin(client: client, state: state) }
            } label: {
                DeckLabel(store.pluginStatus == .notInstalled ? "Install" : (store.pluginStatus == .outdated ? "Update" : "Reinstall"), icon: .download)
            }
            .deckPrimary()
            .disabled(store.pluginWorking || state.client == nil)
            .help("Copies container compose into Apple's plugin folder. Asks for your admin password once.")
        case .installed:
            Button {
                if let client = state.client { store.removePlugin(client: client, state: state) }
            } label: {
                DeckLabel("Remove", icon: .trash)
            }
            .disabled(store.pluginWorking || state.client == nil)
            .help("Removes container compose. Asks for your admin password once.")
        case .notBundled, nil:
            EmptyView()
        }
    }
}

/// Short title for menus.
extension ComposePluginInstaller.Status {
    var menuTitle: String? {
        switch self {
        case .notInstalled: return "Install the container compose Command"
        case .removedByUpgrade: return "Reinstall the container compose Command"
        case .outdated: return "Update the container compose Command"
        case .installed: return "Remove the container compose Command"
        case .notBundled: return nil
        }
    }
}

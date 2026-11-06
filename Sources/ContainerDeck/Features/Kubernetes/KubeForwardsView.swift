import SwiftUI
import AppKit
import DeckCore

/// Port Forwards tab: the `kubectl port-forward` runs for this cluster.
struct KubeForwardsView: View {
    @Environment(AppState.self) private var state
    let cluster: KubeCluster
    let client: ContainerClient
    let store: KubernetesStore

    private var list: [KubePortForward] { store.forwards(for: cluster.name) }

    var body: some View {
        VStack(spacing: 0) {
            if store.tools.kubectl == nil {
                EmptyState(
                    icon: .port,
                    title: "Port forwards need kubectl",
                    message: "Install kubectl with Homebrew (brew install kubectl). \(AppConfig.appName) finds it and runs the forwards for you.",
                    actionTitle: "Check Again"
                ) {
                    store.tools = KubeTools.detect()
                }
            } else if list.isEmpty {
                EmptyState(
                    icon: .port,
                    title: "No port forwards",
                    message: "Open Workloads and use the port button on a service or pod. The forward gives you a local URL on this Mac."
                )
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(list) { forward in
                            KubeForwardRow(forward: forward, store: store)
                        }
                    }
                    .padding(DS.pad)
                }
            }
            ListStatusBar(statusText) {
                if list.contains(where: { !$0.isActive }) {
                    Button("Clear Stopped") {
                        for forward in list where !forward.isActive { store.forwarder.remove(forward.id) }
                    }
                    .buttonStyle(AccentLinkButtonStyle())
                }
                if list.contains(where: \.isActive) {
                    Button("Stop All") { store.forwarder.stopAll(cluster: cluster.name) }
                        .buttonStyle(AccentLinkButtonStyle())
                }
            }
        }
        .background(DS.surface)
    }

    private var statusText: String {
        let active = list.filter(\.isActive).count
        return "\(active) running, \(list.count - active) stopped"
    }
}

struct KubeForwardRow: View {
    let forward: KubePortForward
    let store: KubernetesStore

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(.port, tint: forward.isActive ? DS.accent : DS.stopped, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(forward.target)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(forward.namespace)
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                    stateView
                }
                if let url = forward.localURL, forward.isActive {
                    HStack(spacing: 6) {
                        Text(url)
                            .font(.callout.monospaced())
                            .foregroundStyle(DS.accent)
                            .textSelection(.enabled)
                        Text("to port \(forward.remotePort)")
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                } else if case .failed(let message) = forward.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(DS.danger)
                        .lineLimit(2)
                } else {
                    Text("Port \(forward.remotePort)")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if let url = forward.localURL, forward.state == .running {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    DeckLabel("Copy", icon: .copy)
                }
                Button {
                    if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                } label: {
                    DeckLabel("Open", icon: .openExternal)
                }
            }
            if forward.isActive {
                Button {
                    store.forwarder.stop(forward.id)
                } label: {
                    DeckLabel("Stop", icon: .stop)
                }
            } else {
                Button {
                    store.forwarder.remove(forward.id)
                } label: {
                    DeckLabel("Remove", icon: .close)
                }
            }
        }
        .padding(12)
        .deckCard(radius: DS.smallRadius + 2)
    }

    @ViewBuilder
    private var stateView: some View {
        switch forward.state {
        case .starting: Pill("Starting", tint: DS.warning)
        case .running: Pill("Running", tint: DS.running)
        case .failed: Pill("Failed", tint: DS.danger)
        case .stopped: Pill("Stopped", tint: DS.stopped)
        }
    }
}

/// Asks for the ports of a new forward.
struct KubeForwardSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let cluster: KubeCluster
    let client: ContainerClient
    let store: KubernetesStore
    let target: KubeForwardTarget

    @State private var remotePort = ""
    @State private var localPort = ""
    @State private var starting = false

    var body: some View {
        SheetScaffold(
            "Port Forward",
            subtitle: "Reach \(target.kind == "service" ? "service" : "pod") \(target.name) from this Mac.",
            icon: .port,
            width: 500
        ) {
            if store.tools.kubectl == nil {
                ErrorNote(message: "kubectl is not installed. Install it with Homebrew (brew install kubectl), then try again.")
            }
            DeckFormGroup {
                DeckFormRow("Target") {
                    Text("\(target.namespace)/\(target.name)")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                DeckFormRow("Port", note: target.ports.isEmpty ? "The port inside the cluster." : nil) {
                    HStack(spacing: 8) {
                        TextField("Port", text: $remotePort, prompt: Text("80"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 90)
                        ForEach(target.ports.prefix(5), id: \.self) { port in
                            Button(String(port)) { remotePort = String(port) }
                                .buttonStyle(SoftAccentButtonStyle())
                        }
                    }
                }
                DeckFormRow("Local port", note: "Leave empty to use a free port.") {
                    TextField("Local port", text: $localPort, prompt: Text("Any free port"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 140)
                }
            }
            if let kubectl = store.tools.kubectl {
                CommandHint(([kubectl] + KubePortForwarder.arguments(
                    kubeconfig: "~/.kube/\(cluster.name).kubeconfig", context: cluster.name, namespace: target.namespace,
                    kind: target.kind, name: target.name, remotePort: Int(remotePort) ?? 0, localPort: Int(localPort) ?? 0
                )).joined(separator: " "))
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Start") { start() }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
        }
        .onAppear {
            if remotePort.isEmpty, let first = target.ports.first { remotePort = String(first) }
        }
    }

    private var canStart: Bool {
        guard store.tools.kubectl != nil, !starting, let remote = Int(remotePort), (1...65535).contains(remote) else { return false }
        let local = localPort.trimmingCharacters(in: .whitespaces)
        if local.isEmpty { return true }
        guard let value = Int(local) else { return false }
        return (1...65535).contains(value)
    }

    private func start() {
        guard let remote = Int(remotePort) else { return }
        let local = Int(localPort.trimmingCharacters(in: .whitespaces)) ?? 0
        starting = true
        Task {
            defer { starting = false }
            do {
                try await store.startForward(cluster, client: client, namespace: target.namespace, kind: target.kind, name: target.name, remotePort: remote, localPort: local)
                state.showToast("Forwarding \(target.name). See Port Forwards for the URL.", style: .success)
                dismiss()
            } catch {
                state.showError(error)
            }
        }
    }
}

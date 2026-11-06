import SwiftUI
import AppKit
import DeckCore

/// Overview tab: totals, nodes, the CNI note and how to connect.
struct KubeOverview: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let cluster: KubeCluster
    let client: ContainerClient
    let store: KubernetesStore

    @State private var applying = false

    private var apiNodes: [KubeNodeStatus] { store.nodeStatus[cluster.name] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.repairNeeded.contains(cluster.name) {
                    repairCard
                }
                if store.waitingForCNI(cluster) {
                    cniCard
                }
                if cluster.state == .running, let error = store.apiError[cluster.name] {
                    ErrorNote(message: "Could not reach the cluster's Kubernetes API. It may still be starting.\n\(error)")
                }

                EqualHeightRow(spacing: 12) {
                    MetricTile(title: "Nodes", value: "\(cluster.nodes.count)", subtitle: nodesSubtitle, icon: .machines)
                    MetricTile(title: "CPUs", value: "\(cluster.totalCPUs)", subtitle: "all nodes", icon: .cpu)
                    MetricTile(title: "Memory", value: Format.bytes(cluster.totalMemoryBytes), subtitle: "all nodes", icon: .memory)
                    MetricTile(title: "API port", value: cluster.apiServerHostPort.map(String.init) ?? "-", subtitle: "on 127.0.0.1", icon: .port)
                }

                Card("Nodes", icon: .machines) {
                    nodesGrid
                }

                Card("Connect", icon: .link) {
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueRow("API server", value: cluster.apiServerURL ?? "Not published", monospaced: true, copyable: cluster.apiServerURL != nil)
                        KeyValueRow("Context", value: cluster.name, monospaced: true, copyable: true)
                        KeyValueRow("Kubeconfig", value: KubeconfigPopover.tilde(KubernetesConfig.standaloneKubeconfig(for: cluster.name).path), monospaced: true, copyable: true)
                        KeyValueRow("Tools") {
                            Text(toolsText)
                                .font(.callout)
                                .foregroundStyle(DS.textPrimary)
                        }
                    }
                }

                if showHints {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Use the cluster from Terminal").font(.caption).foregroundStyle(DS.textSecondary)
                        CommandHint(client.commandLine(client.writeKubeconfigArguments(cluster.name, path: "~/.kube/\(cluster.name).kubeconfig")))
                        CommandHint(KubeTools.kubectlHint(kubeconfig: "~/.kube/\(cluster.name).kubeconfig", context: cluster.name))
                    }
                }
            }
            .padding(DS.pad)
        }
        .background(DS.surface)
        .onDeckDebugCommand { name, _ in
            if name == "kube-apply-kindnet" { applyKindnet() }
            if name == "kube-repair" { Task { await store.repair(cluster, client: client, state: state) } }
        }
    }

    private var nodesSubtitle: String {
        let workers = cluster.workers.count
        if workers == 0 { return "control plane only" }
        return workers == 1 ? "1 worker" : "\(workers) workers"
    }

    private var toolsText: String {
        var found: [String] = []
        if store.tools.kubectl != nil { found.append("kubectl") }
        if store.tools.k9s != nil { found.append("k9s") }
        if store.tools.helm != nil { found.append("helm") }
        if let lens = store.tools.lensName { found.append(lens) }
        return found.isEmpty ? "None found. Install kubectl with Homebrew to use port forwards." : found.joined(separator: ", ")
    }

    // MARK: - Nodes

    private var nodesGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(["Node", "Role", "Status", "IP", "CPUs", "Memory", "Ports"], id: \.self) { title in
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.textSecondary)
                }
            }
            Divider()
            ForEach(cluster.nodes) { node in
                GridRow {
                    Text(node.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(roleText(node))
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                    nodeStatus(node)
                    Text(node.ipAddress ?? "-")
                        .font(.callout.monospaced())
                        .foregroundStyle(DS.textSecondary)
                        .textSelection(.enabled)
                    Text(node.cpus.map(String.init) ?? "-")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(DS.textSecondary)
                    Text(Format.bytes(node.memoryBytes))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(DS.textSecondary)
                    Text(node.portsText.isEmpty ? "-" : node.portsText)
                        .font(.callout.monospaced())
                        .foregroundStyle(DS.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roleText(_ node: KubeClusterNode) -> String {
        node.role == .controlPlaneWorker ? "Control plane, worker" : node.role.title
    }

    @ViewBuilder
    private func nodeStatus(_ node: KubeClusterNode) -> some View {
        if node.state != .running {
            StatusPill(node.state)
        } else if let status = apiNodes.first(where: { $0.name == node.name }) {
            if status.ready == true {
                Pill("Ready", tint: DS.running)
            } else {
                Pill(status.statusText, tint: DS.warning)
                    .help(status.message ?? status.statusText)
            }
        } else {
            Pill("Starting", tint: DS.stopped)
        }
    }

    // MARK: - Repair

    private var repairCard: some View {
        Card("New node address", icon: .warning) {
            VStack(alignment: .leading, spacing: 10) {
                Text("The cluster was started outside the app and its node got a new IP address. kube-proxy still uses the old one, so Services, DNS and a network plugin do not work until it is updated.")
                    .font(.callout)
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        Task { await store.repair(cluster, client: client, state: state) }
                    } label: {
                        DeckLabel("Repair Network", icon: .wand)
                    }
                    .deckPrimary()
                    .disabled(store.repairing.contains(cluster.name))
                    if store.repairing.contains(cluster.name) {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - CNI

    private var kindnet: String? { KubeTools.bundledKindnetManifest(cliPath: client.cliPath) }

    private var cniCard: some View {
        Card("Waiting for CNI", icon: .waiting) {
            VStack(alignment: .leading, spacing: 10) {
                Text("The nodes have no network plugin, so pods other than the control plane cannot start. Apply a CNI manifest, such as kindnet that comes with the cluster plugin.")
                    .font(.callout)
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if store.tools.kubectl != nil, kindnet != nil {
                        Button {
                            applyKindnet()
                        } label: {
                            DeckLabel("Apply kindnet", icon: .play)
                        }
                        .deckPrimary()
                        .disabled(applying)
                        if applying {
                            ProgressView().controlSize(.small)
                        }
                    } else if store.tools.kubectl == nil {
                        Text("Install kubectl to apply one from here.")
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                    Spacer()
                }
                if showHints, let kindnet {
                    CommandHint("kubectl --kubeconfig ~/.kube/\(cluster.name).kubeconfig apply -f \(kindnet)")
                }
            }
        }
    }

    private func applyKindnet() {
        guard let kubectl = store.tools.kubectl, let kindnet else { return }
        applying = true
        Task {
            defer { applying = false }
            do {
                let connection = try await store.connection(cluster, client: client)
                // After a restart kube-proxy may still use the node's old address. kindnet
                // reads nodes through it and would wait forever, so fix that first.
                if (try? await client.repairClusterAfterStart(cluster, apiWait: 10)) != nil {
                    store.repairNeeded.remove(cluster.name)
                }
                try await KubeTools.apply(kubectl: kubectl, kubeconfig: connection.kubeconfig, context: connection.context, manifest: kindnet)
                state.showToast("kindnet applied. Nodes turn Ready in a few seconds.", style: .success)
                try? await Task.sleep(for: .seconds(3))
                await store.refreshStatus(cluster, client: client)
            } catch {
                state.showError(error)
            }
        }
    }
}

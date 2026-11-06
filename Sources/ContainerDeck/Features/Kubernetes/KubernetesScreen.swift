import SwiftUI
import DeckCore

/// Local Kubernetes clusters made with Apple's `container cluster` plugin.
struct KubernetesScreen: View {
    @Environment(AppState.self) private var state
    @State private var store = KubernetesStore.shared
    @State private var selection: String?
    @State private var showCreate = false
    @State private var listWidth: Double = 270

    var body: some View {
        Group {
            if let client = state.client {
                content(client)
            } else {
                EmptyState(
                    icon: .kubernetes,
                    title: "Kubernetes",
                    message: "Set up Apple's container tool first.",
                    actionTitle: "Open Setup"
                ) {
                    state.showSetup = true
                }
            }
        }
        .navigationTitle("Kubernetes")
        .toolbar {
            ToolbarItemGroup {
                RefreshButton { await reload(full: true) }
                Button {
                    showCreate = true
                } label: {
                    DeckLabel("New Cluster", icon: .add)
                }
                .help("New Cluster")
                .disabled(state.client == nil || store.supported == false)
            }
        }
        .sheet(isPresented: $showCreate) {
            KubeClusterCreateSheet(existing: Set(store.clusters.map(\.name))) { name in
                selection = name
            }
            .environment(state)
        }
        .task(id: state.resourcesVersion) {
            await reload()
        }
        .autoRefresh(every: 4) {
            await reload()
        }
        .onDeckDebugCommand { name, value in
            switch name {
            case "kube-new": showCreate = true
            case "kube-select": selection = value
            case "kube-create":
                // name[,none]: a small one node cluster, for automation runs.
                let parts = value.split(separator: ",").map(String.init)
                if let client = state.client, let name = parts.first {
                    let options = KubeClusterOptions(name: name, cni: parts.contains("none") ? .none : .kindnet, cpus: 2, memory: "3G")
                    store.create(options, client: client, state: state)
                    selection = name
                }
            default: break
            }
        }
    }

    @ViewBuilder
    private func content(_ client: ContainerClient) -> some View {
        let jobs = store.pendingJobs
        if store.clusters.isEmpty && jobs.isEmpty {
            if store.supported == false {
                EmptyState(
                    icon: .kubernetes,
                    title: "Kubernetes needs a newer container tool",
                    message: "This version of Apple's container tool has no cluster command. Update it to make local Kubernetes clusters.",
                    actionTitle: "Check Again"
                ) {
                    Task { await store.recheckSupport(client) }
                }
            } else if !store.loaded {
                LoadingView("Loading clusters", style: .logo)
            } else if let error = store.loadError {
                EmptyState(icon: .warning, title: "Could not load clusters", message: error, actionTitle: "Try Again") {
                    Task { await reload(full: true) }
                }
            } else {
                EmptyState(
                    icon: .kubernetes,
                    title: "No clusters yet",
                    message: "Make a local Kubernetes cluster that runs in light VMs on this Mac. The first one takes about a minute.",
                    actionTitle: "New Cluster"
                ) {
                    showCreate = true
                }
            }
        } else {
            // A row with a drag handle, not HSplitView: AppKit split views ignore the top
            // safe area, so their panes and divider ran up into the toolbar.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(store.clusters) { cluster in
                            KubeClusterRow(cluster: cluster, store: store)
                                .tag(cluster.name)
                        }
                        ForEach(jobs.filter { job in !store.clusters.contains(where: { $0.name == job.id }) }) { job in
                            KubeJobRow(job: job)
                                .tag(job.id)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    ListStatusBar(statusText)
                }
                .frame(width: CGFloat(listWidth))
                .background(DS.surface, ignoresSafeAreaEdges: [])
                KubeListHandle(width: $listWidth)

                Group {
                    if let name = selection, let job = store.jobs[name], !job.finished || job.failed != nil {
                        KubeJobView(job: job, store: store)
                    } else if let name = selection, let cluster = store.clusters.first(where: { $0.name == name }) {
                        KubeClusterDetailView(cluster: cluster, client: client, store: store)
                            .id(name)
                    } else if let name = selection, let job = store.jobs[name] {
                        KubeJobView(job: job, store: store)
                    } else {
                        EmptyState(icon: .kubernetes, title: "Pick a cluster", message: "Select a cluster on the left to see its nodes and workloads.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.surface, ignoresSafeAreaEdges: [])
            }
        }
    }

    private var statusText: String {
        let count = store.clusters.count == 1 ? "1 cluster" : "\(store.clusters.count) clusters"
        let running = store.clusters.filter { $0.state == .running }.count
        let nodes = store.clusters.reduce(0) { $0 + $1.nodes.count }
        return "\(count), \(running) running, \(nodes) \(nodes == 1 ? "node" : "nodes")"
    }

    private func reload(full: Bool = false) async {
        guard let client = state.client else { return }
        if full { store.tools = KubeTools.detect() }
        await store.reload(client)
        if let current = selection,
           store.clusters.contains(where: { $0.name == current }) || store.jobs[current] != nil {
            // Keep the selection.
        } else {
            selection = store.clusters.first(where: { $0.state == .running })?.name ?? store.clusters.first?.name ?? store.pendingJobs.first?.id
        }
        // Readiness for every running cluster, so the list can show "Waiting for CNI".
        for cluster in store.clusters where cluster.state == .running {
            await store.refreshStatus(cluster, client: client)
        }
    }
}

// MARK: - Rows

struct KubeClusterRow: View {
    let cluster: KubeCluster
    let store: KubernetesStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(.kubernetes, tint: cluster.state == .running ? DS.accent : DS.stopped, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(cluster.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    KubeClusterStatePill(cluster: cluster, store: store)
                }
                HStack(spacing: 10) {
                    MachineFact(icon: .kubernetes, text: store.version(cluster) ?? "Kubernetes")
                    MachineFact(icon: .machines, text: cluster.nodes.count == 1 ? "1 node" : "\(cluster.nodes.count) nodes")
                    if let port = cluster.apiServerHostPort {
                        MachineFact(icon: .port, text: String(port))
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }
}

/// Running, Stopped, or Waiting for CNI.
struct KubeClusterStatePill: View {
    let cluster: KubeCluster
    let store: KubernetesStore

    var body: some View {
        if store.isCreating(cluster.name) {
            Pill("Creating")
        } else if store.waitingForCNI(cluster) {
            Pill("Waiting for CNI", tint: DS.warning)
                .help("The nodes have no network plugin yet, so pods cannot start. Apply a CNI manifest, or recreate the cluster with kindnet.")
        } else if cluster.state == .partial {
            Pill("Partly running", tint: DS.warning)
        } else {
            StatusPill(cluster.state.runState)
        }
    }
}

struct KubeJobRow: View {
    let job: KubeCreateJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(.kubernetes, tint: job.failed == nil ? DS.accent : DS.danger, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.options.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if job.failed != nil {
                        Pill("Failed", tint: DS.danger)
                    } else {
                        Pill("Creating")
                    }
                }
                Text(job.failed == nil ? job.step : "Could not create the cluster")
                    .font(.caption)
                    .deckSecondaryText()
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }
}

/// Right pane while a cluster is being made.
struct KubeJobView: View {
    let job: KubeCreateJob
    let store: KubernetesStore

    var body: some View {
        DeckPage {
            HStack(spacing: 12) {
                IconBadge(.kubernetes, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.options.name).font(.title3.weight(.semibold))
                    Text(job.failed == nil ? "Creating the cluster. This takes about a minute, longer the first time while the node image downloads." : "The cluster could not be created.")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer()
                if job.failed != nil {
                    Button("Dismiss") { store.dismissJob(job.id) }
                }
            }
            if let failed = job.failed {
                ErrorNote(message: failed)
            } else {
                Card("Progress", icon: .waiting) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let progress = job.progress {
                            ProgressView(value: progress)
                                .tint(DS.accent)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(DS.accent)
                        }
                        Text(job.step)
                            .font(.callout.weight(.medium))
                    }
                }
            }
            Card("Output", icon: .logs) {
                ScrollView {
                    Text(job.lines.isEmpty ? "Waiting for output" : job.lines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(job.lines.isEmpty ? DS.textTertiary : DS.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 320)
            }
            ResourceCommandHint(KubeCommands.createArguments(job.options))
        }
    }
}

/// Argument builders without a client (for hints).
enum KubeCommands {
    static func createArguments(_ options: KubeClusterOptions) -> [String] {
        ContainerClient(cliPath: "container").createClusterArguments(options)
    }
}

/// Thin divider you can drag to resize the cluster list.
struct KubeListHandle: View {
    @Binding var width: Double
    static let range: ClosedRange<Double> = 240...320
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(DS.border)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: .trailing))
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                width = min(max(start + value.translation.width, Self.range.lowerBound), Self.range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

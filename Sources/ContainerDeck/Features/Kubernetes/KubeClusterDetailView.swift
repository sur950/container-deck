import SwiftUI
import AppKit
import DeckCore

/// Right side of the Kubernetes screen: actions, nodes, workloads and port forwards.
struct KubeClusterDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case workloads = "Workloads"
        case forwards = "Port Forwards"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.kubeDetailTab) private var tabRaw = Tab.overview.rawValue

    let cluster: KubeCluster
    let client: ContainerClient
    let store: KubernetesStore

    @State private var busy: String?
    @State private var confirmDelete = false
    @State private var confirmRecreate = false
    @State private var showLoadImage = false
    @State private var showKubeconfig = false

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .overview }
    private var running: Bool { cluster.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(DS.pad)
            Picker("View", selection: $tabRaw) {
                ForEach(Tab.allCases) { item in
                    Text(tabTitle(item)).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.pad)
            .padding(.bottom, 10)
            Divider()
            switch tab {
            case .overview:
                KubeOverview(cluster: cluster, client: client, store: store)
            case .workloads:
                if running {
                    KubeWorkloadsView(cluster: cluster, client: client, store: store)
                } else {
                    notRunning
                }
            case .forwards:
                KubeForwardsView(cluster: cluster, client: client, store: store)
            }
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .sheet(isPresented: $showLoadImage) {
            KubeLoadImageSheet(cluster: cluster)
                .environment(state)
        }
        .onDeckDebugCommand { name, value in
            switch name {
            case "kube-tab":
                if let item = Tab.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(value.lowercased()) }) { tabRaw = item.rawValue }
            case "kube-load": showLoadImage = true
            case "kube-kubeconfig": showKubeconfig = true
            case "kube-recreate":
                Task { await perform("Recreating") { try await store.recreate(cluster, client: client, state: state) } }
            case "kube-start":
                Task { await perform("Starting") { try await store.start(cluster, client: client, state: state) } }
            case "kube-stop":
                Task { await perform("Stopping") { try await client.stopCluster(cluster) } }
            case "kube-delete":
                Task { await perform("Deleting") { try await store.delete(cluster, client: client) } }
            default: break
            }
        }
        .confirmationDialog("Delete \(cluster.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Cluster", role: .destructive) {
                Task { await perform("Deleting") { try await store.delete(cluster, client: client) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops and removes all \(cluster.nodes.count) \(cluster.nodes.count == 1 ? "node" : "nodes") and everything that runs in the cluster. It is also removed from ~/.kube/config.")
        }
        .confirmationDialog("Recreate \(cluster.name)?", isPresented: $confirmRecreate, titleVisibility: .visible) {
            Button("Recreate Cluster", role: .destructive) {
                Task { await perform("Recreating") { try await store.recreate(cluster, client: client, state: state) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cluster is deleted and made again with the same name, version, workers, CPUs and memory. Workloads in it are lost.")
        }
    }

    private func tabTitle(_ item: Tab) -> String {
        if item == .forwards {
            let active = store.forwards(for: cluster.name).filter(\.isActive).count
            return active > 0 ? "\(item.rawValue) (\(active))" : item.rawValue
        }
        return item.rawValue
    }

    private var notRunning: some View {
        EmptyState(
            icon: .kubernetes,
            title: "The cluster is stopped",
            message: "Start the cluster to see its namespaces, pods, deployments, services and events.",
            actionTitle: "Start Cluster"
        ) {
            Task { await perform("Starting") { try await store.start(cluster, client: client, state: state) } }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(.kubernetes, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(cluster.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        KubeClusterStatePill(cluster: cluster, store: store)
                        if let version = store.version(cluster) {
                            Pill(version, tint: DS.stopped)
                        }
                    }
                    Text(cluster.apiServerURL ?? "No API port")
                        .font(.caption.monospaced())
                        .foregroundStyle(DS.textSecondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(DS.textSecondary)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    if running || cluster.state == .partial {
                        Button {
                            Task { await perform("Stopping") { try await client.stopCluster(cluster) } }
                        } label: {
                            DeckLabel("Stop", icon: .stop)
                        }
                    }
                    if !running {
                        Button {
                            Task { await perform("Starting") { try await store.start(cluster, client: client, state: state) } }
                        } label: {
                            DeckLabel("Start", icon: .play)
                        }
                        .deckPrimary()
                    }
                    Button {
                        showKubeconfig.toggle()
                    } label: {
                        DeckLabel("Kubeconfig", icon: .file)
                    }
                    .disabled(!running)
                    .help("Write the kubeconfig and copy its path")
                    .popover(isPresented: $showKubeconfig, arrowEdge: .bottom) {
                        KubeconfigPopover(cluster: cluster, client: client, store: store)
                            .environment(state)
                    }
                    KubeOpenInButtons(cluster: cluster, client: client, store: store)
                        .disabled(!running)
                    if cluster.sharedImageStore == true {
                        // container 1.7 --shared-image-store: nodes read this Mac's images, nothing to load.
                        Pill("Uses local images", tint: DS.running)
                            .help("The nodes read images from this Mac's image store. Pods can use local images directly, with imagePullPolicy set to Never or IfNotPresent.")
                    } else {
                        Button {
                            showLoadImage = true
                        } label: {
                            DeckLabel("Load Image", icon: .upload)
                        }
                        .disabled(!running)
                        .help("Copy a local image into the nodes, no registry needed")
                    }
                }
                .fixedSize()
                Spacer(minLength: 8)
                // Full labels when they fit, else icons so no button is cut.
                ViewThatFits(in: .horizontal) {
                    dangerButtons(iconOnly: false)
                    dangerButtons(iconOnly: true)
                }
                .layoutPriority(1)
            }
            .disabled(busy != nil)
        }
    }

    private func dangerButtons(iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                confirmRecreate = true
            } label: {
                DeckLabel("Recreate", icon: .restart)
                    .labelStyle(DangerLabelStyle(iconOnly: iconOnly))
            }
            .help("Delete and make the cluster again with the same settings")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                DeckLabel("Delete", icon: .trash)
                    .labelStyle(DangerLabelStyle(iconOnly: iconOnly))
            }
            .help("Delete the cluster")
        }
        .fixedSize()
    }

    private struct DangerLabelStyle: LabelStyle {
        let iconOnly: Bool
        func makeBody(configuration: Configuration) -> some View {
            if iconOnly {
                configuration.icon
            } else {
                Label(configuration)
            }
        }
    }

    private func perform(_ label: String, _ action: @escaping () async throws -> Void) async {
        busy = label
        defer { busy = nil }
        do {
            try await action()
            store.forgetConnection(cluster.name)
            state.resourcesChanged()
        } catch {
            state.showError(error)
        }
        await store.reload(client)
    }
}

// MARK: - Open in kubectl, k9s, Lens

struct KubeOpenInButtons: View {
    @Environment(AppState.self) private var state
    let cluster: KubeCluster
    let client: ContainerClient
    let store: KubernetesStore

    var body: some View {
        if store.tools.kubectl != nil {
            Button {
                open { connection in
                    guard let kubectl = store.tools.kubectl else { return }
                    try TerminalLauncher.open(command: KubeTools.kubectlShellCommand(kubectl: kubectl, kubeconfig: connection.kubeconfig, context: connection.context))
                }
            } label: {
                DeckLabel("kubectl", icon: .terminal)
            }
            .help("Open a terminal with kubectl set up for this cluster")
        }
        if store.tools.k9s != nil {
            Button {
                open { connection in
                    guard let k9s = store.tools.k9s else { return }
                    try TerminalLauncher.open(command: KubeTools.k9sCommand(k9s: k9s, kubeconfig: connection.kubeconfig, context: connection.context))
                }
            } label: {
                DeckLabel("k9s", icon: .terminal)
            }
            .help("Open k9s for this cluster")
        }
        if let lens = store.tools.lensApp, let lensName = store.tools.lensName {
            Button {
                Task {
                    do {
                        // Lens reads ~/.kube/config.
                        try await client.writeKubeconfig(cluster.name)
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = true
                        try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: lens), configuration: config)
                        state.showToast("Added \(cluster.name) to ~/.kube/config for \(lensName).", style: .success)
                    } catch {
                        state.showError(error)
                    }
                }
            } label: {
                DeckLabel(lensName, icon: .openExternal)
            }
            .help("Add the cluster to ~/.kube/config and open \(lensName)")
        }
    }

    private func open(_ action: @escaping (KubeConnection) throws -> Void) {
        Task {
            do {
                let connection = try await store.connection(cluster, client: client)
                try action(connection)
            } catch {
                state.showError(error)
            }
        }
    }
}

// MARK: - Kubeconfig

struct KubeconfigPopover: View {
    @Environment(AppState.self) private var state
    let cluster: KubeCluster
    let client: ContainerClient
    let store: KubernetesStore
    @State private var busy = false
    @State private var written: String?

    private var standalone: URL { KubernetesConfig.standaloneKubeconfig(for: cluster.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kubeconfig").font(.headline)
            Text("kubectl, k9s, Lens and other tools find the cluster through a kubeconfig file. The context is named \(cluster.name).")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            option(
                title: "Add to ~/.kube/config",
                detail: "Merged with your other clusters and set as the current context.",
                path: KubernetesConfig.defaultKubeconfig
            ) {
                try await client.writeKubeconfig(cluster.name)
                // The plugin sets the current context only when it creates the cluster.
                try KubeConfigFile.setCurrentContext(cluster.name, in: KubernetesConfig.defaultKubeconfig)
            }
            option(
                title: "Own file",
                detail: "Only this cluster. Use it with KUBECONFIG=<path>.",
                path: standalone
            ) {
                try await client.writeKubeconfig(cluster.name, to: standalone)
            }

            if let written {
                HStack(spacing: 6) {
                    DeckIcon(.success, size: 12, color: DS.running)
                    Text("Written and path copied: \(written)")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            ResourceCommandHint(client.writeKubeconfigArguments(cluster.name, path: "~/.kube/\(cluster.name).kubeconfig"))
        }
        .padding(16)
        .frame(width: 420)
        .disabled(busy)
    }

    private func option(title: String, detail: String, path: URL, action: @escaping () async throws -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(DS.textSecondary)
                Text(Self.tilde(path.path)).font(.caption.monospaced()).foregroundStyle(DS.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Write") {
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        try await action()
                        copy(path.path)
                        written = Self.tilde(path.path)
                    } catch {
                        state.showError(error)
                    }
                }
            }
            .buttonStyle(SoftAccentButtonStyle())
        }
        .padding(10)
        .background(DS.surfaceSunken.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

import SwiftUI
import AppKit
import DeckCore

/// What a port forward should target.
struct KubeForwardTarget: Identifiable, Hashable {
    var id: String { "\(namespace)/\(kind)/\(name)" }
    var namespace: String
    /// "service" or "pod".
    var kind: String
    var name: String
    var ports: [Int]
}

/// Workloads tab: namespaces, pods, deployments, services and events read from the
/// Kubernetes API, pod logs, restart and delete.
struct KubeWorkloadsView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case pods = "Pods"
        case deployments = "Deployments"
        case services = "Services"
        case events = "Events"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.kubeNamespace) private var namespace = ""

    let cluster: KubeCluster
    let client: ContainerClient
    let store: KubernetesStore

    @State private var kind: Kind = .pods
    @State private var namespaces: [KubeNamespace] = []
    @State private var pods: [KubePod] = []
    @State private var deployments: [KubeDeployment] = []
    @State private var services: [KubeService] = []
    @State private var events: [KubeEvent] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var podSelection: KubePod.ID?
    @State private var deploymentSelection: KubeDeployment.ID?
    @State private var serviceSelection: KubeService.ID?
    @State private var eventSelection: KubeEvent.ID?
    @State private var logPod: KubePod?
    @State private var forwardTarget: KubeForwardTarget?
    @State private var podToDelete: KubePod?
    @State private var ticket = 0

    private var allNamespaces: Bool { namespace.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, DS.pad)
                .padding(.vertical, 10)
            Divider()
            if let logPod {
                VSplitView {
                    listArea
                        .frame(minHeight: 160)
                    KubePodLogsView(pod: logPod, cluster: cluster, client: client, store: store) {
                        self.logPod = nil
                    }
                    .id(logPod.id)
                    .frame(minHeight: 180, idealHeight: 280)
                }
            } else {
                listArea
            }
        }
        .task(id: "\(cluster.name)|\(namespace)") {
            await load()
        }
        .autoRefresh(every: 5) {
            await load()
        }
        .sheet(item: $forwardTarget) { target in
            KubeForwardSheet(cluster: cluster, client: client, store: store, target: target)
                .environment(state)
        }
        .confirmDelete($podToDelete, title: { "Delete pod \($0.name)?" }, message: "A pod made by a deployment or replica set comes back as a new pod. A standalone pod is gone for good.", actionTitle: "Delete Pod") { pod in
            Task { await deletePod(pod) }
        }
        .onDeckDebugCommand { name, value in
            switch name {
            case "kube-kind":
                if let item = Kind.allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) { kind = item }
            case "kube-ns":
                namespace = value == "all" ? "" : value
            case "kube-logs":
                logPod = pods.first(where: { $0.name.hasPrefix(value) })
            case "kube-select-pod":
                podSelection = pods.first(where: { $0.name.hasPrefix(value) })?.id
            case "kube-forward-sheet":
                if let item = services.first(where: { $0.name == value }) { forward(item) }
            case "kube-forward":
                // Starts a forward to the service's first port without the sheet.
                if let item = services.first(where: { $0.name == value }), let port = item.ports.first?.port {
                    Task {
                        do {
                            try await store.startForward(cluster, client: client, namespace: item.namespace, kind: "service", name: item.name, remotePort: port, localPort: 0)
                        } catch {
                            state.showError(error)
                        }
                    }
                }
            default: break
            }
        }
    }

    // MARK: - Filter bar

    /// One row when it fits, else the actions move up next to the namespace.
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                namespacePicker
                kindFilter
                Spacer(minLength: 0)
                actionGroup
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    namespacePicker
                    Spacer(minLength: 0)
                    actionGroup
                }
                kindFilter
            }
        }
    }

    private var namespacePicker: some View {
        Picker("Namespace", selection: $namespace) {
            Text("All namespaces").tag("")
            if !namespaces.isEmpty { Divider() }
            ForEach(namespaces) { item in
                Text(item.name).tag(item.name)
            }
            if !namespace.isEmpty && !namespaces.contains(where: { $0.name == namespace }) {
                Text(namespace).tag(namespace)
            }
        }
        .labelsHidden()
        .frame(width: 170)
        .popUpAppearanceRefresh()
    }

    private var kindFilter: some View {
        SegmentedFilter(selection: $kind, options: Kind.allCases, label: { $0.rawValue }, count: { count(for: $0) })
            .fixedSize()
    }

    /// Always as wide as the widest set (four pod actions), so the bar keeps one layout
    /// when you switch between pods, deployments, services and events.
    private var actionGroup: some View {
        HStack(spacing: 0) {
            actionButtons
        }
        .fixedSize()
        .frame(width: 96, alignment: .trailing)
    }

    private var selectedPod: KubePod? { podSelection.flatMap { id in pods.first(where: { $0.id == id }) } }
    private var selectedDeployment: KubeDeployment? { deploymentSelection.flatMap { id in deployments.first(where: { $0.id == id }) } }
    private var selectedService: KubeService? { serviceSelection.flatMap { id in services.first(where: { $0.id == id }) } }

    /// Actions for the selected row.
    @ViewBuilder
    private var actionButtons: some View {
        switch kind {
        case .pods:
            let pod = selectedPod
            KubeRowButton(icon: .logs, help: "Logs") { logPod = pod }
                .disabled(pod == nil)
            KubeRowButton(icon: .port, help: "Port forward") { if let pod { forward(pod) } }
                .disabled(pod == nil)
            KubeRowButton(icon: .restart, help: "Restart: delete the pod so its owner makes a new one") {
                if let pod { Task { await deletePod(pod, restart: true) } }
            }
            .disabled(pod?.ownerKind == nil)
            KubeRowButton(icon: .trash, help: "Delete pod") { podToDelete = pod }
                .disabled(pod == nil)
        case .deployments:
            KubeRowButton(icon: .restart, help: "Restart all pods (rollout restart)") {
                if let item = selectedDeployment { Task { await restart(item) } }
            }
            .disabled(selectedDeployment == nil)
        case .services:
            KubeRowButton(icon: .port, help: "Port forward to this Mac") {
                if let item = selectedService { forward(item) }
            }
            .disabled(selectedService?.ports.isEmpty ?? true)
        case .events:
            EmptyView()
        }
    }

    private func count(for kind: Kind) -> Int? {
        guard loaded else { return nil }
        switch kind {
        case .pods: return pods.count
        case .deployments: return deployments.count
        case .services: return services.count
        case .events: return events.count
        }
    }

    // MARK: - Lists

    @ViewBuilder
    private var listArea: some View {
        VStack(spacing: 0) {
            if !loaded {
                LoadingView("Loading workloads")
            } else if let loadError, pods.isEmpty && deployments.isEmpty && services.isEmpty {
                EmptyState(icon: .warning, title: "Could not read the cluster", message: loadError, actionTitle: "Try Again") {
                    store.forgetConnection(cluster.name)
                    Task { await load() }
                }
            } else {
                switch kind {
                case .pods: podsTable
                case .deployments: deploymentsTable
                case .services: servicesTable
                case .events: eventsTable
                }
            }
            ListStatusBar(statusText) {
                if let loadError, loaded, !(pods.isEmpty && deployments.isEmpty && services.isEmpty) {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(DS.danger)
                        .lineLimit(1)
                }
            }
        }
    }

    private var statusText: String {
        let scope = allNamespaces ? "all namespaces" : namespace
        switch kind {
        case .pods:
            let running = pods.filter { $0.status == "Running" }.count
            return "\(pods.count) \(pods.count == 1 ? "pod" : "pods"), \(running) running, \(scope)"
        case .deployments:
            return "\(deployments.count) \(deployments.count == 1 ? "deployment" : "deployments"), \(scope)"
        case .services:
            return "\(services.count) \(services.count == 1 ? "service" : "services"), \(scope)"
        case .events:
            let warnings = events.filter(\.isWarning).count
            return "\(events.count) events, \(warnings) \(warnings == 1 ? "warning" : "warnings"), \(scope)"
        }
    }

    private var podsTable: some View {
        Table(pods, selection: $podSelection) {
            TableColumn("Name") { pod in
                HStack(spacing: 7) {
                    KubeHealthDot(health: pod.health)
                    Text(pod.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
                .help(pod.message ?? pod.name)
            }
            .width(min: 170, ideal: 170)
            TableColumn("Namespace") { pod in
                Text(pod.namespace).deckSecondaryText().lineLimit(1)
            }
            .width(min: 90, ideal: 90)
            TableColumn("Status") { pod in
                Text(pod.status)
                    .foregroundStyle(KubeHealthDot.color(pod.health))
                    .lineLimit(1)
                    .help(pod.status)
            }
            .width(min: 120, ideal: 120)
            TableColumn("Ready") { pod in
                Text(pod.readyText).monospacedDigit().deckSecondaryText()
            }
            .width(min: 44, ideal: 44)
            TableColumn("Restarts") { pod in
                Text("\(pod.restarts)").monospacedDigit().deckSecondaryText()
            }
            .width(min: 56, ideal: 56)
            TableColumn("Age") { pod in
                Text(KubeAge.text(pod.createdAt)).monospacedDigit().deckSecondaryText()
            }
            .width(min: 44, ideal: 44)
        }
        .contextMenu(forSelectionType: KubePod.ID.self) { ids in
            if let id = ids.first, let pod = pods.first(where: { $0.id == id }) {
                Button("Logs") { logPod = pod }
                Button("Port Forward") { forward(pod) }
                if pod.ownerKind != nil {
                    Button("Restart") { Task { await deletePod(pod, restart: true) } }
                }
                Divider()
                Button("Delete Pod", role: .destructive) { podToDelete = pod }
                Button("Copy Name") { copy(pod.name) }
            }
        } primaryAction: { ids in
            if let id = ids.first { logPod = pods.first(where: { $0.id == id }) }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if pods.isEmpty {
                EmptyState(icon: .containers, title: "No pods", message: allNamespaces ? "Nothing runs in this cluster yet. Try kubectl create deployment web --image=nginx." : "No pods in \(namespace).")
            }
        }
    }

    private var deploymentsTable: some View {
        Table(deployments, selection: $deploymentSelection) {
            TableColumn("Name") { item in
                HStack(spacing: 7) {
                    KubeHealthDot(health: item.health)
                    Text(item.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 150, ideal: 150)
            TableColumn("Namespace") { item in
                Text(item.namespace).deckSecondaryText().lineLimit(1)
            }
            .width(min: 90, ideal: 90)
            TableColumn("Ready") { item in
                Text(item.readyText).monospacedDigit().deckSecondaryText()
            }
            .width(min: 50, ideal: 50)
            TableColumn("Up to date") { item in
                Text("\(item.updated)").monospacedDigit().deckSecondaryText()
            }
            .width(min: 64, ideal: 64)
            TableColumn("Available") { item in
                Text("\(item.available)").monospacedDigit().deckSecondaryText()
            }
            .width(min: 60, ideal: 60)
            TableColumn("Images") { item in
                Text(item.images.joined(separator: ", ")).deckSecondaryText().lineLimit(1).truncationMode(.middle)
                    .help(item.images.joined(separator: "\n"))
            }
            .width(min: 100, ideal: 100)
            TableColumn("Age") { item in
                Text(KubeAge.text(item.createdAt)).monospacedDigit().deckSecondaryText()
            }
            .width(min: 44, ideal: 44)
        }
        .contextMenu(forSelectionType: KubeDeployment.ID.self) { ids in
            if let id = ids.first, let item = deployments.first(where: { $0.id == id }) {
                Button("Restart") { Task { await restart(item) } }
                Button("Show Pods") {
                    namespace = item.namespace
                    kind = .pods
                }
                Button("Copy Name") { copy(item.name) }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if deployments.isEmpty {
                EmptyState(icon: .layers, title: "No deployments", message: allNamespaces ? "No deployments in this cluster yet." : "No deployments in \(namespace).")
            }
        }
    }

    private var servicesTable: some View {
        Table(services, selection: $serviceSelection) {
            TableColumn("Name") { item in
                Text(item.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 160, ideal: 160)
            TableColumn("Namespace") { item in
                Text(item.namespace).deckSecondaryText().lineLimit(1)
            }
            .width(min: 90, ideal: 90)
            TableColumn("Type") { item in
                Text(item.type).deckSecondaryText()
            }
            .width(min: 70, ideal: 70)
            TableColumn("Cluster IP") { item in
                Text(item.clusterIP ?? "-").font(.callout.monospaced()).deckSecondaryText()
            }
            .width(min: 90, ideal: 90)
            TableColumn("Ports") { item in
                Text(item.portsText).font(.callout.monospaced()).deckSecondaryText().lineLimit(1)
                    .help(item.portsText)
            }
            .width(min: 110, ideal: 110)
            TableColumn("Age") { item in
                Text(KubeAge.text(item.createdAt)).monospacedDigit().deckSecondaryText()
            }
            .width(min: 44, ideal: 44)
        }
        .contextMenu(forSelectionType: KubeService.ID.self) { ids in
            if let id = ids.first, let item = services.first(where: { $0.id == id }) {
                Button("Port Forward") { forward(item) }
                    .disabled(item.ports.isEmpty)
                Button("Copy Name") { copy(item.name) }
                Button("Copy DNS Name") { copy("\(item.name).\(item.namespace).svc.cluster.local") }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if services.isEmpty {
                EmptyState(icon: .network, title: "No services", message: "No services in \(allNamespaces ? "this cluster" : namespace).")
            }
        }
    }

    private var eventsTable: some View {
        Table(events, selection: $eventSelection) {
            TableColumn("Type") { item in
                Pill(item.type, tint: item.isWarning ? DS.warning : DS.stopped)
            }
            .width(min: 70, ideal: 70)
            TableColumn("Reason") { item in
                Text(item.reason).fontWeight(.medium).lineLimit(1)
            }
            .width(min: 100, ideal: 100)
            TableColumn("Object") { item in
                Text(item.object).deckSecondaryText().lineLimit(1).truncationMode(.middle)
            }
            .width(min: 130, ideal: 130)
            TableColumn("Message") { item in
                Text(item.message).deckSecondaryText().lineLimit(1).help(item.message)
            }
            .width(min: 150, ideal: 150)
            TableColumn("Count") { item in
                Text("\(item.count)").monospacedDigit().deckSecondaryText()
            }
            .width(min: 44, ideal: 44)
            TableColumn("Last seen") { item in
                Text(KubeAge.text(item.lastSeen)).monospacedDigit().deckSecondaryText()
            }
            .width(min: 64, ideal: 64)
        }
        .contextMenu(forSelectionType: KubeEvent.ID.self) { ids in
            if let id = ids.first, let item = events.first(where: { $0.id == id }) {
                Button("Copy Message") { copy(item.message) }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if events.isEmpty {
                EmptyState(icon: .bell, title: "No events", message: "Kubernetes keeps events for about an hour.")
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        ticket += 1
        let current = ticket
        let scope = allNamespaces ? nil : namespace
        do {
            let connection = try await store.connection(cluster, client: client)
            let api = connection.api
            async let ns = api.namespaces()
            async let podList = api.pods(namespace: scope)
            async let deploymentList = api.deployments(namespace: scope)
            async let serviceList = api.services(namespace: scope)
            async let eventList = api.events(namespace: scope)
            let result = try await (ns, podList, deploymentList, serviceList, eventList)
            guard current == ticket else { return }
            if result.0 != namespaces { namespaces = result.0 }
            if result.1 != pods { withAnimation(.easeInOut(duration: 0.2)) { pods = result.1 } }
            if result.2 != deployments { deployments = result.2 }
            if result.3 != services { services = result.3 }
            let newEvents = Array(result.4.prefix(500))
            if newEvents != events { events = newEvents }
            if let open = logPod, let fresh = pods.first(where: { $0.id == open.id }), fresh != open {
                logPod = fresh
            }
            loadError = nil
        } catch {
            guard current == ticket else { return }
            loadError = error.localizedDescription
            store.forgetConnection(cluster.name)
        }
        loaded = true
    }

    private func deletePod(_ pod: KubePod, restart: Bool = false) async {
        do {
            let connection = try await store.connection(cluster, client: client)
            try await connection.api.deletePod(namespace: pod.namespace, name: pod.name)
            if logPod?.id == pod.id { logPod = nil }
            state.showToast(restart ? "Restarting \(pod.name)." : "Deleted \(pod.name).", style: .success)
            await load()
        } catch {
            state.showError(error)
        }
    }

    private func restart(_ deployment: KubeDeployment) async {
        do {
            let connection = try await store.connection(cluster, client: client)
            try await connection.api.restartDeployment(namespace: deployment.namespace, name: deployment.name)
            state.showToast("Restarting \(deployment.name).", style: .success)
            await load()
        } catch {
            state.showError(error)
        }
    }

    private func forward(_ pod: KubePod) {
        forwardTarget = KubeForwardTarget(namespace: pod.namespace, kind: "pod", name: pod.name, ports: pod.ports.map(\.port))
    }

    private func forward(_ service: KubeService) {
        forwardTarget = KubeForwardTarget(namespace: service.namespace, kind: "service", name: service.name, ports: service.ports.map(\.port))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Small parts

struct KubeHealthDot: View {
    let health: KubeHealth

    static func color(_ health: KubeHealth) -> Color {
        switch health {
        case .good: return DS.running
        case .waiting: return DS.warning
        case .bad: return DS.danger
        case .done: return DS.stopped
        }
    }

    var body: some View {
        Circle()
            .fill(Self.color(health))
            .frame(width: 7, height: 7)
    }
}

struct KubeRowButton: View {
    let icon: DeckIconName
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DeckIcon(icon, size: 13)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// kubectl style ages: 45s, 12m, 3h, 5d.
enum KubeAge {
    static func text(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 120 { return "\(seconds)s" }
        if seconds < 3600 * 2 { return "\(seconds / 60)m" }
        if seconds < 86400 * 2 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

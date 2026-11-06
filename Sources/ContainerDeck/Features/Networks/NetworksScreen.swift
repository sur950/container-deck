import SwiftUI
import DeckCore

/// Networks: list, create, delete and prune.
struct NetworksScreen: View {
    @Environment(AppState.self) private var state

    @State private var networks: [NetworkSummary] = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\NetworkSummary.name)]
    @State private var selection: NetworkSummary.ID?
    @State private var showCreate = false
    @State private var activeAlert: NetworksAlert?
    @State private var showPrune = false
    @State private var sequencer = PollSequencer()

    var body: some View {
        content
            .navigationTitle("Networks")
            .searchable(text: $search, placement: .toolbar, prompt: "Search networks")
            .toolbar { toolbarContent }
            .task(id: state.resourcesVersion) { await load(force: true) }
            .autoRefresh { await load() }
            .onChange(of: BackgroundServices.shared.containersVersion) { _, _ in
                Task { await refreshUsers() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deckDebugOpenSheet)) { note in
                if note.object as? String == "network-create" { showCreate = true }
            }
            .sheet(isPresented: $showCreate) {
                NetworkCreateSheet()
                    .environment(state)
            }
            .alert(alertTitle, isPresented: alertShown, presenting: activeAlert) { item in
                alertActions(item)
            } message: { item in
                Text(alertMessage(item))
            }
            .confirmationDialog("Remove unused networks?", isPresented: $showPrune, titleVisibility: .visible) {
                Button("Remove Unused Networks", role: .destructive) { prune() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Networks with no containers are removed. The default network stays.")
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.client == nil {
            ResourceToolMissing(icon: .networks)
        } else if !hasLoaded && isLoading {
            LoadingView("Loading networks", style: .logo)
        } else if let loadError, networks.isEmpty {
            EmptyState(icon: .error, title: "Could not load networks", message: loadError, actionTitle: "Try Again") {
                Task { await load() }
            }
        } else if networks.isEmpty {
            EmptyState(
                icon: .networks,
                title: "No networks",
                message: "Start the container service to get the default network, or create your own.",
                actionTitle: "Create Network"
            ) {
                showCreate = true
            }
        } else {
            VStack(spacing: 0) {
                table
                footer
            }
        }
    }

    private var table: some View {
        Table(visibleNetworks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { network in
                HStack(spacing: 8) {
                    DeckIcon(.networks, size: 14, color: DS.accent)
                    Text(network.name).fontWeight(.medium)
                    if network.isProtected {
                        Pill(network.isDefault ? "Default" : "Built in", tint: DS.stopped)
                    }
                }
            }
            .width(min: 140, ideal: 200)

            TableColumn("Subnet", value: \.subnetSortKey) { network in
                Text(network.subnet ?? "Auto")
                    .font(.callout.monospaced())
                    .deckRowText(network.subnet == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Gateway") { network in
                Text(network.gateway ?? "None")
                    .font(.callout.monospaced())
                    .deckRowText(network.gateway == nil ? .secondary : .primary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Access") { network in
                if network.isInternal {
                    Pill("Host only", tint: DS.warning)
                        .help("Containers cannot reach the internet.")
                } else {
                    Pill("Internet", tint: DS.running)
                        .help("Containers can reach the internet.")
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn("Containers", value: \.attachedCount) { network in
                Text(network.attachedContainers.isEmpty ? "None" : network.attachedContainers.joined(separator: ", "))
                    .deckSecondaryText()
                    .lineLimit(1)
                    .help(network.attachedContainers.joined(separator: ", "))
            }
            .width(min: 90, ideal: 180)
        }
        .contextMenu(forSelectionType: NetworkSummary.ID.self) { ids in
            if let id = ids.first, let network = networks.first(where: { $0.id == id }) {
                rowMenu(network)
            }
        }
    }

    private var footer: some View {
        ListStatusBar(statusText) {
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if let network = selectedNetwork {
                Button(role: .destructive) {
                    askDelete(network)
                } label: {
                    DeckLabel("Delete", icon: .trash)
                }
                .controlSize(.small)
                .disabled(network.isProtected)
                .help(network.isProtected ? "Built in networks cannot be deleted." : "Delete this network")
            } else {
                ResourceCommandHint(["network", "list"])
                    .fixedSize()
            }
        }
    }

    private var statusText: String {
        let count = networks.count == 1 ? "1 network" : "\(networks.count) networks"
        let attached = networks.reduce(0) { $0 + $1.attachedContainers.count }
        guard attached > 0 else { return count }
        return count + ", " + (attached == 1 ? "1 container attached" : "\(attached) containers attached")
    }

    @ViewBuilder
    private func rowMenu(_ network: NetworkSummary) -> some View {
        Button {
            ResourceUsage.copyToPasteboard(network.name)
            state.showToast("Copied \(network.name)")
        } label: {
            DeckLabel("Copy Name", icon: .copy)
        }
        if let subnet = network.subnet {
            Button {
                ResourceUsage.copyToPasteboard(subnet)
                state.showToast("Copied \(subnet)")
            } label: {
                DeckLabel("Copy Subnet", icon: .copy)
            }
        }
        Divider()
        Button(role: .destructive) { askDelete(network) } label: { DeckLabel("Delete…", icon: .trash) }
            .disabled(network.isProtected)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showPrune = true
            } label: {
                DeckLabel("Prune", icon: .prune)
            }
            .help("Remove unused networks")

            RefreshButton(help: "Refresh networks", isBusy: isLoading) {
                await load()
            }

            Button {
                showCreate = true
            } label: {
                DeckLabel("Create", icon: .add)
            }
            .help("Create a network")
        }
    }

    // MARK: - Derived values

    private var selectedNetwork: NetworkSummary? {
        guard let id = selection else { return nil }
        return networks.first { $0.id == id }
    }

    private var visibleNetworks: [NetworkSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? networks : networks.filter { network in
            network.name.lowercased().contains(query)
                || (network.subnet ?? "").contains(query)
                || network.attachedContainers.contains { $0.lowercased().contains(query) }
        }
        return filtered.sorted(using: sortOrder)
    }

    private var alertShown: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { shown in if !shown { activeAlert = nil } }
        )
    }

    private var alertTitle: String {
        switch activeAlert {
        case .delete(let network): return "Delete \(network.name)?"
        case .blocked: return "This network cannot be deleted"
        case .none: return ""
        }
    }

    private func alertMessage(_ item: NetworksAlert) -> String {
        switch item {
        case .delete:
            return "Containers can no longer join this network."
        case .blocked(let network):
            if network.isProtected {
                return "Built in networks are managed by the container service."
            }
            return "Used by \(network.attachedContainers.joined(separator: ", ")). Delete those containers first. Stopped containers still hold the network."
        }
    }

    @ViewBuilder
    private func alertActions(_ item: NetworksAlert) -> some View {
        switch item {
        case .delete(let network):
            Button("Delete", role: .destructive) { delete(network) }
            Button("Cancel", role: .cancel) {}
        case .blocked:
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Actions

    private func askDelete(_ network: NetworkSummary) {
        if network.isProtected || !network.attachedContainers.isEmpty {
            activeAlert = .blocked(network)
        } else {
            activeAlert = .delete(network)
        }
    }

    /// `network list` only. Attached containers come from the shared `ContainerUsage`
    /// (stopped containers too), which inspects only when the container list changed.
    private func load(force: Bool = false) async {
        guard let client = state.client else { return }
        let token = sequencer.begin()
        isLoading = true
        do {
            let list = try await client.listNetworkSummaries()
            await ContainerUsage.shared.refresh(client: client, force: force)
            guard sequencer.accept(token) else { return }
            publish(withUsers(list))
            loadError = nil
            if let id = selection, !list.contains(where: { $0.id == id }) {
                selection = nil
            }
        } catch {
            if !Task.isCancelled, sequencer.accept(token) { loadError = error.localizedDescription }
        }
        isLoading = false
        hasLoaded = true
    }

    private func withUsers(_ list: [NetworkSummary]) -> [NetworkSummary] {
        let users = ContainerUsage.shared.networkUsers
        return list.map { network in
            var copy = network
            copy.attachedContainers = users[network.name] ?? []
            return copy
        }
    }

    private func publish(_ list: [NetworkSummary]) {
        guard list != networks else { return }
        withAnimation(.easeInOut(duration: 0.25)) { networks = list }
    }

    private func refreshUsers() async {
        await ContainerUsage.shared.refresh(client: state.client)
        publish(withUsers(networks))
    }

    private func delete(_ network: NetworkSummary) {
        guard let client = state.client else { return }
        Task {
            do {
                try await client.deleteNetwork(network.name)
                if selection == network.id { selection = nil }
                state.showToast("Deleted \(network.name)", style: .success)
                state.resourcesChanged()
            } catch {
                state.showError(error)
            }
        }
    }

    private func prune() {
        guard let client = state.client else { return }
        Task {
            do {
                try await client.pruneNetworks()
                state.showToast("Removed unused networks", style: .success)
                state.resourcesChanged()
            } catch {
                state.showError(error)
            }
        }
    }
}

private enum NetworksAlert {
    case delete(NetworkSummary)
    case blocked(NetworkSummary)
}

fileprivate extension NetworkSummary {
    /// The default network and other built in ones cannot be deleted.
    var isProtected: Bool { isDefault || isBuiltin }
    var subnetSortKey: String { subnet ?? "" }
    var attachedCount: Int { attachedContainers.count }
}

// MARK: - Create

/// Create a network with an optional subnet.
struct NetworkCreateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var subnet = ""
    @State private var subnetV6 = ""
    @State private var hostOnly = false
    @State private var labels: [ResourcePair] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedSubnet: String { subnet.trimmingCharacters(in: .whitespaces) }
    private var trimmedSubnetV6: String { subnetV6.trimmingCharacters(in: .whitespaces) }

    /// Same rule as the container tool (`NetworkResource.nameValid`): lowercase,
    /// up to 63 characters, starts and ends with a letter or number.
    private var nameIsValid: Bool {
        trimmedName.range(of: "^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil
            && trimmedName != "default"
    }

    private var subnetV6IsValid: Bool {
        trimmedSubnetV6.isEmpty
            || trimmedSubnetV6.range(of: "^[0-9A-Fa-f:]+/[0-9]{1,3}$", options: .regularExpression) != nil
    }

    private var subnetIsValid: Bool {
        trimmedSubnet.isEmpty
            || trimmedSubnet.range(of: "^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", options: .regularExpression) != nil
    }

    private var hintArguments: [String] {
        let name = trimmedName.isEmpty ? "<name>" : trimmedName
        if let client = state.client {
            return client.networkCreateArguments(
                name: name,
                subnet: trimmedSubnet,
                subnetV6: trimmedSubnetV6,
                internal: hostOnly,
                labels: ResourcePairEditor.dictionary(labels)
            )
        }
        var args = ["network", "create"]
        if !trimmedSubnet.isEmpty { args += ["--subnet", trimmedSubnet] }
        if hostOnly { args.append("--internal") }
        args.append(name)
        return args
    }

    var body: some View {
        SheetScaffold("Create Network", subtitle: "Containers on the same network can reach each other.", icon: .networks, width: 520) {
            DeckFormGroup {
                DeckFormRow("Name") {
                    TextField("Name", text: $name, prompt: Text("backend"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if !trimmedName.isEmpty && !nameIsValid {
                        ResourceWarningText("Use lowercase letters, numbers, dots, dashes and underscores. The name default is taken.")
                    }
                }
                DeckFormRow("IPv4 subnet") {
                    TextField("IPv4 subnet", text: $subnet, prompt: Text("Auto"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(trimmedSubnet.isEmpty ? .body : .body.monospaced())
                    if subnetIsValid {
                        DeckFormNote("Optional. For example 192.168.100.0/24.")
                    } else {
                        ResourceWarningText("Use CIDR form, like 192.168.100.0/24.")
                    }
                }
                DeckFormRow("IPv6 prefix") {
                    TextField("IPv6 prefix", text: $subnetV6, prompt: Text("Auto"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(trimmedSubnetV6.isEmpty ? .body : .body.monospaced())
                    if subnetV6IsValid {
                        DeckFormNote("Optional. For example fd00:abcd::/64.")
                    } else {
                        ResourceWarningText("Use CIDR form, like fd00:abcd::/64.")
                    }
                }
                DeckFormRow("Access") {
                    Toggle("Host only", isOn: $hostOnly)
                        .toggleStyle(.checkbox)
                    DeckFormNote(hostOnly
                         ? "Containers can talk to each other and to this Mac, but not to the internet."
                         : "Containers can reach the internet.")
                }
            }
            DeckFormGroup("Labels") {
                ResourcePairEditor(rows: $labels, keyPrompt: "key", valuePrompt: "value", addTitle: "Add Label")
            }
            ResourceCommandHint(hintArguments)
            if let errorMessage {
                ResourceErrorText(errorMessage)
            }
        } footer: {
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid || !subnetIsValid || !subnetV6IsValid || isWorking)
        }
        .frame(height: 560)
    }

    private func create() {
        guard let client = state.client, nameIsValid, subnetIsValid, subnetV6IsValid, !isWorking else { return }
        let networkName = trimmedName
        let networkSubnet = trimmedSubnet.isEmpty ? nil : trimmedSubnet
        let networkSubnetV6 = trimmedSubnetV6.isEmpty ? nil : trimmedSubnetV6
        let networkLabels = ResourcePairEditor.dictionary(labels)
        let isInternal = hostOnly
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await client.createNetwork(name: networkName, subnet: networkSubnet, subnetV6: networkSubnetV6, internal: isInternal, labels: networkLabels)
                state.showToast("Created \(networkName)", style: .success)
                state.resourcesChanged()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

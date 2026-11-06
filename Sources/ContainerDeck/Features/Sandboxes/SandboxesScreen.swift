import SwiftUI
import DeckCore

extension PrefKey {
    /// Width of the sandbox detail pane.
    static let sandboxDetailWidth = "sandboxDetailWidth"
}

/// Sandboxes: containers for AI agents with their own network, model settings and a kill switch.
struct SandboxesScreen: View {
    @State private var discoveredModels: [any SandboxModelSource] = []
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.sandboxDetailWidth) private var detailWidth: Double = 520

    @State private var runtime = SandboxRuntime.shared
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\Sandbox.name)]
    @State private var showCreate = false
    @State private var removing: Sandbox?
    @FocusState private var tableFocused: Bool

    private var feed: BackgroundServices { BackgroundServices.shared }

    private var selection: Sandbox.ID? {
        get { runtime.selection }
        nonmutating set { runtime.selection = newValue }
    }

    var body: some View {
        content
            .navigationTitle("Sandboxes")
            .searchable(text: $search, placement: .toolbar, prompt: "Search sandboxes")
            .toolbar { toolbarContent }
            .onAppear {
                runtime.attach()
                runtime.reconcile(feed.containers)
            }
            .onChange(of: feed.containersVersion) { _, _ in
                // A missing selection just shows no detail. It comes back when a new sandbox
                // with that name shows up in the feed (right after Create).
                runtime.reconcile(feed.containers)
            }
            .task(id: showCreate) {
                if showCreate { discoveredModels = await DiscoveredModelSource.current() }
            }
            .sheet(isPresented: $showCreate) {
                SandboxCreateSheet(modelSources: discoveredModels) { name in
                    selection = name
                    BackgroundServices.shared.pollNow()
                }
                .environment(state)
            }
            .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible, presenting: removing) { sandbox in
                // Default: the chat history volume goes too.
                Button("Remove", role: .destructive) { remove(sandbox) }
                Button("Remove, Keep Chat History") { remove(sandbox, keepChatHistory: true) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The container, its network, its Keychain key and its chat history volume are removed. Files in the workspace folder stay.")
            }
            .onDeckDebugCommand { name, value in
                switch name {
                case "sbx-new": showCreate = true
                case "sbx-select": selection = value
                case "sbx-kill": if let box = sandbox(value) { kill(box) }
                case "sbx-start": if let box = sandbox(value) { start(box) }
                case "sbx-remove": if let box = sandbox(value) { remove(box) }
                default: break
                }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.client == nil {
            ResourceToolMissing(icon: .sandboxes)
        } else if !feed.hasLoaded {
            LoadingView("Loading sandboxes", style: .logo)
        } else if runtime.sandboxes.isEmpty {
            EmptyState(
                icon: .sandboxes,
                title: "No sandboxes yet",
                message: "A sandbox is a container with its own network, an optional model and a kill switch. Good for running AI agents safely.",
                actionTitle: "New Sandbox"
            ) {
                showCreate = true
            }
        } else {
            GeometryReader { geo in
                let detail = clampedDetailWidth(total: geo.size.width)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        table
                        footer
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let selected = selectedSandbox {
                        SandboxSplitHandle(width: $detailWidth, total: geo.size.width, minList: Self.minListWidth)
                        SandboxDetailPane(
                            sandbox: selected,
                            onStart: { start(selected) },
                            onStop: { stop(selected) },
                            onKill: { kill(selected) },
                            onTerminal: { openTerminal(selected) },
                            onRemove: { removing = selected }
                        )
                        .id(selected.id)
                        .frame(width: detail)
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }

    /// The table needs this much room to show every column without cutting one.
    static let minListWidth: CGFloat = 580
    static let detailRange: ClosedRange<CGFloat> = 420...720

    private func clampedDetailWidth(total: CGFloat) -> CGFloat {
        let room = total - Self.minListWidth - 1
        let upper = max(Self.detailRange.lowerBound, min(Self.detailRange.upperBound, room))
        return min(max(detailWidth, Self.detailRange.lowerBound), upper)
    }

    private var table: some View {
        Table(visibleSandboxes, selection: $runtime.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { sandbox in
                HStack(spacing: 8) {
                    DeckIcon(.sandboxes, size: 14, color: DS.accent)
                    Text(sandbox.name).fontWeight(.medium).lineLimit(1)
                }
            }
            .width(min: 130, ideal: 130)

            TableColumn("Status", value: \.statusSortKey) { sandbox in
                if runtime.isKilled(sandbox.name) && !sandbox.isRunning {
                    Pill("Killed", tint: DS.danger)
                } else {
                    StatusPill(sandbox.container.state)
                }
            }
            .width(min: 90, ideal: 90)

            TableColumn("Network", value: \.egress.rawValue) { sandbox in
                SandboxEgressPill(egress: sandbox.egress)
            }
            .width(min: 90, ideal: 90)

            TableColumn("Model") { sandbox in
                Text(sandbox.modelSummary)
                    .deckSecondaryText()
                    .lineLimit(1)
                    .help(sandbox.model?.url.absoluteString ?? "")
            }
            .width(min: 80, ideal: 80)

            TableColumn("Image", value: \.image) { sandbox in
                Text(sandbox.image)
                    .deckSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sandbox.image)
            }
            .width(min: 90, ideal: 90)
        }
        .scrollContentBackground(.hidden)
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .focused($tableFocused)
        .onAppear { tableFocused = true }
        .contextMenu(forSelectionType: Sandbox.ID.self) { ids in
            if let id = ids.first, let box = sandbox(id) {
                rowMenu(box)
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }

    private var footer: some View {
        ListStatusBar(statusText) {
            ResourceCommandHint(["list", "--all", "--format", "json"])
                .frame(maxWidth: 280)
        }
    }

    private var statusText: String {
        let total = runtime.sandboxes.count
        let running = runtime.sandboxes.filter(\.isRunning).count
        let count = total == 1 ? "1 sandbox" : "\(total) sandboxes"
        return running > 0 ? "\(count), \(running) running" : count
    }

    @ViewBuilder
    private func rowMenu(_ sandbox: Sandbox) -> some View {
        if sandbox.isRunning {
            Button { openTerminal(sandbox) } label: { DeckLabel("Open Terminal", icon: .terminal) }
            Button { stop(sandbox) } label: { DeckLabel("Stop", icon: .stop) }
            Button { kill(sandbox) } label: { DeckLabel("Kill Switch", icon: .power) }
        } else {
            Button { start(sandbox) } label: { DeckLabel("Start", icon: .play) }
        }
        Button {
            state.openContainer(sandbox.container.id)
        } label: {
            DeckLabel("Show Container", icon: .containers)
        }
        Divider()
        Button(role: .destructive) { removing = sandbox } label: { DeckLabel("Remove…", icon: .trash) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            RefreshButton(help: "Refresh sandboxes") {
                BackgroundServices.shared.pollNow()
            }
            Button {
                showCreate = true
            } label: {
                DeckLabel("New Sandbox", icon: .add)
            }
            .help("Create a sandbox")
        }
    }

    // MARK: - Derived

    private var selectedSandbox: Sandbox? {
        guard let id = selection else { return nil }
        return sandbox(id)
    }

    private func sandbox(_ id: String) -> Sandbox? {
        runtime.sandboxes.first { $0.id == id }
    }

    private var visibleSandboxes: [Sandbox] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? runtime.sandboxes : runtime.sandboxes.filter { box in
            box.name.lowercased().contains(query) || box.image.lowercased().contains(query)
                || box.egress.title.lowercased().contains(query) || box.modelSummary.lowercased().contains(query)
        }
        return filtered.sorted(using: sortOrder)
    }

    // MARK: - Actions

    private func start(_ sandbox: Sandbox) {
        guard let client = state.client else { return }
        Task {
            do {
                try await runtime.start(sandbox, client: client)
                state.showToast("Started \(sandbox.name)", style: .success)
                BackgroundServices.shared.pollNow()
            } catch {
                state.showError(error)
            }
        }
    }

    private func stop(_ sandbox: Sandbox) {
        guard let client = state.client else { return }
        Task {
            do {
                try await runtime.stop(sandbox, client: client)
                state.showToast("Stopped \(sandbox.name)")
                BackgroundServices.shared.pollNow()
            } catch {
                state.showError(error)
            }
        }
    }

    private func kill(_ sandbox: Sandbox) {
        guard let client = state.client else { return }
        Task {
            do {
                try await runtime.kill(sandbox, client: client)
                state.showToast("Killed \(sandbox.name). All its traffic is stopped.", style: .success)
                BackgroundServices.shared.pollNow()
            } catch {
                state.showError(error)
            }
        }
    }

    private func remove(_ sandbox: Sandbox, keepChatHistory: Bool = false) {
        guard let client = state.client else { return }
        Task {
            do {
                try await runtime.remove(sandbox, client: client, keepChatHistory: keepChatHistory)
                if selection == sandbox.id { selection = nil }
                state.showToast("Removed \(sandbox.name)", style: .success)
                state.resourcesChanged()
                BackgroundServices.shared.pollNow()
            } catch {
                state.showError(error)
            }
        }
    }

    private func openTerminal(_ sandbox: Sandbox) {
        guard let client = state.client else { return }
        do {
            try TerminalLauncher.open(command: client.sandboxShellCommand(sandbox)) { state.showError($0) }
        } catch {
            state.showError(error)
        }
    }
}

// MARK: - Small views

/// Isolated, Internet or Allow list.
struct SandboxEgressPill: View {
    let egress: SandboxEgress

    var body: some View {
        Pill(egress.title, tint: tint)
            .help(help)
    }

    private var tint: Color {
        switch egress {
        case .isolated: return DS.warning
        case .open: return DS.running
        case .allowList: return DS.accent
        }
    }

    private var help: String {
        switch egress {
        case .isolated: return "Host only network. No internet."
        case .open: return "Full internet access."
        case .allowList: return "Only listed hosts, through the app's proxy."
        }
    }
}

/// Thin divider you can drag to resize the detail pane.
struct SandboxSplitHandle: View {
    @Binding var width: Double
    let total: CGFloat
    let minList: CGFloat
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
                                let range = SandboxesScreen.detailRange
                                let upper = max(Double(range.lowerBound), min(Double(range.upperBound), Double(total - minList - 1)))
                                width = min(max(start - value.translation.width, Double(range.lowerBound)), upper)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

extension Sandbox {
    var statusSortKey: String { container.state.rawValue }

    var modelSummary: String {
        guard let model else { return "None" }
        if let name = model.name { return name }
        return model.kind.title
    }
}

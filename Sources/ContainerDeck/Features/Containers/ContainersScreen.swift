import SwiftUI
import AppKit
import DeckCore

/// Containers list with live stats. Opens the detail for one container.
struct ContainersScreen: View {
    @Environment(AppState.self) private var state
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            // The list is covered while a detail is pushed: it stops asking for stats then.
            ContainerListView(isCovered: !path.isEmpty) { id in
                path = [id]
            }
            .navigationDestination(for: String.self) { id in
                // A new identity per container, so opening another one never shows stale data.
                ContainerDetailView(containerID: id)
                    .id(id)
            }
        }
        // A link or the palette can ask for a container before this screen exists. On a cold
        // start a path set in the first update can be dropped, so the request stays in AppState
        // until the detail for it is on screen (the detail clears it) and is pushed again then.
        .onAppear { pushFocus() }
        .task {
            await Task.yield()
            pushFocus()
        }
        .onChange(of: state.focusedContainerID) { _, _ in pushFocus() }
    }

    private func pushFocus() {
        guard let id = state.focusedContainerID, path != [id] else { return }
        DebugAutomation.log("containers: open \(id)")
        if path.isEmpty {
            path = [id]
            return
        }
        // Another detail is open. Swapping the pushed value in place is dropped by
        // NavigationStack, so go back first and push after the pop finishes.
        path = []
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if state.focusedContainerID == id, path.isEmpty { path = [id] }
        }
    }
}

// MARK: - List

private enum ContainerFilter: String, Hashable {
    case all, running
}

/// One table row: the container plus its latest stats, so columns can sort.
private struct ContainerRow: Identifiable {
    let summary: ContainerSummary
    let cpu: Double
    let memory: UInt64
    /// "Measuring" until the sampler has two readings.
    let cpuText: String

    var id: String { summary.id }
    var name: String { summary.name }
    var image: String { summary.image }
    var ip: String { summary.ipAddress ?? "" }
    var stateRank: Int {
        switch summary.state {
        case .running: return 0
        case .stopping: return 1
        case .stopped: return 2
        case .unknown: return 3
        }
    }
}

private struct ContainerListView: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let isCovered: Bool
    let openDetail: (String) -> Void

    init(isCovered: Bool, openDetail: @escaping (String) -> Void) {
        self.isCovered = isCovered
        self.openDetail = openDetail
    }

    private var feed: BackgroundServices { BackgroundServices.shared }
    private var sampler: StatsSampler { StatsSampler.shared }
    @State private var liveOrder = LiveRowOrder()
    @SceneStorage("containers.grouping") private var groupingValue = ""
    @State private var commitTarget: ContainerSummary?
    @State private var selection = Set<String>()
    /// The table takes keyboard focus when the screen opens, so arrows, Space, Delete and Cmd+A work at once.
    @FocusState private var tableFocused: Bool
    @State private var search = ""
    @State private var filter: ContainerFilter = .all
    @State private var sortOrder: [KeyPathComparator<ContainerRow>] = [KeyPathComparator(\ContainerRow.name)]
    @State private var pendingDelete: [String]?
    /// Stop, restart or kill on more than one container asks once first.
    @State private var pendingBulk: BulkRequest?
    @State private var confirmPrune = false

    var body: some View {
        content
            .navigationTitle("Containers")
            .searchable(text: $search, prompt: "Search containers")
            .toolbar { toolbarContent }
            // No loop here: the shared feed polls the list, the shared sampler the stats.
            .usesLiveStats("containers-list", active: !isCovered)
            .onChange(of: feed.containersVersion) { _, _ in
                let ids = Set(containers.map(\.id))
                if !selection.isSubset(of: ids) {
                    selection = selection.intersection(ids)
                }
            }
            .onDeckDebugCommand { name, value in
                // Debug only: containers-group:<compose|label:key|none>, containers-commit:<id>.
                if name == "containers-group" { groupingValue = value == "none" ? "" : value }
                if name == "containers-commit" { commitTarget = container(value) }
                // Debug only: containers-select:all|none, containers-bulk:stop|restart|kill|start|delete.
                // Debug only: open the Diagnostics window or the version screen for made up versions.
                if name == "diagnostics" { DiagnosticsWindow.show(state: state) }
                if name == "version-window" {
                    let parts = value.split(separator: ",").map { SemanticVersion.firstMatch(in: String($0)) }
                    let cli = parts.first ?? nil
                    let daemon = parts.count > 1 ? parts[1] : cli
                    DiagnosticsWindow.showVersion(VersionCompatibility(cliVersion: cli, daemonVersion: daemon), state: state)
                }
                if name == "containers-select" { selection = value == "all" ? Set(rows.map(\.id)) : Set(rows.map(\.id).filter { !value.isEmpty && value != "none" && $0.hasPrefix(value) }) }
                if name == "containers-bulk", let op = ContainerOp(rawValue: value) {
                    if op == .delete { pendingDelete = selectedIDs } else { run(op, selectedIDs) }
                }
            }
            .sheet(item: $commitTarget) { item in
                CommitSheet(container: item)
                    .environment(state)
                    .tint(DS.accent)
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = pendingDelete ?? []
                    pendingDelete = nil
                    run(.delete, ids)
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text(deleteMessage)
            }
            .confirmationDialog(
                pendingBulk.map { ContainerBulk.title($0.op, count: $0.ids.count) } ?? "",
                isPresented: Binding(
                    get: { pendingBulk != nil },
                    set: { if !$0 { pendingBulk = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let request = pendingBulk {
                    Button(request.op.title, role: request.op == .start ? nil : .destructive) {
                        pendingBulk = nil
                        perform(request.op, request.ids)
                    }
                }
                Button("Cancel", role: .cancel) { pendingBulk = nil }
            } message: {
                if let request = pendingBulk {
                    Text(ContainerBulk.message(request.op, names: request.ids.map { container($0)?.name ?? $0 }))
                }
            }
            .confirmationDialog("Remove stopped containers?", isPresented: $confirmPrune, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task { await ContainerOps.prune(state: state) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(pruneMessage)
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if state.client == nil {
            EmptyState(
                icon: .containers,
                title: "Platform not ready",
                message: "\(AppConfig.appName) needs Apple's container tool. Finish setup to see your containers.",
                actionTitle: "Open Setup"
            ) {
                state.showSetup = true
            }
        } else if !state.report.checks.isEmpty && !state.report.serviceRunning {
            EmptyState(
                icon: .containers,
                title: "Service is stopped",
                message: "Start the container service to see and run containers.",
                actionTitle: "Start Service"
            ) {
                Task { await state.fix(.startService) }
            }
        } else if !feed.hasLoaded {
            LoadingView("Loading containers", style: .logo)
        } else if containers.isEmpty {
            if let error = feed.loadError {
                EmptyState(icon: .error, title: "Could not load containers", message: error, actionTitle: "Try Again") {
                    Task { await reload() }
                }
            } else {
                EmptyState(
                    icon: .containers,
                    title: "No containers yet",
                    message: "Run a container from an image to get started.",
                    actionTitle: "Run a Container"
                ) {
                    openRunSheet()
                }
            }
        } else {
            VStack(spacing: 0) {
                table
                    .overlay {
                        if rows.isEmpty {
                            EmptyState(icon: .search, title: "No matches", message: "No container matches your search or filter.")
                        }
                    }
                footer
            }
        }
    }

    /// Containers from the shared feed, without the app's helpers.
    private var containers: [ContainerSummary] {
        feed.visibleContainers
    }

    private var grouping: ContainerGrouping {
        ContainerGrouping(storageValue: groupingValue)
    }

    private var rows: [ContainerRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = containers.filter { item in
            if filter == .running && !item.isRunning { return false }
            if query.isEmpty { return true }
            return item.name.lowercased().contains(query)
                || item.image.lowercased().contains(query)
                || (item.ipAddress ?? "").contains(query)
        }
        let mapped = list.map { item -> ContainerRow in
            let reading = item.isRunning ? sampler.reading(for: item) : nil
            return ContainerRow(
                summary: item,
                cpu: reading?.cpuPercent ?? 0,
                memory: reading?.memoryBytes ?? 0,
                cpuText: sampler.cpuText(for: item)
            )
        }
        return sorted(mapped)
    }

    /// Name, image, state and IP sort normally. CPU and Memory keep rows in place
    /// unless the values really differ, so rows do not jump on every sample.
    private func sorted(_ rows: [ContainerRow]) -> [ContainerRow] {
        guard let first = sortOrder.first else { return rows }
        let descending = first.order == .reverse
        let items: [(id: String, value: Double)]
        let threshold: (Double, Double) -> Double
        if first.keyPath == \ContainerRow.cpu as PartialKeyPath<ContainerRow> {
            items = rows.map { ($0.id, $0.cpu) }
            threshold = StableOrder.band(absolute: 1, relative: 0.15)
        } else if first.keyPath == \ContainerRow.memory as PartialKeyPath<ContainerRow> {
            items = rows.map { ($0.id, Double($0.memory)) }
            threshold = StableOrder.band(absolute: 8 * 1024 * 1024, relative: 0.1)
        } else {
            return rows.sorted(using: sortOrder)
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let key = "\(first.keyPath.hashValue)|\(descending)"
        return liveOrder.order(items, key: key, descending: descending, threshold: threshold).compactMap { byID[$0] }
    }

    /// Sections for the grouped list, rows in the current sort order.
    private var groupedRows: [(group: ContainerGroup, rows: [ContainerRow])] {
        let all = rows
        let groups = ContainerGroups.group(all.map(\.summary), by: grouping)
        return groups.map { group in
            let ids = Set(group.containers.map(\.id))
            return (group, all.filter { ids.contains($0.id) })
        }
    }

    private func groupHeader(_ group: ContainerGroup, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(group.title).font(.callout.weight(.semibold))
            Pill("\(group.runningCount) of \(count) running", tint: group.runningCount > 0 ? DS.running : DS.stopped)
        }
    }

    private var table: some View {
        Table(of: ContainerRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \ContainerRow.name) { row in
                ContainerNameCell(summary: row.summary)
            }
            .width(min: 140, ideal: 170)

            TableColumn("Image", value: \ContainerRow.image) { row in
                Text(ContainerText.shortImage(row.image))
                    .deckSecondaryText()
                    .lineLimit(1)
                    .help(row.image)
            }
            .width(min: 100, ideal: 140)

            TableColumn("State", value: \ContainerRow.stateRank) { row in
                StatusPill(row.summary.state)
            }
            .width(min: 84, ideal: 96)

            TableColumn("IP", value: \ContainerRow.ip) { row in
                Text(row.ip.isEmpty ? "-" : row.ip)
                    .font(.callout.monospaced())
                    .deckRowText(row.ip.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
            }
            .width(min: 90, ideal: 106)

            TableColumn("Ports") { row in
                ContainerPortBadges(ports: row.summary.ports, limit: 2)
            }
            .width(min: 80, ideal: 100)

            TableColumn("CPU", value: \ContainerRow.cpu) { row in
                Text(row.cpuText)
                    .monospacedDigit()
                    .font(row.cpuText == "Measuring" ? .caption : .body)
                    .deckRowText(row.summary.isRunning && row.cpuText != "Measuring" ? .primary : .tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(row.cpuText == "Measuring" ? "CPU shows after two samples, about 4 seconds." : "")
            }
            .width(min: 60, ideal: 68)

            TableColumn("Memory", value: \ContainerRow.memory) { row in
                Text(memoryText(row))
                    .monospacedDigit()
                    .deckRowText(row.summary.isRunning ? .primary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)
        } rows: {
            if grouping == .none {
                ForEach(rows) { row in
                    TableRow(row)
                }
            } else {
                ForEach(groupedRows, id: \.group.id) { section in
                    Section {
                        ForEach(section.rows) { row in
                            TableRow(row)
                        }
                    } header: {
                        groupHeader(section.group, count: section.rows.count)
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .focused($tableFocused)
        .onAppear { tableFocused = true }
        .background {
            // Cmd+A selects every row while the table has focus. Off while typing in search,
            // so Cmd+A there still selects the text.
            Button("Select All") { selection = Set(rows.map(\.id)) }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!tableFocused || rows.isEmpty)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onDeleteCommand {
            // Delete key: ask first, like the toolbar button.
            if !selection.isEmpty { pendingDelete = selectedIDs }
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "aA"), phases: .down) { press in
            // Cmd+A when the menu did not take it first.
            guard press.modifiers.contains(.command), !rows.isEmpty else { return .ignored }
            selection = Set(rows.map(\.id))
            return .handled
        }
        .onKeyPress(.space) {
            // Space opens the selected container.
            guard selection.count == 1, let id = selection.first else { return .ignored }
            openDetail(id)
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { ids in
            rowMenu(Array(ids))
        } primaryAction: { ids in
            if let id = ids.first { openDetail(id) }
        }
    }

    private var footer: some View {
        ListStatusBar(footerText) {
            if showHints, let client = state.client {
                CommandHint(footerCommand(client))
                    .frame(maxWidth: 420)
            }
        }
    }

    private func memoryText(_ row: ContainerRow) -> String {
        guard row.summary.isRunning else { return "-" }
        return sampler.reading(for: row.summary) == nil ? "-" : Format.bytes(row.memory)
    }

    private var footerText: String {
        let total = containers.count
        let running = containers.filter(\.isRunning).count
        if selection.isEmpty {
            return "\(total) \(total == 1 ? "container" : "containers"), \(running) running"
        }
        return "\(selection.count) of \(total) selected"
    }

    private func footerCommand(_ client: ContainerClient) -> String {
        let ids = selectedIDs
        if ids.count == 1, let id = ids.first, let item = container(id), item.isRunning {
            return ContainerOps.terminalCommandLine(id, client: client)
        }
        if !ids.isEmpty {
            return (anySelectedRunning ? ContainerOp.stop : ContainerOp.start).commandLine(ids, client: client)
        }
        return client.commandLine(["list", "--all"])
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Picker("Show", selection: $filter) {
                Text("All").tag(ContainerFilter.all)
                Text("Running").tag(ContainerFilter.running)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show all containers or only running ones")
        }
        ToolbarItemGroup {
            Button {
                run(.start, selectedIDs.filter { !(container($0)?.isRunning ?? false) })
            } label: {
                DeckLabel("Start", icon: .play)
            }
            .disabled(!anySelectedStopped)
            .help(toolbarHelp(.start))

            Button {
                run(.stop, selectedIDs.filter { container($0)?.isRunning ?? false })
            } label: {
                DeckLabel("Stop", icon: .stop)
            }
            .disabled(!anySelectedRunning)
            .help(toolbarHelp(.stop))

            Button {
                run(.restart, selectedIDs.filter { container($0)?.isRunning ?? false })
            } label: {
                DeckLabel("Restart", icon: .restart)
            }
            .disabled(!anySelectedRunning)
            .help(toolbarHelp(.restart))

            Button {
                pendingDelete = selectedIDs
            } label: {
                DeckLabel("Delete", icon: .trash)
            }
            .disabled(selection.isEmpty)
            .help(toolbarHelp(.delete))
        }
        ToolbarItemGroup {
            Menu {
                Picker(selection: $groupingValue) {
                    Text("No Groups").tag(ContainerGrouping.none.storageValue)
                    Text("Compose Project").tag(ContainerGrouping.composeProject.storageValue)
                    let keys = ContainerGroups.labelKeys(containers)
                    if !keys.isEmpty {
                        Divider()
                        ForEach(keys.prefix(12), id: \.self) { key in
                            Text("Label \(key)").tag(ContainerGrouping.label(key).storageValue)
                        }
                    }
                } label: {
                    DeckLabel("Group By", icon: .layers)
                }
                .pickerStyle(.menu)
                Divider()
                Button {
                    selection = Set(rows.map(\.id))
                } label: {
                    DeckLabel("Select All", icon: .checklist)
                }
                .disabled(rows.isEmpty)
                Button {
                    selection = []
                } label: {
                    DeckLabel("Select None", icon: .close)
                }
                .disabled(selection.isEmpty)
                Button {
                    if let id = selectedIDs.first, let item = container(id) {
                        Task { await ContainerOps.exportFilesystem(item.id, name: item.name, state: state) }
                    }
                } label: {
                    DeckLabel("Export as Tar…", icon: .export)
                }
                .disabled(selection.count != 1)
                Button {
                    confirmPrune = true
                } label: {
                    DeckLabel("Remove Stopped Containers…", icon: .prune)
                }
                .disabled(stoppedCount == 0)
            } label: {
                DeckLabel("More", icon: .more)
            }
            .menuIndicator(.hidden)
            .help("More actions")

            RefreshButton(help: "Reload the container list") {
                await feed.refresh()
            }
            .disabled(state.client == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                openRunSheet()
            } label: {
                DeckLabel("Run", icon: .add)
            }
            .disabled(state.client == nil)
            .help("Run a new container")
        }
    }

    private func toolbarHelp(_ op: ContainerOp) -> String {
        guard showHints, let client = state.client, !selection.isEmpty else {
            return "\(op.title) the selected containers"
        }
        return op.commandLine(selectedIDs, client: client)
    }

    // MARK: Context menu

    @ViewBuilder
    private func rowMenu(_ ids: [String]) -> some View {
        let items = ids.compactMap { container($0) }
        let running = items.contains { $0.isRunning }
        let stopped = items.contains { !$0.isRunning }
        if items.count == 1, let item = items.first {
            Button {
                openDetail(item.id)
            } label: {
                DeckLabel("Open Details", icon: .inspect)
            }
            if item.isRunning {
                Button {
                    ContainerOps.openTerminal(item.id, state: state)
                } label: {
                    DeckLabel("Open Terminal", icon: .terminal)
                }
            }
            ForEach(Array(item.ports.enumerated()), id: \.offset) { _, port in
                if let url = ContainerText.portURL(port) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        DeckLabel("Open \(url.absoluteString)", icon: .openExternal)
                    }
                }
            }
            Divider()
        }
        if stopped {
            Button {
                run(.start, items.filter { !$0.isRunning }.map(\.id))
            } label: {
                DeckLabel("Start", icon: .play)
            }
        }
        if running {
            Button {
                run(.stop, items.filter(\.isRunning).map(\.id))
            } label: {
                DeckLabel("Stop", icon: .stop)
            }
            Button {
                run(.restart, items.filter(\.isRunning).map(\.id))
            } label: {
                DeckLabel("Restart", icon: .restart)
            }
            Button {
                run(.kill, items.filter(\.isRunning).map(\.id))
            } label: {
                DeckLabel("Kill", icon: .kill)
            }
        }
        if items.count == 1, let item = items.first {
            Divider()
            Button {
                Task { await ContainerOps.editAndRecreate(item.id, state: state) }
            } label: {
                DeckLabel("Edit and Recreate…", icon: .edit)
            }
            if CommitSheet.isSupported(state) {
                Button {
                    commitTarget = item
                } label: {
                    DeckLabel("Commit to Image…", icon: .layers)
                }
            }
            Button {
                Task { await ContainerOps.exportFilesystem(item.id, name: item.name, state: state) }
            } label: {
                DeckLabel("Export as Tar…", icon: .export)
            }
            Button {
                state.openContainer(item.id, tab: .mounts)
            } label: {
                DeckLabel("Show Mounts", icon: .volumes)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.name, forType: .string)
            } label: {
                DeckLabel("Copy Name", icon: .copy)
            }
        }
        if !items.isEmpty {
            Divider()
            Button(role: .destructive) {
                pendingDelete = items.map(\.id)
            } label: {
                DeckLabel("Delete…", icon: .trash)
            }
        }
    }

    // MARK: Helpers

    private var selectedIDs: [String] {
        containers.map(\.id).filter { selection.contains($0) }
    }

    private func container(_ id: String) -> ContainerSummary? {
        containers.first { $0.id == id }
    }

    private var anySelectedRunning: Bool {
        selectedIDs.contains { container($0)?.isRunning ?? false }
    }

    private var anySelectedStopped: Bool {
        selectedIDs.contains { !(container($0)?.isRunning ?? true) }
    }

    /// Stopped containers Remove Stopped deletes. The builder is never one of them.
    private var stoppedCount: Int {
        ContainersStore.removableStopped(containers).count
    }

    private var pruneMessage: String {
        let names = ContainersStore.removableStopped(containers).map(\.name)
        let list = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " and \(names.count - 5) more" : "")
        let subject = names.count == 1 ? "This stopped container is" : "These \(names.count) stopped containers are"
        let keepsBuilder = containers.contains { !$0.isRunning && ContainersStore.isBuilder($0) }
        return "\(subject) deleted: \(list)." + (keepsBuilder ? " The image builder is kept." : "")
    }

    private var deleteTitle: String {
        let count = pendingDelete?.count ?? 0
        if count == 1, let id = pendingDelete?.first {
            return "Delete \(container(id)?.name ?? id)?"
        }
        return "Delete \(count) containers?"
    }

    private var deleteMessage: String {
        let hasBuilder = (pendingDelete ?? []).contains { id in container(id).map(ContainersStore.isBuilder) ?? false }
        let base = "Running containers are stopped first. This cannot be undone."
        return hasBuilder ? "This includes the image builder. The next build starts a new one. " + base : base
    }

    /// Runs an op from the toolbar, menu or keyboard. Stopping more than one container asks once.
    private func run(_ op: ContainerOp, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        if ContainerBulk.needsConfirmation(op, count: ids.count) {
            pendingBulk = BulkRequest(op: op, ids: ids)
            return
        }
        perform(op, ids)
    }

    private func perform(_ op: ContainerOp, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        var names: [String: String] = [:]
        for item in containers { names[item.id] = item.name }
        Task {
            await ContainerOps.perform(op, ids: ids, names: names, state: state)
        }
    }

    private func reload() async {
        await feed.refresh()
    }

    private func openRunSheet() {
        state.runRequest = RunRequest(options: RunOptions(image: ""))
    }
}

/// Name cell with a small status icon.
private struct ContainerNameCell: View {
    let summary: ContainerSummary

    var body: some View {
        HStack(spacing: 8) {
            DeckIcon(.containers, size: 14, color: summary.isRunning ? DS.running : DS.stopped)
            Text(summary.name)
                .fontWeight(.medium)
                .lineLimit(1)
            if ContainersStore.isBuilder(summary) {
                Pill("Builder", tint: DS.stopped)
                    .help("Apple's image builder. Container Deck starts it for builds.")
            }
        }
        .help(summary.id == summary.name ? summary.name : "\(summary.name) (\(summary.id))")
    }
}

/// A bulk op waiting for the one confirmation.
private struct BulkRequest: Equatable {
    var op: ContainerOp
    var ids: [String]
}

/// Words for bulk confirmations.
enum ContainerBulk {
    /// Stop, restart and kill on two or more containers ask once. Start never asks.
    /// Delete has its own dialog.
    static func needsConfirmation(_ op: ContainerOp, count: Int) -> Bool {
        count > 1 && (op == .stop || op == .restart || op == .kill)
    }

    static func title(_ op: ContainerOp, count: Int) -> String {
        "\(op.title) \(count) containers?"
    }

    static func message(_ op: ContainerOp, names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        let more = names.count > 5 ? " and \(names.count - 5) more" : ""
        switch op {
        case .stop: return "These containers stop: \(shown)\(more)."
        case .restart: return "These containers stop and start again: \(shown)\(more)."
        case .kill: return "These containers are killed at once, without a clean shutdown: \(shown)\(more)."
        default: return "\(shown)\(more)."
        }
    }
}

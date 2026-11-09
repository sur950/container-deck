import SwiftUI
import AppKit
import DeckCore

extension Notification.Name {
    /// Automation only: switches the open container detail to a tab.
    static let deckDebugContainerTab = Notification.Name("deckDebugContainerTab")
}

enum ContainerDetailTab: String, CaseIterable, Identifiable {
    case overview, logs, stats, mounts, inspect, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .logs: return "Logs"
        case .stats: return "Stats"
        case .mounts: return "Mounts"
        case .inspect: return "Inspect"
        case .files: return "Files"
        }
    }
}

/// One container: header with actions and tabs for overview, logs, stats, mounts, inspect and files.
struct ContainerDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let containerID: String

    @State private var detail: ContainerDetail?
    @State private var loadError: String?
    @State private var tab: ContainerDetailTab = .overview
    @State private var confirmDelete = false
    @State private var busy: ContainerOp?
    @State private var autoStart = false
    @State private var showCommit = false

    init(containerID: String) {
        self.containerID = containerID
    }

    var body: some View {
        Group {
            if let detail {
                loaded(detail)
            } else if let loadError {
                EmptyState(icon: .error, title: "Container not found", message: loadError, actionTitle: "Back to List") {
                    dismiss()
                }
            } else {
                LoadingView("Loading container", style: .logo)
            }
        }
        .background(DS.surface)
        .navigationTitle(detail?.summary.name ?? containerID)
        // No loop: the shared feed already polls the list. Inspect again only when this
        // container's row in it changes (state, IP, ports) or something was changed in the app.
        .task(id: ReloadKey(summary: BackgroundServices.shared.container(containerID), version: state.resourcesVersion)) {
            await load()
        }
        .sheet(isPresented: $showCommit) {
            if let detail {
                CommitSheet(container: detail.summary)
                    .environment(state)
                    .tint(DS.accent)
            }
        }
        .onAppear {
            autoStart = ContainerOps.isAutoStart(containerID)
            // The Containers screen keeps a link's request until this detail is on screen.
            if state.focusedContainerID == containerID { state.focusedContainerID = nil }
        }
        // Palette and links ask for a tab through AppState (works in release builds).
        // A cold push can build this view twice and throw the first one away, so the request
        // is applied at once but only cleared by a detail that stays on screen: the task is
        // cancelled when its view goes away.
        .task(id: state.focusedContainerTab) {
            guard let focus = consumeTabFocus() else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, state.focusedContainerTab == focus { state.focusedContainerTab = nil }
        }
        .onChange(of: detail?.summary.name) { _, _ in _ = consumeTabFocus() }
        .onReceive(NotificationCenter.default.publisher(for: .deckDebugContainerTab)) { note in
            // Automation only (DebugAutomation "ctab").
            if let raw = note.object as? String, let value = ContainerDetailTab(rawValue: raw) { tab = value }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    busy = .delete
                    let ok = await ContainerOps.perform(.delete, ids: [containerID], names: [containerID: name], state: state)
                    busy = nil
                    if ok { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The container is stopped and removed. This cannot be undone.")
        }
    }

    private var name: String { detail?.summary.name ?? containerID }

    /// Switches to the tab the palette or a link asked for, when the request is for this container.
    /// Returns the request it applied.
    @discardableResult
    private func consumeTabFocus() -> ContainerTabFocus? {
        guard let focus = state.focusedContainerTab,
              let wanted = focus.tab(forContainer: containerID, name: detail?.summary.name) else { return nil }
        tab = wanted
        return focus
    }

    private struct ReloadKey: Equatable {
        var summary: ContainerSummary?
        var version: Int
    }

    private func load() async {
        guard let client = state.client else { return }
        do {
            let fresh = try await client.inspectContainer(containerID)
            if fresh != detail { detail = fresh }
            loadError = nil
        } catch is CancellationError {
            // The view went away.
        } catch {
            let message = error.localizedDescription
            // Deleted elsewhere (or removed on stop with --rm): leave the stale view.
            if detail == nil || message.lowercased().contains("not found") {
                detail = nil
                loadError = message
            }
        }
    }

    // MARK: Layout

    private func loaded(_ detail: ContainerDetail) -> some View {
        VStack(spacing: 0) {
            header(detail)
                .padding(.horizontal, Layout.pagePadding)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Picker("Section", selection: $tab) {
                ForEach(ContainerDetailTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            .padding(.horizontal, Layout.pagePadding)
            .padding(.bottom, 12)
            Divider()
            tabContent(detail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func tabContent(_ detail: ContainerDetail) -> some View {
        switch tab {
        case .overview:
            ContainerOverviewTab(detail: detail)
        case .logs:
            ContainerLogsView(containerID: containerID, isRunning: detail.summary.isRunning)
        case .stats:
            if detail.summary.isRunning {
                ContainerStatsView(containerID: containerID, isRunning: true)
            } else {
                stoppedState(icon: .stats, message: "Start the container to see live stats.")
            }
        case .mounts:
            ContainerMountsTab(detail: detail)
        case .inspect:
            ContainerInspectTab(json: detail.rawJSON, containerID: containerID)
        case .files:
            if detail.summary.isRunning {
                FileBrowserView(containerID: containerID)
            } else {
                stoppedState(icon: .files, message: "Start the container to browse its files.")
            }
        }
    }

    private func stoppedState(icon: DeckIconName, message: String) -> some View {
        EmptyState(icon: icon, title: "Container is stopped", message: message, actionTitle: "Start Container") {
            perform(.start)
        }
    }

    // MARK: Header

    private func header(_ detail: ContainerDetail) -> some View {
        let summary = detail.summary
        let tint = summary.isRunning ? DS.running : DS.stopped
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                IconBadge(.containers, tint: tint, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(summary.name)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        StatusPill(summary.state)
                        if ContainersStore.isBuilder(summary) {
                            Pill("Builder", tint: DS.stopped)
                        }
                        if detail.rosetta || summary.platform.contains("amd64") {
                            Pill("Rosetta", tint: DS.warning)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(summary.image)
                            .font(.callout)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if !summary.ports.isEmpty {
                            ContainerPortBadges(ports: summary.ports, limit: 3)
                        }
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                actionButtons(summary)
            }
            HStack(spacing: 16) {
                Toggle("Start when Container Deck opens", isOn: Binding(
                    get: { autoStart },
                    set: { value in
                        autoStart = value
                        ContainerOps.setAutoStart(containerID, value)
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)
                .fixedSize()
                Spacer(minLength: 8)
                if showHints, let client = state.client {
                    CommandHint(hintCommand(summary, client: client))
                        .frame(maxWidth: 420)
                }
            }
        }
    }

    private func hintCommand(_ summary: ContainerSummary, client: ContainerClient) -> String {
        if summary.isRunning {
            return ContainerOps.terminalCommandLine(containerID, client: client)
        }
        return ContainerOp.start.commandLine([containerID], client: client)
    }

    @ViewBuilder
    private func actionButtons(_ summary: ContainerSummary) -> some View {
        HStack(spacing: 8) {
            if busy != nil {
                ProgressView().controlSize(.small).frame(width: 18)
            }
            if summary.isRunning {
                Button {
                    ContainerOps.openTerminal(containerID, state: state)
                } label: {
                    DeckLabel("Terminal", icon: .terminal)
                }
                .help(hintFor(.terminal))
                Button {
                    perform(.stop)
                } label: {
                    DeckLabel("Stop", icon: .stop)
                }
                .help(opHelp(.stop))
                Button {
                    perform(.restart)
                } label: {
                    DeckLabel("Restart", icon: .restart)
                }
                .help(opHelp(.restart))
            } else {
                Button {
                    perform(.start)
                } label: {
                    DeckLabel("Start", icon: .play)
                }
                .deckPrimary()
                .help(opHelp(.start))
            }
            Menu {
                moreMenu(summary)
            } label: {
                DeckLabel("More", icon: .more)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            // AppKit menu buttons keep the old text color after a Light or Dark switch.
            .id(colorScheme)
        }
        .fixedSize()
        .disabled(busy != nil)
    }

    @ViewBuilder
    private func moreMenu(_ summary: ContainerSummary) -> some View {
        let links = summary.ports.compactMap { ContainerText.portURL($0) }
        if !links.isEmpty {
            ForEach(links, id: \.self) { url in
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    DeckLabel("Open \(url.absoluteString)", icon: .openExternal)
                }
            }
            Divider()
        }
        if summary.isRunning {
            Button {
                perform(.kill)
            } label: {
                DeckLabel("Kill", icon: .kill)
            }
        }
        Button {
            Task { await ContainerOps.exportFilesystem(containerID, name: summary.name, state: state) }
        } label: {
            DeckLabel("Export File System…", icon: .export)
        }
        Button {
            Task { await ContainerOps.editAndRecreate(containerID, state: state) }
        } label: {
            DeckLabel("Edit and Recreate…", icon: .edit)
        }
        if CommitSheet.isSupported(state) {
            Button {
                showCommit = true
            } label: {
                DeckLabel("Commit to Image…", icon: .layers)
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary.name, forType: .string)
        } label: {
            DeckLabel("Copy Name", icon: .copy)
        }
        Divider()
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            DeckLabel("Delete…", icon: .trash)
        }
    }

    private enum HintKind { case terminal }

    private func hintFor(_ kind: HintKind) -> String {
        guard showHints, let client = state.client else { return "Open a shell in \(Prefs.terminalApp.title)" }
        return ContainerOps.terminalCommandLine(containerID, client: client)
    }

    private func opHelp(_ op: ContainerOp) -> String {
        guard showHints, let client = state.client else { return op.title }
        return op.commandLine([containerID], client: client)
    }

    private func perform(_ op: ContainerOp) {
        Task {
            busy = op
            await ContainerOps.perform(op, ids: [containerID], names: [containerID: name], state: state)
            busy = nil
            await load()
        }
    }
}

// MARK: - Overview

/// Image, command, resources, network, ports, mounts, env and labels.
/// Cards sit in rows of two with the same height, environment gets the full width.
struct ContainerOverviewTab: View {
    @Environment(AppState.self) private var state
    let detail: ContainerDetail
    @State private var preparing = false

    init(detail: ContainerDetail) {
        self.detail = detail
    }

    private var summary: ContainerSummary { detail.summary }

    var body: some View {
        DeckPage {
            if let shell = BareShell.quickExitShell(detail) {
                quickExitCard(shell)
            }
            EqualHeightRow {
                generalCard
                networkCard
            }
            EqualHeightRow {
                resourcesCard
                portsCard
            }
            EqualHeightRow {
                mountsCard
                labelsCard
            }
            envCard
        }
    }

    /// Shown when the container ran a bare shell with no terminal and stopped at once.
    private func quickExitCard(_ shell: String) -> some View {
        Card {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(.warning, tint: DS.warning, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("This container ran \(shell) without a terminal, so it stopped right away.")
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Keep It Running makes it again with the command sleep infinity. Then Terminal opens a shell in it.")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if preparing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task {
                        preparing = true
                        await ContainerOps.keepRunning(summary.id, shell: shell, state: state)
                        preparing = false
                    }
                } label: {
                    DeckLabel("Keep It Running", icon: .play)
                }
                .deckPrimary()
                .disabled(preparing)
                .help("Recreates it with the command sleep infinity. Volumes are kept.")
            }
        }
    }

    private var generalCard: some View {
        Card("Container", icon: .containers) {
            VStack(alignment: .leading, spacing: 0) {
                KeyValueRow("Image", value: summary.image, copyable: true)
                KeyValueRow("Command") {
                    Text(processText)
                        .font(processText == "Image default" ? Font.callout : Font.callout.monospaced())
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                KeyValueRow("Working folder", value: detail.workingDir ?? "Image default", monospaced: detail.workingDir != nil)
                KeyValueRow("Created", value: date(summary.createdAt) ?? "Unknown")
                KeyValueRow("Started", value: summary.isRunning ? (date(summary.startedAt) ?? "Unknown") : "Not running")
                KeyValueRow("ID", value: summary.id, monospaced: true, copyable: true)
            }
        }
    }

    private func date(_ value: Date?) -> String? {
        value.map { $0.formatted(date: .abbreviated, time: .shortened) }
    }

    private var processText: String {
        var parts = detail.entrypoint
        if !summary.command.starts(with: detail.entrypoint) || detail.entrypoint.isEmpty {
            parts += summary.command
        } else {
            parts = summary.command
        }
        return parts.isEmpty ? "Image default" : ContainerText.shellJoin(parts)
    }

    private var resourcesCard: some View {
        Card("Resources", icon: .cpu) {
            VStack(alignment: .leading, spacing: 0) {
                KeyValueRow("CPUs", value: summary.cpus.map { "\($0)" } ?? "Default")
                KeyValueRow("Memory", value: summary.memoryBytes.map { Format.bytes($0) } ?? "Default")
                KeyValueRow("Platform", value: summary.platform + (detail.rosetta ? " (Rosetta)" : ""))
            }
        }
    }

    private var networkCard: some View {
        Card("Network", icon: .network) {
            if detail.networks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    KeyValueRow("IP address", value: summary.ipAddress ?? "None", monospaced: summary.ipAddress != nil, copyable: summary.ipAddress != nil)
                    KeyValueRow("Hostname", value: summary.hostname ?? "None")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(detail.networks.enumerated()), id: \.offset) { index, net in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 0) {
                            KeyValueRow("Network", value: net.network)
                            KeyValueRow("IP address", value: net.ipAddress ?? "None", monospaced: net.ipAddress != nil, copyable: net.ipAddress != nil)
                            KeyValueRow("Gateway", value: net.gateway ?? "None", monospaced: net.gateway != nil)
                            KeyValueRow("MAC address", value: net.macAddress ?? "None", monospaced: net.macAddress != nil)
                            KeyValueRow("Hostname", value: net.hostname ?? summary.hostname ?? "None")
                        }
                    }
                }
            }
        }
    }

    private var portsCard: some View {
        Card("Ports", icon: .port) {
            if summary.ports.isEmpty {
                CardEmptyText("No published ports")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(summary.ports.enumerated()), id: \.offset) { _, port in
                        HStack(spacing: 8) {
                            Text(verbatim: "\(port.hostAddress ?? "0.0.0.0"):\(port.hostPort)")
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            DeckIcon(.chevronRight, size: 10, color: DS.textTertiary)
                            Text(verbatim: "\(port.containerPort)/\(port.proto)")
                                .font(.callout.monospaced())
                                .foregroundStyle(DS.textSecondary)
                            Spacer(minLength: 8)
                            if let url = ContainerText.portURL(port) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    DeckLabel("Open", icon: .openExternal)
                                }
                                .controlSize(.small)
                                .help(url.absoluteString)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var mountsCard: some View {
        Card("Mounts", icon: .volumes) {
            if detail.mounts.isEmpty {
                CardEmptyText("No mounts")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(detail.mounts.enumerated()), id: \.offset) { _, mount in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(mount.destination)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer(minLength: 6)
                                Pill(mount.type.capitalized, tint: DS.stopped)
                                if mount.readOnly { Pill("Read only", tint: DS.warning) }
                            }
                            Text(mount.source)
                                .font(.caption.monospaced())
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var envCard: some View {
        Card("Environment", icon: .settings) {
            if detail.env.isEmpty {
                CardEmptyText("No variables")
            } else {
                ContainerInfoGrid(rows: detail.env.map { ($0.key, $0.value) }, monospaced: true)
            }
        }
    }

    private var labelsCard: some View {
        Card("Labels", icon: .tag) {
            if summary.labels.isEmpty {
                CardEmptyText("No labels")
            } else {
                ContainerInfoGrid(
                    rows: summary.labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                    monospaced: true
                )
            }
        }
    }
}

/// Label and value rows in a two column grid. Used for env and labels, where keys vary in length.
struct ContainerInfoGrid: View {
    let rows: [(String, String)]
    var monospaced: Bool

    init(rows: [(String, String)], monospaced: Bool = false) {
        self.rows = rows
        self.monospaced = monospaced
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .font(monospaced ? Font.callout.monospaced() : Font.callout)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .gridColumnAlignment(.leading)
                        .textSelection(.enabled)
                    Text(row.1.isEmpty ? " " : row.1)
                        .font(monospaced ? Font.callout.monospaced() : Font.callout)
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Inspect

/// Raw `container inspect` JSON with a copy button.
struct ContainerInspectTab: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let json: String
    var containerID: String

    init(json: String, containerID: String = "") {
        self.json = json
        self.containerID = containerID
    }

    var body: some View {
        VStack(spacing: 0) {
            ContainerTabBar {
                if showHints, let client = state.client, !containerID.isEmpty {
                    CommandHint(client.commandLine(["inspect", containerID]))
                        .frame(maxWidth: 360)
                }
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                    state.showToast("Copied inspect output", style: .success)
                } label: {
                    DeckLabel("Copy JSON", icon: .copy)
                }
                .help("Copy the JSON")
                .disabled(json.isEmpty)
            }
            if json.isEmpty {
                EmptyState(icon: .inspect, title: "No data", message: "The container did not report any details.")
            } else {
                GeometryReader { geo in
                    // Two way scroll views center narrow content. The min frame keeps it top left.
                    ScrollView([.vertical, .horizontal]) {
                        Text(json)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(DS.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.horizontal, Layout.pagePadding)
                            .padding(.vertical, 16)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                .background(DS.surfaceSunken)
            }
        }
    }
}

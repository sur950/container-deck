import SwiftUI
import AppKit
import DeckCore

/// Every image build: from this screen, the Build sheet and Compose.
/// Live logs, cancel, history across restarts, builder status and cache.
struct BuildsScreen: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.buildsHistoryLimit) private var historyLimit = BuildsConfig.defaultHistoryLimit
    @AppStorage("buildsDetailWidth") private var detailWidth: Double = 420

    @State private var selection: BuildRecord.ID?
    @State private var search = ""
    @State private var filter: BuildsFilter = .all
    @State private var sortOrder = [KeyPathComparator(\BuildRecord.startedAt, order: .reverse)]
    @State private var sheet: BuildsSheet?
    @State private var builder = BuilderModel()
    @State private var showPrune = false
    @State private var showClear = false
    @FocusState private var tableFocused: Bool

    private var store: BuildsStore { BuildsStore.shared }

    var body: some View {
        content
            .navigationTitle(SidebarItem.builds.title)
            .searchable(text: $search, placement: .toolbar, prompt: "Search builds")
            .toolbar { toolbarContent }
            .background(DS.surface, ignoresSafeAreaEdges: [])
            .onAppear {
                store.attach(state)
                if selection == nil { selection = store.records.first?.id }
            }
            .task(id: state.resourcesVersion) { await builder.load(state.client, cache: true) }
            .autoRefresh { await builder.load(state.client, cache: false) }
            .onChange(of: store.runningCount) { old, new in
                // A build finished: the cache grew.
                if new < old { Task { await builder.load(state.client, cache: true) } }
            }
            .onChange(of: historyLimit) { _, _ in store.applyHistoryLimit() }
            .sheet(item: $sheet) { item in
                BuildSheet(request: BuildRequest(contextDir: item.spec?.contextDir), prefill: item.spec, startsInBackground: true) { id in
                    selection = id
                }
                .environment(state)
            }
            .confirmationDialog("Clear the build cache?", isPresented: $showPrune, titleVisibility: .visible) {
                Button("Clear Unused Cache") { prune(all: false) }
                Button("Clear All Cache", role: .destructive) { prune(all: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Builds after this take longer, because every step runs again. Images are kept.")
            }
            .confirmDelete(isPresented: $showClear, title: "Clear build history?",
                           message: "Finished builds and their logs are removed from this list. Images are kept.",
                           actionTitle: "Clear") {
                store.clearFinished()
                selection = store.records.first?.id
            }
            .onDeckDebugCommand { name, value in
                guard name == "builds" else { return }
                switch value {
                case "new": sheet = BuildsSheet(spec: nil)
                case "first": selection = store.records.first?.id
                case "second": selection = store.records.dropFirst().first?.id
                case "prune": showPrune = true
                case "details": NotificationCenter.default.post(name: .buildsDetailTab, object: "details")
                case "log": NotificationCenter.default.post(name: .buildsDetailTab, object: "log")
                case "cancel": if let id = selection { store.cancel(id) }
                default:
                    // "run=<folder>,<tag>,<platform>" starts a build (automation only).
                    guard value.hasPrefix("run="), let client = state.client else { return }
                    let parts = value.dropFirst(4).split(separator: ",").map(String.init)
                    guard parts.count >= 2 else { return }
                    let options = BuildOptions(contextDir: parts[0], tags: [parts[1]], platform: parts.count > 2 ? parts[2] : "linux/arm64")
                    selection = store.start(options, client: client)
                }
            }
    }

    // MARK: - Layout

    @ViewBuilder
    private var content: some View {
        if state.client == nil {
            ResourceToolMissing(icon: .builds)
        } else {
            VStack(spacing: 0) {
                BuilderStrip(builder: builder, records: store.records, historyLimit: historyLimit,
                             onStart: startBuilder, onStop: stopBuilder, onPrune: { showPrune = true },
                             onNew: { sheet = BuildsSheet(spec: nil) })
                    .padding(.horizontal, Layout.pagePadding)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                Divider()
                if store.records.isEmpty {
                    EmptyState(
                        icon: .builds,
                        title: "No builds yet",
                        message: "Builds from this screen, the Images screen and Compose show here with their logs.",
                        actionTitle: "New Build"
                    ) {
                        sheet = BuildsSheet(spec: nil)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    split
                }
            }
        }
    }

    private var split: some View {
        GeometryReader { geo in
            let detail = clampedDetailWidth(total: geo.size.width)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    table
                    footer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                BuildsSplitHandle(width: $detailWidth, total: geo.size.width, minList: Self.minListWidth, range: Self.detailRange)
                Group {
                    if let record = store.record(selection) {
                        BuildDetailPane(record: record, onRebuild: rebuild, onEdit: { sheet = BuildsSheet(spec: record.spec) })
                            .id(record.id)
                    } else {
                        EmptyState(icon: .builds, title: "No build selected", message: "Pick a build to see its log and details.")
                    }
                }
                .frame(width: detail)
                .frame(maxHeight: .infinity)
                .background(DS.surface, ignoresSafeAreaEdges: [])
            }
        }
    }

    /// Every column at its minimum, with cell spacing and the leading inset, so none is cut.
    static let minListWidth: CGFloat = 650
    static let detailRange: ClosedRange<CGFloat> = 360...720

    private func clampedDetailWidth(total: CGFloat) -> CGFloat {
        let room = total - Self.minListWidth - 1
        let upper = max(Self.detailRange.lowerBound, min(Self.detailRange.upperBound, room))
        return min(max(detailWidth, Self.detailRange.lowerBound), upper)
    }

    private var table: some View {
        Table(visibleRecords, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Image", value: \.title) { record in
                BuildNameCell(record: record)
            }
            .width(min: 170, ideal: 170)

            TableColumn("Status", value: \.status.rawValue) { record in
                BuildStatusLabel(record: record)
            }
            .width(min: 96, ideal: 96)

            TableColumn("Platform", value: \.spec.platform) { record in
                Text(record.spec.shortPlatform).deckSecondaryText()
            }
            .width(min: 62, ideal: 62)

            TableColumn("From", value: \.origin.rawValue) { record in
                Text(BuildText.origin(record)).deckSecondaryText().lineLimit(1)
            }
            .width(min: 70, ideal: 70)

            TableColumn("Started", value: \.startedAt) { record in
                Text(BuildText.started(record.startedAt)).deckSecondaryText()
            }
            .width(min: 70, ideal: 70)

            TableColumn("Time") { record in
                BuildDurationText(record: record).deckSecondaryText()
            }
            .width(min: 56, ideal: 56)
        }
        .scrollContentBackground(.hidden)
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .focused($tableFocused)
        .onAppear { tableFocused = true }
        .contextMenu(forSelectionType: BuildRecord.ID.self) { ids in
            if let id = ids.first, let record = store.record(id) {
                rowMenu(record)
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }

    private var footer: some View {
        ListStatusBar(summaryText) {
            SegmentedFilter(selection: $filter, options: BuildsFilter.allCases, label: { $0.title }, count: { count(for: $0) })
        }
    }

    @ViewBuilder
    private func rowMenu(_ record: BuildRecord) -> some View {
        if record.status == .running {
            Button { store.cancel(record.id) } label: { DeckLabel("Stop Build", icon: .stop) }
        } else {
            if record.status == .succeeded, let tag = record.spec.tags.first {
                Button { BuildActions.run(record, state: state) } label: { DeckLabel("Run", icon: .play) }
                Button { BuildActions.openImage(tag, state: state) } label: { DeckLabel("Show Image", icon: .images) }
            }
            Button { rebuild(record) } label: { DeckLabel("Rebuild", icon: .restart) }
            Button { sheet = BuildsSheet(spec: record.spec) } label: { DeckLabel("Edit and Rebuild…", icon: .edit) }
        }
        Button { ResourceUsage.revealInFinder(record.spec.contextDir) } label: { DeckLabel("Show Folder", icon: .folder) }
        if let client = state.client {
            Button { ResourceUsage.copyToPasteboard(client.commandLine(client.buildArguments(record.spec.options))) } label: {
                DeckLabel("Copy Command", icon: .copy)
            }
        }
        if record.status.isFinished {
            Divider()
            Button(role: .destructive) { remove(record) } label: { DeckLabel("Remove from List", icon: .trash) }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                sheet = BuildsSheet(spec: nil)
            } label: {
                DeckLabel("New Build", icon: .build)
            }
            .help("Build an image from a Dockerfile")

            Menu {
                Picker("Keep", selection: $historyLimit) {
                    ForEach(BuildsConfig.historyLimitChoices, id: \.self) { value in
                        Text("Last \(value) builds").tag(value)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Clear Finished Builds…") { showClear = true }
                    .disabled(!store.records.contains { $0.status.isFinished })
            } label: {
                DeckLabel("History", icon: .clock)
            }
            .help("How many builds to keep")

            RefreshButton(help: "Reload the builder status", isBusy: builder.isLoading) {
                store.refresh()
                await builder.load(state.client, cache: true)
            }
        }
    }

    // MARK: - Values

    private var visibleRecords: [BuildRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.records
            .filter { filter.matches($0) }
            .filter { record in
                query.isEmpty
                    || record.spec.tags.contains { $0.lowercased().contains(query) }
                    || record.spec.contextDir.lowercased().contains(query)
                    || (record.originDetail ?? "").lowercased().contains(query)
            }
            .sorted(using: sortOrder)
    }

    private func count(for filter: BuildsFilter) -> Int? {
        store.records.filter { filter.matches($0) }.count
    }

    private var summaryText: String {
        let total = store.records.count
        let running = store.runningCount
        var text = total == 1 ? "1 build" : "\(total) builds"
        if running > 0 { text += ", \(running) running" }
        return text
    }

    // MARK: - Actions

    private func rebuild(_ record: BuildRecord) {
        guard let client = state.client else { return }
        selection = store.rebuild(record, client: client)
    }

    private func remove(_ record: BuildRecord) {
        let index = visibleRecords.firstIndex { $0.id == record.id }
        store.remove([record.id])
        if selection == record.id {
            let rest = visibleRecords
            if let index, !rest.isEmpty {
                selection = rest[min(index, rest.count - 1)].id
            } else {
                selection = nil
            }
        }
    }

    private func startBuilder() {
        guard let client = state.client else { return }
        Task {
            do {
                builder.isChanging = true
                try await client.startBuilder()
                builder.isChanging = false
                await builder.load(client, cache: true)
                state.showToast("Builder started", style: .success)
            } catch {
                builder.isChanging = false
                state.showError(error)
            }
        }
    }

    private func stopBuilder() {
        guard let client = state.client else { return }
        if store.runningCount > 0 {
            state.showToast("Builds are running. Stop them first.", style: .error)
            return
        }
        Task {
            do {
                builder.isChanging = true
                try await client.stopBuilder()
                builder.isChanging = false
                await builder.load(client, cache: false)
                state.showToast("Builder stopped", style: .success)
            } catch {
                builder.isChanging = false
                state.showError(error)
            }
        }
    }

    private func prune(all: Bool) {
        guard let client = state.client else { return }
        let before = builder.cache?.totalBytes
        Task {
            do {
                builder.isPruning = true
                try await client.pruneBuilderCache(all: all)
                builder.isPruning = false
                await builder.load(client, cache: true)
                let after = builder.cache?.totalBytes ?? 0
                if let before, before > after {
                    state.showToast("Freed \(Format.bytes(before - after))", style: .success)
                } else {
                    state.showToast("Build cache cleared", style: .success)
                }
            } catch {
                builder.isPruning = false
                state.showError(error)
            }
        }
    }
}

extension Notification.Name {
    /// Automation only: switch the build detail tab.
    static let buildsDetailTab = Notification.Name("BuildsDetailTab")
}

/// The sheet the Builds screen opens: a new build, or a copy of an old one to edit.
struct BuildsSheet: Identifiable {
    let id = UUID()
    var spec: BuildSpec?
}

enum BuildsFilter: String, CaseIterable, Hashable {
    case all, running, failed

    var title: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .failed: return "Failed"
        }
    }

    func matches(_ record: BuildRecord) -> Bool {
        switch self {
        case .all: return true
        case .running: return record.status == .running
        case .failed: return record.status == .failed
        }
    }
}

// MARK: - Builder state

/// Builder status and cache size, loaded through ContainerClient.
@MainActor
@Observable
final class BuilderModel {
    var status: BuilderStatus?
    var cache: BuildCacheUsage?
    var statusError: String?
    var cacheError: String?
    var isLoading = false
    var isChanging = false
    var isPruning = false
    /// Only the newest load writes its result.
    @ObservationIgnored private var loadID = 0

    private func isCurrent(_ ticket: Int) -> Bool { ticket == loadID }

    func load(_ client: ContainerClient?, cache withCache: Bool) async {
        guard let client else { return }
        loadID += 1
        let ticket = loadID
        isLoading = true
        defer { if isCurrent(ticket) { isLoading = false } }
        do {
            let fresh = try await client.builderStatus()
            guard isCurrent(ticket) else { return }
            if fresh != status { status = fresh }
            statusError = nil
            if !fresh.isRunning {
                cache = nil
                cacheError = nil
                return
            }
        } catch {
            guard isCurrent(ticket) else { return }
            statusError = error.localizedDescription
            return
        }
        guard withCache || cache == nil else { return }
        do {
            let usage = try await client.builderCacheUsage(builderID: status?.id ?? BuildsConfig.builderContainerID)
            guard isCurrent(ticket) else { return }
            if usage != cache { cache = usage }
            cacheError = nil
        } catch {
            guard isCurrent(ticket) else { return }
            cacheError = error.localizedDescription
        }
    }
}

// MARK: - Top strip

/// Builder, cache and history at a glance, each with its main action.
private struct BuilderStrip: View {
    let builder: BuilderModel
    let records: [BuildRecord]
    let historyLimit: Int
    let onStart: () -> Void
    let onStop: () -> Void
    let onPrune: () -> Void
    let onNew: () -> Void

    var body: some View {
        EqualHeightRow {
            BuildsTile(title: "Builder", value: builderValue, subtitle: builderSubtitle, icon: .build, tint: builderTint) {
                if builder.isChanging {
                    ProgressView().controlSize(.small)
                } else if builder.status?.isRunning == true {
                    Button("Stop", action: onStop)
                        .help("Stop the BuildKit builder. The next build starts it again.")
                } else {
                    Button("Start", action: onStart)
                        .help("Start the BuildKit builder")
                }
            }
            BuildsTile(title: "Build Cache", value: cacheValue, subtitle: cacheSubtitle, icon: .disk) {
                if builder.isPruning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Clear…", action: onPrune)
                        .disabled(builder.status?.isRunning != true)
                        .help("Remove cached build steps")
                }
            }
            BuildsTile(title: "Builds", value: buildsValue, subtitle: "Keeping the last \(historyLimit)", icon: .builds) {
                Button(action: onNew) { DeckLabel("New Build", icon: .add) }
                    .deckPrimary()
            }
        }
    }

    private var builderValue: String {
        guard let status = builder.status else { return builder.statusError == nil ? "Checking" : "Unknown" }
        switch status.state {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .stopping: return "Stopping"
        case .notCreated: return "Not started"
        case .unknown: return "Unknown"
        }
    }

    private var builderTint: Color {
        switch builder.status?.state {
        case .running: return DS.running
        case .stopping: return DS.warning
        default: return DS.accent
        }
    }

    private var builderSubtitle: String {
        if let error = builder.statusError { return error }
        guard let status = builder.status else { return " " }
        if status.state == .notCreated { return "Starts with the first build" }
        var parts: [String] = []
        if let cpus = status.cpus { parts.append(cpus == 1 ? "1 CPU" : "\(cpus) CPUs") }
        if let memory = status.memoryBytes { parts.append(Format.bytes(memory)) }
        if status.rosetta == true { parts.append("amd64 ready") }
        return parts.isEmpty ? (status.shortImage ?? " ") : parts.joined(separator: ", ")
    }

    private var cacheValue: String {
        if let cache = builder.cache { return Format.bytes(cache.totalBytes) }
        if builder.status?.isRunning == false { return "-" }
        return builder.cacheError == nil ? "…" : "Unknown"
    }

    private var cacheSubtitle: String {
        if builder.status?.isRunning == false { return "Start the builder to see it" }
        if let error = builder.cacheError { return error }
        guard let cache = builder.cache else { return " " }
        let entries = cache.entries == 1 ? "1 entry" : "\(cache.entries) entries"
        return "\(entries), \(Format.bytes(cache.reclaimableBytes)) can be freed"
    }

    private var buildsValue: String {
        let running = records.filter { $0.status == .running }.count
        if running > 0 { return "\(running) running" }
        return "\(records.count)"
    }
}

/// A metric tile with one action on the right of its value.
private struct BuildsTile<Action: View>: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: DeckIconName
    var tint: Color = DS.accent
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                IconBadge(icon, tint: tint, size: 26)
            }
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(subtitle)
                }
                Spacer(minLength: 8)
                action
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .deckCard()
    }
}

// MARK: - Cells

private struct BuildNameCell: View {
    let record: BuildRecord

    var body: some View {
        HStack(spacing: 6) {
            Text(record.title)
                .deckPrimaryText()
                .lineLimit(1)
                .truncationMode(.middle)
            if record.spec.tags.count > 1 {
                Text("+\(record.spec.tags.count - 1)")
                    .deckTertiaryText()
                    .help(record.spec.tags.dropFirst().joined(separator: ", "))
            }
        }
        .help(record.spec.tags.joined(separator: ", "))
    }
}

/// Icon and word for a build state. Running builds show the step.
struct BuildStatusLabel: View {
    let record: BuildRecord

    var body: some View {
        HStack(spacing: 6) {
            if record.status == .running {
                ProgressView().controlSize(.mini)
            } else {
                DeckIcon(BuildText.icon(record.status), size: 12, color: BuildText.tint(record.status))
            }
            Text(text).lineLimit(1)
        }
        .help(record.message ?? record.lastStep ?? record.status.title)
    }

    private var text: String {
        if record.status == .running, let index = record.stepIndex, let count = record.stepCount {
            return "\(index) of \(count)"
        }
        return record.status.title
    }
}

/// Elapsed time. Ticks once a second while the build runs.
struct BuildDurationText: View {
    let record: BuildRecord

    var body: some View {
        if record.status == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(BuildText.duration(record.duration(now: context.date))).monospacedDigit()
            }
        } else {
            Text(BuildText.duration(record.duration())).monospacedDigit()
        }
    }
}

// MARK: - Shared text and actions

enum BuildText {
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        let rest = total % 60
        if minutes < 60 { return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "Just now" for the first seconds, so a fresh build never reads "in 0s".
    static func started(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 5 ? "Just now" : Format.relative(date)
    }

    static func origin(_ record: BuildRecord) -> String {
        if record.origin == .compose, let detail = record.originDetail { return "Compose, \(detail)" }
        return record.origin.title
    }

    static func icon(_ status: BuildStatus) -> DeckIconName {
        switch status {
        case .running: return .waiting
        case .succeeded: return .success
        case .failed: return .error
        case .cancelled: return .stop
        case .interrupted: return .warning
        }
    }

    static func tint(_ status: BuildStatus) -> Color {
        switch status {
        case .running: return DS.accent
        case .succeeded: return DS.running
        case .failed: return DS.danger
        case .cancelled: return DS.stopped
        case .interrupted: return DS.warning
        }
    }
}

@MainActor
enum BuildActions {
    /// Opens the Run sheet. amd64 builds run as amd64.
    static func run(_ record: BuildRecord, state: AppState) {
        guard let tag = record.spec.tags.first else { return }
        let platform = record.spec.platform == ImagePlatform.host ? nil : record.spec.platform
        state.runRequest = RunRequest(options: RunOptions(image: tag, platform: platform))
    }

    /// Goes to the image, the same way a containerdeck://image link does.
    static func openImage(_ reference: String, state: AppState) {
        DeepLinkRouter.route(.image(reference), state: state)
    }

    /// Containers made from any tag of this build.
    static func users(of record: BuildRecord, in containers: [ContainerSummary]) -> [ContainerSummary] {
        guard record.status == .succeeded else { return [] }
        return containers.filter { container in
            record.spec.tags.contains { ImageRefMatch.same($0, container.image) }
        }
    }
}

/// Thin divider you can drag to resize the detail pane.
struct BuildsSplitHandle: View {
    @Binding var width: Double
    let total: CGFloat
    let minList: CGFloat
    let range: ClosedRange<CGFloat>
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
                                let proposed = start - value.translation.width
                                let upper = max(Double(range.lowerBound), min(Double(range.upperBound), Double(total - minList - 1)))
                                width = min(max(proposed, Double(range.lowerBound)), upper)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

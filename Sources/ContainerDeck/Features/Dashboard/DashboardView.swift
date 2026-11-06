import SwiftUI
import Charts
import DeckCore

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var model = DashboardModel()
    @State private var checksExpandedChoice: Bool?
    @State private var showFreeUpSpace = false
    @State private var contentWidth: CGFloat = 900
    @AppStorage(PrefKey.dashboardRange) private var rangeRaw = StatsHistoryRange.fifteenMinutes.rawValue
    @AppStorage(PrefKey.agentsTab) private var agentsTabRaw = AgentsTab.servers.rawValue

    private var history: StatsHistoryRecorder { StatsHistoryRecorder.shared }
    private var range: StatsHistoryRange { StatsHistoryRange(rawValue: rangeRaw) ?? .fifteenMinutes }

    /// Seconds a model server check stays good for the AI Models tile.
    private static let aiMaxAge: Double = 30

    /// Below this width the Activity and Disk cards stack.
    private static let twoColumnWidth: CGFloat = 720

    var body: some View {
        ScrollViewReader { proxy in
        DeckPage {
            platformCard
                .id("dash-top")
            if let error = state.lastError {
                ErrorNote(message: error)
            }
            tiles
            if contentWidth >= Self.twoColumnWidth {
                EqualHeightRow {
                    activityCard
                    diskCard
                }
                EqualHeightRow {
                    networkCard
                    diskActivityCard
                }
            } else {
                activityCard
                diskCard
                networkCard
                diskActivityCard
            }
            runningCard
            checksCard
                .id("dash-bottom")
        }
        .onDeckDebugCommand { name, value in
            // Automation only: dash-scroll:bottom or dash-scroll:top.
            guard name == "dash-scroll" else { return }
            if value == "top" {
                proxy.scrollTo("dash-top", anchor: .top)
            } else {
                proxy.scrollTo("dash-bottom", anchor: .bottom)
            }
        }
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem {
                RefreshButton(help: "Check the platform again and reload", isBusy: state.isChecking) {
                    await state.refresh()
                    async let counts: Void = model.load(client: state.client)
                    async let list: Void = BackgroundServices.shared.refresh()
                    _ = await (counts, list)
                }
            }
        }
        // Containers and stats come from the shared feed and sampler. Counts reload when
        // something changed in the app, and when the app comes back to the front.
        .usesLiveStats("dashboard")
        .task(id: loadKey) {
            await model.load(client: state.client)
        }
        // The AI Models tile reuses the AI screen's discovery. A recent result is kept, and
        // the check pauses while the window is hidden.
        .task { await AIModelsStore.shared.discoverIfStale(maxAge: Self.aiMaxAge) }
        .autoRefresh(every: Self.aiMaxAge) {
            await AIModelsStore.shared.discoverIfStale(maxAge: Self.aiMaxAge - 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.load(client: state.client) }
        }
        .sheet(isPresented: $showFreeUpSpace) {
            FreeUpSpaceSheet(usage: model.usage)
        }
        .task { StatsHistoryRecorder.shared.start() }
        .onDeckDebugCommand { name, value in
            switch name {
            case "dash-range": rangeRaw = value
            case "free-space": showFreeUpSpace = true
            case "logs-window":
                LogsWindow.open(state: state, containerIDs: value.split(separator: ",").map(String.init))
            default: break
            }
        }
    }

    private var loadKey: String {
        "\(state.resourcesVersion)|\(state.report.cliPath ?? "")|\(state.report.serviceRunning)"
    }

    // MARK: Platform

    private var platformCard: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                LogoBadge(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Container platform").font(.headline)
                        serviceBadge
                    }
                    Text(versionLine)
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                    if let path = state.report.cliPath {
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(DS.textTertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 12)
                serviceControl
            }
        }
    }

    @ViewBuilder
    private var serviceBadge: some View {
        if state.report.cliPath == nil {
            Pill("Not installed", tint: DS.warning)
        } else if state.report.serviceRunning {
            Pill("Running", tint: DS.running)
        } else {
            Pill("Stopped", tint: DS.stopped)
        }
    }

    private var versionLine: String {
        guard state.report.cliPath != nil else { return "Apple's container tool is not installed yet." }
        let version = state.report.cliVersion.map { "Version \($0)" } ?? "Version unknown"
        let service = state.report.serviceRunning ? "service running" : "service stopped"
        return "\(version), \(service)"
    }

    @ViewBuilder
    private var serviceControl: some View {
        Group {
            if state.report.cliPath == nil {
                Button("Set Up") { state.showSetup = true }
                    .deckPrimary()
            } else if state.busyFix == .startService {
                ProgressView().controlSize(.small)
            } else if state.report.serviceRunning {
                Button {
                    Task { await state.stopService() }
                } label: {
                    DeckLabel("Stop Service", icon: .stop)
                }
            } else {
                Button {
                    Task { await state.fix(.startService) }
                } label: {
                    DeckLabel("Start Service", icon: .play)
                }
                .deckPrimary()
            }
        }
        .controlSize(.large)
    }

    // MARK: Tiles

    private static let tileCount = 6

    private var tileColumns: [GridItem] {
        let count = DashboardFormat.tileColumns(width: contentWidth, tiles: Self.tileCount)
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    private var ai: AIModelsStore { AIModelsStore.shared }

    private var tiles: some View {
        let ready = state.client != nil
        let counts = model.counts
        return LazyVGrid(columns: tileColumns, spacing: 12) {
            tileButton(.containers) {
                MetricTile(
                    title: "Containers",
                    value: ready ? DashboardCounts.count(counts.containersRunning) : "-",
                    subtitle: ready ? counts.containersSubtitle : nil,
                    icon: .containers,
                    tint: DS.running
                )
            }
            tileButton(.kubernetes) {
                MetricTile(
                    title: "Kubernetes",
                    value: ready ? DashboardCounts.count(counts.clustersRunning) : "-",
                    subtitle: ready ? counts.kubernetesSubtitle : nil,
                    icon: .kubernetes
                )
            }
            tileButton(.aiModels) {
                let aiReady = ai.hasDiscovered
                MetricPairTile(
                    title: "AI and MCP",
                    leading: (aiReady ? DashboardCounts.count(DashboardCounts.aiCounts(ai.endpoints).servers) : "-",
                              aiReady && DashboardCounts.aiCounts(ai.endpoints).servers == 1 ? "Server" : "Servers"),
                    trailing: (ready ? DashboardCounts.count(counts.mcpRunning) : "-", "MCP"),
                    subtitle: aiReady ? DashboardCounts.aiSubtitle(ai.endpoints) : nil,
                    icon: .aiModels,
                    trailingHelp: "Open MCP servers",
                    trailingAction: {
                        agentsTabRaw = AgentsTab.servers.rawValue
                        state.selection = .agents
                    }
                )
            }
            tileButton(.sandboxes) {
                MetricTile(
                    title: "Sandboxes",
                    value: ready ? DashboardCounts.count(counts.sandboxesRunning) : "-",
                    subtitle: ready ? counts.sandboxesSubtitle : nil,
                    icon: .sandboxes
                )
            }
            tileButton(.machines) {
                MetricTile(
                    title: "Machines",
                    value: model.machines.map { DashboardCounts.count(DashboardCounts.machineCounts($0).running) } ?? "-",
                    subtitle: model.machines.map(DashboardCounts.machinesSubtitle),
                    icon: .machines
                )
            }
            MetricTile(
                title: "Disk used",
                value: model.usage.map { DashboardFormat.bytes($0.totalBytes) } ?? "-",
                subtitle: model.usage.map { usage in
                    usage.reclaimableBytes > 0 ? "\(DashboardFormat.bytes(usage.reclaimableBytes)) can be freed" : "Nothing to free"
                },
                icon: .disk
            )
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if width > 0 { contentWidth = width }
        }
    }

    private func tileButton<Content: View>(_ item: SidebarItem, @ViewBuilder content: () -> Content) -> some View {
        Button {
            state.selection = item
        } label: {
            content()
                .contentShape(RoundedRectangle(cornerRadius: DS.radius))
        }
        .buttonStyle(.plain)
        .help("Open \(item.title)")
    }

    // MARK: Activity

    /// Card with a title row and controls on the right.
    private func chartCard<Trailing: View, Content: View>(_ title: String, icon: DeckIconName,
                                                          @ViewBuilder trailing: () -> Trailing,
                                                          @ViewBuilder content: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(icon, size: 26)
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    trailing()
                }
                content()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var rangePicker: some View {
        SegmentedFilter(
            selection: Binding(get: { range }, set: { rangeRaw = $0.rawValue }),
            options: StatsHistoryRange.allCases,
            label: { $0.title }
        )
        .help("Time window for the charts")
    }

    /// History totals for the picked window. Read once per body.
    private func totals(now: Date) -> [StatsPoint] {
        history.totals(range: range, now: now)
    }

    private var activityCard: some View {
        chartCard("Activity", icon: .stats) {
            if state.client != nil { rangePicker }
        } content: {
            if state.client == nil {
                cardNote("Live CPU and memory show up here once the platform is ready.")
            } else {
                let now = Date()
                let points = totals(now: now)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 24) {
                        liveValue("CPU", value: cpuNow, tint: DashboardColors.cpu)
                        liveValue("Memory", value: memoryNow, tint: DashboardColors.memory)
                        liveValue("Running", value: "\(model.running.count)", tint: DS.running)
                        Spacer(minLength: 0)
                    }
                    if model.containersLoaded && model.running.isEmpty && points.isEmpty {
                        Text("Start a container to see live CPU and memory here.")
                            .font(.callout)
                            .foregroundStyle(DS.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    } else {
                        // Room between the charts so the bottom and top axis labels do not touch.
                        VStack(alignment: .leading, spacing: 20) {
                        HistoryChart(
                            points: points,
                            lines: [HistoryLine(id: "cpu", title: "CPU", color: DashboardColors.cpu) { $0.cpuPercent }],
                            range: range, now: now, minimumTop: 100,
                            label: { "\(Int($0.rounded()))%" },
                            height: 76,
                            showsTimeAxis: false
                        )
                        HistoryChart(
                            points: points,
                            lines: [HistoryLine(id: "memory", title: "Memory", color: DashboardColors.memory) { $0.memoryBytes }],
                            range: range, now: now, minimumTop: 64 * 1024 * 1024,
                            label: { DashboardFormat.bytes($0) },
                            height: 84
                        )
                        }
                    }
                    Spacer(minLength: 0)
                    Text(windowCaption)
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    private var networkCard: some View {
        rateCard(
            "Network", icon: .network,
            lines: [
                HistoryLine(id: "rx", title: "In", color: DashboardColors.cpu) { $0.netRxPerSec },
                HistoryLine(id: "tx", title: "Out", color: DashboardColors.memory) { $0.netTxPerSec }
            ],
            empty: "Network traffic shows up here once a container runs."
        )
    }

    private var diskActivityCard: some View {
        rateCard(
            "Disk activity", icon: .disk,
            lines: [
                HistoryLine(id: "read", title: "Read", color: DashboardColors.cpu) { $0.diskReadPerSec },
                HistoryLine(id: "write", title: "Write", color: DashboardColors.memory) { $0.diskWritePerSec }
            ],
            empty: "Disk reads and writes show up here once a container runs."
        )
    }

    private func rateCard(_ title: String, icon: DeckIconName, lines: [HistoryLine], empty: String) -> some View {
        chartCard(title, icon: icon) {
            Text(range.phrase)
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
        } content: {
            if state.client == nil {
                cardNote(empty)
            } else {
                let now = Date()
                let points = totals(now: now)
                VStack(alignment: .leading, spacing: 10) {
                    HistoryLegend(lines: lines, values: Dictionary(uniqueKeysWithValues: lines.map { line in
                        (line.id, HistoryScale.rate(points.last.flatMap(line.value) ?? 0))
                    }))
                    HistoryChart(
                        points: points, lines: lines, range: range, now: now,
                        minimumTop: 16 * 1024,
                        label: { HistoryScale.rate($0) },
                        height: 96, showsArea: false
                    )
                }
            }
        }
    }

    /// What the charts cover.
    private var windowCaption: String {
        let scope = "Total for running containers. \(range.phrase)."
        if !history.isLoaded { return scope }
        return StatsSampler.shared.isSampling || !model.running.isEmpty
            ? scope + " Kept between launches."
            : scope
    }

    private var cpuNow: String {
        if model.containersLoaded && model.running.isEmpty { return Format.percent(0) }
        guard let last = model.samples.last, last.cpuMeasured else { return "Measuring" }
        return Format.percent(last.cpuPercent)
    }

    private var memoryNow: String {
        if model.containersLoaded && model.running.isEmpty { return DashboardFormat.bytes(UInt64(0)) }
        guard let last = model.samples.last else { return "Measuring" }
        return DashboardFormat.bytes(last.memoryBytes)
    }

    private func liveValue(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(DS.textSecondary)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func cardNote(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(DS.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }

    // MARK: Disk

    private struct DiskPart: Identifiable {
        let id: String
        let title: String
        let icon: DeckIconName
        let bucket: UsageBucket
        let color: Color
        /// Line under the title. Defaults to "N of M in use".
        var summary: String? = nil
    }

    /// Apple's disk use counts its own system images (the builder and the VM init image),
    /// which the image list hides. Say so, so the row matches the Images screen.
    private func imagesSummary(_ bucket: UsageBucket) -> String? {
        guard let listed = model.imageCount, bucket.total > listed else { return nil }
        let system = bucket.total - listed
        return "\(bucket.active) of \(bucket.total) in use, \(system) for the system"
    }

    private var diskParts: [DiskPart] {
        guard let usage = model.usage else { return [] }
        return [
            DiskPart(id: "images", title: "Images", icon: .images, bucket: usage.images, color: DashboardColors.images,
                     summary: imagesSummary(usage.images)),
            DiskPart(id: "containers", title: "Containers", icon: .containers, bucket: usage.containers, color: DashboardColors.containers),
            DiskPart(id: "volumes", title: "Volumes", icon: .volumes, bucket: usage.volumes, color: DashboardColors.volumes)
        ]
    }

    private var diskCard: some View {
        Card("Disk usage", icon: .disk) {
            if let usage = model.usage {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(DashboardFormat.bytes(usage.totalBytes))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text("used by containers, images and volumes")
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    usageBar(usage)
                    VStack(spacing: 0) {
                        ForEach(Array(diskParts.enumerated()), id: \.element.id) { index, part in
                            if index > 0 { Divider() }
                            diskRow(part, total: usage.totalBytes)
                        }
                    }
                    Spacer(minLength: 0)
                    Divider()
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(usage.reclaimableBytes > 0 ? DashboardFormat.bytes(usage.reclaimableBytes) : "Nothing")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                            Text("can be freed")
                                .font(.caption)
                                .foregroundStyle(DS.textSecondary)
                        }
                        Spacer(minLength: 8)
                        cleanupButton(usage)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else if state.client == nil {
                cardNote("Disk use shows up here once the platform is ready.")
            } else {
                LoadingView("Reading disk use", style: .chart)
                    .frame(minHeight: 160)
            }
        }
    }

    private func diskRow(_ part: DiskPart, total: UInt64) -> some View {
        HStack(spacing: 10) {
            IconBadge(part.icon, tint: part.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(part.title).font(.callout.weight(.medium))
                Text(part.summary ?? "\(part.bucket.active) of \(part.bucket.total) in use")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(DashboardFormat.bytes(part.bucket.sizeBytes))
                    .font(.callout)
                    .monospacedDigit()
                Text(part.bucket.reclaimableBytes > 0 ? "\(DashboardFormat.bytes(part.bucket.reclaimableBytes)) unused" : "All in use")
                    .font(.caption)
                    .foregroundStyle(part.bucket.reclaimableBytes > 0 ? DS.warning : DS.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
    }

    private func usageBar(_ usage: DiskUsage) -> some View {
        let total = max(Double(usage.totalBytes), 1)
        let parts = diskParts
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(parts) { part in
                    let fraction = Double(part.bucket.sizeBytes) / total
                    if fraction > 0 {
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(3, (geo.size.width - 4) * fraction))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(DS.surfaceSunken)
        .clipShape(Capsule())
    }

    private func cleanupButton(_ usage: DiskUsage) -> some View {
        Button {
            showFreeUpSpace = true
        } label: {
            HStack(spacing: 6) {
                DeckIcon(.prune, size: 13, color: DS.accent)
                Text("Free Up Space")
            }
        }
        .buttonStyle(SoftAccentButtonStyle())
        .disabled(state.client == nil)
        .help("Pick what to remove and see what it frees")
    }

    // MARK: Running containers

    private var runningCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconBadge(.containers, size: 26)
                    Text("Running containers").font(.headline)
                    if state.client != nil, model.containersLoaded {
                        Pill("\(model.running.count)", tint: model.running.isEmpty ? DS.stopped : DS.running)
                    }
                    Spacer(minLength: 8)
                    if state.client != nil, !model.running.isEmpty {
                        Button {
                            LogsWindow.open(state: state, containerIDs: Array(model.running.filter { $0.id != "buildkit" }.prefix(4).map(\.id)))
                        } label: {
                            HStack(spacing: 5) {
                                DeckIcon(.logs, size: 12, color: DS.accent)
                                Text("Logs")
                            }
                        }
                        .buttonStyle(AccentLinkButtonStyle())
                        .help("Open the logs of running containers side by side")
                        .padding(.trailing, 6)
                    }
                    if state.client != nil, !model.containers.isEmpty {
                        Button {
                            state.selection = .containers
                        } label: {
                            HStack(spacing: 4) {
                                Text("Show All")
                                DeckIcon(.chevronRight, size: 10, color: DS.accent)
                            }
                        }
                        .buttonStyle(AccentLinkButtonStyle())
                    }
                }
                runningContent
            }
        }
    }

    @ViewBuilder
    private var runningContent: some View {
        let running = model.running
        if state.client == nil {
            Text("Finish setup to run containers.")
                .foregroundStyle(DS.textSecondary)
                .padding(.vertical, 6)
        } else if running.isEmpty {
            HStack(spacing: 12) {
                Text(model.containersLoaded ? "Nothing is running right now." : "Loading")
                    .foregroundStyle(DS.textSecondary)
                Spacer()
                Button {
                    state.runRequest = RunRequest(options: RunOptions(image: ""))
                } label: {
                    DeckLabel("Run a Container", icon: .add)
                }
                .deckPrimary()
            }
            .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(running.prefix(6).enumerated()), id: \.element.id) { index, item in
                    Divider()
                    runningRow(item)
                }
                if running.count > 6 {
                    Divider()
                    Text("\(running.count - 6) more running")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func runningRow(_ item: ContainerSummary) -> some View {
        let reading = model.reading(for: item)
        return Button {
            state.focusedContainerID = item.id
            state.selection = .containers
        } label: {
            HStack(spacing: 12) {
                StatusPill(item.state)
                    .frame(width: 84, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).fontWeight(.medium).lineLimit(1)
                    Text(ContainerText.shortImage(item.image))
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                ContainerPortBadges(ports: item.ports, limit: 2)
                if contentWidth >= Self.twoColumnWidth {
                    let now = Date()
                    HistorySparkline(
                        points: history.points(item.id, range: .fiveMinutes, now: now),
                        value: { $0.cpuPercent },
                        range: .fiveMinutes, now: now,
                        color: DashboardColors.cpu
                    )
                    .frame(width: 110, height: 24)
                    .help("CPU, last 5 minutes")
                }
                HStack(spacing: 14) {
                    statValue(.cpu, StatsSampler.shared.cpuText(for: item))
                        .frame(width: 84, alignment: .trailing)
                    statValue(.memory, reading.map { DashboardFormat.bytes($0.memoryBytes) } ?? "-")
                        .frame(width: 90, alignment: .trailing)
                }
                DeckIcon(.chevronRight, size: 11, color: DS.textTertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(item.name)")
    }

    private func statValue(_ icon: DeckIconName, _ text: String) -> some View {
        HStack(spacing: 5) {
            DeckIcon(icon, size: 12, color: DS.textTertiary)
            Text(text).monospacedDigit().lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(DS.textSecondary)
    }

    // MARK: Setup checks

    private var checksExpanded: Bool {
        checksExpandedChoice ?? !state.report.isReady
    }

    private var issueCount: Int {
        state.report.checks.filter { !$0.state.isPassing }.count
    }

    private var checksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            checksExpandedChoice = !checksExpanded
                        }
                    } label: {
                        HStack(spacing: 10) {
                            IconBadge(.checklist, size: 26)
                            Text("Setup checks").font(.headline)
                            if !state.report.checks.isEmpty {
                                if issueCount == 0 {
                                    Pill("All good", tint: DS.running)
                                } else {
                                    Pill(issueCount == 1 ? "1 to fix" : "\(issueCount) to fix", tint: DS.warning)
                                }
                            }
                            DeckIcon(.chevronRight, size: 11, color: DS.textSecondary)
                                .rotationEffect(.degrees(checksExpanded ? 90 : 0))
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(checksExpanded ? "Hide checks" : "Show checks")
                    if state.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        state.showSetup = true
                    } label: {
                        DeckLabel("Setup Guide", icon: .wand)
                    }
                }
                if checksExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(state.report.checks) { check in
                            Divider()
                            CheckRow(check: check)
                        }
                    }
                    .padding(.top, 10)
                }
            }
        }
    }
}

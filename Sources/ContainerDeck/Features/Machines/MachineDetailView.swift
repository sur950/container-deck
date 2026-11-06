import SwiftUI
import AppKit
import DeckCore

/// Right side of the Machines screen: actions, configuration, logs, stats and inspect.
struct MachineDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        case stats = "Stats"
        case inspect = "Inspect"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let machine: MachineSummary
    let client: ContainerClient
    let onChange: () async -> Void

    @State private var tab: Tab = .overview
    @State private var detail: MachineDetail?
    @State private var bootConfig: MachineBootConfig?
    @State private var busy: String?
    @State private var actionError: String?
    @State private var confirmDelete = false

    init(machine: MachineSummary, client: ContainerClient, onChange: @escaping () async -> Void) {
        self.machine = machine
        self.client = client
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(DS.pad)
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.pad)
            .padding(.bottom, 10)
            Divider()
            switch tab {
            case .overview:
                overview
            case .logs:
                MachineLogsView(machineName: machine.name, client: client)
            case .stats:
                MachineStatsView(machine: machine, client: client)
            case .inspect:
                MachineInspectView(machineName: machine.name, client: client)
            }
        }
        .task(id: "\(machine.name)|\(machine.state.rawValue)|\(state.resourcesVersion)") {
            detail = try? await client.machineDetail(machine.name)
            bootConfig = client.machineBootConfig(machine.name)
        }
        .onDeckDebugCommand { name, value in
            if name == "machine-tab", let item = Tab.allCases.first(where: { $0.rawValue.lowercased() == value }) {
                tab = item
            }
        }
        .confirmationDialog("Delete \(machine.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Machine", role: .destructive) {
                Task {
                    await perform("Deleting") { try await client.deleteMachine(machine.name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the machine and its disk. Files in your Mac home folder stay as they are.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(.machines, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(machine.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        StatusPill(machine.state)
                        if machine.isDefault {
                            Pill("Default")
                        }
                    }
                    Text(machine.hostname ?? MachineImages.dnsName(for: machine.name))
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
                if machine.state == .running {
                    Button {
                        Task { await perform("Stopping") { try await client.stopMachine(machine.name) } }
                    } label: {
                        DeckLabel("Stop", icon: .stop)
                    }
                } else {
                    Button {
                        Task { await perform("Booting") { try await client.bootMachine(machine.name) } }
                    } label: {
                        DeckLabel("Boot", icon: .play)
                    }
                    .deckPrimary()
                }
                Button {
                    openTerminal()
                } label: {
                    DeckLabel("Terminal", icon: .terminal)
                }
                .help("Open a shell. The machine boots first if needed.")
                if !machine.isDefault {
                    Button {
                        Task { await perform("Saving") { try await client.setDefaultMachine(machine.name) } }
                    } label: {
                        DeckLabel("Set Default", icon: .star)
                    }
                    .help("Commands without a machine name use the default machine.")
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    DeckLabel("Delete", icon: .trash)
                }
            }
            .disabled(busy != nil)
        }
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let actionError {
                    ErrorNote(message: actionError)
                }
                EqualHeightRow(spacing: 12) {
                    MetricTile(title: "CPUs", value: machine.cpus.map { "\($0)" } ?? "-", subtitle: "virtual cores", icon: .cpu)
                    MetricTile(title: "Memory", value: Format.bytes(machine.memoryBytes), subtitle: "assigned", icon: .memory)
                    MetricTile(title: "Disk", value: Format.bytes(detail?.diskSizeBytes), subtitle: "on this Mac", icon: .disk)
                }

                Card("Configuration", icon: .info) {
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueRow("Image", value: machine.image.isEmpty ? "Unknown" : machine.image, monospaced: true, copyable: true)
                        KeyValueRow("Platform", value: detail?.platform ?? "linux/arm64", monospaced: true)
                        KeyValueRow("IP address", value: machine.ipAddress ?? "Not running", monospaced: machine.ipAddress != nil, copyable: machine.ipAddress != nil)
                        KeyValueRow("DNS name", value: machine.hostname ?? MachineImages.dnsName(for: machine.name), monospaced: true, copyable: true)
                        KeyValueRow("Home folder", value: MachineDefaults.homeMountTitle(machine.homeMount))
                        KeyValueRow("Nested VMs", value: (bootConfig?.virtualization ?? false) ? "On" : "Off")
                        KeyValueRow("Kernel", value: kernelText, monospaced: !(bootConfig?.usesSystemKernel ?? true))
                        if let user = detail?.username {
                            KeyValueRow("User", value: userText(user, home: detail?.guestHome))
                        }
                        KeyValueRow("Created", value: Format.relative(detail?.createdAt))
                        if machine.state == .running {
                            KeyValueRow("Started", value: Format.relative(detail?.startedAt))
                        }
                        if let containerID = detail?.containerID {
                            KeyValueRow("Container", value: containerID, monospaced: true, copyable: true)
                        }
                    }
                }

                MachineEditCard(machine: machine, client: client, bootConfig: bootConfig) {
                    await onChange()
                }
                .id("settings")

                if showHints {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Open a shell from Terminal").font(.caption).foregroundStyle(DS.textSecondary)
                        CommandHint(client.commandLine(["machine", "run", "--name", machine.name]))
                    }
                }
            }
            .padding(DS.pad)
        }
        .background(DS.surface)
        .onDeckDebugCommand { name, value in
            // Automation only: machine-scroll:settings shows the Settings card.
            if name == "machine-scroll" { withAnimation { proxy.scrollTo(value, anchor: .top) } }
        }
        }
    }

    private var kernelText: String {
        guard let config = bootConfig, !config.usesSystemKernel, let path = config.kernelPath else { return "System kernel" }
        return (path as NSString).lastPathComponent
    }

    private func userText(_ user: String, home: String?) -> String {
        guard let home else { return user }
        return "\(user), home \(home)"
    }

    // MARK: - Actions

    private func perform(_ label: String, _ action: () async throws -> Void) async {
        busy = label
        actionError = nil
        do {
            try await action()
            state.resourcesChanged()
        } catch {
            actionError = error.localizedDescription
            state.showError(error)
        }
        busy = nil
        await onChange()
    }

    private func openTerminal() {
        do {
            try TerminalLauncher.open(command: client.machineShellCommand(machine.name))
        } catch {
            state.showError(error)
        }
    }
}

// MARK: - Edit settings

/// CPUs, memory, home folder, nested virtualisation and kernel. Saves with
/// `machine set`. Apply and Restart stops and boots a running machine so the change is live.
struct MachineEditCard: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let machine: MachineSummary
    let client: ContainerClient
    let bootConfig: MachineBootConfig?
    let onSaved: () async -> Void

    @State private var cpus = 2
    @State private var memoryGB = 4
    @State private var homeMount = "rw"
    @State private var virtualization = false
    @State private var kernelPath = ""
    @State private var saving: String?
    @State private var failure: String?

    init(machine: MachineSummary, client: ContainerClient, bootConfig: MachineBootConfig?, onSaved: @escaping () async -> Void) {
        self.machine = machine
        self.client = client
        self.bootConfig = bootConfig
        self.onSaved = onSaved
    }

    var body: some View {
        Card("Settings", icon: .edit) {
            VStack(alignment: .leading, spacing: 12) {
                resourceRow("CPUs") {
                    Stepper(value: $cpus, in: 1...max(MachineDefaults.maxCPUs, currentCPUs)) {
                        EmptyView()
                    }
                    .labelsHidden()
                    Text("\(cpus)").monospacedDigit()
                }
                resourceRow("Memory") {
                    Stepper(value: $memoryGB, in: 1...max(MachineDefaults.maxMemoryGB, currentMemoryGB)) {
                        EmptyView()
                    }
                    .labelsHidden()
                    Text("\(memoryGB) GB").monospacedDigit()
                }
                resourceRow("Home folder") {
                    Picker("Home folder", selection: $homeMount) {
                        Text("Read and write").tag("rw")
                        Text("Read only").tag("ro")
                        Text("None").tag("none")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                resourceRow("Nested VMs") {
                    Toggle("Nested virtualisation", isOn: $virtualization)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(!MachineHost.supportsNestedVirtualization() && !currentVirtualization)
                    Text(virtualization ? "On" : "Off")
                        .foregroundStyle(DS.textSecondary)
                    if !MachineHost.supportsNestedVirtualization() {
                        Text("Needs M3 or newer")
                            .font(.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                resourceRow("Kernel") {
                    TextField("Kernel", text: $kernelPath, prompt: Text("System kernel"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 320)
                    Button("Choose…") { chooseKernel() }
                        .controlSize(.small)
                    if !kernelIsSystem {
                        Button("Use System Kernel") { kernelPath = "" }
                            .controlSize(.small)
                            .help("Points the machine at the default kernel again.")
                    }
                }

                HStack(spacing: 6) {
                    DeckIcon(.info, size: 12, color: DS.textSecondary)
                    Text(machine.state == .running
                         ? "Changes apply on the next boot. Apply and Restart stops and boots the machine now."
                         : "Changes apply on the next boot.")
                }
                .font(.caption)
                .foregroundStyle(DS.textSecondary)

                if let failure {
                    ErrorNote(message: failure)
                }

                if hasChanges || saving != nil {
                    Divider()
                    HStack(spacing: 8) {
                        if showHints {
                            CommandHint(client.commandLine(client.setMachineArguments(machine.name, change: change)))
                        }
                        Spacer(minLength: 8)
                        if let saving {
                            ProgressView().controlSize(.small)
                            Text(saving).font(.callout).foregroundStyle(DS.textSecondary)
                        }
                        Button("Reset") { reset() }
                            .disabled(saving != nil)
                        if machine.state == .running {
                            Button("Save") { save(restart: false) }
                                .disabled(saving != nil || !kernelIsValid)
                            Button("Apply and Restart") { save(restart: true) }
                                .deckPrimary()
                                .disabled(saving != nil || !kernelIsValid)
                        } else {
                            Button("Save") { save(restart: false) }
                                .deckPrimary()
                                .disabled(saving != nil || !kernelIsValid)
                        }
                    }
                    if !kernelIsValid {
                        Text("The kernel path must start with /.")
                            .font(.caption)
                            .foregroundStyle(DS.danger)
                    }
                }
            }
        }
        .task(id: "\(machine.name)|\(machine.cpus ?? 0)|\(machine.memoryBytes ?? 0)|\(machine.homeMount ?? "")|\(String(describing: bootConfig))") {
            reset()
        }
        .onDeckDebugCommand { name, value in
            // Automation only: machine-edit:cpus=3 changes a field to show the Apply bar.
            guard name == "machine-edit" else { return }
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            switch parts[0] {
            case "cpus": cpus = Int(parts[1]) ?? cpus
            case "virtualization": virtualization = parts[1] == "true"
            case "apply": save(restart: parts[1] == "restart")
            default: break
            }
        }
    }

    private func resourceRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .frame(width: 120, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var currentCPUs: Int { bootConfig?.cpus ?? machine.cpus ?? MachineDefaults.defaultCPUs }

    private var currentMemoryGB: Int {
        guard let bytes = machine.memoryBytes else { return MachineDefaults.defaultMemoryGB }
        return max(1, Int((Double(bytes) / 1_073_741_824).rounded()))
    }

    private var currentHomeMount: String { bootConfig?.homeMount ?? machine.homeMount ?? "rw" }
    private var currentVirtualization: Bool { bootConfig?.virtualization ?? false }
    /// Empty when the machine uses the system kernel.
    private var currentKernel: String {
        guard let config = bootConfig, !config.usesSystemKernel else { return "" }
        return config.kernelPath ?? ""
    }

    private var trimmedKernel: String { kernelPath.trimmingCharacters(in: .whitespaces) }
    private var kernelIsSystem: Bool { trimmedKernel.isEmpty }
    private var kernelIsValid: Bool { trimmedKernel.isEmpty || trimmedKernel.hasPrefix("/") }

    private var hasChanges: Bool {
        cpus != currentCPUs || memoryGB != currentMemoryGB || homeMount != currentHomeMount
            || virtualization != currentVirtualization || trimmedKernel != currentKernel
    }

    /// The 1.6.1 CLI cannot clear a kernel, so "system kernel" points at the default link.
    private var change: MachineConfigChange {
        var kernel: String?
        if trimmedKernel != currentKernel {
            kernel = trimmedKernel.isEmpty
                ? URL(fileURLWithPath: MachineBootConfig.defaultAppRoot).appendingPathComponent("kernels/default.kernel-arm64").path
                : trimmedKernel
        }
        return MachineConfigChange(
            cpus: cpus != currentCPUs ? cpus : nil,
            memory: memoryGB != currentMemoryGB ? "\(memoryGB)G" : nil,
            homeMount: homeMount != currentHomeMount ? homeMount : nil,
            virtualization: virtualization != currentVirtualization ? virtualization : nil,
            kernelPath: kernel
        )
    }

    private func reset() {
        cpus = currentCPUs
        memoryGB = currentMemoryGB
        homeMount = currentHomeMount
        virtualization = currentVirtualization
        kernelPath = currentKernel
        failure = nil
    }

    private func chooseKernel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Kernel"
        panel.message = "Pick a Linux kernel binary, such as vmlinux."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            kernelPath = url.path
        }
    }

    private func save(restart: Bool) {
        let name = machine.name
        let pending = change
        let restartNow = restart && machine.state == .running
        saving = restartNow ? "Restarting" : "Saving"
        failure = nil
        Task {
            do {
                try await client.applyMachineConfig(name, change: pending, restart: restartNow)
                state.showToast(restartNow ? "Applied. \(name) restarted with the new settings." : "Saved. Changes apply on the next boot.", style: .success)
                state.resourcesChanged()
                await onSaved()
            } catch {
                failure = error.localizedDescription
                DiagnosticsLog.shared.record(error, source: "Machines")
            }
            saving = nil
        }
    }
}

// MARK: - Logs

struct MachineLogsView: View {
    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    let machineName: String
    let client: ContainerClient

    @State private var lines: [LogLine] = []
    @State private var bootLog = false
    @State private var filter = ""
    @State private var streamError: String?

    init(machineName: String, client: ContainerClient) {
        self.machineName = machineName
        self.client = client
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Log", selection: $bootLog) {
                    Text("Output").tag(false)
                    Text("Boot log").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button {
                    lines = []
                } label: {
                    DeckLabel("Clear", icon: .trash)
                }
            }
            .padding(10)
            Divider()
            if lines.isEmpty {
                if let streamError {
                    EmptyState(icon: .logs, title: "No logs", message: streamError)
                } else {
                    LoadingView("Waiting for log lines")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visibleLines) { line in
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: lines.count) { _, _ in
                        if filter.isEmpty, let last = lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                if let streamError {
                    ErrorNote(message: streamError).padding(10)
                }
            }
        }
        .task(id: "\(machineName)|\(bootLog)") {
            await follow()
        }
    }

    private var visibleLines: [LogLine] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private func follow() async {
        lines = []
        streamError = nil
        let stream = bootLog ? client.machineBootLogs(machineName) : client.machineLogs(machineName)
        var next = 0
        do {
            for try await text in stream {
                lines.append(LogLine(id: next, text: text))
                next += 1
                if lines.count > 3000 {
                    lines.removeFirst(lines.count - 3000)
                }
            }
        } catch {
            if !Task.isCancelled {
                streamError = error.localizedDescription
            }
        }
    }
}

// MARK: - Stats

/// Live usage read from /proc inside the machine. A machine is not a regular
/// container, so `container stats` does not know it (checked on 1.6.1).
struct MachineStatsView: View {
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let machine: MachineSummary
    let client: ContainerClient

    @State private var latest: MachineProcSample?
    @State private var previous: MachineProcSample?
    @State private var cpuHistory: [Double] = []
    @State private var message: String?

    static let interval: Duration = .seconds(2)

    init(machine: MachineSummary, client: ContainerClient) {
        self.machine = machine
        self.client = client
    }

    var body: some View {
        if machine.state != .running {
            EmptyState(icon: .stats, title: "Machine is stopped", message: "Boot the machine to see live usage.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    EqualHeightRow(spacing: 12) {
                        MetricTile(
                            title: "CPU",
                            value: cpuText,
                            subtitle: latest.map { "\($0.cpuCount) cores, load \(String(format: "%.2f", $0.load1))" },
                            icon: .cpu
                        )
                        MetricTile(
                            title: "Memory",
                            value: latest.map { Format.bytes($0.memoryUsedBytes) } ?? "-",
                            subtitle: latest.map { "of \(Format.bytes($0.memoryTotalBytes))" },
                            icon: .memory
                        )
                    }
                    EqualHeightRow(spacing: 12) {
                        MetricTile(
                            title: "Network",
                            value: latest.map { "\(Format.bytes($0.netRxBytes)) in" } ?? "-",
                            subtitle: latest.map { "\(Format.bytes($0.netTxBytes)) out" },
                            icon: .network
                        )
                        MetricTile(
                            title: "Disk",
                            value: latest.map { "\(Format.bytes($0.diskReadBytes)) read" } ?? "-",
                            subtitle: latest.map { "\(Format.bytes($0.diskWriteBytes)) written" },
                            icon: .disk
                        )
                    }
                    if cpuHistory.count > 1 {
                        Card("CPU history", icon: .stats) {
                            MachineSparkline(values: cpuHistory, maxValue: Double(max(1, latest?.cpuCount ?? 1)) * 100)
                                .frame(height: 70)
                        }
                    }
                    HStack(spacing: 6) {
                        DeckIcon(.info, size: 12, color: DS.textSecondary)
                        Text(latest.map { "\($0.processes) processes. Updates every 2 seconds." } ?? "Reading /proc inside the machine.")
                    }
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    if let message {
                        Text(message).font(.callout).foregroundStyle(DS.textSecondary)
                    }
                    if showHints {
                        CommandHint(client.commandLine(["machine", "run", "--name", machine.name, "--", "top", "-b", "-n", "1"]))
                    }
                }
                .padding(DS.pad)
            }
            .background(DS.surface)
            .task(id: machine.name) {
                while !Task.isCancelled {
                    do {
                        let sample = try await client.machineProcSample(machine.name)
                        if let cpu = sample.cpuPercent(since: latest) {
                            cpuHistory.append(cpu)
                            if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
                        }
                        previous = latest
                        latest = sample
                        message = nil
                    } catch is CancellationError {
                        return
                    } catch {
                        if !Task.isCancelled {
                            message = "Live stats are not available. \(error.localizedDescription)"
                        }
                    }
                    try? await Task.sleep(for: Self.interval)
                }
            }
        }
    }

    private var cpuText: String {
        guard let latest, let cpu = latest.cpuPercent(since: previous) else { return latest == nil ? "-" : "Measuring" }
        return Format.percent(cpu)
    }
}

/// Small line chart for one series. Brand red line on a soft fill.
struct MachineSparkline: View {
    let values: [Double]
    let maxValue: Double

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue, values.max() ?? 1, 1)
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: geo.size.height * (1 - CGFloat(value / top)))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    for point in points { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(DS.accent.opacity(0.12))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(DS.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .accessibilityLabel("CPU history")
    }
}

// MARK: - Inspect

struct MachineInspectView: View {
    let machineName: String
    let client: ContainerClient

    @State private var text = ""
    @State private var failure: String?

    init(machineName: String, client: ContainerClient) {
        self.machineName = machineName
        self.client = client
    }

    var body: some View {
        ScrollView {
            Text(failure ?? (text.isEmpty ? "Loading" : text))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.pad)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                DeckLabel("Copy", icon: .copy)
            }
            .disabled(text.isEmpty)
            .padding(10)
        }
        .task(id: machineName) {
            do {
                text = try await client.inspectMachine(machineName)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

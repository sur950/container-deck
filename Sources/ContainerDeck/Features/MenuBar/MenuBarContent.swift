import SwiftUI
import AppKit
import DeckCore

/// Window style menu bar panel: service status, usage rings, containers and quick actions.
struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var host = HostWindow()

    private let services = BackgroundServices.shared
    private let updates = AppUpdates.shared

    private var sampler: StatsSampler { StatsSampler.shared }
    @State private var busy: Set<String> = []
    @State private var serviceBusy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let required = updates.required {
                // A compulsory update: no container actions until it is installed.
                requiredRow(required)
            } else if state.client == nil {
                notInstalled
            } else if !serviceRunning {
                serviceStopped
            } else {
                usage
                containerList
            }

            if let message {
                HStack(alignment: .top, spacing: 6) {
                    DeckIcon(.error, size: 12, color: DS.danger)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if updates.required == nil, updates.shouldOfferUpdate || updates.install != .idle, let latest = updates.latest {
                updateRow(latest)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(HostWindowReader(host: host))
        .task {
            if state.report.checks.isEmpty && !state.isChecking {
                await state.refresh()
            }
            BackgroundServices.shared.start(state: state)
            StatsHistoryRecorder.shared.start()
            // Fresh numbers when the panel opens. The shared feed keeps them current after that.
            await services.poll()
        }
        .onAppear { AppActivity.shared.setPanelOpen(true) }
        .onDisappear { AppActivity.shared.setPanelOpen(false) }
        .usesLiveStats("menu-bar", active: updates.required == nil)
    }

    // MARK: - Sections

    private var serviceRunning: Bool {
        services.serviceRunning ?? state.report.serviceRunning
    }

    private var runningContainers: [ContainerSummary] {
        services.containers.filter(\.isRunning)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoBadge(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppConfig.appName).font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if state.client != nil, updates.required == nil {
                Pill(serviceRunning ? "Running" : "Stopped", tint: serviceRunning ? DS.running : DS.stopped)
                if serviceBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        toggleService()
                    } label: {
                        DeckIcon(serviceRunning ? .stop : .play, size: 13)
                    }
                    .buttonStyle(.borderless)
                    .help(serviceRunning ? "Stop the container service" : "Start the container service")
                }
            }
        }
    }

    private var statusLine: String {
        guard state.client != nil else { return "Not set up yet" }
        guard serviceRunning else { return "Service is stopped" }
        let total = services.containers.count
        let running = runningContainers.count
        if total == 0 { return "No containers yet" }
        return "\(running) of \(total) containers running"
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                DeckIcon(.warning, size: 13, color: DS.warning)
                Text("Apple's container tool is not installed.")
                    .font(.callout)
            }
            Button("Open Setup") {
                openMainWindow()
                state.showSetup = true
            }
            .deckPrimary()
            .controlSize(.small)
        }
    }

    private var serviceStopped: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start the service to run your containers.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                toggleService()
            } label: {
                DeckLabel("Start Service", icon: .play)
            }
            .deckPrimary()
            .controlSize(.small)
            .disabled(serviceBusy)
        }
    }

    private var usage: some View {
        let running = runningContainers
        let cpu = running.reduce(0.0) { $0 + (sampler.reading(for: $1)?.cpuPercent ?? 0) }
        let memUsed = running.reduce(UInt64(0)) { $0 + (sampler.reading(for: $1)?.memoryBytes ?? 0) }
        let memLimit = running.reduce(UInt64(0)) { $0 + (sampler.reading(for: $1)?.memoryLimitBytes ?? 0) }
        let memTotal = memLimit > 0 ? memLimit : ProcessInfo.processInfo.physicalMemory
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)

        return Card {
            HStack(spacing: 12) {
                UsageRing(
                    title: "CPU",
                    icon: .cpu,
                    fraction: cpu / (Double(cores) * 100),
                    value: Format.percent(cpu),
                    detail: "\(cores) cores"
                )
                UsageRing(
                    title: "Memory",
                    icon: .memory,
                    fraction: memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0,
                    value: Format.bytes(memUsed),
                    detail: "of \(Format.bytes(memTotal))"
                )
            }
            usageHistory
        }
    }

    /// CPU over the last 15 minutes from the saved history. Hidden until there is some.
    @ViewBuilder
    private var usageHistory: some View {
        let now = Date()
        let points = StatsHistoryRecorder.shared.totals(range: .fifteenMinutes, now: now)
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 3) {
                HistorySparkline(points: points, value: { $0.cpuPercent }, range: .fifteenMinutes, now: now, color: DS.accent)
                    .frame(height: 26)
                Text("CPU, last 15 minutes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
    }

    private var containerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Containers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if services.containers.isEmpty {
                Text("No containers yet. Open Container Deck to run one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(services.containers) { container in
                            MenuContainerRow(
                                container: container,
                                reading: sampler.reading(for: container),
                                isBusy: busy.contains(container.id),
                                onToggle: { toggle(container) },
                                onOpen: { open(container) },
                                onRestart: { restart(container) },
                                onLogs: {
                                    closePanel()
                                    LogsWindow.open(state: state, containerIDs: [container.id])
                                }
                            )
                        }
                    }
                }
                // Explicit height: a ScrollView has no natural height inside the panel.
                .frame(height: CGFloat(min(services.containers.count, 6)) * (MenuContainerRow.height + 2) - 2)
            }
        }
    }

    /// Short notice while a compulsory update blocks the app. Open shows the Update required screen.
    private func requiredRow(_ required: RequiredUpdate) -> some View {
        HStack(spacing: 10) {
            DeckIcon(.download, size: 14, color: DS.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update required")
                    .font(.callout.weight(.semibold))
                Text("Install version \(required.version) to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Open") { openMainWindow() }
                .deckPrimary()
                .controlSize(.small)
        }
        .padding(10)
        .background(DS.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.smallRadius))
    }

    private func updateRow(_ latest: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DeckIcon(.download, size: 14, color: DS.accent)
                Text("Version \(latest.version.description) is ready")
                    .font(.callout)
                Spacer()
                if !updates.isInstalling {
                    Button("Later") { updates.skipLatest() }
                        .controlSize(.small)
                    Button("Install") { updates.installAndRelaunch() }
                        .controlSize(.small)
                }
            }
            UpdateInstallStatus(compact: true)
        }
        .padding(10)
        .background(DS.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.smallRadius))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuActionButton(title: "Open Container Deck", icon: .dashboard) {
                openMainWindow()
            }
            if updates.required == nil {
                MenuActionButton(title: "Open Logs", icon: .logs) {
                    let running = runningContainers.filter { $0.id != "buildkit" }.prefix(4).map(\.id)
                    closePanel()
                    LogsWindow.open(state: state, containerIDs: Array(running))
                }
            }
            MenuActionButton(title: "Settings…", icon: .settings) {
                closePanel()
                NSApp.activate()
                openSettings()
            }
            MenuActionButton(title: "Quit Container Deck", icon: .close) {
                confirmQuit()
            }
        }
    }

    // MARK: - Actions

    private func confirmQuit() {
        closePanel()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Quit Container Deck?"
        alert.informativeText = "Your containers keep running. They belong to Apple's container service, not to this app."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    /// Actions that open a window or a dialog close the panel first, like a menu does.
    private func closePanel() {
        dismiss()
        if let window = host.window, window.isVisible { window.close() }
    }

    private func openMainWindow() {
        closePanel()
        if !MainWindow.bringForward() {
            openWindow(id: "main")
            NSApp.activate()
        }
    }

    private func open(_ container: ContainerSummary) {
        DeepLinkRouter.route(.container(container.id), state: state)
        openMainWindow()
    }

    private func toggleService() {
        serviceBusy = true
        message = nil
        state.lastError = nil
        let wasRunning = serviceRunning
        Task {
            if wasRunning {
                await services.stopService()
            } else {
                await services.startService()
            }
            if let error = state.lastError {
                message = error
            }
            serviceBusy = false
        }
    }

    private func restart(_ container: ContainerSummary) {
        guard let client = state.client else { return }
        busy.insert(container.id)
        message = nil
        Task {
            do {
                services.noteUserAction(stopping: container.id)
                try await client.restartContainer(container.id)
                state.resourcesChanged()
            } catch {
                message = error.localizedDescription
            }
            busy.remove(container.id)
            await services.poll()
        }
    }

    private func toggle(_ container: ContainerSummary) {
        guard let client = state.client else { return }
        busy.insert(container.id)
        message = nil
        Task {
            do {
                if container.isRunning {
                    services.noteUserAction(stopping: container.id)
                    try await client.stopContainer(container.id)
                } else {
                    try await client.startContainer(container.id)
                }
                state.resourcesChanged()
            } catch {
                message = error.localizedDescription
            }
            busy.remove(container.id)
            await services.poll()
        }
    }
}

/// Icon shown in the menu bar.
struct MenuBarLabel: View {
    var body: some View {
        Image(nsImage: Brand.menuBarImage())
            .accessibilityLabel(AppConfig.appName)
            // The label exists from launch, so stats history starts recording with the app.
            .onAppear { StatsHistoryRecorder.shared.start() }
    }
}

// MARK: - Pieces

/// One container in the panel. Click the row to open it, use the button to start or stop.
/// Running containers show small CPU and memory rings. Right click for restart and logs.
private struct MenuContainerRow: View {
    let container: ContainerSummary
    let reading: StatsReading?
    let isBusy: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onRestart: () -> Void
    let onLogs: () -> Void

    static let height: CGFloat = 40

    @State private var isHovered = false

    private var title: String { container.name.isEmpty ? container.id : container.name }

    /// CPU against the cores the container may use (100 % is one core).
    private var cpuFraction: Double {
        guard let cpu = reading?.cpuPercent else { return 0 }
        let cores = Double(max(1, container.cpus ?? ProcessInfo.processInfo.activeProcessorCount))
        return cpu / (cores * 100)
    }

    private var memoryFraction: Double {
        guard let reading, reading.memoryLimitBytes > 0 else { return 0 }
        return Double(reading.memoryBytes) / Double(reading.memoryLimitBytes)
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(container.isRunning ? DS.running : DS.stopped)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(ContainerText.shortImage(container.image))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 2)
            if container.isRunning, let reading {
                MiniRing(fraction: cpuFraction, text: reading.cpuPercent.map { Format.percent($0) } ?? "...")
                    .help("CPU")
                MiniRing(fraction: memoryFraction, text: MenuBarFormat.shortBytes(reading.memoryBytes))
                    .help("Memory of \(Format.bytes(reading.memoryLimitBytes))")
            }
            if isBusy {
                ProgressView().controlSize(.small)
                    .frame(width: 20)
            } else {
                Button(action: onToggle) {
                    DeckIcon(container.isRunning ? .stop : .play, size: 12)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(container.isRunning ? "Stop" : "Start")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(
            isHovered ? DS.hover : Color.clear,
            in: RoundedRectangle(cornerRadius: DS.smallRadius)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .help("Open \(title)")
        .contextMenu {
            Button(container.isRunning ? "Stop" : "Start", action: onToggle)
            if container.isRunning {
                Button("Restart", action: onRestart)
            }
            Divider()
            Button("Show Logs", action: onLogs)
            Button("Open", action: onOpen)
        }
    }
}

/// Tiny ring with a value next to it, for container rows.
private struct MiniRing: View {
    let fraction: Double
    let text: String

    /// Rounded to whole percents so the ring only redraws when it can be seen.
    private var clamped: Double {
        let value = min(1, max(0, fraction.isFinite ? fraction : 0))
        return (value * 100).rounded() / 100
    }

    private var tint: Color {
        if clamped > 0.85 { return DS.danger }
        if clamped > 0.6 { return DS.warning }
        return DS.accent
    }

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(DS.borderStrong, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 44, alignment: .leading)
        }
    }
}

/// Full width, menu like action row.
private struct MenuActionButton: View {
    let title: String
    let icon: DeckIconName
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DeckIcon(icon, size: 14, color: DS.textSecondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                isHovered ? DS.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.smallRadius)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Small ring with a value next to it.
private struct UsageRing: View {
    let title: String
    let icon: DeckIconName
    let fraction: Double
    let value: String
    let detail: String

    /// Rounded to half a percent: the ring only redraws and animates when the change can be seen,
    /// not on every sample (memory moves by a few bytes each time).
    private var clamped: Double {
        let value = min(1, max(0, fraction.isFinite ? fraction : 0))
        return (value * 200).rounded() / 200
    }

    private var tint: Color {
        if clamped > 0.85 { return DS.danger }
        if clamped > 0.6 { return DS.warning }
        return DS.accent
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(DS.borderStrong, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                DeckIcon(icon, size: 13, color: tint)
            }
            .frame(width: 42, height: 42)
            .animation(.easeOut(duration: 0.4), value: clamped)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Short numbers for the narrow container rows: "16.9 MB", "210 MB", "1.6 GB".
enum MenuBarFormat {
    static func shortBytes(_ value: UInt64) -> String {
        let v = Double(value)
        if v < 1_000_000 { return "\(Int((v / 1_000).rounded())) KB" }
        if v < 1_000_000_000 {
            let mb = v / 1_000_000
            return mb < 99.95 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB"
        }
        let gb = v / 1_000_000_000
        return gb < 9.995 ? String(format: "%.1f GB", gb) : "\(Int(gb.rounded())) GB"
    }
}

/// The window the panel is drawn in. `dismiss` does not always close a menu bar panel,
/// so actions close this window directly.
@MainActor
final class HostWindow {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { host.window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { host.window = view.window }
    }
}

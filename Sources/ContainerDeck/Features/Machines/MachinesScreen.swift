import SwiftUI
import DeckCore

/// Container machines: light Linux VMs with your Mac user and home folder.
struct MachinesScreen: View {
    @Environment(AppState.self) private var state
    @State private var machines: [MachineSummary] = []
    @State private var selection: String?
    @State private var loaded = false
    @State private var loadError: String?
    @State private var showCreate = false
    /// The installed container tool has no `machine` command.
    @State private var unsupported = false

    var body: some View {
        Group {
            if let client = state.client {
                content(client)
            } else {
                EmptyState(
                    icon: .machines,
                    title: "Machines",
                    message: "Set up Apple's container tool first.",
                    actionTitle: "Open Setup"
                ) {
                    state.showSetup = true
                }
            }
        }
        .navigationTitle("Machines")
        .toolbar {
            ToolbarItemGroup {
                RefreshButton { await reload() }
                Button {
                    showCreate = true
                } label: {
                    DeckLabel("New Machine", icon: .add)
                }
                .help("New Machine")
                .disabled(state.client == nil || unsupported)
            }
        }
        .sheet(isPresented: $showCreate) {
            MachineCreateSheet { name in
                selection = name
                Task { await reload() }
            }
            .environment(state)
        }
        .task(id: state.resourcesVersion) {
            await reload()
        }
        // Same shared pattern as the other screens: polls only while the window is on screen.
        .autoRefresh(every: max(Prefs.refreshInterval, 5)) {
            await reload()
        }
        .onDeckDebugCommand { name, _ in
            if name == "machine-new" { showCreate = true }
        }
        .onAppear { applyFocus() }
        .onChange(of: state.focusedMachine) { _, _ in applyFocus() }
    }

    @ViewBuilder
    private func content(_ client: ContainerClient) -> some View {
        if machines.isEmpty {
            if unsupported {
                EmptyState(
                    icon: .machines,
                    title: "Machines need a newer container tool",
                    message: "This version of Apple's container tool has no machine command. Update it to use machines.",
                    actionTitle: "Check Again"
                ) {
                    Task { await reload() }
                }
            } else if !loaded {
                LoadingView("Loading machines", style: .logo)
            } else if let loadError {
                EmptyState(icon: .warning, title: "Could not load machines", message: loadError, actionTitle: "Try Again") {
                    Task { await reload() }
                }
            } else {
                EmptyState(
                    icon: .machines,
                    title: "No machines yet",
                    message: "A machine is a light Linux VM. Your Mac user and home folder are already there, so you can edit on the Mac and build inside Linux.",
                    actionTitle: "New Machine"
                ) {
                    showCreate = true
                }
            }
        } else {
            // A plain row, not HSplitView: AppKit split views run their panes and divider up
            // into the toolbar. The list draws no background of its own for the same reason.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(machines) { machine in
                            MachineRow(machine: machine)
                                .tag(machine.name)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    ListStatusBar(statusText)
                }
                .frame(width: 280)
                .background(DS.surface, ignoresSafeAreaEdges: [])

                Divider()

                Group {
                    if let name = selection, let machine = machines.first(where: { $0.name == name }) {
                        MachineDetailView(machine: machine, client: client) {
                            await reload()
                        }
                        .id(name)
                    } else {
                        EmptyState(icon: .machines, title: "Pick a machine", message: "Select a machine on the left to see its details.")
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var statusText: String {
        let running = machines.filter { $0.state == .running }.count
        let count = machines.count == 1 ? "1 machine" : "\(machines.count) machines"
        return "\(count), \(running) running"
    }

    private func reload() async {
        guard let client = state.client else { return }
        do {
            let list = try await client.listMachines()
            machines = list
            loadError = nil
            unsupported = false
            if let current = selection, list.contains(where: { $0.name == current }) {
                // Keep the selection.
            } else {
                selection = list.first(where: { $0.isDefault })?.name ?? list.first?.name
            }
        } catch {
            if MachineParser.isUnsupported(error) {
                unsupported = true
                machines = []
            } else if machines.isEmpty {
                loadError = error.localizedDescription
            }
        }
        loaded = true
    }

    private func applyFocus() {
        guard let name = state.focusedMachine else { return }
        selection = name
        state.focusedMachine = nil
    }
}

// MARK: - Row

struct MachineRow: View {
    let machine: MachineSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconBadge(.machines, tint: machine.state == .running ? DS.accent : DS.stopped, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                // The name gets the whole first line. Pills go on the second line with the image,
                // so a long name is never squeezed to "deck-q…" in the narrow list.
                Text(machine.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    StatusPill(machine.state)
                    if machine.isDefault {
                        Pill("Default")
                    }
                    if !machine.image.isEmpty {
                        Text(ContainerText.shortImage(machine.image))
                            .font(.caption)
                            .deckSecondaryText()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                HStack(spacing: 10) {
                    MachineFact(icon: .cpu, text: machine.cpus.map { "\($0) CPU" } ?? "CPU")
                    MachineFact(icon: .memory, text: Format.bytes(machine.memoryBytes))
                    if let ip = machine.ipAddress {
                        MachineFact(icon: .network, text: ip)
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }
}

struct MachineFact: View {
    let icon: DeckIconName
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            DeckIcon(icon, size: 11, color: DS.textTertiary)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
        }
        .font(.caption)
        .deckSecondaryText()
    }
}

// MARK: - Defaults for new machines

enum MachineDefaults {
    static var maxCPUs: Int { max(1, ProcessInfo.processInfo.processorCount) }

    /// Same rule as the container tool: half the cores, at least 4.
    static var defaultCPUs: Int { min(maxCPUs, max(maxCPUs / 2, 4)) }

    static var maxMemoryGB: Int {
        max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    }

    /// About half of the Mac's memory.
    static var defaultMemoryGB: Int { max(1, maxMemoryGB / 2) }

    static func homeMountTitle(_ value: String?) -> String {
        switch value {
        case "ro": return "Read only"
        case "none": return "Not mounted"
        case "rw": return "Read and write"
        default: return "Read and write"
        }
    }
}

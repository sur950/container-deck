import SwiftUI
import AppKit
import DeckCore

/// Compose: import compose files, preview them and run whole stacks.
struct ComposeScreen: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.composeDefaultCPUs) private var defaultCPUs = 2
    @AppStorage(PrefKey.composeDefaultMemory) private var defaultMemory = "1G"

    @State private var store = ComposeStore()
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 0) {
            ComposeProjectList(store: store)
                .frame(width: 250)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.surface)
        .navigationTitle("Compose")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton(help: "Refresh stacks") {
                    await store.refreshStacks(client: state.client)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.chooseFile()
                } label: {
                    DeckLabel("Import Compose File", icon: .add)
                }
                .help("Open a compose.yaml file or a folder that has one")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            store.open(files: urls)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: DS.radius)
                    .stroke(DS.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(DS.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.radius))
                    .overlay {
                        VStack(spacing: 8) {
                            DeckIcon(.compose, size: 34, color: DS.accent)
                            Text("Drop a compose file or folder").font(.headline)
                        }
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            applyDefaults()
            store.refreshPluginStatus()
        }
        .onChange(of: defaultCPUs) { applyDefaults() }
        .onChange(of: defaultMemory) { applyDefaults() }
        // Stacks come from the shared container feed. No list loop of its own.
        .onChange(of: BackgroundServices.shared.containersVersion, initial: true) { _, _ in
            store.applyContainers(BackgroundServices.shared.containers)
        }
        // The palette asks for a stack through AppState (works in release builds).
        .onChange(of: state.focusedComposeStack, initial: true) { _, _ in consumeStackFocus() }
        .onDisappear { store.stopLogs() }
        .onReceive(NotificationCenter.default.publisher(for: .deckDebugComposeOpen)) { note in
            // Debug only: a path opens the file, "up", "dryrun" and "down" run the stack.
            guard let value = note.object as? String else { return }
            if value == "up", let client = state.client {
                store.up(client: client, state: state, options: ComposeRunner.UpOptions())
            } else if value == "dryrun", let client = state.client {
                store.up(client: client, state: state, options: ComposeRunner.UpOptions(dryRun: true))
            } else if value == "down", let client = state.client {
                store.down(client: client, state: state, removeVolumes: false)
            } else if value.hasPrefix("stack:") {
                store.select(.stack(String(value.dropFirst(6))))
            } else if value.hasPrefix("tab:"), let tab = ComposeTab.allCases.first(where: { "tab:\($0)" == value }) {
                store.tab = tab
            } else if value.contains(",") {
                // Several paths, comma separated, open as one project.
                store.open(files: value.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            } else {
                store.open(URL(fileURLWithPath: value))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if state.client == nil {
            EmptyState(
                icon: .compose,
                title: "Container tool not found",
                message: "Finish setup to run compose files.",
                actionTitle: "Open Setup"
            ) {
                state.showSetup = true
            }
        } else if store.selection == nil {
            VStack(spacing: 0) {
                EmptyState(
                    icon: .compose,
                    title: "Run a whole stack",
                    message: "Import a compose.yaml file or drop it here. Stacks you start here show up on the left.",
                    actionTitle: "Import Compose File"
                ) {
                    store.chooseFile()
                }
                ComposePluginCard(store: store)
                    .frame(width: 480)
                    .padding(.horizontal, DS.pad)
                    .padding(.bottom, DS.pad)
            }
        } else {
            ComposeDetailView(store: store)
        }
    }

    private func consumeStackFocus() {
        guard let focus = state.focusedComposeStack else { return }
        state.focusedComposeStack = nil
        // Stacks may not be grouped yet when the screen just appeared.
        store.applyContainers(BackgroundServices.shared.containers)
        switch focus.selection() {
        case .file(let path):
            store.open(URL(fileURLWithPath: path))
        case .stack(let name):
            store.select(.stack(name))
        }
    }

    private func applyDefaults() {
        store.defaultCPUs = defaultCPUs > 0 ? defaultCPUs : nil
        let memory = defaultMemory.trimmingCharacters(in: .whitespaces)
        store.defaultMemory = memory.isEmpty ? nil : memory
        store.replan()
    }
}

// MARK: - Project list

private struct ComposeProjectList: View {
    let store: ComposeStore

    var body: some View {
        List(selection: Binding(get: { store.selection }, set: { store.select($0) })) {
            Section("On this Mac") {
                if store.stacks.isEmpty {
                    Text("No stacks yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.stacks) { stack in
                    StackRow(stack: stack)
                        .tag(ComposeSelection.stack(stack.name))
                }
            }
            Section("Recent files") {
                if store.recentFiles.isEmpty {
                    Text("Files you open show up here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.recentFiles, id: \.path) { file in
                    FileRow(file: file, extraFiles: store.extraFiles(for: file))
                        .tag(ComposeSelection.file(file.path))
                        .contextMenu {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([file])
                            } label: {
                                DeckLabel("Show in Finder", icon: .folder)
                            }
                            Button {
                                store.forget(file)
                            } label: {
                                DeckLabel("Remove from List", icon: .close)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        // The sidebar material would run up under the toolbar on this side only and split
        // the toolbar strip in two at the detail pane. Keep the list below the toolbar.
        .scrollContentBackground(.hidden)
        .clipped()
        .background(DS.surface, ignoresSafeAreaEdges: [])
    }
}

private struct StackRow: View {
    let stack: ComposeStack

    var body: some View {
        HStack(spacing: 8) {
            DeckIcon(.compose, size: 14, color: stack.runningCount > 0 ? DS.running : DS.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(stack.name).lineLimit(1)
                Text("\(stack.runningCount) of \(stack.services.count) running" + (stack.origin == .docker ? ", Compose labels" : ""))
                    .font(.caption)
                    .deckSecondaryText()
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FileRow: View {
    let file: URL
    var extraFiles: [URL] = []

    private var caption: String {
        switch extraFiles.count {
        case 0: return file.lastPathComponent
        case 1: return "\(file.lastPathComponent) + \(extraFiles[0].lastPathComponent)"
        default: return "\(file.lastPathComponent) + \(extraFiles.count) more"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            DeckIcon(.file, size: 14, color: DS.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.deletingLastPathComponent().lastPathComponent).lineLimit(1)
                Text(caption)
                    .font(.caption)
                    .deckSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .help(([file] + extraFiles).map(\.path).joined(separator: "\n"))
    }
}

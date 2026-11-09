import SwiftUI
import DeckCore

/// Volumes: list, create, delete, prune and browse files.
struct VolumesScreen: View {
    @Environment(AppState.self) private var state

    @State private var volumes: [VolumeSummary] = []
    /// Bytes each volume's sparse disk image really takes on the Mac, by name.
    @State private var onDisk: [String: UInt64] = [:]
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\VolumeSummary.name)]
    @State private var selection: VolumeSummary.ID?
    @State private var showCreate = false
    @State private var browsing: VolumeSummary?
    @State private var activeAlert: VolumesAlert?
    @State private var showPrune = false
    @State private var sequencer = PollSequencer()

    var body: some View {
        content
            .navigationTitle("Volumes")
            .searchable(text: $search, placement: .toolbar, prompt: "Search volumes")
            .toolbar { toolbarContent }
            .task(id: state.resourcesVersion) { await load(force: true) }
            .autoRefresh { await load() }
            .onChange(of: BackgroundServices.shared.containersVersion) { _, _ in
                Task { await refreshUsers() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deckDebugOpenSheet)) { note in
                let value = note.object as? String ?? ""
                if value == "volume-create" { showCreate = true }
                if value.hasPrefix("volume-browse:") {
                    let name = String(value.dropFirst("volume-browse:".count))
                    browsing = volumes.first { $0.name == name }
                }
            }
            .sheet(isPresented: $showCreate) {
                VolumeCreateSheet()
                    .environment(state)
            }
            .sheet(item: $browsing) { volume in
                VolumeBrowserSheet(volume: volume)
                    .environment(state)
            }
            .alert(alertTitle, isPresented: alertShown, presenting: activeAlert) { item in
                alertActions(item)
            } message: { item in
                Text(alertMessage(item))
            }
            .confirmationDialog("Remove unused volumes?", isPresented: $showPrune, titleVisibility: .visible) {
                Button("Remove Unused Volumes", role: .destructive) { prune() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Volumes not used by any container are deleted with all their data. Chat history volumes stay.")
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.client == nil {
            ResourceToolMissing(icon: .volumes)
        } else if !hasLoaded && isLoading {
            LoadingView("Loading volumes", style: .logo)
        } else if let loadError, volumes.isEmpty {
            EmptyState(icon: .error, title: "Could not load volumes", message: loadError, actionTitle: "Try Again") {
                Task { await load() }
            }
        } else if volumes.isEmpty {
            EmptyState(
                icon: .volumes,
                title: "No volumes yet",
                message: "Volumes keep data when a container is deleted.",
                actionTitle: "Create Volume"
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
        Table(visibleVolumes, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { volume in
                HStack(spacing: 8) {
                    DeckIcon(.volumes, size: 14, color: DS.accent)
                    Text(volume.name).fontWeight(.medium).lineLimit(1)
                    if volume.isAnonymous {
                        Pill("Anonymous", tint: DS.stopped)
                    }
                    if !volume.usedBy.isEmpty {
                        Pill("In use", tint: DS.running)
                    }
                }
            }
            .width(min: 160, ideal: 240)

            TableColumn("On Disk") { volume in
                Text(onDisk[volume.name].map { Format.bytes($0) } ?? "Unknown")
                    .monospacedDigit()
                    .deckRowText(onDisk[volume.name] == nil ? .secondary : .primary)
                    .help("Space the volume takes on this Mac now")
            }
            .width(min: 60, ideal: 80)

            TableColumn("Max Size", value: \.sizeSortKey) { volume in
                Text(volume.sizeBytes.map { Format.bytes($0) } ?? "Unknown")
                    .monospacedDigit()
                    .deckSecondaryText()
                    .help("The most data this volume can hold")
            }
            .width(min: 60, ideal: 80)

            TableColumn("Created", value: \.createdSortKey) { volume in
                Text(Format.relative(volume.createdAt)).deckSecondaryText()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Labels") { volume in
                Text(Self.labelText(volume.labels))
                    .deckSecondaryText()
                    .lineLimit(1)
                    .help(Self.labelText(volume.labels))
            }
            .width(min: 80, ideal: 160)

            TableColumn("Used By") { volume in
                Text(volume.usedBy.isEmpty ? "Not used" : volume.usedBy.joined(separator: ", "))
                    .deckSecondaryText()
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: VolumeSummary.ID.self) { ids in
            if let id = ids.first, let volume = volumes.first(where: { $0.id == id }) {
                rowMenu(volume)
            }
        } primaryAction: { ids in
            if let id = ids.first, let volume = volumes.first(where: { $0.id == id }) {
                browsing = volume
            }
        }
    }

    private var footer: some View {
        ListStatusBar(statusText) {
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if let volume = selectedVolume {
                HStack(spacing: 8) {
                    Button {
                        browsing = volume
                    } label: {
                        DeckLabel("Browse Files", icon: .files)
                    }
                    if let path = volume.backingPath {
                        Button {
                            ResourceUsage.revealInFinder(path)
                        } label: {
                            DeckLabel("Show in Finder", icon: .folder)
                        }
                    }
                    Button(role: .destructive) {
                        askDelete(volume)
                    } label: {
                        DeckLabel("Delete", icon: .trash)
                    }
                }
                .controlSize(.small)
            } else {
                ResourceCommandHint(["volume", "list"])
                    .fixedSize()
            }
        }
    }

    private var statusText: String {
        let count = volumes.count == 1 ? "1 volume" : "\(volumes.count) volumes"
        let used = volumes.filter { !$0.usedBy.isEmpty }.count
        let total = onDisk.values.reduce(UInt64(0), +)
        var parts = [count]
        if used > 0 { parts.append("\(used) in use") }
        if total > 0 { parts.append("\(Format.bytes(total)) on disk") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func rowMenu(_ volume: VolumeSummary) -> some View {
        Button { browsing = volume } label: { DeckLabel("Browse Files", icon: .files) }
        if let path = volume.backingPath {
            Button { ResourceUsage.revealInFinder(path) } label: { DeckLabel("Show in Finder", icon: .folder) }
        }
        Button {
            ResourceUsage.copyToPasteboard(volume.name)
            state.showToast("Copied \(volume.name)")
        } label: {
            DeckLabel("Copy Name", icon: .copy)
        }
        Divider()
        Button(role: .destructive) { askDelete(volume) } label: { DeckLabel("Delete…", icon: .trash) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showPrune = true
            } label: {
                DeckLabel("Prune", icon: .prune)
            }
            .help("Remove unused volumes")

            RefreshButton(help: "Refresh volumes", isBusy: isLoading) {
                await load()
            }

            Button {
                showCreate = true
            } label: {
                DeckLabel("Create", icon: .add)
            }
            .help("Create a volume")
        }
    }

    // MARK: - Derived values

    private var selectedVolume: VolumeSummary? {
        guard let id = selection else { return nil }
        return volumes.first { $0.id == id }
    }

    private var visibleVolumes: [VolumeSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? volumes : volumes.filter { volume in
            volume.name.lowercased().contains(query)
                || volume.labels.contains { $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query) }
        }
        return filtered.sorted(using: sortOrder)
    }

    static func labelText(_ labels: [String: String]) -> String {
        labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }

    private var alertShown: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { shown in if !shown { activeAlert = nil } }
        )
    }

    private var alertTitle: String {
        switch activeAlert {
        case .delete(let volume): return "Delete \(volume.name)?"
        case .inUse: return "This volume is in use"
        case .none: return ""
        }
    }

    private func alertMessage(_ item: VolumesAlert) -> String {
        switch item {
        case .delete(let volume) where volume.name == ChatVolumeSync.volumeName:
            return "Saved AI Models chats are deleted, and Save chat history in Settings turns off. This cannot be undone."
        case .delete:
            return "All data in this volume is deleted. This cannot be undone."
        case .inUse(let volume):
            return "Used by \(volume.usedBy.joined(separator: ", ")). Delete those containers first."
        }
    }

    @ViewBuilder
    private func alertActions(_ item: VolumesAlert) -> some View {
        switch item {
        case .delete(let volume):
            Button("Delete", role: .destructive) { delete(volume) }
            Button("Cancel", role: .cancel) {}
        case .inUse:
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Actions

    private func askDelete(_ volume: VolumeSummary) {
        activeAlert = volume.usedBy.isEmpty ? .delete(volume) : .inUse(volume)
    }

    /// `volume list` only. Who uses each volume comes from the shared `ContainerUsage`,
    /// which inspects containers only when the container list changed.
    /// `force`: something changed in the app, so look at the users again too.
    private func load(force: Bool = false) async {
        guard let client = state.client else { return }
        let token = sequencer.begin()
        isLoading = true
        do {
            let list = try await client.listVolumeSummaries()
            await ContainerUsage.shared.refresh(client: client, force: force)
            // An older load that finishes late must not replace a newer one.
            guard sequencer.accept(token) else { return }
            var sizes: [String: UInt64] = [:]
            for volume in list {
                if let bytes = ContainerClient.allocatedBytes(atPath: volume.backingPath) { sizes[volume.name] = bytes }
            }
            publish(withUsers(list))
            if sizes != onDisk { onDisk = sizes }
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

    private func withUsers(_ list: [VolumeSummary]) -> [VolumeSummary] {
        let users = ContainerUsage.shared.volumeUsers
        return list.map { volume in
            var copy = volume
            copy.usedBy = users[volume.name] ?? []
            return copy
        }
    }

    /// Only real changes reach the table, animated.
    private func publish(_ list: [VolumeSummary]) {
        guard list != volumes else { return }
        withAnimation(.easeInOut(duration: 0.25)) { volumes = list }
    }

    private func refreshUsers() async {
        await ContainerUsage.shared.refresh(client: state.client)
        publish(withUsers(volumes))
    }

    private func delete(_ volume: VolumeSummary) {
        guard let client = state.client else { return }
        Task {
            do {
                try await client.deleteVolume(volume.name)
                if volume.name == ChatVolumeSync.volumeName {
                    // Otherwise the chat would make it again: the switch decides.
                    UserDefaults.standard.set(false, forKey: PrefKey.saveChatHistory)
                    ChatSyncCenter.shared.historySettingChanged(ChatSyncCenter.modelsTarget)
                }
                if selection == volume.id { selection = nil }
                state.showToast("Deleted \(volume.name)", style: .success)
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
                let removed = try await client.pruneVolumes()
                state.showToast(removed.isEmpty ? "No unused volumes" : "Removed \(removed.count) unused \(removed.count == 1 ? "volume" : "volumes")", style: .success)
                state.resourcesChanged()
            } catch {
                state.showError(error)
            }
        }
    }
}

private enum VolumesAlert {
    case delete(VolumeSummary)
    case inUse(VolumeSummary)
}

fileprivate extension VolumeSummary {
    var sizeSortKey: UInt64 { sizeBytes ?? 0 }
    var createdSortKey: Date { createdAt ?? .distantPast }
}

// MARK: - Create

/// Create a named volume with an optional size and labels.
struct VolumeCreateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var size = ""
    @State private var labels: [ResourcePair] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedSize: String { size.trimmingCharacters(in: .whitespaces).uppercased() }

    /// Same rule as the container tool (`VolumeStorage.volumeNamePattern`).
    private var nameIsValid: Bool {
        trimmedName.count <= 255
            && trimmedName.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }

    /// The tool takes 10G, 10GB or 10GIB (any case). A bare number is bytes, at least 1 MiB.
    private var sizeIsValid: Bool {
        if trimmedSize.isEmpty { return true }
        if let bytes = UInt64(trimmedSize) { return bytes >= 1_048_576 }
        return trimmedSize.range(of: "^[0-9]+([KMGTP](I?B)?|B)$", options: .regularExpression) != nil
    }

    private var hintArguments: [String] {
        let name = trimmedName.isEmpty ? "<name>" : trimmedName
        let size = trimmedSize.isEmpty ? nil : trimmedSize
        let labelMap = ResourcePairEditor.dictionary(labels)
        if let client = state.client {
            return client.volumeCreateArguments(name: name, size: size, labels: labelMap)
        }
        var args = ["volume", "create"]
        if let size { args += ["-s", size] }
        for (key, value) in labelMap.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }
        args.append(name)
        return args
    }

    var body: some View {
        SheetScaffold("Create Volume", subtitle: "Keeps data when a container is deleted.", icon: .volumes, width: 520) {
            DeckFormGroup {
                DeckFormRow("Name") {
                    TextField("Name", text: $name, prompt: Text("my-data"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if !trimmedName.isEmpty && !nameIsValid {
                        ResourceWarningText("Use letters, numbers, dots, dashes and underscores.")
                    }
                }
                DeckFormRow("Size") {
                    TextField("Size", text: $size, prompt: Text("Default size"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if sizeIsValid {
                        DeckFormNote("For example 10G or 512M. Empty means 512 GB. It only uses the space you fill.")
                    } else {
                        ResourceWarningText("Use a number with K, M, G, T or P, like 10G. The smallest size is 1M.")
                    }
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
                .disabled(!nameIsValid || !sizeIsValid || isWorking)
        }
        .frame(height: 480)
    }

    private func create() {
        guard let client = state.client, nameIsValid, sizeIsValid, !isWorking else { return }
        let volumeName = trimmedName
        let volumeSize = trimmedSize.isEmpty ? nil : trimmedSize
        let volumeLabels = ResourcePairEditor.dictionary(labels)
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await client.createVolume(name: volumeName, size: volumeSize, labels: volumeLabels)
                state.showToast("Created \(volumeName)", style: .success)
                state.resourcesChanged()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

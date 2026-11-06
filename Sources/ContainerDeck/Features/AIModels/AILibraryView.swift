import SwiftUI
import AppKit
import DeckCore

/// Model library: search mlx-community on Hugging Face, see the size, download with
/// progress (resumable), and manage the models on this Mac.
struct AILibraryView: View {
    enum Section: String, CaseIterable { case browse, local }

    private var store: AIModelsStore { AIModelsStore.shared }
    @State private var section: Section = .browse
    @State private var localSelection: LocalModel.ID?
    @State private var deleting: LocalModel?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            switch section {
            case .browse: browse
            case .local: local
            }
        }
        .task {
            if !store.hasSearched { await store.search() }
            await store.loadLocalModels()
        }
        .confirmDelete($deleting, title: { "Delete \($0.name)?" }, message: deleteMessage) { model in
            Task { await store.deleteLocalModel(model) }
        }
    }

    private var deleteMessage: String {
        guard let deleting else { return "" }
        return deleting.source == .library
            ? "\(Format.bytes(deleting.sizeBytes)) is freed. You can download it again."
            : "It is removed from the shared Hugging Face cache, which other apps use too."
    }

    private var topBar: some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            SegmentedFilter(selection: $section, options: Section.allCases, label: { $0 == .browse ? "Browse" : "On this Mac" }) { option in
                option == .local ? store.localModels.count : nil
            }
            if section == .browse {
                HStack(spacing: 6) {
                    DeckIcon(.search, size: 13, color: DS.textSecondary)
                    TextField("Search \(AIConfig.libraryAuthor)", text: $store.query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await store.search() } }
                    if store.isSearching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 360)
                .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
                Button("Search") { Task { await store.search() } }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 10)
    }

    // MARK: Browse

    @ViewBuilder
    private var browse: some View {
        if !store.hasSearched {
            LoadingView("Searching Hugging Face", style: .logo)
        } else if let error = store.searchError, store.results.isEmpty {
            EmptyState(icon: .error, title: "Could not search Hugging Face", message: error, actionTitle: "Try Again") {
                Task { await store.search() }
            }
        } else if store.results.isEmpty {
            EmptyState(icon: .search, title: "No models found", message: "Try a shorter name, like qwen or llama.")
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    resultsTable
                    ListStatusBar("\(store.results.count) models from \(AIConfig.libraryAuthor), most downloaded first")
                }
                Divider()
                AILibraryDetail(repo: store.selectedRepo.flatMap { id in store.results.first { $0.id == id } })
                    .frame(width: 300)
                    .background(DS.surface, ignoresSafeAreaEdges: [])
            }
        }
    }

    private var resultsTable: some View {
        @Bindable var store = store
        return Table(store.results, selection: $store.selectedRepo) {
            TableColumn("Model") { model in
                HStack(spacing: 8) {
                    DeckIcon(.aiModels, size: 14, color: DS.accent)
                    Text(model.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(model.id)
                    if store.isDownloaded(model.id) { Pill("On this Mac", tint: DS.running) }
                    if store.downloads[model.id] != nil { Pill("Downloading", tint: DS.accent) }
                }
            }
            .width(min: 220, ideal: 220)
            TableColumn("Parameters") { model in
                Text(model.parameterText ?? "-").monospacedDigit().deckSecondaryText()
            }
            .width(min: 76, ideal: 76)
            TableColumn("Bits") { model in
                Text(model.quantization ?? "-").deckSecondaryText()
            }
            .width(min: 50, ideal: 50)
            TableColumn("Size") { model in
                Text(store.sizes[model.id].map { Format.bytes($0) } ?? "...").monospacedDigit().deckSecondaryText()
            }
            .width(min: 70, ideal: 70)
            TableColumn("Downloads") { model in
                Text(Format.count(model.downloads)).monospacedDigit().deckSecondaryText()
            }
            .width(min: 76, ideal: 76)
            TableColumn("Updated") { model in
                Text(Format.relative(model.lastModified)).deckSecondaryText()
            }
            .width(min: 70, ideal: 70)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: store.selectedRepo) { _, repo in
            if let repo { Task { await store.loadSizes([repo]) } }
        }
        .contextMenu(forSelectionType: HFModel.ID.self) { ids in
            if let id = ids.first {
                Button("Download") { store.download(id) }
                    .disabled(store.isDownloaded(id) || store.downloads[id] != nil)
                Button("Open on Hugging Face") {
                    if let url = URL(string: "https://huggingface.co/\(id)") { NSWorkspace.shared.open(url) }
                }
                Button("Copy Name") { ResourceUsage.copyToPasteboard(id) }
            }
        }
    }

    // MARK: On this Mac

    @ViewBuilder
    private var local: some View {
        if !store.localLoaded {
            LoadingView("Reading models", style: .logo)
        } else if store.localModels.isEmpty {
            EmptyState(icon: .download, title: "No MLX models yet", message: "Download one from Browse. Models from the Hugging Face cache show up here too.",
                       actionTitle: "Browse Models") {
                section = .browse
            }
        } else {
            VStack(spacing: 0) {
                localTable
                localFooter
            }
        }
    }

    private var localTable: some View {
        Table(store.localModels, selection: $localSelection) {
            TableColumn("Model") { model in
                HStack(spacing: 8) {
                    DeckIcon(.aiModels, size: 14, color: DS.accent)
                    Text(model.repo).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if !model.isComplete { Pill("Unfinished", tint: DS.warning) }
                    if store.serverState.isActive && store.serverConfig?.model == model.modelPath { Pill("Serving", tint: DS.running) }
                }
            }
            .width(min: 260, ideal: 260)
            TableColumn("Size") { model in
                Text(Format.bytes(model.sizeBytes)).monospacedDigit().deckSecondaryText()
            }
            .width(min: 70, ideal: 70)
            TableColumn("Where") { model in
                Text(model.source == .library ? AppConfig.appName : "Hugging Face cache").deckSecondaryText()
            }
            .width(min: 130, ideal: 130)
            TableColumn("Changed") { model in
                Text(Format.relative(model.modified)).deckSecondaryText()
            }
            .width(min: 70, ideal: 70)
        }
        .contextMenu(forSelectionType: LocalModel.ID.self) { ids in
            if let id = ids.first, let model = store.localModels.first(where: { $0.id == id }) {
                if model.isComplete {
                    Button("Serve with MLX") { serve(model) }
                } else if model.source == .library {
                    Button("Resume Download") { store.download(model.repo) }
                }
                Button("Show in Finder") { ResourceUsage.revealInFinder(model.folder.path) }
                Divider()
                Button("Delete", role: .destructive) { deleting = model }
            }
        } primaryAction: { ids in
            if let id = ids.first, let model = store.localModels.first(where: { $0.id == id }), model.isComplete { serve(model) }
        }
    }

    private var localFooter: some View {
        let total = LocalModelStore.totalSize(store.localModels)
        let free = LocalModelStore.freeSpace(at: store.paths.models)
        var text = "\(store.localModels.count) \(store.localModels.count == 1 ? "model" : "models"), \(Format.bytes(total)) on disk"
        if let free { text += ", \(Format.bytes(free)) free" }
        return ListStatusBar(text) {
            if let id = localSelection, let model = store.localModels.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    if model.isComplete {
                        Button {
                            serve(model)
                        } label: {
                            DeckLabel("Serve with MLX", icon: .play)
                        }
                    } else if model.source == .library && store.downloads[model.repo] == nil {
                        Button {
                            store.download(model.repo)
                        } label: {
                            DeckLabel("Resume", icon: .download)
                        }
                    }
                    Button {
                        ResourceUsage.revealInFinder(model.folder.path)
                    } label: {
                        DeckLabel("Show in Finder", icon: .folder)
                    }
                    Button(role: .destructive) {
                        deleting = model
                    } label: {
                        DeckLabel("Delete", icon: .trash)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func serve(_ model: LocalModel) {
        if !store.serverState.isActive { store.serverModelPath = model.modelPath }
        store.tab = .mlx
    }
}

/// Right pane: one search result with its size and the download button.
struct AILibraryDetail: View {
    let repo: HFModel?
    private var store: AIModelsStore { AIModelsStore.shared }

    var body: some View {
        if let repo {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        IconBadge(.aiModels, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.name).font(.headline).lineLimit(2)
                            Text(repo.author).font(.caption).foregroundStyle(DS.textSecondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueRow("Download size", value: store.sizes[repo.id].map { Format.bytes($0) } ?? "Checking")
                        KeyValueRow("Files", value: store.files[repo.id].map { "\($0.count)" } ?? "-")
                        KeyValueRow("Parameters", value: repo.parameterText ?? "Unknown")
                        KeyValueRow("Bits", value: repo.quantization ?? "Unknown")
                        KeyValueRow("Task", value: repo.pipelineTag ?? "Unknown")
                        KeyValueRow("Downloads", value: Format.count(repo.downloads))
                        KeyValueRow("Updated", value: Format.relative(repo.lastModified))
                    }
                    downloadSection(repo)
                    Button {
                        if let url = URL(string: "https://huggingface.co/\(repo.id)") { NSWorkspace.shared.open(url) }
                    } label: {
                        DeckLabel("Open on Hugging Face", icon: .openExternal)
                    }
                    .deckLink()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(icon: .aiModels, title: "Pick a model", message: "See its size and download it to run with MLX.")
        }
    }

    @ViewBuilder
    private func downloadSection(_ repo: HFModel) -> some View {
        if let progress = store.downloads[repo.id] {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction).tint(DS.accent)
                Text("\(Format.bytes(progress.completedBytes)) of \(Format.bytes(progress.totalBytes)), file \(min(progress.filesDone + 1, max(progress.fileCount, 1))) of \(max(progress.fileCount, 1))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                Button("Stop") { store.cancelDownload(repo.id) }
                    .help("Stops the download. Start it again to resume where it stopped.")
            }
        } else if store.isDownloaded(repo.id) {
            HStack(spacing: 8) {
                DeckIcon(.success, size: 14, color: DS.running)
                Text("On this Mac").font(.callout)
                Spacer(minLength: 0)
                Button("Serve with MLX") {
                    if let model = store.localModels.first(where: { $0.repo == repo.id && $0.isComplete }), !store.serverState.isActive {
                        store.serverModelPath = model.modelPath
                    }
                    store.tab = .mlx
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    store.download(repo.id)
                } label: {
                    DeckLabel(store.partialModel(repo.id) != nil ? "Resume Download" : "Download", icon: .download)
                        .frame(maxWidth: .infinity)
                }
                .deckPrimary()
                .controlSize(.large)
                if let error = store.downloadErrors[repo.id] {
                    Text(error).font(.caption).foregroundStyle(DS.danger)
                } else if let free = LocalModelStore.freeSpace(at: store.paths.models) {
                    Text("\(Format.bytes(free)) free on this Mac")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
        }
    }
}

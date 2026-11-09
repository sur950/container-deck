import SwiftUI
import AppKit
import DeckCore

/// Model Library: one place to find, download and clean up models for MLX, Ollama and LM Studio.
/// Browse searches mlx-community on Hugging Face, ollama.com and LM Studio's catalog. On this Mac
/// lists the models every runtime has on disk.
struct AILibraryView: View {
    enum Section: String, CaseIterable { case browse, local }

    private var store: AIModelsStore { AIModelsStore.shared }
    private var library: ModelLibraryStore { ModelLibraryStore.shared }
    @AppStorage(PrefKey.aiLibrarySection) private var sectionRaw = Section.browse.rawValue
    @State private var localSelection: InstalledModel.ID?
    /// Debug automation: a Browse row to scroll to.
    @State private var scrollTarget: String?
    @AppStorage(PrefKey.aiLibraryBrowseSort) private var browseSortRaw = AILibrarySort.browseDefault.rawValue
    @AppStorage(PrefKey.aiLibraryLocalSort) private var localSortRaw = AILibrarySort.localDefault.rawValue

    private var section: Section { Section(rawValue: sectionRaw) ?? .browse }
    private var browseSort: AILibrarySort { AILibrarySort(rawValue: browseSortRaw) ?? .browseDefault }
    private var localSort: AILibrarySort { AILibrarySort(rawValue: localSortRaw) ?? .localDefault }

    /// Table sort, saved in Prefs.
    private var browseSortOrder: Binding<[AILibraryComparator]> {
        Binding(get: { [AILibraryComparator(browseSort)] },
                set: { order in if let first = order.first { browseSortRaw = first.sort.rawValue } })
    }

    private var localSortOrder: Binding<[AILocalComparator]> {
        Binding(get: { [AILocalComparator(localSort)] },
                set: { order in if let first = order.first { localSortRaw = first.sort.rawValue } })
    }

    private var sortedRows: [AILibraryRow] {
        AILibraryRow.rows(library.rows, size: rowSize).sorted(using: AILibraryComparator(browseSort))
    }

    private var sortedInstalled: [InstalledModel] {
        library.installed.sorted(using: AILocalComparator(localSort))
    }

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            topBar
            Divider()
            switch section {
            case .browse: browse
            case .local: local
            }
        }
        .task {
            await library.search()
            await library.checkRuntimes()
            if !library.installedLoaded { await library.loadInstalled() }
        }
        .onChange(of: library.filter) { _, _ in
            Task { await library.search() }
        }
        .onChange(of: section) { _, value in
            if value == .local { Task { await library.loadInstalled() } }
        }
        .sheet(item: $library.pendingDelete) { pending in
            ModelDeleteSheet(pending: pending)
        }
        #if DEBUG
        .onDeckDebugCommand { name, value in
            switch name {
            case "ai-library-section":
                if let value = Section(rawValue: value) { sectionRaw = value.rawValue }
            case "ai-library-source":
                if let value = LibrarySourceFilter(rawValue: value) { library.filter = value }
            case "ai-library-delete":
                // Opens the delete sheet for a model on this Mac (by key). Never deletes.
                if let model = library.installed.first(where: { $0.key == value || $0.id == value }) { library.askToDelete(model) }
            case "ai-library-scroll":
                // A row index, or "bottom", in the sorted Browse list.
                let rows = sortedRows
                let index = value == "bottom" ? rows.count - 1 : (Int(value) ?? 0)
                if rows.indices.contains(index) { scrollTarget = rows[index].id }
            case "ai-library-download":
                // Starts a Browse row's download (stand in tools in checks).
                if let model = library.rows.first(where: { $0.id == value }) { library.download(model) }
            case "ai-library-local-select":
                localSelection = library.installed.first(where: { $0.key == value || $0.id == value })?.id
            case "ai-sort":
                // "size:asc" sorts the table that is showing.
                guard AILibrarySort(rawValue: value) != nil else { return }
                if section == .browse { browseSortRaw = value } else { localSortRaw = value }
            default:
                break
            }
        }
        #endif
    }

    /// Size for a row: the MLX download size, the picked Ollama tag, the smallest LM Studio option.
    private func rowSize(_ model: LibraryModel) -> UInt64? {
        switch model.source {
        case .mlx:
            return store.sizes[model.key]
        case .ollama:
            // The tag picked in the details pane, else the default tag the size queue found.
            if let tags = library.ollamaTags[model.key], let picked = library.ollamaPickedTag[model.key],
               let size = tags.first(where: { $0.tag == picked })?.sizeBytes {
                return size
            }
            return library.rowSizes[model.id]?.bytes
        case .lmStudio:
            if let detail = library.lmDetails[model.key] {
                let sizes = detail.variants.compactMap(\.repo).compactMap { repo in
                    library.variantSizes[repo] ?? library.ggufFiles[repo]?.first?.size
                }
                if let smallest = sizes.min() { return smallest }
            }
            return library.rowSizes[model.id]?.bytes
        }
    }

    /// Tooltip for the Size column: what the size is of.
    private func sizeHelp(_ row: AILibraryRow) -> String {
        switch row.model.source {
        case .mlx:
            return [row.model.quantization, "all files"].compactMap { $0 }.joined(separator: ", ")
        case .ollama:
            let tag = library.ollamaTags[row.model.key] != nil ? library.ollamaPickedTag[row.model.key] : library.rowSizes[row.model.id]?.label
            return "\(row.model.key):\(tag ?? "latest")"
        case .lmStudio:
            if let label = library.rowSizes[row.model.id]?.label { return "Smallest download option, \(label)" }
            return "Smallest download option"
        }
    }

    private var topBar: some View {
        @Bindable var store = store
        @Bindable var library = library
        let sectionBinding = Binding(get: { section }, set: { sectionRaw = $0.rawValue })
        return HStack(spacing: 12) {
            SegmentedFilter(selection: sectionBinding, options: Section.allCases, label: { $0 == .browse ? "Browse" : "On this Mac" }) { option in
                option == .local && library.installedLoaded ? library.installed.count : nil
            }
            if section == .browse {
                SegmentedFilter(selection: $library.filter, options: LibrarySourceFilter.allCases, label: \.title)
                HStack(spacing: 6) {
                    DeckIcon(.search, size: 13, color: DS.textSecondary)
                    TextField(searchPlaceholder, text: $store.query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await library.search() } }
                    if library.isSearching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 320)
                .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
                Button("Search") { Task { await library.search() } }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 10)
    }

    private var searchPlaceholder: String {
        switch library.filter {
        case .all: return "Search all models"
        case .mlx: return "Search \(AIConfig.libraryAuthor)"
        case .ollama: return "Search ollama.com"
        case .lmStudio: return "Search LM Studio models"
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var browse: some View {
        if !library.hasSearched && library.rows.isEmpty {
            LoadingView("Searching models", style: .logo)
        } else if library.rows.isEmpty {
            if let error = browseError {
                EmptyState(icon: .error, title: "Could not search", message: error, actionTitle: "Try Again") {
                    Task { await library.search(force: true) }
                }
            } else {
                EmptyState(icon: .search, title: "No models found", message: "Try a shorter name, like qwen or llama.")
            }
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    resultsTable
                    browseFooter
                }
                Divider()
                AILibraryDetail(model: selectedRow)
                    .frame(width: 300)
                    .background(DS.surface, ignoresSafeAreaEdges: [])
            }
        }
    }

    private var browseError: String? {
        switch library.filter {
        case .mlx: return store.searchError
        case .lmStudio: return library.lmError
        case .ollama: return nil
        case .all: return [store.searchError, library.lmError].compactMap { $0 }.first
        }
    }

    private var selectedRow: LibraryModel? {
        guard let id = store.selectedRepo else { return nil }
        return library.rows.first { $0.id == id }
    }

    private var resultsTable: some View {
        @Bindable var store = store
        return ScrollViewReader { proxy in
            Table(sortedRows, selection: $store.selectedRepo, sortOrder: browseSortOrder) {
                TableColumn("Model", sortUsing: AILibraryComparator(column: .model)) { row in
                    HStack(spacing: 8) {
                        DeckIcon(row.model.source.deckIcon, size: 14, color: DS.accent)
                        Text(row.model.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(row.model.summary ?? row.model.key)
                        if library.isDownloading(row.model) {
                            Pill("Downloading", tint: DS.accent)
                        } else if library.isOnThisMac(row.model) {
                            Pill("On this Mac", tint: DS.running)
                        }
                        if row.model.isStaffPick { Pill("Staff pick", tint: DS.stopped).help("Picked by the LM Studio team") }
                        if row.model.source == .mlx, let type = store.unsupportedModelType(row.model.key) {
                            // An icon keeps the name readable. The detail pane shows the full pill.
                            DeckIcon(.warning, size: 12, color: DS.warning)
                                .help("Not supported by MLX yet. \(store.unsupportedNote(type))")
                        }
                    }
                    // Rows on screen look up their size, a few at a time.
                    .onAppear { library.rowAppeared(row.model) }
                    .onDisappear { library.rowDisappeared(row.model) }
                }
                .width(min: 190, ideal: 210)
                TableColumn("Source", sortUsing: AILibraryComparator(column: .source)) { row in
                    Text(row.model.source.displayName).deckSecondaryText()
                }
                .width(min: 66, ideal: 72)
                TableColumn("Parameters", sortUsing: AILibraryComparator(column: .parameters, order: .reverse)) { row in
                    Text(row.model.parameterText ?? "-").monospacedDigit().deckSecondaryText().help(row.model.parameterText ?? "")
                }
                .width(min: 76, ideal: 92)
                TableColumn("Size", sortUsing: AILibraryComparator(column: .size)) { row in
                    // Size when known, else the quantization.
                    Text(sizeText(row)).monospacedDigit().deckSecondaryText().help(sizeHelp(row))
                }
                .width(min: 64, ideal: 70)
                TableColumn("Downloads", sortUsing: AILibraryComparator(column: .downloads, order: .reverse)) { row in
                    Text(row.model.downloads > 0 ? Format.count(row.model.downloads) : "-").monospacedDigit().deckSecondaryText()
                }
                .width(min: 70, ideal: 76)
                TableColumn("Updated", sortUsing: AILibraryComparator(column: .updated, order: .reverse)) { row in
                    Text(row.model.lastModified == nil ? "-" : Format.relative(row.model.lastModified)).deckSecondaryText()
                }
                .width(min: 64, ideal: 70)
            }
            .onChange(of: library.rows) { _, _ in
                // Keep a kept selection in view after a new search.
                if let id = store.selectedRepo { proxy.scrollTo(id) }
            }
            .onChange(of: browseSortRaw) { _, _ in
                if let id = store.selectedRepo { proxy.scrollTo(id) }
            }
            .onChange(of: scrollTarget) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: store.selectedRepo) { _, id in
                if let id, let model = library.rows.first(where: { $0.id == id }) { Task { await library.loadDetail(model) } }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let model = library.rows.first(where: { $0.id == id }) {
                    Button("Download") { library.download(model) }
                        .disabled(library.isOnThisMac(model) || library.isDownloading(model) || library.blocker(model.source) != nil)
                    if let url = model.webURL {
                        Button("Open on \(Self.siteName(model.source))") { NSWorkspace.shared.open(url) }
                    }
                    Button("Copy Name") { ResourceUsage.copyToPasteboard(model.key) }
                }
            }
        }
    }

    /// The size, "…" while it is looked up, "-" only when it can't be found.
    private func sizeText(_ row: AILibraryRow) -> String {
        if let size = row.size { return Format.bytes(size) }
        if row.model.source == .mlx { return quantText(row.model) ?? "…" }
        if library.sizeMissing.contains(row.model.id) { return quantText(row.model) ?? "-" }
        return "…"
    }

    private func quantText(_ model: LibraryModel) -> String? {
        if let quantization = model.quantization { return quantization }
        if model.source == .ollama, let picked = library.ollamaPickedTag[model.key],
           let tag = library.ollamaTags[model.key]?.first(where: { $0.tag == picked }) {
            return tag.quantization
        }
        return nil
    }

    static func siteName(_ source: ModelSource) -> String {
        switch source {
        case .mlx: return "Hugging Face"
        case .ollama: return "ollama.com"
        case .lmStudio: return "lmstudio.ai"
        }
    }

    private var browseFooter: some View {
        @Bindable var library = library
        return ListStatusBar(browseStatus) {
            if library.filter == .ollama {
                HStack(spacing: 6) {
                    TextField("Pull any name:tag", text: $library.exactName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .onSubmit { pullExact() }
                    Button {
                        pullExact()
                    } label: {
                        DeckLabel("Pull", icon: .pull)
                    }
                    .disabled(library.exactName.trimmingCharacters(in: .whitespaces).isEmpty || store.isPulling || library.blocker(.ollama) != nil)
                    .help(library.blocker(.ollama)?.reason ?? "Downloads this exact name with Ollama")
                }
                .controlSize(.small)
            }
        }
    }

    private func pullExact() {
        library.pullOllama(library.exactName)
        library.exactName = ""
    }

    private var browseStatus: String {
        let count = library.rows.count
        var parts: [String] = []
        switch library.filter {
        case .all: parts.append("\(count) models from Hugging Face, ollama.com and LM Studio")
        case .mlx: parts.append("\(count) models from \(AIConfig.libraryAuthor)")
        case .ollama: parts.append("\(count) models from ollama.com")
        case .lmStudio: parts.append("\(count) models from LM Studio's catalog")
        }
        parts.append(browseSort.phrase)
        var text = parts.joined(separator: ", ")
        if library.filter.includes(.ollama), library.ollamaOrigin == .builtIn {
            text += ". ollama.com did not answer, showing popular models"
        } else if library.filter.includes(.ollama), library.ollamaOrigin == .cached || library.filter.includes(.lmStudio) && library.lmOrigin == .cached {
            text += ". Offline, showing saved results"
        }
        return text
    }

    // MARK: On this Mac

    @ViewBuilder
    private var local: some View {
        if !library.installedLoaded {
            LoadingView("Reading models", style: .logo)
        } else if library.installed.isEmpty {
            EmptyState(icon: .download, title: "No models yet",
                       message: "Download one from Browse. Models from Ollama, LM Studio and the Hugging Face cache show up here too.",
                       actionTitle: "Browse Models") {
                sectionRaw = Section.browse.rawValue
            }
        } else {
            VStack(spacing: 0) {
                localTable
                localFooter
            }
        }
    }

    private var localTable: some View {
        Table(sortedInstalled, selection: $localSelection, sortOrder: localSortOrder) {
            TableColumn("Model", sortUsing: AILocalComparator(column: .model)) { model in
                HStack(spacing: 8) {
                    DeckIcon(model.source.deckIcon, size: 14, color: DS.accent)
                    Text(model.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(model.key)
                    if library.deleting.contains(model.id) {
                        ProgressView().controlSize(.small)
                    } else if model.isLoaded {
                        AIStatusPill(text: model.source == .mlx ? "Serving" : "Loaded", tint: DS.running)
                    }
                    if !model.isComplete { Pill("Unfinished", tint: DS.warning) }
                    if model.isBuiltIn { Pill("Built in", tint: DS.stopped).help("Comes with LM Studio") }
                    if model.filesMissing { Pill("Files missing", tint: DS.warning).help("LM Studio still lists it, but its files are gone") }
                    if model.isComplete, model.source == .mlx, let local = model.local, let type = store.unsupportedModelType(local: local) {
                        DeckIcon(.warning, size: 12, color: DS.warning).help(store.unsupportedNote(type))
                    }
                }
            }
            .width(min: 230, ideal: 260)
            TableColumn("Source", sortUsing: AILocalComparator(column: .source)) { model in
                Text(model.source.displayName).deckSecondaryText()
            }
            .width(min: 70, ideal: 76)
            TableColumn("Size", sortUsing: AILocalComparator(column: .size, order: .reverse)) { model in
                Text(Format.bytes(model.sizeBytes)).monospacedDigit().deckSecondaryText()
            }
            .width(min: 66, ideal: 72)
            TableColumn("Last used", sortUsing: AILocalComparator(column: .updated, order: .reverse)) { model in
                Text(Self.lastUsedText(model)).deckSecondaryText()
                    .help(model.downloaded.map { "Downloaded \(Format.relative($0))" } ?? "")
            }
            .width(min: 78, ideal: 86)
            TableColumn("Where", sortUsing: AILocalComparator(column: .location)) { model in
                Text(model.folderText ?? "-")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .deckSecondaryText()
                    .help(model.folder?.path ?? (model.filesMissing ? "Its files are gone" : ""))
            }
            .width(min: 140, ideal: 260)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: InstalledModel.ID.self) { ids in
            if let id = ids.first, let model = library.installed.first(where: { $0.id == id }) {
                if model.isComplete {
                    Button(library.useTitle(model)) { Task { await library.use(model) } }
                        .disabled(!library.canUse(model))
                } else if model.source == .mlx {
                    Button("Resume Download") { store.download(model.key) }
                }
                if let location = model.location {
                    Button("Show in Finder") { ResourceUsage.revealInFinder(location.path) }
                }
                Button("Copy Name") { ResourceUsage.copyToPasteboard(model.key) }
                Divider()
                Button("Delete", role: .destructive) { library.askToDelete(model) }
                    .disabled(!model.isDeletable)
            }
        } primaryAction: { ids in
            if let id = ids.first, let model = library.installed.first(where: { $0.id == id }), model.isComplete, library.canUse(model) {
                Task { await library.use(model) }
            }
        }
    }

    static func lastUsedText(_ model: InstalledModel) -> String {
        if model.isLoaded { return "Now" }
        guard let used = model.lastUsed else { return "Not yet" }
        return Format.relative(used)
    }

    private var localFooter: some View {
        let totals = library.totals
        var text = "\(totals.count) \(totals.count == 1 ? "model" : "models"), \(Format.bytes(totals.total)) on disk"
        let breakdown = totals.breakdown(Format.bytes)
        if totals.bySource.filter({ $0.value > 0 }).count > 1 { text += " (\(breakdown))" }
        return ListStatusBar(text) {
            if let id = localSelection, let model = library.installed.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    if model.isComplete {
                        Button {
                            Task { await library.use(model) }
                        } label: {
                            DeckLabel(library.useTitle(model), icon: model.isLoaded ? .chat : .play)
                        }
                        .disabled(!library.canUse(model))
                    } else if model.source == .mlx && store.downloads[model.key] == nil {
                        Button {
                            store.download(model.key)
                        } label: {
                            DeckLabel("Resume", icon: .download)
                        }
                    }
                    if let location = model.location {
                        Button {
                            ResourceUsage.revealInFinder(location.path)
                        } label: {
                            DeckLabel("Show in Finder", icon: .folder)
                        }
                    }
                    Button(role: .destructive) {
                        library.askToDelete(model)
                    } label: {
                        DeckLabel("Delete", icon: .trash)
                    }
                    .disabled(!model.isDeletable || library.deleting.contains(model.id))
                    .help(model.isDeletable ? "Delete it from this Mac" : (model.filesMissing ? "Its files are already gone" : "Comes with LM Studio"))
                }
                .controlSize(.small)
            }
        }
    }
}

extension ModelSource {
    /// Same icons as the server kinds.
    var deckIcon: DeckIconName {
        switch self {
        case .mlx: return .cpu
        case .ollama: return .aiModels
        case .lmStudio: return .sparkle
        }
    }
}

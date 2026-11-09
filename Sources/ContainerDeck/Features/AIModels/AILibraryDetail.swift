import SwiftUI
import AppKit
import DeckCore

/// Right pane of Browse: one model with its sizes and the download button for its runtime.
struct AILibraryDetail: View {
    let model: LibraryModel?
    private var store: AIModelsStore { AIModelsStore.shared }
    private var library: ModelLibraryStore { ModelLibraryStore.shared }

    var body: some View {
        if let model {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(model)
                    if let summary = model.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switch model.source {
                    case .mlx: mlxFacts(model)
                    case .ollama: ollamaFacts(model)
                    case .lmStudio: lmFacts(model)
                    }
                    downloadSection(model)
                    // Tags and download options sit under the button, so it stays in view.
                    switch model.source {
                    case .mlx: EmptyView()
                    case .ollama: ollamaTags(model)
                    case .lmStudio: lmVariants(model)
                    }
                    if let url = model.webURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            DeckLabel("Open on \(AILibraryView.siteName(model.source))", icon: .openExternal)
                        }
                        .deckLink()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(icon: .aiModels, title: "Pick a model", message: "See its sizes and download it for MLX, Ollama or LM Studio.")
        }
    }

    private func header(_ model: LibraryModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(model.source.deckIcon, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name).font(.headline).lineLimit(2)
                if let author = model.author { Text(author).font(.caption).foregroundStyle(DS.textSecondary) }
                HStack(spacing: 4) {
                    Pill(model.source.displayName)
                    if model.isStaffPick { Pill("Staff pick", tint: DS.stopped) }
                    ForEach(model.capabilities.filter { $0 != "text-generation" }.prefix(3), id: \.self) { capability in
                        Pill(capability.capitalized, tint: DS.stopped)
                    }
                }
                if model.source == .mlx, let type = store.unsupportedModelType(model.key) {
                    Pill("Not supported by MLX yet", tint: DS.warning).help(store.unsupportedNote(type))
                }
            }
        }
    }

    // MARK: Facts

    private func mlxFacts(_ model: LibraryModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            KeyValueRow("Download size", value: store.sizes[model.key].map { Format.bytes($0) } ?? "Checking")
            KeyValueRow("Files", value: store.files[model.key].map { "\($0.count)" } ?? "-")
            KeyValueRow("Parameters", value: model.parameterText ?? "Unknown")
            KeyValueRow("Bits", value: model.quantization ?? "Unknown")
            KeyValueRow("Downloads", value: Format.count(model.downloads))
            KeyValueRow("Updated", value: Format.relative(model.lastModified))
        }
    }

    private func ollamaFacts(_ model: LibraryModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                KeyValueRow("Sizes", value: model.parameterText ?? "One size")
                KeyValueRow("Downloads", value: model.downloads > 0 ? Format.count(model.downloads) : "Unknown")
                KeyValueRow("Updated", value: model.lastModified == nil ? "Unknown" : Format.relative(model.lastModified))
                if let count = model.tagCount { KeyValueRow("Tags", value: "\(count)") }
            }
        }
    }

    @ViewBuilder
    private func ollamaTags(_ model: LibraryModel) -> some View {
        if let tags = library.ollamaTags[model.key] {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tag").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                VStack(spacing: 0) {
                    ForEach(Array(tags.prefix(40).enumerated()), id: \.element.id) { index, tag in
                        if index > 0 { Divider() }
                        tagRow(model, tag)
                    }
                }
                .deckCard(radius: DS.smallRadius)
                if tags.count > 40 {
                    Text("\(tags.count - 40) more on ollama.com. Pull any of them by name.")
                        .font(.caption).foregroundStyle(DS.textTertiary)
                }
            }
        } else if let error = library.ollamaTagErrors[model.key] {
            Text(error).font(.caption).foregroundStyle(DS.textSecondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading tags").font(.caption).foregroundStyle(DS.textSecondary)
            }
        }
    }

    private func tagRow(_ model: LibraryModel, _ tag: OllamaLibraryTag) -> some View {
        let picked = library.ollamaPickedTag[model.key] == tag.tag
        let installed = store.ollamaModels.contains { $0.id == "\(model.key):\(tag.tag)" }
        return Button {
            library.ollamaPickedTag[model.key] = tag.tag
        } label: {
            HStack(spacing: 8) {
                DeckIcon(picked ? .success : .pending, size: 12, color: picked ? DS.accent : DS.textTertiary)
                Text(tag.tag).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                if installed { Pill("On this Mac", tint: DS.running) }
                Spacer(minLength: 4)
                Text(tag.sizeBytes.map { Format.bytes($0) } ?? "-")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tag.context.map { "\(tag.tag), \($0) context" } ?? tag.tag)
    }

    private func lmFacts(_ model: LibraryModel) -> some View {
        let detail = library.lmDetails[model.key]
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                KeyValueRow("Parameters", value: detail?.parameters.joined(separator: ", ").nonEmpty ?? model.parameterText ?? "Unknown")
                KeyValueRow("Needs memory", value: detail?.minMemoryBytes.map { "About \(Format.bytes($0))" } ?? (detail == nil ? "Checking" : "Unknown"))
                KeyValueRow("Formats", value: detail?.formatText ?? (detail == nil ? "Checking" : "Unknown"))
                if let context = detail?.contextLength { KeyValueRow("Context", value: Format.count(context) + " tokens") }
                KeyValueRow("Downloads", value: Format.count(model.downloads))
                KeyValueRow("Updated", value: model.lastModified == nil ? "Unknown" : Format.relative(model.lastModified))
            }
        }
    }

    @ViewBuilder
    private func lmVariants(_ model: LibraryModel) -> some View {
        let detail = library.lmDetails[model.key]
        VStack(alignment: .leading, spacing: 12) {
            if let detail, !detail.variants.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Download options").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                    VStack(spacing: 0) {
                        ForEach(Array(detail.variants.enumerated()), id: \.element.id) { index, variant in
                            if index > 0 { Divider() }
                            variantRow(variant)
                        }
                    }
                    .deckCard(radius: DS.smallRadius)
                    Text("lms picks the best option for this Mac.")
                        .font(.caption).foregroundStyle(DS.textTertiary)
                }
            } else if let error = library.lmDetailErrors[model.key] {
                Text(error).font(.caption).foregroundStyle(DS.textSecondary)
            }
        }
    }

    private func variantRow(_ variant: LMStudioVariant) -> some View {
        let repo = variant.repo ?? variant.key
        let size: String
        if let bytes = library.variantSizes[repo] {
            size = Format.bytes(bytes)
        } else if let files = library.ggufFiles[repo], let low = files.first?.size, let high = files.last?.size {
            size = low == high ? Format.bytes(low) : "\(Format.bytes(low)) to \(Format.bytes(high))"
        } else {
            size = "-"
        }
        return HStack(spacing: 8) {
            Pill(variant.format, tint: variant.format == "MLX" ? DS.accent : DS.stopped)
            Text(variant.quantization ?? (repo.split(separator: "/").last.map(String.init) ?? repo))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(size).font(.caption.monospacedDigit()).foregroundStyle(DS.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help(repo)
    }

    // MARK: Download

    @ViewBuilder
    private func downloadSection(_ model: LibraryModel) -> some View {
        if library.isDownloading(model) {
            progress(model)
        } else if library.isOnThisMac(model) && (model.source != .ollama || pickedTagInstalled(model)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DeckIcon(.success, size: 14, color: DS.running)
                    Text("On this Mac").font(.callout)
                    Spacer(minLength: 0)
                    Button(model.source == .mlx ? "Serve with MLX" : "Show") { showOnThisMac(model) }
                        .disabled(model.source == .mlx && store.unsupportedModelType(model.key) != nil)
                }
                if model.source == .mlx { unsupportedWarning(model) }
            }
        } else if let blocker = library.blocker(model.source) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    DeckIcon(.info, size: 13, color: DS.textSecondary)
                    Text(blocker.reason).font(.callout).foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    store.tab = blocker.tab
                } label: {
                    DeckLabel(blocker.buttonTitle, icon: .chevronRight)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.source == .mlx { unsupportedWarning(model) }
                Button {
                    library.download(model)
                } label: {
                    DeckLabel(downloadTitle(model), icon: .download)
                        .frame(maxWidth: .infinity)
                }
                .deckPrimary()
                .controlSize(.large)
                .disabled(model.source == .ollama && store.isPulling)
                .help(downloadHelp(model))
                if let error = downloadError(model) {
                    Text(error).font(.caption).foregroundStyle(DS.danger).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(downloadNote(model)).font(.caption).foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func pickedTagInstalled(_ model: LibraryModel) -> Bool {
        let name = library.ollamaPullName(model.key)
        let full = name.contains(":") ? name : name + ":latest"
        return store.ollamaModels.contains { $0.id == full }
    }

    private func downloadTitle(_ model: LibraryModel) -> String {
        switch model.source {
        case .mlx: return store.partialModel(model.key) != nil ? "Resume Download" : "Download"
        case .ollama: return "Download \(library.ollamaPullName(model.key))"
        case .lmStudio: return "Download with LM Studio"
        }
    }

    private func downloadHelp(_ model: LibraryModel) -> String {
        switch model.source {
        case .mlx: return "Downloads into \(AppConfig.appName)'s model folder"
        case .ollama: return "ollama pull \(library.ollamaPullName(model.key))"
        case .lmStudio: return "lms get \(model.key) --yes"
        }
    }

    private func downloadNote(_ model: LibraryModel) -> String {
        let free = LocalModelStore.freeSpace(at: store.paths.models).map { "\(Format.bytes($0)) free on this Mac" } ?? ""
        switch model.source {
        case .mlx: return free
        case .ollama: return store.isPulling ? "Another pull is running." : free
        case .lmStudio: return free
        }
    }

    private func downloadError(_ model: LibraryModel) -> String? {
        switch model.source {
        case .mlx: return store.downloadErrors[model.key]
        case .ollama: return nil
        case .lmStudio: return library.lmDownloadErrors[model.key]
        }
    }

    @ViewBuilder
    private func progress(_ model: LibraryModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.source {
            case .mlx:
                if let progress = store.downloads[model.key] {
                    ProgressView(value: progress.fraction).tint(DS.accent)
                    caption("\(Format.bytes(progress.completedBytes)) of \(Format.bytes(progress.totalBytes)), file \(min(progress.filesDone + 1, max(progress.fileCount, 1))) of \(max(progress.fileCount, 1))")
                }
            case .ollama:
                if let progress = store.pullProgress {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).tint(DS.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(DS.accent)
                    }
                    caption(pullCaption(progress))
                }
            case .lmStudio:
                if let progress = library.lmDownloads[model.key] {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).tint(DS.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(DS.accent)
                    }
                    if let done = progress.completedBytes, let total = progress.totalBytes {
                        caption("\(Format.bytes(done)) of \(Format.bytes(total))")
                    } else if let message = progress.message {
                        caption(message)
                    }
                }
            }
            Button("Stop") { library.cancelDownload(model) }
                .help(model.source == .lmStudio ? "Stops lms get" : "Stops the download. Start it again to resume where it stopped.")
        }
    }

    private func pullCaption(_ progress: OllamaPullProgress) -> String {
        var text = (store.pullingName.map { $0 + ": " } ?? "") + progress.stepText
        if let total = progress.total, let done = progress.completed, total > 0 {
            text += ", \(Format.bytes(done)) of \(Format.bytes(total))"
        }
        return text
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(DS.textSecondary)
            .lineLimit(2)
    }

    private func showOnThisMac(_ model: LibraryModel) {
        if model.source == .mlx {
            if let local = store.localModels.first(where: { $0.repo == model.key && $0.isComplete }), !store.serverState.isActive {
                store.serverModelPath = local.modelPath
            }
            store.tab = .mlx
        } else {
            UserDefaults.standard.set(AILibraryView.Section.local.rawValue, forKey: PrefKey.aiLibrarySection)
        }
    }

    /// This mlx-lm cannot load the repo's model type. The download stays allowed.
    @ViewBuilder
    private func unsupportedWarning(_ model: LibraryModel) -> some View {
        if let type = store.unsupportedModelType(model.key) {
            HStack(alignment: .top, spacing: 6) {
                DeckIcon(.warning, size: 12, color: DS.warning)
                Text("\(store.unsupportedNote(type)) You can download it, but the MLX server can't run it until mlx-lm supports it.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

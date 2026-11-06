import SwiftUI
import AppKit
import DeckCore

/// Ollama: start and stop the server, pull models, load and unload them, delete them.
struct AIOllamaView: View {
    private var store: AIModelsStore { AIModelsStore.shared }
    @State private var selection: ModelEndpointModel.ID?
    @State private var deleting: ModelEndpointModel?
    @State private var sortOrder = [KeyPathComparator(\ModelEndpointModel.id)]

    var body: some View {
        Group {
            if !store.ollamaLoaded {
                LoadingView("Checking Ollama", style: .logo)
            } else if !store.ollamaInstalled {
                EmptyState(icon: .aiModels, title: "Ollama is not installed",
                           message: "Install Ollama to pull and run models like Llama, Qwen and Mistral. It shows up here on its own.",
                           actionTitle: "Get Ollama") {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                }
            } else if !store.ollamaRunning {
                EmptyState(icon: .aiModels, title: "Ollama is not running",
                           message: "Start it to list, pull and load models.",
                           actionTitle: store.ollamaStarting ? "Starting" : "Start Ollama") {
                    Task { await store.startOllama() }
                }
            } else {
                VStack(spacing: 0) {
                    pullBar
                    Divider()
                    if store.ollamaModels.isEmpty {
                        EmptyState(icon: .download, title: "No models yet", message: "Pull one above, like qwen3:0.6b or llama3.2.")
                    } else {
                        table
                    }
                    footer
                }
            }
        }
        .task { await store.loadOllama() }
        .confirmDelete($deleting, title: { "Delete \($0.id)?" }, message: "The model is removed from Ollama on this Mac.") { model in
            Task { await store.deleteOllamaModel(model) }
        }
    }

    private var pullBar: some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            DeckIcon(.download, size: 16, color: DS.textSecondary)
            TextField("Model to pull, like qwen3:0.6b", text: $store.pullName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit { store.pullOllamaModel() }
                .disabled(store.isPulling)
            if store.isPulling {
                Button("Stop") { store.cancelPull() }
                if let progress = store.pullProgress {
                    VStack(alignment: .leading, spacing: 3) {
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction).tint(DS.accent)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(DS.accent)
                        }
                        Text(pullCaption(progress))
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 320)
                }
            } else {
                Button {
                    store.pullOllamaModel()
                } label: {
                    DeckLabel("Pull", icon: .pull)
                }
                .deckPrimary()
                .disabled(store.pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com/library")!)
                } label: {
                    DeckLabel("Browse Models", icon: .openExternal)
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
            Button {
                Task { await store.stopOllama() }
            } label: {
                DeckLabel("Stop Ollama", icon: .stop)
            }
            .help("Quit Ollama. Models stay on disk.")
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 10)
    }

    private func pullCaption(_ progress: OllamaPullProgress) -> String {
        var text = progress.stepText
        if let total = progress.total, let done = progress.completed, total > 0 {
            text += ", \(Format.bytes(done)) of \(Format.bytes(total))"
        }
        return text
    }

    private var sortedModels: [ModelEndpointModel] {
        store.ollamaModels.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(sortedModels, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.id) { model in
                HStack(spacing: 8) {
                    DeckIcon(.aiModels, size: 14, color: DS.accent)
                    Text(model.id).fontWeight(.medium).lineLimit(1)
                }
            }
            .width(min: 200, ideal: 200)
            TableColumn("Status") { model in
                if store.ollamaBusy.contains(model.id) {
                    ProgressView().controlSize(.small)
                } else if model.isLoaded {
                    AIStatusPill(text: "Loaded", tint: DS.running)
                } else {
                    AIStatusPill(text: "On disk", tint: DS.stopped)
                }
            }
            .width(min: 90, ideal: 90)
            TableColumn("Size") { model in
                Text(Format.bytes(model.sizeBytes)).monospacedDigit().deckSecondaryText()
            }
            .width(min: 70, ideal: 70)
            TableColumn("Parameters") { model in
                Text(model.parameterSize ?? "-").monospacedDigit().deckSecondaryText()
            }
            .width(min: 80, ideal: 80)
            TableColumn("Quantization") { model in
                Text(model.quantization ?? "-").deckSecondaryText()
            }
            .width(min: 90, ideal: 90)
            TableColumn("") { model in
                HStack(spacing: 6) {
                    Button(model.isLoaded ? "Unload" : "Load") {
                        Task { await store.toggleOllamaModel(model) }
                    }
                    .controlSize(.small)
                    .disabled(store.ollamaBusy.contains(model.id))
                    .help(model.isLoaded ? "Free the memory it uses" : "Load it into memory now")
                }
            }
            .width(min: 70, ideal: 70)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: ModelEndpointModel.ID.self) { ids in
            if let id = ids.first, let model = store.ollamaModels.first(where: { $0.id == id }) {
                Button(model.isLoaded ? "Unload" : "Load") { Task { await store.toggleOllamaModel(model) } }
                if let endpoint = store.endpoints.first(where: { $0.kind == .ollama && $0.isRunning }) {
                    Button("Chat") { store.openChat(endpoint, model: model.id) }
                }
                Button("Copy Name") { ResourceUsage.copyToPasteboard(model.id) }
                Divider()
                Button("Delete", role: .destructive) { deleting = model }
            }
        }
    }

    private var footer: some View {
        let loaded = store.ollamaModels.filter(\.isLoaded).count
        let total = store.ollamaModels.reduce(UInt64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let text = "\(store.ollamaModels.count) \(store.ollamaModels.count == 1 ? "model" : "models"), \(loaded) loaded, \(Format.bytes(total)) on disk"
        return ListStatusBar(text) {
            if let id = selection, let model = store.ollamaModels.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    if let endpoint = store.endpoints.first(where: { $0.kind == .ollama && $0.isRunning }) {
                        Button {
                            store.openChat(endpoint, model: model.id)
                        } label: {
                            DeckLabel("Chat", icon: .chat)
                        }
                    }
                    Button(role: .destructive) {
                        deleting = model
                    } label: {
                        DeckLabel("Delete", icon: .trash)
                    }
                }
                .controlSize(.small)
            } else {
                CommandHint("ollama list")
                    .fixedSize()
            }
        }
    }
}

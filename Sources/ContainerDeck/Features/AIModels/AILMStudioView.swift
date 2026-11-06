import SwiftUI
import AppKit
import DeckCore

/// LM Studio: get it, start and stop its server, and load or unload the models it has on disk.
struct AILMStudioView: View {
    private var store: AIModelsStore { AIModelsStore.shared }
    @State private var selection: LMStudioModel.ID?
    @State private var sortOrder = [KeyPathComparator(\LMStudioModel.id)]

    var body: some View {
        Group {
            if !store.lmLoaded {
                LoadingView("Checking LM Studio", style: .logo)
            } else if let status = store.lmStatus, status.isInstalled {
                if status.cliPath == nil {
                    EmptyState(icon: .sparkle, title: "Open LM Studio once",
                               message: "LM Studio sets up its lms command the first time it opens. Open it, then come back here.",
                               actionTitle: "Open LM Studio") {
                        openApp()
                    }
                } else {
                    VStack(spacing: 0) {
                        serverBar(status)
                        Divider()
                        if store.lmModels.isEmpty {
                            EmptyState(icon: .download, title: "No models yet",
                                       message: status.isCoreOnly
                                           ? "Download a model in Terminal with lms get, for example lms get qwen/qwen3-4b. It shows up here."
                                           : "Download models in the LM Studio app. They show up here.",
                                       actionTitle: status.appPath == nil ? nil : "Open LM Studio") {
                                openApp()
                            }
                        } else {
                            table
                        }
                        footer
                    }
                }
            } else {
                notInstalled
            }
        }
        .task { await store.loadLMStudio() }
    }

    private var lmEndpoint: ModelEndpoint? {
        store.endpoints.first { $0.kind == .lmStudio && $0.isRunning }
    }

    private func openApp() {
        guard let path = store.lmStatus?.appPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: Not installed

    private var notInstalled: some View {
        let brew = store.lmStatus?.brewPath
        return ScrollView {
            VStack(spacing: 16) {
                EmptyState(icon: .sparkle, title: "LM Studio is not installed",
                           message: "LM Studio runs models on this Mac with an OpenAI compatible server on port \(AIConfig.lmStudioPort). Nothing installs until you choose to.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    if store.lmInstalling && store.lmInstallKind == .core {
                        Button("Stop") { store.cancelLMStudioInstall() }
                            .controlSize(.large)
                    } else {
                        installCoreButton
                            .controlSize(.large)
                    }
                    Text("Runs LM Studio's own installer. Adds the lms command and the background service, no window.")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, -24)
                CommandHint(LMStudioRuntime.installCoreCommandLine)
                    .fixedSize()
                if store.lmDiskImageFailed && !store.lmInstalling {
                    diskImageNotice
                }
                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(AIConfig.lmStudioDownloadURL)
                    } label: {
                        DeckLabel("Download LM Studio app", icon: .openExternal)
                    }
                    if brew != nil {
                        if store.lmInstalling && store.lmInstallKind == .homebrew {
                            Button("Stop") { store.cancelLMStudioInstall() }
                        } else {
                            Button {
                                store.installLMStudioWithHomebrew()
                            } label: {
                                DeckLabel("Install with Homebrew", icon: .download)
                            }
                            .disabled(store.lmInstalling)
                            .help(LMStudioRuntime.brewInstallCommandLine)
                        }
                    }
                }
                .controlSize(.regular)
                if store.lmInstalling || !store.lmInstallLog.isEmpty {
                    installLog
                }
            }
            .padding(.horizontal, Layout.pagePadding)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var installCoreButton: some View {
        Button {
            store.installLMStudioCore()
        } label: {
            DeckLabel("Install LM Studio core", icon: .download)
        }
        .deckPrimary()
        .disabled(store.lmInstalling)
    }

    /// The Homebrew install failed because this Mac cannot mount LM Studio's disk image.
    private var diskImageNotice: some View {
        HStack(spacing: 12) {
            DeckIcon(.warning, size: 16, color: DS.warning)
            Text(LMStudioRuntime.diskImageFailureMessage)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            installCoreButton
        }
        .padding(DS.pad)
        .frame(maxWidth: 640)
        .deckCard()
    }

    private var installLog: some View {
        let title: String
        switch store.lmInstallKind {
        case .core: title = store.lmInstalling ? "Installing LM Studio core" : "Install output"
        case .homebrew: title = store.lmInstalling ? "Installing with Homebrew" : "Homebrew output"
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if store.lmInstalling { ProgressView().controlSize(.small) }
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            ResourceLogView(lines: store.lmInstallLog, placeholder: "Installer output shows here.")
                .frame(height: 220)
        }
        .padding(DS.pad)
        .frame(maxWidth: 640)
        .deckCard()
    }

    // MARK: Installed

    private func serverBar(_ status: LMStudioStatus) -> some View {
        HStack(spacing: 10) {
            AIStatusPill(text: status.serverRunning ? "Server running on port \(status.port)" : "Server stopped",
                         tint: status.serverRunning ? DS.running : DS.stopped)
            if let label = status.installLabel {
                Pill(label)
                    .help(status.isCoreOnly ? "The lms command and the background service, no app" : "The LM Studio app")
            }
            if store.lmServerBusy { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if status.serverRunning {
                if let endpoint = lmEndpoint, !endpoint.models.isEmpty {
                    Button {
                        store.openChat(endpoint)
                    } label: {
                        DeckLabel("Chat", icon: .chat)
                    }
                }
                Button {
                    Task { await store.unloadAllLMStudio() }
                } label: {
                    DeckLabel("Unload All", icon: .stop)
                }
                .disabled(store.lmServerBusy || !store.lmModels.contains(where: \.isLoaded))
                .help("Free the memory every loaded model uses")
                Button {
                    Task { await store.stopLMStudio() }
                } label: {
                    DeckLabel("Stop Server", icon: .stop)
                }
                .disabled(store.lmServerBusy)
            } else {
                Button {
                    Task { await store.startLMStudio() }
                } label: {
                    DeckLabel(store.lmServerBusy ? "Starting" : "Start Server", icon: .play)
                }
                .deckPrimary()
                .disabled(store.lmServerBusy)
            }
            if status.appPath != nil {
                Button {
                    openApp()
                } label: {
                    DeckLabel("Open LM Studio", icon: .openExternal)
                }
            }
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 10)
    }

    private var sortedModels: [LMStudioModel] {
        store.lmModels.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(sortedModels, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.id) { model in
                HStack(spacing: 8) {
                    DeckIcon(.aiModels, size: 14, color: DS.accent)
                    Text(model.displayName).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(model.id)
                    if model.isEmbedding { Pill("Embedding", tint: DS.stopped) }
                }
            }
            .width(min: 220, ideal: 240)
            TableColumn("Status") { model in
                if store.lmBusy.contains(model.id) {
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
                Text(model.parameters ?? "-").monospacedDigit().deckSecondaryText()
            }
            .width(min: 80, ideal: 80)
            TableColumn("Format") { model in
                Text(model.format?.uppercased() ?? "-").deckSecondaryText()
            }
            .width(min: 80, ideal: 80)
            TableColumn("") { model in
                Button(model.isLoaded ? "Unload" : "Load") {
                    Task { await store.toggleLMStudioModel(model) }
                }
                .controlSize(.small)
                .disabled(store.lmBusy.contains(model.id))
                .help(model.isLoaded ? "Free the memory it uses" : "Load it into memory now")
            }
            .width(min: 70, ideal: 70)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: LMStudioModel.ID.self) { ids in
            if let id = ids.first, let model = store.lmModels.first(where: { $0.id == id }) {
                Button(model.isLoaded ? "Unload" : "Load") { Task { await store.toggleLMStudioModel(model) } }
                if let endpoint = lmEndpoint {
                    Button("Chat") { store.openChat(endpoint, model: model.id) }
                }
                Button("Copy Name") { ResourceUsage.copyToPasteboard(model.id) }
            }
        }
    }

    private var footer: some View {
        let loaded = store.lmModels.filter(\.isLoaded).count
        let total = store.lmModels.reduce(UInt64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let text = "\(store.lmModels.count) \(store.lmModels.count == 1 ? "model" : "models"), \(loaded) loaded, \(Format.bytes(total)) on disk"
        return ListStatusBar(text) {
            if let id = selection, let model = store.lmModels.first(where: { $0.id == id }), let endpoint = lmEndpoint {
                Button {
                    store.openChat(endpoint, model: model.id)
                } label: {
                    DeckLabel("Chat", icon: .chat)
                }
                .controlSize(.small)
            } else {
                CommandHint("lms ls")
                    .fixedSize()
            }
        }
    }
}

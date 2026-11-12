import SwiftUI
import AppKit
import DeckCore

/// Chat tester: streams answers from any discovered OpenAI compatible endpoint and shows the speed.
struct AIChatView: View {
    private var store: AIModelsStore { AIModelsStore.shared }
    @FocusState private var inputFocused: Bool
    @AppStorage(PrefKey.saveChatHistory) private var saveHistory = true

    static let suggestions = [
        "Explain what a container is in two sentences",
        "Write a Python function that checks if a word is a palindrome",
        "Give me three tips for a small, fast container image"
    ]

    /// "152 tok/s, 24 tokens, first token in 111 ms". Speed is left out for very short answers.
    static func caption(_ stats: ChatStats) -> String {
        var parts: [String] = []
        if let speed = stats.tokensPerSecond() { parts.append(AIFormat.tokensPerSecond(speed)) }
        parts.append(stats.tokens == 1 ? "1 token" : "\(stats.tokens) tokens")
        if let first = stats.timeToFirstToken { parts.append("first token in \(AIFormat.seconds(first))") }
        return parts.joined(separator: ", ")
    }

    /// Store entries as the shared chat views draw them.
    static func items(_ entries: [AIModelsStore.ChatEntry], fallbackKind: ModelServerKind?) -> [ChatItem] {
        entries.map { entry in
            let kind = entry.serverKind ?? fallbackKind
            return ChatItem(
                id: entry.id,
                role: entry.role == .user ? .user : .assistant,
                text: entry.text,
                reasoning: entry.reasoning,
                failed: entry.failed,
                author: ModelDisplayName.short(entry.model),
                authorHelp: entry.model.isEmpty ? nil : entry.model,
                details: entry.details,
                actionTitle: entry.modelLoadFailed ? "Pick another model" : nil,
                authorDetail: kind?.displayName,
                icon: kind?.deckIcon ?? .aiModels,
                caption: entry.stats.flatMap { $0.tokens > 0 ? caption($0) : nil },
                notice: notice(entry)
            )
        }
    }

    /// Why an answer is short or missing, in plain words.
    static func notice(_ entry: AIModelsStore.ChatEntry) -> String? {
        guard entry.role == .assistant, !entry.failed else { return nil }
        let answer = entry.reasoning.isEmpty ? ChatMarkdown.splitThinking(entry.text).1 : entry.text
        if entry.cutOff {
            return answer.isEmpty
                ? "The model reached its length limit while thinking, before it answered. Ask again or try another model."
                : "The answer stopped at the model's length limit."
        }
        if answer.isEmpty, entry.stats?.finished != nil {
            return entry.reasoning.isEmpty ? "No answer came back." : "The model only sent its thoughts, no answer."
        }
        return nil
    }

    var body: some View {
        if store.runningEndpoints.isEmpty {
            EmptyState(icon: .aiModels, title: "No model server is running",
                       message: "Start Ollama, LM Studio or the MLX server, then chat with it here.",
                       actionTitle: "Open Servers") {
                store.tab = .servers
            }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                if let endpoint = store.chatEndpoint, endpoint.models.isEmpty {
                    noModels(endpoint)
                } else {
                    Group {
                        if store.chat.isEmpty {
                            intro
                        } else {
                            ChatTranscript(items: Self.items(store.chat, fallbackKind: store.chatEndpoint?.kind),
                                           streamingID: store.isStreaming && store.streamingKey == store.chatKey ? store.chat.last?.id : nil,
                                           onAction: { _ in Task { await store.pickAnotherMLXModel() } })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ChatSaveNotice(status: store.chatSaveStatus) { await store.chatNoticeAction() }
                        .animation(.easeInOut(duration: 0.2), value: store.chatSaveStatus)
                    composer
                }
            }
            .background(DS.surface)
            .task(id: store.chatKey) { store.ensureChatLoaded() }
            .onChange(of: saveHistory) { _, _ in
                ChatSyncCenter.shared.historySettingChanged(ChatSyncCenter.modelsTarget)
            }
        }
    }

    private var modelName: String {
        store.chatModel.isEmpty ? "the model" : ModelDisplayName.short(store.chatModel)
    }

    private var canSend: Bool {
        !store.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.chatModel.isEmpty && !store.isStreaming
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = store
        return HStack(spacing: 16) {
            HStack(spacing: 18) {
                ChatPickerGroup("Server") {
                    Picker("Server", selection: $store.chatEndpointID) {
                        ForEach(store.runningEndpoints) { endpoint in
                            Text(verbatim: "\(endpoint.kind.displayName) :\(endpoint.port)").tag(Optional(endpoint.id))
                        }
                    }
                    .frame(width: 170)
                    .onChange(of: store.chatEndpointID) { _, _ in store.normalizeChatModel() }
                }
                ChatPickerGroup("Model") {
                    Picker("Model", selection: $store.chatModel) {
                        if store.chatEndpoint?.models.isEmpty ?? true {
                            Text("No models").tag("")
                        }
                        ForEach(store.chatEndpoint?.models ?? []) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .frame(width: 230)
                    .help(store.chatModel)
                }
            }
            .fixedSize()
            .layoutPriority(1)
            Spacer(minLength: 12)
            statsView
            Button {
                store.clearChat()
                inputFocused = true
            } label: {
                DeckLabel("Clear", icon: .trash)
            }
            .fixedSize()
            .disabled(store.chat.isEmpty)
            .help("Start a new conversation")
        }
        .padding(.horizontal, Layout.pagePadding)
        .frame(height: 52)
    }

    /// Speed of the last answer, updated while it streams.
    @ViewBuilder
    private var statsView: some View {
        if let stats = store.chat.last(where: { $0.role == .assistant && !$0.failed })?.stats {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let items = [
                    ("Speed", AIFormat.tokensPerSecond(stats.tokensPerSecond(now: context.date))),
                    ("First token", AIFormat.seconds(stats.timeToFirstToken)),
                    ("Tokens", stats.tokens > 0 ? "\(stats.tokens)" : "-")
                ]
                ViewThatFits(in: .horizontal) {
                    AIChatStatStrip(items: items, showTitles: true)
                    AIChatStatStrip(items: items, showTitles: false)
                    AIChatStatStrip(items: Array(items.prefix(1)), showTitles: false)
                }
            }
        }
    }

    // MARK: Empty states

    private var intro: some View {
        let endpoint = store.chatEndpoint
        return ChatIntro(icon: endpoint?.kind.deckIcon ?? .aiModels,
                         title: "Chat with \(modelName)",
                         message: endpoint.map { "Answers stream from \($0.kind.displayName) on port \($0.port). Try one of these or write your own." }
                             ?? "Pick a model and send a message.",
                         suggestions: Self.suggestions) { suggestion in
            store.chatInput = suggestion
            inputFocused = true
        }
    }

    private func noModels(_ endpoint: ModelEndpoint) -> some View {
        let isOllama = endpoint.kind == .ollama
        return EmptyState(icon: .aiModels, title: "No models on \(endpoint.kind.displayName)",
                          message: isOllama ? "Pull a model in the Ollama tab, then pick it here." : "Download a model in Model Library and serve it, then pick it here.",
                          actionTitle: isOllama ? "Open Ollama" : "Open Model Library") {
            store.tab = isOllama ? .ollama : .library
        }
    }

    // MARK: Composer

    private var composer: some View {
        @Bindable var store = store
        return ChatComposer(text: $store.chatInput, placeholder: "Message \(modelName)", canSend: canSend,
                            isBusy: store.isStreaming, focused: $inputFocused,
                            onSend: { store.sendChat() }, onStop: { store.stopChat() }) {
            ChatKeyHint()
        }
    }
}

/// Speed, first token and tokens in one sunken strip.
struct AIChatStatStrip: View {
    var items: [(String, String)]
    var showTitles: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle().fill(DS.border).frame(width: 1, height: 14)
                }
                HStack(spacing: 5) {
                    if showTitles {
                        Text(item.0).foregroundStyle(DS.textSecondary)
                    }
                    Text(item.1)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(DS.textPrimary)
                }
                .padding(.horizontal, 11)
                .help(item.0)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
        .frame(height: 26)
        .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}

// MARK: - Automation

#if DEBUG
extension AIModelsStore {
    /// Fills the chat with sample messages so every message state can be checked in snapshots.
    /// Only reached from DebugAutomation commands.
    func loadDebugTranscript(_ variant: String) {
        stopChat()
        let start = Date().addingTimeInterval(-4)
        var stats = ChatStats(started: start)
        stats.firstToken = start.addingTimeInterval(0.4)
        stats.chunks = 212
        stats.finished = start.addingTimeInterval(1.6)
        let kind = chatEndpoint?.kind ?? .ollama
        let model = chatModel.isEmpty ? "qwen3:0.6b" : chatModel
        var entries: [ChatEntry] = [
            ChatEntry(role: .user, text: "How do I run a small web server in a container?"),
            ChatEntry(role: .assistant, text: """
            You can run **nginx** in one line. The `-p` flag publishes the port on your Mac.

            ## Steps

            1. Pull and start the image.
            2. Open `http://localhost:8080` in a browser.
            3. Stop it when you are done.

            ```bash
            container run -d --name web -p 8080:80 nginx:alpine
            container logs web
            container stop web
            ```

            | Flag | What it does |
            | --- | --- |
            | `-d` | Runs in the background |
            | `-p` | Publishes a port |

            > Tip: add `--rm` so the container is removed when it stops.
            """, reasoning: "The user wants a quick way to serve web pages. nginx:alpine is small. I should show the run command, the port flag and how to stop it.", stats: stats, model: model, serverKind: kind),
            ChatEntry(role: .user, text: "Thanks. Can it also serve a folder from my Mac?\nShort answer please."),
            ChatEntry(role: .assistant, text: "Could not connect to the server.", stats: ChatStats(started: start), failed: true, model: model, serverKind: kind)
        ]
        switch variant {
        case "streaming":
            entries.append(ChatEntry(role: .user, text: "Try again"))
            entries.append(ChatEntry(role: .assistant, text: "", reasoning: "Mounting a folder uses the volume flag", stats: ChatStats(), model: model, serverKind: kind))
            setDebugStreaming(true)
        case "waiting":
            entries.append(ChatEntry(role: .user, text: "Try again"))
            entries.append(ChatEntry(role: .assistant, text: "", stats: ChatStats(), model: model, serverKind: kind))
            setDebugStreaming(true)
        case "cutoff":
            // A thinking model that used the whole length limit before answering.
            var cut = ChatEntry(role: .assistant, text: "", reasoning: "Wait, the user wants JSON with a category, a confidence and the reasoning. Let me look at the categories again.", stats: stats, model: model, serverKind: kind)
            cut.cutOff = true
            entries.append(ChatEntry(role: .user, text: "Classify this message and return JSON"))
            entries.append(cut)
            setDebugStreaming(false)
        case "clear":
            entries = []
            setDebugStreaming(false)
        default:
            setDebugStreaming(false)
        }
        chat = entries
    }
}
#endif

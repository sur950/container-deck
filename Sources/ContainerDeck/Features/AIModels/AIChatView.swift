import SwiftUI
import DeckCore

/// Chat tester: streams answers from any discovered OpenAI compatible endpoint and shows the speed.
struct AIChatView: View {
    private var store: AIModelsStore { AIModelsStore.shared }
    @FocusState private var inputFocused: Bool

    var body: some View {
        if store.runningEndpoints.isEmpty {
            EmptyState(icon: .aiModels, title: "No model server is running",
                       message: "Start Ollama, LM Studio or the MLX server, then chat with it here.",
                       actionTitle: "Set Up MLX") {
                store.tab = .mlx
            }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                inputBar
            }
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            Picker("Server", selection: $store.chatEndpointID) {
                ForEach(store.runningEndpoints) { endpoint in
                    Text(verbatim: "\(endpoint.kind.displayName) :\(endpoint.port)").tag(Optional(endpoint.id))
                }
            }
            .frame(maxWidth: 220)
            .popUpAppearanceRefresh()
            .onChange(of: store.chatEndpointID) { _, _ in store.normalizeChatModel() }
            Picker("Model", selection: $store.chatModel) {
                if store.chatEndpoint?.models.isEmpty ?? true {
                    Text("No models").tag("")
                }
                ForEach(store.chatEndpoint?.models ?? []) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .frame(maxWidth: 340)
            .popUpAppearanceRefresh()
            Spacer(minLength: 8)
            statsView
            Button {
                store.clearChat()
            } label: {
                DeckLabel("Clear", icon: .trash)
            }
            .disabled(store.chat.isEmpty)
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 10)
    }

    /// Speed of the last answer, updated while it streams.
    private var statsView: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let stats = store.chat.last(where: { $0.role == .assistant })?.stats
            HStack(spacing: 14) {
                stat("Speed", AIFormat.tokensPerSecond(stats?.tokensPerSecond(now: context.date)))
                stat("First token", AIFormat.seconds(stats?.timeToFirstToken))
                stat("Tokens", stats.map { "\($0.tokens)" } ?? "-")
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(DS.textSecondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
        }
        .frame(minWidth: 64, alignment: .trailing)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.chat.isEmpty {
                        VStack(spacing: 10) {
                            IconBadge(.aiModels, size: 44)
                            Text("Send a message to test this model").font(.headline)
                            Text(store.chatEndpoint.map { "Requests go to \($0.baseURL.absoluteString)/chat/completions" } ?? "")
                                .font(.callout.monospaced())
                                .foregroundStyle(DS.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                    ForEach(store.chat) { entry in
                        AIChatBubble(entry: entry, streaming: store.isStreaming && entry.id == store.chat.last?.id)
                            .id(entry.id)
                    }
                }
                .padding(Layout.pagePadding)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.chat.last?.text) { _, _ in
                if let id = store.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: store.chat.count) { _, _ in
                if let id = store.chat.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .background(DS.surface)
    }

    // MARK: Input

    private var inputBar: some View {
        @Bindable var store = store
        return HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $store.chatInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { store.sendChat() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DS.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.smallRadius + 2, style: .continuous).strokeBorder(DS.borderStrong, lineWidth: 1))
            if store.isStreaming {
                Button {
                    store.stopChat()
                } label: {
                    DeckLabel("Stop", icon: .stop)
                }
                .controlSize(.large)
            } else {
                Button {
                    store.sendChat()
                } label: {
                    DeckLabel("Send", icon: .upload)
                }
                .deckPrimary()
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.chatModel.isEmpty)
            }
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 12)
        .background(DS.surfaceSunken)
        .onAppear { inputFocused = true }
    }
}

/// One message.
struct AIChatBubble: View {
    let entry: AIModelsStore.ChatEntry
    let streaming: Bool
    @State private var showReasoning = false

    /// "152 tok/s, 24 tokens, first token in 111 ms". Speed is left out for very short answers.
    static func caption(_ stats: ChatStats) -> String {
        var parts: [String] = []
        if let speed = stats.tokensPerSecond() { parts.append(AIFormat.tokensPerSecond(speed)) }
        parts.append(stats.tokens == 1 ? "1 token" : "\(stats.tokens) tokens")
        if let first = stats.timeToFirstToken { parts.append("first token in \(AIFormat.seconds(first))") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let isUser = entry.role == .user
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 8) {
                if !entry.reasoning.isEmpty {
                    DisclosureGroup(isExpanded: $showReasoning) {
                        Text(entry.reasoning)
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Text(entry.text.isEmpty && streaming ? "Thinking" : "Thoughts")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DS.textSecondary)
                    }
                }
                if entry.text.isEmpty && streaming && entry.reasoning.isEmpty {
                    ProgressView().controlSize(.small)
                } else if !entry.text.isEmpty {
                    Text(entry.text)
                        .textSelection(.enabled)
                        .foregroundStyle(entry.failed ? DS.danger : DS.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let stats = entry.stats, !streaming, !entry.failed, stats.tokens > 0 {
                    Text(Self.caption(stats))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isUser ? DS.accentSoft : DS.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isUser ? Color.clear : DS.border, lineWidth: 1)
            )
            .frame(maxWidth: 640, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if !isUser { Spacer(minLength: 80) }
        }
    }
}

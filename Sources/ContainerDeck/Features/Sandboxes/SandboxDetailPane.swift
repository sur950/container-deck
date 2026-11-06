import SwiftUI
import AppKit
import DeckCore

/// Details for one sandbox: overview, chat, egress log and container logs.
struct SandboxDetailPane: View {
    @Environment(AppState.self) private var state

    let sandbox: Sandbox
    var onStart: () -> Void
    var onStop: () -> Void
    var onKill: () -> Void
    var onTerminal: () -> Void
    var onRemove: () -> Void

    @State private var tab: Tab = .overview
    private var runtime: SandboxRuntime { SandboxRuntime.shared }

    enum Tab: String, CaseIterable, Identifiable {
        case overview, chat, egress, logs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .chat: return "Chat"
            case .egress: return "Egress"
            case .logs: return "Logs"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.pad)
                .padding(.top, DS.pad)
                .padding(.bottom, 12)
            SegmentedFilter(selection: $tab, options: Tab.allCases, label: { $0.title }, count: { tab in
                tab == .egress ? (runtime.events[sandbox.name]?.count ?? 0) : nil
            })
            .padding(.horizontal, DS.pad)
            .padding(.bottom, 12)
            Divider()
            Group {
                switch tab {
                case .overview: SandboxOverview(sandbox: sandbox)
                case .chat: SandboxChatView(sandbox: sandbox)
                case .egress: SandboxEgressView(sandbox: sandbox)
                case .logs: SandboxLogsView(containerID: sandbox.container.id, isRunning: sandbox.isRunning)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .onDeckDebugCommand { name, value in
            if name == "sbx-tab", let next = Tab(rawValue: value) { tab = next }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBadge(.sandboxes, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sandbox.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        if runtime.isKilled(sandbox.name) && !sandbox.isRunning {
                            Pill("Killed", tint: DS.danger)
                        } else {
                            StatusPill(sandbox.container.state)
                        }
                        SandboxEgressPill(egress: sandbox.egress)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if sandbox.isRunning {
                    Button(action: onKill) {
                        DeckLabel("Kill Switch", icon: .power)
                    }
                    .deckPrimary()
                    .help("Cut all network traffic and stop the sandbox right now")
                    Button(action: onTerminal) { DeckLabel("Terminal", icon: .terminal) }
                    Button(action: onStop) { DeckLabel("Stop", icon: .stop) }
                } else {
                    Button(action: onStart) { DeckLabel("Start", icon: .play) }
                        .deckPrimary()
                }
                Spacer(minLength: 0)
                Button(role: .destructive, action: onRemove) { DeckLabel("Remove", icon: .trash) }
            }
            .controlSize(.regular)
        }
    }
}

// MARK: - Overview

private struct SandboxOverview: View {
    @Environment(AppState.self) private var state
    let sandbox: Sandbox
    private var runtime: SandboxRuntime { SandboxRuntime.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                if let error = runtime.serviceErrors[sandbox.name], sandbox.isRunning {
                    ResourceWarningText(error)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .deckCard(radius: DS.smallRadius + 2)
                }
                Card("Network", icon: .network) {
                    KeyValueRow("Access", value: sandbox.egress.title)
                    KeyValueRow("Network", value: sandbox.networkName, monospaced: true, copyable: true)
                    KeyValueRow("Gateway", value: sandbox.gateway ?? "Unknown", monospaced: true)
                    if sandbox.egress == .allowList {
                        KeyValueRow("Proxy", value: proxyText, monospaced: sandbox.isRunning)
                        KeyValueRow("Allowed") {
                            if sandbox.allowList.isEmpty {
                                Text("Nothing. Every host is blocked.").foregroundStyle(DS.textSecondary)
                            } else {
                                SandboxHostChips(hosts: sandbox.allowList)
                            }
                        }
                    }
                    DeckFormNote(limitNote)
                }
                Card("Model", icon: .aiModels) {
                    if let model = sandbox.model {
                        KeyValueRow("Server", value: model.kind.title)
                        KeyValueRow("On this Mac", value: model.url.absoluteString, monospaced: true, copyable: true)
                        if let url = sandbox.containerModelURL, url != model.url {
                            KeyValueRow("In sandbox", value: url.absoluteString, monospaced: true, copyable: true)
                        }
                        KeyValueRow("Model", value: model.name ?? "Not set")
                        KeyValueRow("API key", value: model.hasKey ? "In Keychain, in memory inside" : "None")
                        KeyValueRow("Variables") {
                            Text(variables(model))
                                .font(.callout.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("No model. Create a new sandbox to connect one.")
                            .foregroundStyle(DS.textSecondary)
                    }
                }
                Card("Container", icon: .containers) {
                    KeyValueRow("Image", value: sandbox.image, monospaced: true, copyable: true)
                    KeyValueRow("Template", value: sandbox.template?.title ?? "Custom")
                    KeyValueRow("CPUs", value: sandbox.container.cpus.map(String.init) ?? "Default")
                    KeyValueRow("Memory", value: sandbox.container.memoryBytes.map { Format.bytes($0) } ?? "Default")
                    KeyValueRow("Workspace") {
                        if let workspace = sandbox.workspace {
                            HStack(spacing: 6) {
                                Text((workspace as NSString).abbreviatingWithTildeInPath)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Pill(sandbox.workspaceReadOnly ? "Read only" : "Read and write", tint: sandbox.workspaceReadOnly ? DS.stopped : DS.warning)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace)])
                                } label: {
                                    DeckIcon(.folder, size: 12)
                                }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                            }
                        } else {
                            Text("None").foregroundStyle(DS.textSecondary)
                        }
                    }
                }
                if let client = state.client {
                    CommandHint(client.sandboxShellCommand(sandbox))
                }
            }
            .padding(DS.pad)
        }
    }

    private var proxyText: String {
        if runtime.isKilled(sandbox.name) { return "Off, kill switch used" }
        guard sandbox.isRunning else { return "Off while stopped" }
        guard runtime.activeServices.contains(sandbox.name), let gateway = sandbox.gateway else { return "Starting" }
        return "http://\(gateway):\(sandbox.proxyPort)"
    }

    private var limitNote: String {
        switch sandbox.egress {
        case .isolated:
            return "Host only network. Nothing leaves this Mac."
        case .allowList:
            return "Apps must honour HTTP_PROXY and HTTPS_PROXY (curl, pip, npm, apk, Python and most agent SDKs do). Other traffic is blocked by the host only network. BusyBox wget cannot use the proxy for https."
        case .open:
            return "Full internet access. Pick Isolated or Allow list for untrusted agents."
        }
    }

    private func variables(_ model: SandboxModel) -> String {
        var names = ["OPENAI_BASE_URL"]
        if model.kind == .ollama { names.append("OLLAMA_HOST") }
        names.append(model.hasKey ? "OPENAI_API_KEY (shells)" : "OPENAI_API_KEY")
        return names.joined(separator: ", ")
    }
}

/// Allowed hosts as small chips that wrap.
private struct SandboxHostChips: View {
    let hosts: [String]

    var body: some View {
        SandboxFlowLayout(spacing: 4) {
            ForEach(hosts, id: \.self) { host in
                Text(host)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.surfaceSunken))
                    .overlay(Capsule().strokeBorder(DS.border))
            }
        }
    }
}

/// Simple wrapping row layout.
struct SandboxFlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Egress

private struct SandboxEgressView: View {
    let sandbox: Sandbox
    private var runtime: SandboxRuntime { SandboxRuntime.shared }

    private var events: [SandboxEgressEvent] {
        (runtime.events[sandbox.name] ?? []).reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            ContainerTabBar {
                Text(summary).font(.callout).foregroundStyle(DS.textSecondary)
                Spacer(minLength: 0)
                Button("Clear") { runtime.clearEvents(sandbox.name) }
                    .disabled(events.isEmpty)
            }
            if events.isEmpty {
                EmptyState(icon: .network, title: "No traffic yet", message: emptyMessage)
            } else {
                List(events) { event in
                    HStack(spacing: 10) {
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: 70, alignment: .leading)
                        Pill(title(event.kind), tint: tint(event.kind))
                            .frame(width: 72, alignment: .leading)
                        Text(event.port > 0 ? "\(event.host):\(event.port)" : event.host)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(event.detail)
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var summary: String {
        let list = runtime.events[sandbox.name] ?? []
        let blocked = list.filter { $0.kind == .blocked }.count
        let allowed = list.filter { $0.kind == .allowed || $0.kind == .relay }.count
        return "\(allowed) let through, \(blocked) blocked"
    }

    private var emptyMessage: String {
        switch sandbox.egress {
        case .allowList: return "Requests through the allow list proxy and model calls show up here."
        case .isolated: return "Model calls through the relay show up here. Nothing else can leave."
        case .open: return "Model calls through the relay show up here. Other traffic goes straight out and is not logged."
        }
    }

    private func title(_ kind: SandboxEgressEvent.Kind) -> String {
        switch kind {
        case .allowed: return "Allowed"
        case .blocked: return "Blocked"
        case .relay: return "Model"
        case .failed: return "Failed"
        }
    }

    private func tint(_ kind: SandboxEgressEvent.Kind) -> Color {
        switch kind {
        case .allowed: return DS.running
        case .blocked: return DS.danger
        case .relay: return DS.accent
        case .failed: return DS.warning
        }
    }
}

// MARK: - Chat

private struct SandboxChatView: View {
    @Environment(AppState.self) private var state
    let sandbox: Sandbox

    @State private var messages: [SandboxChatMessage] = []
    @State private var draft = ""
    @State private var modelName = ""
    @State private var models: [String] = []
    @State private var sending = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        if sandbox.model == nil {
            EmptyState(icon: .aiModels, title: "No model", message: "This sandbox has no model. Create one with a model to chat.")
        } else if !sandbox.isRunning {
            EmptyState(icon: .aiModels, title: "Sandbox is stopped", message: "Start the sandbox to chat with its model.")
        } else {
            VStack(spacing: 0) {
                ContainerTabBar {
                    Text("Model").font(.callout).foregroundStyle(DS.textSecondary)
                    if models.isEmpty {
                        TextField("Model", text: $modelName, prompt: Text("model name"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    } else {
                        Picker("Model", selection: $modelName) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .popUpAppearanceRefresh()
                    }
                    Spacer(minLength: 0)
                    Button("Clear") { messages = []; errorMessage = nil }
                        .disabled(messages.isEmpty || sending)
                }
                if let warning = SandboxRuntime.shared.serviceErrors[sandbox.name] {
                    ResourceWarningText(warning)
                        .padding(.horizontal, DS.pad)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                messageList
                if let errorMessage {
                    ResourceErrorText(errorMessage)
                        .padding(.horizontal, DS.pad)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Message", text: $draft, prompt: Text("Ask the model. Sent from inside the sandbox."), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .onSubmit(send)
                    Button(action: send) {
                        if sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Send")
                        }
                    }
                    .deckPrimary()
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelName.isEmpty || sending)
                }
                .padding(12)
            }
            .task(id: sandbox.container.id) { await loadModels() }
            .onDeckDebugCommand { name, value in
                if name == "sbx-chat" {
                    draft = value
                    send()
                }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        Text("Messages go from inside the sandbox to the model, the same way an agent would.")
                            .font(.callout)
                            .foregroundStyle(DS.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(messages) { message in
                        bubble(message).id(message.id)
                    }
                    if sending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking").font(.callout).foregroundStyle(DS.textSecondary)
                        }
                        .id("pending")
                    }
                }
                .padding(DS.pad)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private func bubble(_ message: SandboxChatMessage) -> some View {
        let mine = message.role == .user
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(mine ? DS.accentSoft : DS.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func loadModels() async {
        if modelName.isEmpty { modelName = sandbox.model?.name ?? "" }
        guard let client = state.client else { return }
        let found = (try? await client.sandboxModels(sandbox)) ?? []
        models = found
        if !found.isEmpty && !found.contains(modelName) { modelName = found[0] }
        if !found.isEmpty, let name = sandbox.model?.name, !found.contains(name) { models.insert(name, at: 0); modelName = name }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !modelName.isEmpty, !sending, let client = state.client else { return }
        draft = ""
        errorMessage = nil
        messages.append(SandboxChatMessage(role: .user, content: text))
        sending = true
        let history = messages
        let model = modelName
        Task {
            do {
                let reply = try await client.sandboxChat(sandbox, model: model, messages: history)
                messages.append(SandboxChatMessage(role: .assistant, content: reply.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                errorMessage = error.localizedDescription
            }
            sending = false
            inputFocused = true
        }
    }
}

// MARK: - Logs

private struct SandboxLogStreamKey: Hashable {
    var id: String
    var follow: Bool
    var isRunning: Bool
    var cliPath: String?
}

/// Container logs sized for the detail pane: filter, follow, copy and clear on one short row.
/// The full logs view needs more room than this pane has.
struct SandboxLogsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let containerID: String
    var isRunning: Bool

    @State private var model = ContainerLogModel()
    @State private var follow = true
    @State private var query = ""

    private var options: LogOptions {
        LogOptions(follow: follow && isRunning, tail: 500, boot: false)
    }

    private var shown: [ContainerLogLine] {
        guard !query.isEmpty else { return model.lines }
        return model.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ContainerTabBar {
                ContainerFilterField(prompt: "Filter lines", text: $query)
                    .frame(minWidth: 110, maxWidth: 220)
                Spacer(minLength: 8)
                if model.isStreaming && follow && isRunning {
                    Pill("Live", tint: DS.running)
                }
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .help("Keep reading new lines")
                    .fixedSize()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.map(\.text).joined(separator: "\n"), forType: .string)
                    state.showToast("Copied \(shown.count) lines", style: .success)
                } label: {
                    DeckIcon(.copy, size: 13).frame(width: 18, height: 16)
                }
                .help("Copy the shown lines")
                .disabled(shown.isEmpty)
                Button {
                    model.clear()
                } label: {
                    DeckIcon(.trash, size: 13).frame(width: 18, height: 16)
                }
                .help("Clear the view")
                .disabled(model.lines.isEmpty)
            }
            .font(.callout)
            lineList
            ListStatusBar(statusText) {
                if showHints, let client = state.client {
                    CommandHint(client.commandLine(client.logArguments(containerID, options: options)))
                        .frame(maxWidth: 240)
                }
            }
        }
        .task(id: SandboxLogStreamKey(id: containerID, follow: follow, isRunning: isRunning, cliPath: state.client?.cliPath)) {
            guard let client = state.client else { return }
            await model.run(client: client, id: containerID, options: options)
        }
    }

    private var statusText: String {
        let total = model.lines.count
        let noun = total == 1 ? "line" : "lines"
        if !query.isEmpty { return "\(shown.count) of \(total) \(noun) match" }
        if model.isStreaming && follow && isRunning { return "\(total) \(noun), following" }
        return "\(total) \(noun)"
    }

    private var lineList: some View {
        let lines = shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(DS.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("sandbox-log-bottom")
                }
                .padding(.horizontal, DS.pad)
                .padding(.vertical, 12)
            }
            .background(DS.surfaceSunken)
            .overlay {
                if lines.isEmpty { emptyOverlay }
            }
            .onChange(of: model.lines.last?.id) {
                guard follow, query.isEmpty else { return }
                proxy.scrollTo("sandbox-log-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if let error = model.errorText {
            EmptyState(icon: .error, title: "Could not read logs", message: error)
        } else if !model.lines.isEmpty {
            EmptyState(icon: .search, title: "No matches", message: "No line matches your filter.")
        } else if model.isStreaming {
            EmptyState(icon: .logs, title: "Waiting for output", message: "New lines show up here as the sandbox writes them.")
        } else {
            EmptyState(icon: .logs, title: "No logs", message: "This sandbox has not written anything yet.")
        }
    }
}

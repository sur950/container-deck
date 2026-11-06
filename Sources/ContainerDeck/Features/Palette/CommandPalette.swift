import SwiftUI
import AppKit
import DeckCore

/// Cmd+K palette. Fuzzy search over screens, commands and every resource,
/// plus verbs: "stop web", "logs api", "shell db", "pull nginx:alpine".
struct CommandPalette: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @State private var data = PaletteData()
    @State private var loading = false
    @State private var recentIDs = PaletteRecents().ids
    @State private var pending: PaletteAction?
    /// Set when a pull starts. The palette turns into the Pull sheet.
    @State private var pullReference: String?
    @FocusState private var focused: Bool
    @State private var lastMouse = NSEvent.mouseLocation

    private let recents = PaletteRecents()

    var body: some View {
        if let pullReference {
            ImagesPullSheet(reference: pullReference, autoStart: !pullReference.isEmpty)
        } else {
            palette
        }
    }

    // MARK: - Data

    private var containers: [ContainerSummary] {
        let feed = BackgroundServices.shared
        if feed.lastPoll == nil, let loaded = data.containers { return loaded }
        return feed.containers
    }

    private var sections: [(title: String, rows: [PaletteRow])] {
        let resources = PaletteCatalog.resources(state: state, containers: containers, data: data)
        return PaletteCatalog.sections(for: query, resources: resources, recents: recentIDs)
    }

    private func load() async {
        guard let client = state.client else { return }
        loading = true
        data = await PaletteData.load(client: client, needContainers: BackgroundServices.shared.lastPoll == nil)
        loading = false
    }

    // MARK: - Layout

    private var palette: some View {
        let sections = self.sections
        let rows = sections.flatMap(\.rows)
        let current = rows.indices.contains(highlighted) ? rows[highlighted] : rows.first
        let parsed = PaletteQuery.parse(query)
        return VStack(spacing: 0) {
            header(parsed: parsed, rows: rows)
            Divider()
            if rows.isEmpty {
                emptyView(parsed)
            } else {
                list(sections, flat: rows)
            }
            Divider()
            footer(current: current)
        }
        .frame(width: 640, height: 480)
        .background(DS.surface)
        .tint(DS.accent)
        .onAppear { focused = true }
        .task { await load() }
        .onExitCommand { dismiss() }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onDeckDebugCommand { name, value in
            if name == "palette-query" { query = value }
        }
        .confirmDelete($pending, title: { $0.confirmation?.title ?? "" },
                       message: pending?.confirmation?.message ?? "",
                       actionTitle: pending?.confirmation?.button ?? "Delete") { action in
            perform(action)
        }
        .background {
            // Cmd+Enter runs the second action of the highlighted row.
            Button("") { runCurrent(alternate: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func header(parsed: PaletteQuery, rows: [PaletteRow]) -> some View {
        HStack(spacing: 10) {
            DeckIcon(.search, size: 18)
            TextField("Search, or type a verb like stop web", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { runCurrent(alternate: false) }
                .onKeyPress(keys: [.upArrow, .downArrow, .tab, .return]) { press in
                    switch press.key {
                    case .downArrow: moveHighlight(1)
                    case .upArrow: moveHighlight(-1)
                    case .tab:
                        if let completed = PaletteQuery.complete(query) { query = completed }
                    default:
                        runCurrent(alternate: press.modifiers.contains(.command))
                    }
                    return .handled
                }
            if loading {
                ProgressView().controlSize(.small)
            }
            if let verb = parsed.verb {
                Pill(verb.rawValue.capitalized)
            }
            KeyCap("esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func emptyView(_ parsed: PaletteQuery) -> some View {
        VStack(spacing: 8) {
            DeckIcon(.search, size: 28, color: DS.textTertiary)
            Text("No matches").font(.headline)
            Text(parsed.verb.map { "Nothing to \($0.rawValue) matches \"\(parsed.target)\"." }
                 ?? "Try a name, a screen, or a verb like stop web.")
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ sections: [(title: String, rows: [PaletteRow])], flat: [PaletteRow]) -> some View {
        let indexByID = Dictionary(flat.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack: lists are capped, and lazy rows could keep a stale highlight.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { offset, section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, offset == 0 ? 2 : 10)
                            .padding(.bottom, 3)
                        ForEach(section.rows) { row in
                            let index = indexByID[row.id] ?? 0
                            rowView(row, index: index)
                                .id(row.id)
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: highlighted) { _, newValue in
                if flat.indices.contains(newValue) {
                    proxy.scrollTo(flat[newValue].id)
                }
            }
        }
    }

    private func rowView(_ row: PaletteRow, index: Int) -> some View {
        let isOn = index == highlighted
        return Button {
            highlighted = index
            execute(row.primary, row: row)
        } label: {
            HStack(spacing: 12) {
                IconBadge(row.icon, tint: isOn ? .white : DS.textSecondary, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    title(row, isOn: isOn)
                        .lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isOn ? Color.white.opacity(0.85) : DS.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let badge = row.badge {
                    Pill(badge, tint: DS.stopped)
                }
                if let status = row.status {
                    StatusPill(status)
                }
                if isOn {
                    keyHints(row)
                } else {
                    Text(kindLabel(row.kind))
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                        .frame(minWidth: 62, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Crimson with white text, like a selected row in any list of the app.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn ? DS.accent : Color.clear)
            )
            // Pills, status pills and icon badges switch to their on-crimson look.
            .environment(\.backgroundProminence, isOn ? .increased : .standard)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            // Only a real mouse move picks a row. Rows sliding under a still pointer while typing do not.
            let location = NSEvent.mouseLocation
            guard inside, location != lastMouse else { return }
            lastMouse = location
            highlighted = index
        }
    }

    private func title(_ row: PaletteRow, isOn: Bool = false) -> Text {
        var text = AttributedString()
        if !row.verbPrefix.isEmpty {
            var prefix = AttributedString(row.verbPrefix + " ")
            prefix.foregroundColor = isOn ? Color.white.opacity(0.85) : DS.textSecondary
            prefix.font = .system(size: 13, weight: .regular)
            text += prefix
        }
        for (offset, character) in row.title.enumerated() {
            var piece = AttributedString(String(character))
            if row.highlights.contains(where: { $0.contains(offset) }) {
                // On crimson the match stays white and is underlined instead.
                piece.foregroundColor = isOn ? Color.white : DS.accent
                piece.font = .system(size: 13, weight: .bold)
                if isOn { piece.underlineStyle = .single }
            } else {
                piece.foregroundColor = isOn ? Color.white : DS.textPrimary
                piece.font = .system(size: 13, weight: .medium)
            }
            text += piece
        }
        return Text(text)
    }

    private func keyHints(_ row: PaletteRow) -> some View {
        HStack(spacing: 5) {
            OnAccentKeyCap("↵")
            Text(row.primary.label)
            if let alternate = row.alternate {
                OnAccentKeyCap("⌘↵").padding(.leading, 4)
                Text(alternate.label)
            }
        }
        .font(.caption)
        .foregroundStyle(Color.white.opacity(0.9))
        .fixedSize()
    }

    private func kindLabel(_ kind: PaletteKind) -> String {
        switch kind {
        case .screen: return "Screen"
        case .action: return "Command"
        case .container: return "Container"
        case .image: return "Image"
        case .volume: return "Volume"
        case .network: return "Network"
        case .machine: return "Machine"
        case .stack: return "Stack"
        }
    }

    private func footer(current: PaletteRow?) -> some View {
        HStack(spacing: 6) {
            KeyCap("↑")
            KeyCap("↓")
            Text("move")
            if let current {
                KeyCap("↵").padding(.leading, 8)
                Text(current.primary.label.lowercased())
                if let alternate = current.alternate {
                    KeyCap("⌘↵").padding(.leading, 8)
                    Text(alternate.label.lowercased())
                }
            }
            if let completion = PaletteQuery.complete(query) {
                KeyCap("tab").padding(.leading, 8)
                Text(completion.trimmingCharacters(in: .whitespaces) + "…")
            }
            Spacer()
            LogoBadge(size: 16)
            Text(AppConfig.appName)
        }
        .font(.caption)
        .foregroundStyle(DS.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Running

    private func moveHighlight(_ delta: Int) {
        let count = sections.reduce(0) { $0 + $1.rows.count }
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

    private func runCurrent(alternate: Bool) {
        let rows = sections.flatMap(\.rows)
        guard let row = rows.indices.contains(highlighted) ? rows[highlighted] : rows.first else { return }
        guard let action = alternate ? row.alternate : row.primary else { return }
        execute(action, row: row)
    }

    private func execute(_ action: PaletteAction, row: PaletteRow?) {
        if let id = row?.entryID, !id.isEmpty {
            recents.add(id)
            recentIDs = recents.ids
        }
        if action.confirmation != nil {
            pending = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PaletteAction) {
        if case .imagePull(let reference) = action {
            // The palette sheet becomes the Pull sheet, so progress shows right away.
            pullReference = reference
            return
        }
        let state = self.state
        dismiss()
        Task { @MainActor in
            // Let the palette sheet close before another sheet or alert opens.
            try? await Task.sleep(for: .milliseconds(250))
            await PaletteRunner.run(action, state: state)
        }
    }
}

/// Runs palette actions through the same helpers the screens use.
@MainActor
enum PaletteRunner {
    static func run(_ action: PaletteAction, state: AppState) async {
        switch action {
        case .screen(let item):
            state.selection = item
        case .custom(_, _, let perform):
            perform(state)
        case .container(let op, let id, let name):
            await ContainerOps.perform(op, ids: [id], names: [id: name], state: state)
        case .containerOpen(let id, let tab):
            // The Containers screen and the detail pick these up when they appear or change.
            state.openContainer(id, tab: tab.flatMap(ContainerDetailTab.init(rawValue:)))
        case .containerShell(let id):
            ContainerOps.openTerminal(id, state: state)
        case .machineOpen(let name):
            DeepLinkRouter.route(.machine(name), state: state)
        case .machineBoot(let name):
            await machine(state, done: "Started \(name)") { try await $0.bootMachine(name) }
        case .machineStop(let name):
            await machine(state, done: "Stopped \(name)") { try await $0.stopMachine(name) }
        case .machineDelete(let name):
            await machine(state, done: "Deleted \(name)") { try await $0.deleteMachine(name) }
        case .machineShell(let name):
            guard let client = state.client else { return }
            do {
                try TerminalLauncher.open(command: client.machineShellCommand(name)) { state.showError($0) }
            } catch {
                state.showError(error)
            }
        case .imageOpen(let reference):
            DeepLinkRouter.route(.image(reference), state: state)
        case .imageRun(let reference):
            state.runRequest = RunRequest(options: RunOptions(image: reference))
        case .imagePull:
            break // Handled by the palette view.
        case .imageDelete(let reference):
            await resource(state, done: "Deleted \(ContainerText.shortImage(reference))") { try await $0.deleteImage(reference) }
        case .volumeOpen:
            state.selection = .volumes
        case .volumeDelete(let name):
            await resource(state, done: "Deleted volume \(name)") { try await $0.deleteVolume(name) }
        case .networkOpen:
            state.selection = .networks
        case .networkDelete(let name):
            await resource(state, done: "Deleted network \(name)") { try await $0.deleteNetwork(name) }
        case .stackOpen(let name, let file):
            state.openComposeStack(name, file: file)
        case .pruneContainers:
            await ContainerOps.prune(state: state)
        case .stopService:
            await state.stopService()
        }
    }

    private static func machine(_ state: AppState, done: String, _ work: (ContainerClient) async throws -> Void) async {
        guard let client = state.client else { return }
        do {
            try await work(client)
            state.showToast(done, style: .success)
        } catch {
            state.showError(MachineParser.explain(error))
        }
        state.resourcesChanged()
    }

    private static func resource(_ state: AppState, done: String, _ work: (ContainerClient) async throws -> Void) async {
        guard let client = state.client else { return }
        do {
            try await work(client)
            state.showToast(done, style: .success)
        } catch {
            state.showError(error)
        }
        state.resourcesChanged()
    }
}

/// Key cap for the highlighted (crimson) palette row.
private struct OnAccentKeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
    }
}

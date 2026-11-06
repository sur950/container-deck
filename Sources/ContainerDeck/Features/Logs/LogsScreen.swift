import SwiftUI
import AppKit
import DeckCore

/// Multi pane log viewer. One container per pane, up to four, side by side, stacked or in a grid.
/// One filter for every pane, with highlights. Each pane follows or pauses on its own.
struct LogsScreen: View {
    @Environment(AppState.self) private var state
    /// AppKit menus keep the old colors after a Light or Dark switch. They rebuild with `.id(colorScheme)`.
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrefKey.logPanes) private var savedPanes = ""
    @AppStorage(PrefKey.logSplit) private var splitRaw = LogSplit.columns.rawValue
    @AppStorage(PrefKey.logTimestamps) private var timestamps = true

    @State private var model: LogsModel

    /// Opens with these containers, or the ones from last time when empty.
    init(containerIDs: [String] = []) {
        let ids = containerIDs.isEmpty
            ? LogsModel.restore(UserDefaults.standard.string(forKey: PrefKey.logPanes) ?? "")
            : containerIDs
        _model = State(initialValue: LogsModel(containerIDs: ids))
    }

    private var split: LogSplit { LogSplit(rawValue: splitRaw) ?? .columns }
    private var query: LogQuery { LogQuery(model.query) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            panes
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .onChange(of: model.savedValue) { _, value in savedPanes = value }
        .onAppear { savedPanes = model.savedValue }
        .onReceive(NotificationCenter.default.publisher(for: .deckLogsAdd)) { note in
            for id in (note.userInfo?["ids"] as? [String]) ?? [] { model.add(id) }
        }
        .onDeckDebugCommand { name, value in
            switch name {
            case "logs-add": model.add(value)
            case "logs-close": LogsWindow.close()
            case "logs-split": splitRaw = value
            case "logs-filter": model.query = value
            case "logs-only": model.onlyMatches = value != "off"
            case "logs-pause":
                if let index = Int(value), model.panes.indices.contains(index) {
                    model.panes[index].setPaused(!model.panes[index].isPaused)
                }
            case "logs-remove":
                if let index = Int(value), model.panes.indices.contains(index) { model.remove(model.panes[index]) }
            default: break
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            LogsFilterField(prompt: "Filter all panes", text: $model.query)
                .frame(minWidth: 160, maxWidth: 260)
                .help("Words to find. Start a word with - to hide lines that have it.")
            Toggle("Only matches", isOn: $model.onlyMatches)
                .toggleStyle(.checkbox)
                .disabled(query.include.isEmpty && query.exclude.isEmpty)
                .fixedSize()
            Toggle("Timestamps", isOn: $timestamps)
                .toggleStyle(.checkbox)
                .help("Time each line was read. Earlier lines have none.")
                .fixedSize()

            Spacer(minLength: 8)

            Picker("Layout", selection: $splitRaw) {
                ForEach(LogSplit.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.panes.count < 2)
            .help("How panes share the window")

            addMenu
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(DS.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var addMenu: some View {
        Menu {
            let shown = Set(model.panes.compactMap(\.containerID))
            let choices = LogsContainerChoices.list(BackgroundServices.shared.visibleContainers)
            if choices.isEmpty {
                Text("No containers yet")
            }
            ForEach(choices) { item in
                Button {
                    model.add(item.id)
                } label: {
                    Text(item.isRunning ? item.name : "\(item.name) (stopped)")
                }
                .disabled(shown.contains(item.id))
            }
            Divider()
            Button("Empty Pane") { model.add(nil) }
        } label: {
            DeckLabel("Add Pane", icon: .add)
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(!model.canAdd)
        .help(model.canAdd ? "Show another container" : "Up to \(ObservabilityConfig.maxLogPanes) panes")
        .id(colorScheme)
    }

    // MARK: Panes

    private var panes: some View {
        let rows = split.arrangement(count: model.panes.count)
        let horizontalLines = split == .rows
        return Group {
            if horizontalLines {
                VSplitView {
                    ForEach(rows.flatMap { $0 }, id: \.self) { index in
                        pane(index).frame(minHeight: 120)
                    }
                }
            } else {
                VSplitView {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HSplitView {
                            ForEach(row, id: \.self) { index in
                                pane(index).frame(minWidth: 220)
                            }
                        }
                        .frame(minHeight: 120)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pane(_ index: Int) -> some View {
        if model.panes.indices.contains(index) {
            let pane = model.panes[index]
            LogPaneView(
                pane: pane,
                query: query,
                onlyMatches: model.onlyMatches,
                timestamps: timestamps,
                canClose: model.panes.count > 1 || pane.containerID != nil,
                taken: Set(model.panes.compactMap(\.containerID)),
                close: { model.remove(pane) }
            )
            .id(pane.id)
        }
    }
}

extension Notification.Name {
    /// Adds panes to an open Logs view. userInfo "ids": [String].
    static let deckLogsAdd = Notification.Name("DeckLogsAdd")
}

/// Containers to offer in the pickers: running first, then by name. Apple's builder is left out.
enum LogsContainerChoices {
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
        let isRunning: Bool
    }

    static func list(_ containers: [ContainerSummary]) -> [Choice] {
        containers
            .filter { $0.id != "buildkit" }
            .map { Choice(id: $0.id, name: $0.name.isEmpty ? $0.id : $0.name, isRunning: $0.isRunning) }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

/// Small search field for the Logs bar.
struct LogsFilterField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            DeckIcon(.search, size: 12, color: DS.textSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    DeckIcon(.close, size: 9, color: DS.textSecondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}

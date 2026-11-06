import SwiftUI
import AppKit
import DeckCore

private struct PaneStreamKey: Hashable {
    var id: String?
    var isRunning: Bool
    var cliPath: String?
}

/// One pane in the Logs view: header with the container, follow or pause, copy, clear, close.
struct LogPaneView: View {
    @Environment(AppState.self) private var state
    /// AppKit menus keep the old colors after a Light or Dark switch. They rebuild with `.id(colorScheme)`.
    @Environment(\.colorScheme) private var colorScheme
    let pane: LogPaneModel
    let query: LogQuery
    let onlyMatches: Bool
    let timestamps: Bool
    let canClose: Bool
    let taken: Set<String>
    let close: () -> Void

    @State private var hoverHeader = false

    private var container: ContainerSummary? {
        guard let id = pane.containerID else { return nil }
        return BackgroundServices.shared.containers.first { $0.id == id || $0.name == id }
    }

    private var isRunning: Bool { container?.isRunning ?? false }
    private var tint: Color { LogPalette.color(pane.colorSlot) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if pane.containerID == nil {
                picker
            } else {
                lines
            }
        }
        .background(DS.surfaceSunken)
        .task(id: PaneStreamKey(id: pane.containerID, isRunning: isRunning, cliPath: state.client?.cliPath)) {
            guard let client = state.client, let id = pane.containerID else { return }
            // Following a stopped container would wait forever, so it reads once.
            await pane.run(client: client, id: id, follow: isRunning)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 4, height: 16)
            containerMenu
            if pane.containerID != nil {
                statusBadge
            }
            Spacer(minLength: 4)
            if pane.containerID != nil {
                Text(countText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                headerButton(pane.isPaused ? .play : .pause, help: pane.isPaused ? "Follow new lines" : "Pause the view") {
                    pane.setPaused(!pane.isPaused)
                }
                headerButton(.copy, help: "Copy the shown lines") { copy() }
                    .disabled(shown.isEmpty)
                headerButton(.trash, help: "Clear this pane") { pane.clear() }
                    .disabled(pane.entries.isEmpty)
            }
            if canClose {
                headerButton(.close, help: "Close this pane", action: close)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(DS.surfaceRaised)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var containerMenu: some View {
        Menu {
            ForEach(LogsContainerChoices.list(BackgroundServices.shared.visibleContainers)) { item in
                Button(item.isRunning ? item.name : "\(item.name) (stopped)") {
                    pane.containerID = item.id
                }
                .disabled(taken.contains(item.id) && item.id != pane.containerID)
            }
        } label: {
            Text(container?.name ?? pane.containerID ?? "Pick a container")
                .font(.callout.weight(.semibold))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show another container in this pane")
        .id(colorScheme)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if pane.isPaused {
            Pill("Paused", tint: DS.warning)
        } else if pane.isStreaming && isRunning {
            Pill("Live", tint: DS.running)
        } else if !isRunning {
            Pill("Stopped", tint: DS.stopped)
        }
    }

    private var countText: String {
        let total = pane.entries.count
        var text: String
        if !query.isEmpty {
            let matches = pane.entries.reduce(0) { $0 + (query.matches($1.text) ? 1 : 0) }
            text = "\(matches) of \(total)"
        } else {
            text = total == 1 ? "1 line" : "\(total) lines"
        }
        let waiting = pane.newWhilePaused
        if waiting > 0 { text += ", \(waiting) new" }
        return text
    }

    private func headerButton(_ icon: DeckIconName, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DeckIcon(icon, size: 12, color: DS.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: Lines

    private var shown: [LogEntry] {
        guard onlyMatches, !query.isEmpty else { return pane.entries }
        return pane.entries.filter { query.matches($0.text) }
    }

    private var lines: some View {
        let entries = shown
        return ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { entry in
                        LogLineRow(entry: entry, query: query, timestamps: timestamps, dimmed: !onlyMatches && !query.include.isEmpty && !query.matches(entry.text))
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("pane-bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .overlay {
                if entries.isEmpty { emptyOverlay }
            }
            .onChange(of: entries.last?.id) {
                guard !pane.isPaused else { return }
                proxy.scrollTo("pane-bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("pane-bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if let error = pane.errorText {
            EmptyState(icon: .error, title: "Could not read logs", message: error)
        } else if pane.isStreaming && pane.entries.isEmpty {
            EmptyState(icon: .logs, title: "Waiting for output", message: "New lines show up here as the container writes them.")
        } else if !pane.entries.isEmpty {
            EmptyState(icon: .search, title: "No matches", message: "No line in this pane matches the filter.")
        } else {
            EmptyState(icon: .logs, title: "No logs", message: "This container has not written anything yet.")
        }
    }

    private var picker: some View {
        let choices = LogsContainerChoices.list(BackgroundServices.shared.visibleContainers).filter { !taken.contains($0.id) }
        return VStack(spacing: 14) {
            EmptyState(icon: .logs, title: "Pick a container", message: choices.isEmpty ? "No other containers to show." : "Its logs stream into this pane.")
                .fixedSize(horizontal: false, vertical: true)
            if !choices.isEmpty {
                VStack(spacing: 2) {
                    ForEach(choices.prefix(8)) { item in
                        LogPickRow(choice: item) { pane.containerID = item.id }
                    }
                }
                .frame(maxWidth: 280)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy() {
        let text = LogFormat.copyText(shown, timestamps: timestamps)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.showToast(shown.count == 1 ? "Copied 1 line" : "Copied \(shown.count) lines", style: .success)
    }
}

/// One log line: optional time, then the text with matches marked.
private struct LogLineRow: View {
    let entry: LogEntry
    let query: LogQuery
    let timestamps: Bool
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if timestamps {
                Text(entry.time.map { LogFormat.timestamp($0) } ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DS.textTertiary)
                    .frame(width: 84, alignment: .leading)
            }
            Text(highlighted)
                .foregroundStyle(dimmed ? DS.textTertiary : DS.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
    }

    private var highlighted: AttributedString {
        var result = AttributedString(entry.text)
        guard !query.include.isEmpty else { return result }
        let text = entry.text
        for range in query.highlights(in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].backgroundColor = DS.warning.opacity(0.35)
        }
        return result
    }
}

/// Container row in an empty pane.
private struct LogPickRow: View {
    let choice: LogsContainerChoices.Choice
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(choice.isRunning ? DS.running : DS.stopped).frame(width: 7, height: 7)
                Text(choice.name).font(.callout).foregroundStyle(DS.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                DeckIcon(.chevronRight, size: 10, color: DS.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered ? DS.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

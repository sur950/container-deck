import SwiftUI
import AppKit
import DeckCore

/// One log line with a stable id for lists.
struct ContainerLogLine: Identifiable, Hashable {
    let id: Int
    let text: String
}

/// Streams log lines and batches them so the list stays smooth.
@MainActor
@Observable
final class ContainerLogModel {
    private(set) var lines: [ContainerLogLine] = []
    private(set) var isStreaming = false
    var errorText: String?

    private var pending: [String] = []
    private var nextID = 0
    private var flushTask: Task<Void, Never>?
    private var generation = 0
    private let maxLines = 10_000

    func run(client: ContainerClient, id: String, options: LogOptions) async {
        // A new run can start before the old one has wound down. Only the
        // newest run may touch the lines.
        generation += 1
        let mine = generation
        flushTask?.cancel()
        flushTask = nil
        lines = []
        pending = []
        errorText = nil
        isStreaming = true
        do {
            for try await line in client.logs(id, options: options) {
                guard mine == generation, !Task.isCancelled else { break }
                pending.append(line)
                scheduleFlush()
            }
        } catch is CancellationError {
            // Stopped on purpose.
        } catch {
            if !Task.isCancelled && mine == generation { errorText = error.localizedDescription }
        }
        guard mine == generation else { return }
        flushTask?.cancel()
        flushTask = nil
        flush()
        isStreaming = false
    }

    func clear() {
        lines = []
        pending = []
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        var batch: [ContainerLogLine] = []
        batch.reserveCapacity(pending.count)
        for text in pending {
            batch.append(ContainerLogLine(id: nextID, text: text))
            nextID += 1
        }
        pending = []
        var all = lines
        all.append(contentsOf: batch)
        if all.count > maxLines {
            all.removeFirst(all.count - maxLines)
        }
        lines = all
    }
}

private struct LogStreamKey: Hashable {
    var id: String
    var follow: Bool
    var boot: Bool
    var tail: Int
    var isRunning: Bool
    var cliPath: String?
}

/// Live logs with follow, boot log, tail, search, copy and clear.
struct ContainerLogsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let containerID: String
    /// Following a stopped container would wait forever, so it reads once instead.
    var isRunning: Bool

    @State private var model = ContainerLogModel()
    @State private var follow = true
    @State private var boot = false
    @State private var tail = 500
    @State private var query = ""
    @State private var onlyMatches = false
    @State private var autoscroll = true

    init(containerID: String, isRunning: Bool = true) {
        self.containerID = containerID
        self.isRunning = isRunning
    }

    private static let tailChoices = [100, 500, 1000, 5000, 0]

    var body: some View {
        VStack(spacing: 0) {
            controls
            logList
            ListStatusBar(statusText) {
                if showHints, let client = state.client {
                    CommandHint(client.commandLine(client.logArguments(containerID, options: logOptions)))
                        .frame(maxWidth: 420)
                }
            }
        }
        .task(id: LogStreamKey(id: containerID, follow: follow, boot: boot, tail: tail, isRunning: isRunning, cliPath: state.client?.cliPath)) {
            guard let client = state.client else { return }
            await model.run(client: client, id: containerID, options: logOptions)
        }
    }

    private var logOptions: LogOptions {
        LogOptions(follow: follow && isRunning, tail: tail == 0 ? nil : tail, boot: boot)
    }

    private var statusText: String {
        let total = model.lines.count
        let noun = total == 1 ? "line" : "lines"
        if !query.isEmpty {
            let matches = model.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }.count
            return "\(matches) of \(total) \(noun) match"
        }
        if model.isStreaming && follow && isRunning {
            return "\(total) \(noun), following"
        }
        return "\(total) \(noun)"
    }

    // MARK: Controls

    private var controls: some View {
        ContainerTabBar {
            ContainerFilterField(prompt: "Filter lines", text: $query)
                .frame(minWidth: 140, maxWidth: 240)

            Toggle("Only matches", isOn: $onlyMatches)
                .toggleStyle(.checkbox)
                .disabled(query.isEmpty)
                .fixedSize()

            Spacer(minLength: 8)

            if model.isStreaming && follow && isRunning {
                HStack(spacing: 5) {
                    Circle().fill(DS.running).frame(width: 7, height: 7)
                    Text("Live").font(.caption.weight(.medium)).foregroundStyle(DS.running)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(DS.running.opacity(0.12)))
                .fixedSize()
            }

            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
                .help("Keep reading new lines")
                .fixedSize()
            Toggle("Auto scroll", isOn: $autoscroll)
                .toggleStyle(.checkbox)
                .help("Jump to the newest line")
                .fixedSize()
            Toggle("Boot log", isOn: $boot)
                .toggleStyle(.checkbox)
                .help("Show the Linux boot log instead of the app output")
                .fixedSize()

            Picker("Lines", selection: $tail) {
                ForEach(Self.tailChoices, id: \.self) { value in
                    Text(value == 0 ? "All lines" : "Last \(value)").tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("How many earlier lines to load")
            .id(colorScheme)

            Divider().frame(height: 18)

            Button {
                copyLines()
            } label: {
                DeckIcon(.copy, size: 13)
                    .frame(width: 18, height: 16)
            }
            .help("Copy the shown lines")
            .disabled(model.lines.isEmpty)

            Button {
                model.clear()
            } label: {
                DeckIcon(.trash, size: 13)
                    .frame(width: 18, height: 16)
            }
            .help("Clear the view")
            .disabled(model.lines.isEmpty)
        }
        .font(.callout)
    }

    // MARK: List

    private var shownLines: [ContainerLogLine] {
        guard onlyMatches, !query.isEmpty else { return model.lines }
        return model.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var logList: some View {
        let shown = shownLines
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { line in
                        Text(highlighted(line.text))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(DS.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("log-bottom")
                }
                .padding(.horizontal, Layout.pagePadding)
                .padding(.vertical, 12)
            }
            .background(DS.surfaceSunken)
            .overlay {
                if shown.isEmpty {
                    emptyOverlay
                }
            }
            .onChange(of: model.lines.last?.id) {
                guard autoscroll else { return }
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
            .onChange(of: autoscroll) { _, on in
                if on { proxy.scrollTo("log-bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if let error = model.errorText {
            EmptyState(icon: .error, title: "Could not read logs", message: error)
        } else if model.isStreaming && model.lines.isEmpty {
            EmptyState(icon: .logs, title: "Waiting for output", message: "New lines show up here as the container writes them.")
        } else if !model.lines.isEmpty {
            EmptyState(icon: .search, title: "No matches", message: "No line matches your filter.")
        } else {
            EmptyState(icon: .logs, title: "No logs", message: "This container has not written anything yet.")
        }
    }

    /// Marks every match of the filter text.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let needle = query
        guard !needle.isEmpty else { return result }
        let mark = DS.warning.opacity(0.35)
        var start = result.startIndex
        while start < result.endIndex,
              let range = result[start...].range(of: needle, options: [.caseInsensitive]) {
            result[range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = mark
            if range.upperBound <= start { break }
            start = range.upperBound
        }
        return result
    }

    private func copyLines() {
        let text = shownLines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.showToast("Copied \(shownLines.count) lines", style: .success)
    }
}

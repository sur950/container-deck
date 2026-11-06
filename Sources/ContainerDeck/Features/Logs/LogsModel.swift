import SwiftUI
import DeckCore

extension PrefKey {
    /// Container names open in the Logs window, comma separated, so it opens the same way next time.
    static let logPanes = "logs.panes"
    /// `LogSplit` raw value.
    static let logSplit = "logs.split"
    static let logTimestamps = "logs.timestamps"
}

/// Colours that tell panes apart. Brand crimson first, the rest sit well next to it in Light and Dark.
enum LogPalette {
    static let colors: [Color] = [
        DS.accent,
        Color.adaptive(light: 0x7A4FB8, dark: 0xA783E0), // plum
        Color.adaptive(light: 0x1C7F86, dark: 0x4FBEC4), // teal
        Color.adaptive(light: 0xA9650A, dark: 0xE2A64E), // amber
        Color.adaptive(light: 0x3E68A8, dark: 0x82A7E0), // steel blue
        Color.adaptive(light: 0x5C7A2A, dark: 0x9CC25E)  // olive
    ]

    static func color(_ slot: Int) -> Color {
        colors[((slot % colors.count) + colors.count) % colors.count]
    }
}

/// One pane: one container's log stream.
@MainActor
@Observable
final class LogPaneModel: Identifiable {
    let id = UUID()
    var containerID: String?
    var colorSlot: Int

    private(set) var buffer = LogBuffer()
    private(set) var isStreaming = false
    private(set) var errorText: String?
    /// The shown lines while paused. New lines keep coming in underneath.
    private(set) var frozen: [LogEntry]?

    @ObservationIgnored private var pending: [(Date?, String)] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Lines that arrive this soon after the stream opens are the earlier tail, which has no real time.
    static let tailWindow: TimeInterval = 0.75

    init(containerID: String?, colorSlot: Int) {
        self.containerID = containerID
        self.colorSlot = colorSlot
    }

    var isPaused: Bool { frozen != nil }
    var entries: [LogEntry] { frozen ?? buffer.entries }
    var newWhilePaused: Int {
        guard let frozen else { return 0 }
        let lastShown = frozen.last?.id ?? -1
        return buffer.entries.reduce(0) { $0 + ($1.id > lastShown ? 1 : 0) }
    }

    func setPaused(_ paused: Bool) {
        frozen = paused ? buffer.entries : nil
    }

    func clear() {
        buffer.clear()
        pending = []
        if frozen != nil { frozen = [] }
    }

    func run(client: ContainerClient, id: String, follow: Bool) async {
        generation += 1
        let mine = generation
        flushTask?.cancel()
        flushTask = nil
        buffer.clear()
        pending = []
        frozen = nil
        errorText = nil
        isStreaming = true
        let opened = Date()
        do {
            let options = LogOptions(follow: follow, tail: 500, boot: false)
            for try await line in client.logs(id, options: options) {
                guard mine == generation, !Task.isCancelled else { break }
                let now = Date()
                pending.append((now.timeIntervalSince(opened) < Self.tailWindow ? nil : now, line))
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

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        var next = buffer
        next.append(pending)
        pending = []
        buffer = next
    }
}

/// The whole Logs view: up to four panes, a shared filter and layout.
@MainActor
@Observable
final class LogsModel {
    private(set) var panes: [LogPaneModel] = []
    var query = ""
    var onlyMatches = false

    init(containerIDs: [String] = []) {
        for id in containerIDs.prefix(ObservabilityConfig.maxLogPanes) { add(id) }
        if panes.isEmpty { add(nil) }
    }

    var canAdd: Bool { panes.count < ObservabilityConfig.maxLogPanes }

    @discardableResult
    func add(_ containerID: String?) -> LogPaneModel? {
        if let containerID, let existing = panes.first(where: { $0.containerID == containerID }) { return existing }
        // An empty pane is filled first.
        if let containerID, let empty = panes.first(where: { $0.containerID == nil }) {
            empty.containerID = containerID
            return empty
        }
        guard canAdd else { return nil }
        let slot = LogFormat.nextColorSlot(used: panes.map(\.colorSlot), slots: LogPalette.colors.count)
        let pane = LogPaneModel(containerID: containerID, colorSlot: slot)
        panes.append(pane)
        return pane
    }

    func remove(_ pane: LogPaneModel) {
        panes.removeAll { $0.id == pane.id }
        if panes.isEmpty { add(nil) }
    }

    /// Container ids shown, for saving.
    var savedValue: String {
        panes.compactMap(\.containerID).joined(separator: ",")
    }

    static func restore(_ value: String) -> [String] {
        value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

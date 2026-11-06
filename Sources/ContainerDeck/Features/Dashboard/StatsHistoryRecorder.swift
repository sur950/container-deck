import SwiftUI
import AppKit
import DeckCore

/// Keeps stats history between launches. Listens to the shared `StatsSampler` (no loop,
/// no process of its own): each new frame of readings goes into a `StatsHistoryStore`,
/// which is saved to Application Support every two minutes while samples come in and
/// when the app quits. History only grows while some screen keeps the sampler running.
@MainActor
@Observable
final class StatsHistoryRecorder {
    static let shared = StatsHistoryRecorder()

    private(set) var store = StatsHistoryStore()
    /// True once the saved file has been read.
    private(set) var isLoaded = false

    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastFrame: Date?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?
    @ObservationIgnored private let file: URL

    private init(file: URL = ObservabilityConfig.historyFile) {
        self.file = file
    }

    /// Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        let file = self.file
        Task {
            let saved = await Task.detached(priority: .utility) { StatsHistoryCodec.load(from: file) }.value
            self.merge(saved)
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StatsHistoryRecorder.shared.saveNow() }
        }
        observe()
    }

    /// Re-arms after every change of the sampler's readings.
    private func observe() {
        withObservationTracking {
            _ = StatsSampler.shared.readings
        } onChange: {
            Task { @MainActor in
                let recorder = StatsHistoryRecorder.shared
                recorder.ingest(StatsSampler.shared.readings)
                recorder.observe()
            }
        }
    }

    /// Adds the newest frame. Ignores repeats (the sampler also publishes when it prunes).
    func ingest(_ readings: [String: StatsReading]) {
        guard let date = readings.values.map(\.date).max() else { return }
        if let lastFrame, date <= lastFrame { return }
        lastFrame = date
        var names: [String: String] = [:]
        for container in BackgroundServices.shared.containers where readings[container.id] != nil {
            names[container.id] = container.name.isEmpty ? container.id : container.name
        }
        var next = store
        next.record(readings.mapValues { StatsPoint($0) }, names: names, at: date)
        store = next
        dirty = true
        scheduleSave()
    }

    /// Points for one container, by id.
    func points(_ id: String, range: StatsHistoryRange, now: Date = Date()) -> [StatsPoint] {
        store.points(id, range: range, now: now)
    }

    func totals(range: StatsHistoryRange, now: Date = Date()) -> [StatsPoint] {
        store.totals(range: range, now: now)
    }

    // MARK: Saving

    private func merge(_ saved: StatsHistoryStore) {
        if store.isEmpty {
            store = saved
        } else {
            // Samples arrived before the file was read. Keep the file and add the new ones on top.
            var merged = saved
            merged.absorb(store)
            store = merged
        }
        isLoaded = true
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ObservabilityConfig.saveInterval))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.saveInBackground()
        }
    }

    private func saveInBackground() {
        guard dirty else { return }
        dirty = false
        let snapshot = store
        let file = self.file
        Task.detached(priority: .utility) {
            try? StatsHistoryCodec.save(snapshot, to: file)
        }
    }

    /// Writes at once (app quit).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        dirty = false
        try? StatsHistoryCodec.save(store, to: file)
    }
}

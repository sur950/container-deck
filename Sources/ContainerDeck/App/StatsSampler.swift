import SwiftUI
import DeckCore

/// One stats sampler for the whole app. Runs only while a screen that shows stats is
/// on screen (reference counted), and never while nothing of ours is visible.
///
/// With the direct API (`BackgroundServices.statsAreDirect`) it asks the daemon for
/// all running containers about every 1.5 seconds (about 25 ms a call, no process) and
/// works out CPU from its own consecutive samples (`StatsTracker`).
///
/// On the container command it keeps one `container stats <ids>` process running in its streaming table mode,
/// which prints a fresh frame about every 2.2 seconds. That is one process instead of one
/// every 2.2 seconds. If the table cannot be read, it falls back to back to back
/// `stats --no-stream --format json` calls and works out CPU from its own consecutive samples.
/// Every consumer (Dashboard, Containers list, Stats tab, menu bar) reads the same results.
@MainActor
@Observable
final class StatsSampler {
    static let shared = StatsSampler()

    /// About five minutes at one sample every 2.2 seconds (3.5 minutes at 1.5 s with the direct API).
    static let maxSamples = 140
    /// Time between direct samples.
    static let directInterval: Double = 1.5
    /// Time between direct samples when only the menu bar panel is on screen.
    static let directPanelInterval: Double = 3

    /// Latest reading per container id.
    private(set) var readings: [String: StatsReading] = [:]
    /// Chart history per container id.
    private(set) var history: [String: [ContainerStatsSample]] = [:]
    /// Totals across running containers, for the Dashboard.
    private(set) var totals: [ContainerStatsSample] = []

    @ObservationIgnored private var subscriptions = SubscriptionSet()
    @ObservationIgnored private var tracker = StatsTracker()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sampledIDs: [String] = []
    @ObservationIgnored private var useSnapshots = false
    /// The running task samples over the direct API.
    @ObservationIgnored private var sampledDirect = false
    @ObservationIgnored private var lastFrameAt: Date?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var pendingStop: Task<Void, Never>?
    /// Stream runs that ended without a single frame, in a row. Three of them mean this CLI cannot stream.
    @ObservationIgnored private var quickFailures = 0
    @ObservationIgnored private var frameCount = 0

    private init() {
        AppActivity.shared.onChange { StatsSampler.shared.update() }
    }

    func attach(_ state: AppState) {
        self.state = state
    }

    // MARK: Subscriptions

    func subscribe(_ owner: String) -> Int {
        let token = subscriptions.acquire(owner)
        DebugAutomation.log("stats: + \(owner) (\(subscriptions.count))")
        update()
        return token
    }

    func unsubscribe(_ token: Int) {
        if subscriptions.release(token) {
            DebugAutomation.log("stats: - token \(token) (\(subscriptions.count))")
            update()
        }
    }

    var subscriberCount: Int { subscriptions.count }
    var isSampling: Bool { task != nil }

    // MARK: Reading

    func reading(for container: ContainerSummary) -> StatsReading? {
        readings[container.id] ?? readings[container.name]
    }

    /// CPU text for lists: "Measuring" until two samples exist.
    func cpuText(for container: ContainerSummary) -> String {
        guard container.isRunning else { return "-" }
        guard let cpu = reading(for: container)?.cpuPercent else { return "Measuring" }
        return Format.percent(cpu)
    }

    // MARK: Control

    /// Starts, stops or retargets the sampler. Called when subscriptions, the window or the running containers change.
    func update() {
        let running = BackgroundServices.shared.containers.filter(\.isRunning).map(\.id).sorted()
        pruneHistory(keeping: Set(running))
        let wanted = subscriptions.isActive
            && AppActivity.shared.mode != .background
            && state?.client != nil
            && !running.isEmpty
        guard wanted else {
            if task != nil {
                DebugAutomation.log("stats: not wanted. subs \(subscriptions.count) mode \(AppActivity.shared.mode) running \(running.count)")
            }
            // Switching screens drops the last subscriber and adds the next one a moment later.
            // Wait a second before stopping so the stream is not restarted for nothing.
            if task != nil, !running.isEmpty, AppActivity.shared.mode != .background, state?.client != nil {
                scheduleStop()
            } else {
                stop()
            }
            return
        }
        pendingStop?.cancel()
        pendingStop = nil
        let direct = BackgroundServices.shared.statsAreDirect
        if task != nil, running == sampledIDs, direct == sampledDirect { return }
        start(running, direct: direct)
    }

    private func scheduleStop() {
        guard pendingStop == nil else { return }
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pendingStop = nil
            if !self.subscriptions.isActive { self.stop() }
        }
    }

    private func stop() {
        pendingStop?.cancel()
        pendingStop = nil
        if task != nil { DebugAutomation.log("stats: stop") }
        task?.cancel()
        task = nil
        sampledIDs = []
    }

    private func start(_ ids: [String], direct: Bool) {
        let kind = direct ? "direct" : (useSnapshots ? "snapshots" : "stream")
        DebugAutomation.log("stats: start \(kind) \(ids) for \(subscriptions.owners)")
        task?.cancel()
        sampledIDs = ids
        sampledDirect = direct
        generation += 1
        let gen = generation
        guard let client = state?.client else { return }
        let needsSeed = ids.contains { readings[$0] == nil }
        let snapshots = useSnapshots
        task = Task { [weak self] in
            if direct {
                await self?.runDirect(client: client, generation: gen)
            } else if snapshots {
                await self?.runSnapshots(client: client, ids: ids, generation: gen)
            } else {
                await self?.runStream(client: client, ids: ids, generation: gen, seed: needsSeed)
            }
        }
    }

    /// One long running `container stats <ids>`. A JSON snapshot runs next to it first
    /// so memory and network show after about 2 seconds instead of 4.
    private func runStream(client: ContainerClient, ids: [String], generation gen: Int, seed: Bool) async {
        let started = Date()
        lastFrameAt = nil
        if seed {
            Task { [weak self] in
                guard let batch = try? await client.stats(ids) else { return }
                await MainActor.run {
                    guard let self, self.generation == gen, self.lastFrameAt == nil else { return }
                    self.ingest(batch)
                }
            }
        }
        // Watchdog: no frame within 12 seconds means the table changed shape. Use snapshots.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == gen, self.lastFrameAt == nil else { return }
                self.switchToSnapshots()
            }
        }
        defer { watchdog.cancel() }

        var assembler = StatsFrameAssembler(expectedRows: ids.count)
        do {
            for try await line in client.statsStream(ids) {
                if Task.isCancelled { return }
                if let frame = assembler.feed(line, at: Date()) {
                    lastFrameAt = Date()
                    quickFailures = 0
                    ingest(frame)
                }
            }
        } catch {
            // Falls through to the checks below.
        }
        guard !Task.isCancelled, generation == gen else { return }
        // The stream ended. Usually a container in the list just stopped or was deleted, so
        // refresh the list and try again. Only repeated runs without any frame mean this CLI
        // cannot stream: then use snapshots from now on.
        if lastFrameAt == nil && Date().timeIntervalSince(started) < 5 {
            quickFailures += 1
        }
        if quickFailures >= 3 {
            switchToSnapshots()
            return
        }
        BackgroundServices.shared.pollNow()
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, generation == gen else { return }
        task = nil
        update()
    }

    private func switchToSnapshots() {
        guard !useSnapshots else { return }
        useSnapshots = true
        task?.cancel()
        task = nil
        update()
    }

    /// Direct API: one call for all running containers, then a short wait. The first
    /// sample shows memory, network and disk at once, CPU shows from the second.
    private func runDirect(client: ContainerClient, generation gen: Int) async {
        while !Task.isCancelled, generation == gen {
            let started = Date()
            do {
                // All running containers: no "no such container" for one that just stopped.
                let batch = try await client.stats([])
                guard !Task.isCancelled, generation == gen else { return }
                ingest(batch)
            } catch {
                // The service went away or a call failed. The feed retargets the sampler.
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            let pace = AppActivity.shared.mode == .panel ? Self.directPanelInterval : Self.directInterval
            let wait = pace - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }

    /// Back to back JSON samples. The CLI waits about 2 seconds inside each call, so no extra sleep.
    private func runSnapshots(client: ContainerClient, ids: [String], generation gen: Int) async {
        while !Task.isCancelled, generation == gen {
            do {
                let batch = try await client.stats(ids)
                guard !Task.isCancelled, generation == gen else { return }
                ingest(batch)
            } catch {
                // A container stopped between the list and the call, or the service went away.
                // Wait a moment. The feed retargets the sampler when the list changes.
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Results

    private func ingest(_ batch: [ContainerStats]) {
        guard !batch.isEmpty else { return }
        let fresh = tracker.ingest(batch)
        frameCount += 1
        if AppActivity.shared.mode == .panel, frameCount > 2, readings.keys.count == fresh.keys.count {
            // Only the menu bar panel is looking: a glance view. The stream (one frame about
            // every 2.2 s) publishes every other frame. Direct samples already come every 3 s.
            if !sampledDirect, frameCount % 2 == 1 { return }
            // Nothing the panel shows changed: no view update at all.
            if Self.panelSignature(fresh) == Self.panelSignature(readings) { return }
        }
        readings = fresh

        var nextHistory = history
        for (id, reading) in fresh {
            var list = nextHistory[id] ?? []
            list.append(ContainerStatsSample(reading))
            if list.count > Self.maxSamples { list.removeFirst(list.count - Self.maxSamples) }
            nextHistory[id] = list
        }
        history = nextHistory

        let date = fresh.values.map(\.date).max() ?? Date()
        let measured = fresh.values.allSatisfy { $0.cpuPercent != nil }
        var total = ContainerStatsSample(
            date: date,
            cpuPercent: fresh.values.reduce(0) { $0 + ($1.cpuPercent ?? 0) },
            memoryBytes: fresh.values.reduce(0) { $0 + Double($1.memoryBytes) },
            memoryLimitBytes: fresh.values.reduce(0) { $0 + Double($1.memoryLimitBytes) },
            netRxPerSec: 0, netTxPerSec: 0, diskReadPerSec: 0, diskWritePerSec: 0,
            pids: fresh.values.reduce(0) { $0 + $1.pids }
        )
        total.cpuMeasured = measured
        var nextTotals = totals
        nextTotals.append(total)
        if nextTotals.count > Self.maxSamples { nextTotals.removeFirst(nextTotals.count - Self.maxSamples) }
        totals = nextTotals
    }

    /// What the menu bar panel shows, rounded like it shows it (CPU to 0.1 %, memory to 1 MB).
    static func panelSignature(_ readings: [String: StatsReading]) -> [String: [Int]] {
        readings.mapValues { reading in
            [reading.cpuPercent.map { Int(($0 * 10).rounded()) } ?? -1, Int(reading.memoryBytes / 1_000_000)]
        }
    }

    private func pruneHistory(keeping running: Set<String>) {
        let gone = history.keys.filter { !running.contains($0) }
        if !gone.isEmpty {
            var next = history
            for id in gone { next.removeValue(forKey: id) }
            history = next
        }
        let staleReadings = readings.keys.filter { !running.contains($0) }
        if !staleReadings.isEmpty {
            var next = readings
            for id in staleReadings { next.removeValue(forKey: id) }
            readings = next
        }
    }
}

// MARK: - View hook

extension View {
    /// Keeps the shared stats sampler running while this view is on screen and `active` is true.
    func usesLiveStats(_ owner: String, active: Bool = true) -> some View {
        modifier(LiveStatsSubscription(owner: owner, active: active))
    }
}

private struct LiveStatsSubscription: ViewModifier {
    let owner: String
    let active: Bool

    func body(content: Content) -> some View {
        // A task lives exactly as long as the view is in the hierarchy and `active` stays the same.
        // The token goes back when it is cancelled.
        content.task(id: active) {
            guard active else { return }
            let token = StatsSampler.shared.subscribe(owner)
            defer { StatsSampler.shared.unsubscribe(token) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

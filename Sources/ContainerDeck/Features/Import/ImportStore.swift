import SwiftUI
import AppKit
import DeckCore

/// Engines, their images and the running import. Shared so an import keeps
/// going (and keeps its progress) when you switch screens.
@MainActor
@Observable
final class ImportStore {
    static let shared = ImportStore()

    var engines: [DetectedEngine] = []
    var images: [EngineImage] = []
    var engineErrors: [String: String] = [:]
    var isScanning = false
    var lastScan: Date?

    var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue else { return }
            importNote = nil
            // Picking a row again is a new action. Its old result goes away.
            if !isImporting {
                for id in selection.subtracting(oldValue) where steps[id]?.isFinished == true {
                    steps[id] = nil
                }
            }
        }
    }
    /// Per image progress. Only filled during an import and for its results afterwards.
    var steps: [String: ImportStep] = [:]
    /// One short line after a cancelled import ("Import cancelled"). Clears on the next action.
    var importNote: String?
    /// Engine id to open (true) or closed (false), as the person left it. Saved in Prefs.
    private(set) var savedExpanded: [String: Bool] = [:]
    var isImporting = false
    var importError: String?
    var currentIndex = 0
    var totalCount = 0
    /// What the import does with a stopped engine ("Starting OrbStack", "Exporting 2 of 5").
    var importActivity: EngineActivity?

    /// Stopped engine id to what it is doing while we load its images.
    var engineActivity: [String: EngineActivity] = [:]

    /// Images read from a stopped engine (started in the background just for that).
    struct OfflineSource {
        var plan: EngineControlPlan
        /// Images as the screen shows them, under the stopped engine's id.
        var images: [EngineImage]
        /// Screen image id to the image as the running engine named it.
        var originals: [String: EngineImage]
    }

    /// Stopped engine id to its loaded images.
    private(set) var offline: [String: OfflineSource] = [:]

    private var runningLists: [String: [EngineImage]] = [:]
    /// Apple's container images as last read. The source for "In Apple's store".
    private var localImages: [ImageSummary] = []
    private var importTask: Task<Void, Never>?
    private var activeIDs: Set<String> = []
    private var loadTasks: [String: Task<Void, Never>] = [:]
    /// Engines we started and have not stopped yet. Stopped on app quit.
    private var startedPlans: [String: EngineControlPlan] = [:]
    private let planner = EngineControlPlanner()
    #if DEBUG
    /// Automation only: the list shows made up images. Import is blocked.
    private(set) var isSampleListing = false
    #endif

    init() {
        savedExpanded = UserDefaults.standard.dictionary(forKey: PrefKey.importExpandedEngines) as? [String: Bool] ?? [:]
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ImportStore.shared.stopStartedEnginesNow()
            }
        }
    }

    // MARK: - Scan

    func scan(client: ContainerClient?) async {
        guard !isScanning else { return }
        isScanning = true
        importNote = nil
        #if DEBUG
        isSampleListing = false
        #endif

        var found = await EngineDetector().detect()
        let catalog = EngineCatalog()
        var lists: [String: [EngineImage]] = [:]
        var errors: [String: String] = [:]
        for index in found.indices where found[index].isRunning {
            do {
                let list = try await catalog.images(in: found[index])
                lists[found[index].id] = list
                found[index].imageCount = list.count
            } catch {
                errors[found[index].id] = error.localizedDescription
            }
        }

        // Keep images loaded from engines that are still stopped. Drop the rest.
        for id in offline.keys {
            guard let index = found.firstIndex(where: { $0.id == id && $0.state == .stopped }) else {
                offline[id] = nil
                continue
            }
            found[index].imageCount = offline[id]?.images.count
        }
        // Keep errors from loading stopped engines while they are still stopped.
        for (id, message) in engineErrors where found.contains(where: { $0.id == id && $0.state == .stopped }) {
            errors[id] = message
        }

        if let client, let here = try? await client.listImages() {
            localImages = here
        }

        engines = found
        runningLists = lists
        engineErrors = errors
        // A scan is a fresh look. Results from an earlier import go away.
        if !isImporting { steps = [:] }
        rebuildImages()
        lastScan = Date()
        isScanning = false
    }

    private func rebuildImages() {
        var lists: [[EngineImage]] = []
        for engine in engines {
            if let list = runningLists[engine.id] {
                lists.append(list)
            } else if let source = offline[engine.id] {
                lists.append(source.images)
            }
        }
        images = ImportListRules.markPresence(EngineCatalog.merge(lists, localReferences: []), local: localImages)
        let validIDs = Set(images.map(\.id))
        selection = selection.filter { validIDs.contains($0) }
    }

    /// Reads Apple's image list again and updates "In Apple's store" on every row.
    /// Runs when the screen appears and whenever the app's images change.
    func refreshLocalImages(client: ContainerClient?) async {
        guard let client, !isScanning, let here = try? await client.listImages() else { return }
        localImages = here
        images = ImportListRules.markPresence(images, local: here)
        if !isImporting {
            steps = ImportListRules.droppingGoneResults(steps, images: images)
        }
    }

    // MARK: - Stopped engines

    /// How to start this engine in the background, or nil when it is running or we cannot.
    func plan(for engine: DetectedEngine) -> EngineControlPlan? {
        guard engine.state == .stopped else { return nil }
        return planner.plan(for: engine)
    }

    func isLoading(_ engine: DetectedEngine) -> Bool {
        loadTasks[engine.id] != nil
    }

    func loadedCount(_ engine: DetectedEngine) -> Int? {
        offline[engine.id]?.images.count
    }

    var isBusyWithEngines: Bool { !loadTasks.isEmpty }

    /// Starts a stopped engine in the background, lists its images, and stops it again.
    func loadImages(from engine: DetectedEngine, state: AppState) {
        guard let plan = plan(for: engine), loadTasks[engine.id] == nil, !isImporting else { return }
        let id = engine.id
        let name = plan.name
        engineErrors[id] = nil
        importNote = nil
        engineActivity[id] = .starting(name)

        loadTasks[id] = Task {
            let workflow = StoppedEngineWorkflow(plan: plan)
            do {
                let listing = try await workflow.listImages(
                    activity: { activity in await self.engineChanged(id, plan: plan, activity: activity) }
                ) { running in
                    let catalog = EngineCatalog()
                    var all: [EngineImage] = []
                    for item in running {
                        all += try await catalog.images(in: item)
                    }
                    return all
                }
                if listing.wasRunning {
                    // Someone started it in the meantime. A normal scan picks it up.
                    finishLoad(id)
                    await scan(client: state.client)
                    return
                }
                storeOffline(listing.images, for: engine, plan: plan)
                finishLoad(id)
                if let warning = listing.stop?.warning {
                    engineErrors[id] = warning
                    state.showToast(warning, style: .error)
                } else {
                    let count = listing.images.count
                    let what = count == 1 ? "1 image" : "\(count) images"
                    state.showToast("Loaded \(what) from \(name). It is stopped again.", style: .success)
                }
            } catch {
                finishLoad(id)
                if error is CancellationError {
                    state.showToast("Stopped. \(name) is stopped again.", style: .info)
                } else {
                    engineErrors[id] = error.localizedDescription
                    state.showError(error)
                }
            }
        }
    }

    func cancelLoad(_ engine: DetectedEngine) {
        loadTasks[engine.id]?.cancel()
    }

    private func engineChanged(_ id: String, plan: EngineControlPlan, activity: EngineActivity) {
        if case .starting = activity { startedPlans[id] = plan }
        if loadTasks[id] != nil { engineActivity[id] = activity }
    }

    private func finishLoad(_ id: String) {
        loadTasks[id] = nil
        engineActivity[id] = nil
        startedPlans[id] = nil
    }

    private func storeOffline(_ list: [EngineImage], for engine: DetectedEngine, plan: EngineControlPlan) {
        var shown: [EngineImage] = []
        var originals: [String: EngineImage] = [:]
        for original in list {
            var copy = original
            copy.engineID = engine.id
            copy.engineName = engine.name
            // Two namespaces can hold the same tag. Show it once.
            if originals[copy.id] != nil { continue }
            originals[copy.id] = original
            shown.append(copy)
        }
        offline[engine.id] = OfflineSource(plan: plan, images: shown, originals: originals)
        if let index = engines.firstIndex(where: { $0.id == engine.id }) {
            engines[index].imageCount = shown.count
        }
        rebuildImages()
    }

    /// App quit: stop engines we started and did not stop yet. Blocks for a few seconds at most.
    private func stopStartedEnginesNow() {
        for plan in startedPlans.values {
            plan.stopBlocking()
        }
        startedPlans.removeAll()
    }

    // MARK: - Selection

    func images(in engine: DetectedEngine) -> [EngineImage] {
        images.filter { $0.engineID == engine.id }
    }

    var selectedImages: [EngineImage] {
        images.filter { selection.contains($0.id) }
    }

    func selectAll(_ list: [EngineImage]) {
        for image in list where !image.alreadyHere {
            selection.insert(image.id)
        }
    }

    func deselectAll(_ list: [EngineImage]) {
        for image in list {
            selection.remove(image.id)
        }
    }

    // MARK: - Sections

    /// Whether an engine section is open. `defaults` comes from `ImportListRules.defaultExpanded`.
    func isExpanded(_ engineID: String, defaults: Set<String>) -> Bool {
        ImportListRules.isExpanded(engineID, saved: savedExpanded, defaults: defaults)
    }

    func setExpanded(_ engineID: String, _ open: Bool) {
        savedExpanded[engineID] = open
        UserDefaults.standard.set(savedExpanded, forKey: PrefKey.importExpandedEngines)
    }

    /// Back to the default rule for every engine.
    func forgetExpanded() {
        savedExpanded = [:]
        UserDefaults.standard.removeObject(forKey: PrefKey.importExpandedEngines)
    }

    // MARK: - Import

    func startImport(client: ContainerClient, state: AppState) {
        let chosen = selectedImages
        guard !chosen.isEmpty, !isImporting, loadTasks.isEmpty else { return }
        importNote = nil
        #if DEBUG
        if isSampleListing {
            importError = "Sample images cannot be imported. Scan again to see the real ones."
            return
        }
        #endif
        let importer = EngineImporter(client: client)
        do {
            try importer.checkDiskSpace(for: chosen)
        } catch {
            importError = error.localizedDescription
            return
        }

        importError = nil
        // A new run starts clean. Results from an earlier run go away.
        steps = [:]
        for image in chosen {
            steps[image.id] = .waiting
        }
        isImporting = true
        totalCount = chosen.count
        currentIndex = 0
        importActivity = nil
        activeIDs = Set(chosen.map(\.id))
        let engineByID = Dictionary(engines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Running engines first, one image at a time. Then each stopped engine as one batch.
        let direct = chosen.filter { offline[$0.engineID] == nil }
        var batches: [(engineID: String, source: OfflineSource, images: [EngineImage])] = []
        for engine in engines {
            guard let source = offline[engine.id] else { continue }
            let list = chosen.filter { $0.engineID == engine.id }
            if !list.isEmpty { batches.append((engine.id, source, list)) }
        }

        importTask = Task {
            var moved = 0
            var failed = 0
            var stopped = false
            var warnings: [String] = []

            for (index, image) in direct.enumerated() {
                if Task.isCancelled {
                    stopped = true
                    break
                }
                currentIndex = index + 1
                let id = image.id
                guard let engine = engineByID[image.engineID] else {
                    steps[id] = .failed("The engine is gone. Scan again.")
                    failed += 1
                    continue
                }
                do {
                    let method = try await importer.importImage(image, from: engine) { step in
                        await self.setStep(id, step)
                    }
                    steps[id] = .done(method: method)
                    markHere(id)
                    moved += 1
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        steps[id] = .cancelled
                        stopped = true
                        break
                    }
                    steps[id] = .failed(error.localizedDescription)
                    failed += 1
                }
            }

            for batch in batches where !stopped {
                let result = await importBatch(batch.images, source: batch.source, engineID: batch.engineID, importer: importer)
                moved += result.moved
                failed += result.failed
                if result.cancelled { stopped = true }
                if let warning = result.warning { warnings.append(warning) }
            }

            for image in chosen where steps[image.id] == .waiting {
                steps[image.id] = .cancelled
            }
            importActivity = nil
            finish(moved: moved, failed: failed, cancelled: stopped, warnings: warnings, state: state)
        }
    }

    /// Imports from one stopped engine: pulls what it can, starts the engine only for the rest.
    private func importBatch(
        _ chosen: [EngineImage], source: OfflineSource, engineID: String, importer: EngineImporter
    ) async -> (moved: Int, failed: Int, cancelled: Bool, warning: String?) {
        // The workflow works with the images as the running engine named them.
        var shownID: [String: String] = [:]
        var originals: [EngineImage] = []
        for image in chosen {
            guard let original = source.originals[image.id] else { continue }
            shownID[original.id] = image.id
            originals.append(original)
        }
        let map = shownID
        let workflow = StoppedEngineWorkflow(plan: source.plan)
        let plan = source.plan
        do {
            let outcome = try await workflow.importImages(
                originals,
                neededBytes: EngineImporter.requiredBytes(for: originals),
                freeBytes: importer.freeBytes,
                activity: { activity in await self.importChanged(engineID, plan: plan, activity: activity) },
                step: { id, step in await self.batchStep(map[id] ?? id, step) },
                pull: { image in
                    let id = map[image.id] ?? image.id
                    try await importer.pullFromRegistry(image) { step in await self.setStep(id, step) }
                },
                export: { image, engine in
                    let id = map[image.id] ?? image.id
                    try await importer.copy(image, from: engine) { step in await self.setStep(id, step) }
                }
            )
            startedPlans[engineID] = nil
            for id in outcome.moved.keys {
                if let shown = map[id] { markHere(shown) }
            }
            return (outcome.moved.count, outcome.failed.count, outcome.cancelled, outcome.stop?.warning)
        } catch {
            // Only the disk space check throws, before anything started.
            startedPlans[engineID] = nil
            for image in chosen {
                steps[image.id] = .failed(error.localizedDescription)
            }
            importError = error.localizedDescription
            return (0, chosen.count, false, nil)
        }
    }

    private func importChanged(_ engineID: String, plan: EngineControlPlan, activity: EngineActivity) {
        if case .starting = activity { startedPlans[engineID] = plan }
        importActivity = activity
    }

    private func batchStep(_ id: String, _ step: ImportStep) {
        steps[id] = step
        if step.isFinished {
            let finished = activeIDs.filter { steps[$0]?.isFinished == true }.count
            currentIndex = min(totalCount, max(currentIndex, finished))
        }
    }

    func cancel() {
        importTask?.cancel()
    }

    private func setStep(_ id: String, _ step: ImportStep) {
        // Ignore late progress after the image finished.
        if let current = steps[id], current.isFinished { return }
        steps[id] = step
    }

    private func markHere(_ id: String) {
        if let index = images.firstIndex(where: { $0.id == id }) {
            // Shown right away. The next read of Apple's image list confirms it.
            images[index].alreadyHere = true
        }
        selection.remove(id)
    }

    /// Rows keep only real results. A cancelled run leaves one short line in the bar instead.
    private func endRun(moved: Int, cancelled: Bool) {
        steps = ImportListRules.keepingResults(steps)
        if cancelled {
            importNote = moved == 0 ? "Import cancelled." : "Import cancelled. \(moved) moved."
        }
    }

    private func finish(moved: Int, failed: Int, cancelled: Bool, warnings: [String], state: AppState) {
        isImporting = false
        importTask = nil
        endRun(moved: moved, cancelled: cancelled)
        if moved > 0 {
            state.resourcesChanged()
        }
        if let warning = warnings.first {
            state.showToast(warning, style: .error)
        } else if cancelled {
            state.showToast("Import stopped. \(moved) moved.", style: .info)
        } else if failed > 0 {
            state.showToast("\(moved) moved, \(failed) failed.", style: .error)
        } else {
            state.showToast(moved == 1 ? "1 image moved." : "\(moved) images moved.", style: .success)
        }
    }
}

#if DEBUG
// MARK: - Automation samples

extension ImportStore {
    /// Fills found engines with made up images so the list can be checked without
    /// starting any engine. The first found engine gets 25, the next 1, then 4 each.
    func showSampleListing() {
        var targets = engines.filter { $0.state != .notFound }
        if targets.isEmpty { targets = Array(engines.prefix(2)) }
        guard !targets.isEmpty else { return }
        let names = ["nginx", "postgres", "redis", "node", "python", "golang", "alpine", "ubuntu",
                     "mysql", "mongo", "rabbitmq", "traefik", "grafana/grafana", "prom/prometheus",
                     "ghcr.io/acme/api", "ghcr.io/acme/web", "busybox", "httpd", "memcached", "minio/minio",
                     "pgvector/pgvector", "amazon/aws-cli", "clamav/clamav", "caddy", "local/devbox"]
        let tags = ["latest", "16-alpine", "7-alpine", "24-alpine", "3.12-slim", "1.23", "3.20", "24.04",
                    "8.4", "7.0", "3-management", "v3.1", "11.2.0", "v2.53.0", "1.4.2", "main", "1.36",
                    "2.4", "1.6", "RELEASE.2024", "pg17", "latest", "stable", "2", "dev"]
        let others = ["rancher/k3s", "registry", "kindest/node", "hashicorp/vault", "nats", "temporalio/server"]
        let now = Date()
        var lists: [String: [EngineImage]] = [:]
        for (index, engine) in targets.enumerated() {
            let count = index == 0 ? 25 : (index == 1 ? 1 : 4)
            lists[engine.id] = (0..<count).map { item in
                let slot = (item + index * 7) % names.count
                let local = names[slot].hasPrefix("local/")
                // Other engines get their own names. The same tag in two engines shows once.
                let reference = index == 0
                    ? "\(names[slot]):\(tags[slot])"
                    : "\(others[(item + index) % others.count]):\(index)"
                return EngineImage(
                    engineID: engine.id, engineName: engine.name, imageID: "sha256:sample\(index)\(item)",
                    reference: reference,
                    repoDigests: local ? [] : ["\(names[slot])@sha256:sample\(slot)"],
                    sizeBytes: UInt64(20 + slot * 37) * 1_048_576,
                    architecture: slot % 6 == 5 ? "amd64" : "arm64", os: "linux",
                    // One image per engine without a date, like Rancher reports some.
                    createdAt: item == count - 1 ? nil : now.addingTimeInterval(-Double(item + 1) * 86_400 * 3)
                )
            }
        }
        for engine in targets {
            if let index = engines.firstIndex(where: { $0.id == engine.id }) {
                engines[index].imageCount = lists[engine.id]?.count
            }
        }
        runningLists = lists
        offline = [:]
        steps = [:]
        importNote = nil
        isSampleListing = true
        rebuildImages()
    }

    /// Shows every per row state on the first rows, as during an import.
    func showSampleSteps() {
        let ids = images.prefix(5).map(\.id)
        let samples: [ImportStep] = [
            .waiting, .exporting(done: 120_000_000, total: 310_000_000), .pulling("Fetching layers"),
            .done(method: "Pulled from the registry"), .failed("Not enough free disk space for this image.")
        ]
        for (id, step) in zip(ids, samples) { steps[id] = step }
    }

    /// Ends a made up run as cancelled, the same way a real cancel ends.
    func showSampleCancel() {
        for image in images.prefix(8) where steps[image.id] == nil { steps[image.id] = .cancelled }
        endRun(moved: 1, cancelled: true)
    }
}
#endif

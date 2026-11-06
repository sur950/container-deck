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

    var selection: Set<String> = []
    var steps: [String: ImportStep] = [:]
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
    private var localReferences: [String] = []
    private var importTask: Task<Void, Never>?
    private var activeIDs: Set<String> = []
    private var loadTasks: [String: Task<Void, Never>] = [:]
    /// Engines we started and have not stopped yet. Stopped on app quit.
    private var startedPlans: [String: EngineControlPlan] = [:]
    private let planner = EngineControlPlanner()

    init() {
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
            localReferences = here.map(\.reference)
        }

        engines = found
        runningLists = lists
        engineErrors = errors
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
        images = EngineCatalog.merge(lists, localReferences: localReferences)
        let validIDs = Set(images.map(\.id))
        selection = selection.filter { validIDs.contains($0) }
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

    // MARK: - Import

    func startImport(client: ContainerClient, state: AppState) {
        let chosen = selectedImages
        guard !chosen.isEmpty, !isImporting, loadTasks.isEmpty else { return }
        let importer = EngineImporter(client: client)
        do {
            try importer.checkDiskSpace(for: chosen)
        } catch {
            importError = error.localizedDescription
            return
        }

        importError = nil
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
            images[index].alreadyHere = true
            localReferences.append(images[index].normalizedReference)
        }
        selection.remove(id)
    }

    private func finish(moved: Int, failed: Int, cancelled: Bool, warnings: [String], state: AppState) {
        isImporting = false
        importTask = nil
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

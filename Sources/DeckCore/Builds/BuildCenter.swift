import Foundation

/// What changed in the build center. Observers get these on a background thread.
public enum BuildCenterEvent: Sendable, Equatable {
    /// A build was added, changed state or moved to a new step.
    case changed(UUID)
    /// New log lines for a running build.
    case log(UUID)
    /// Builds were removed (trim, delete, clear).
    case removed([UUID])
}

/// Every image build in the app: the Build sheet, the Builds screen and Compose.
/// Runs `container build`, keeps the live log, saves the history and cancels builds.
/// Thread safe. Use `BuildCenter.shared` in the app.
public final class BuildCenter: @unchecked Sendable {
    public static let shared = BuildCenter(store: BuildCenter.defaultStore())

    /// Tests never touch the real history unless they ask for a folder.
    static func defaultStore() -> BuildHistoryStore {
        let env = ProcessInfo.processInfo.environment
        let override = env[BuildsConfig.directoryOverrideVariable]
        if (override ?? "").isEmpty && NSClassFromString("XCTestCase") != nil {
            return .memoryOnly
        }
        return BuildHistoryStore(directory: BuildsConfig.defaultDirectory)
    }

    public typealias Observer = @Sendable (BuildCenterEvent) -> Void

    private let lock = NSLock()
    private let store: BuildHistoryStore
    private let historyLimit: @Sendable () -> Int
    private var loaded = false
    private var records: [BuildRecord] = []
    /// Logs of running builds, and of finished ones read back from disk.
    private var logs: [UUID: [String]] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: Observer] = [:]
    /// One builder check shared by builds that start together (see `ensureBuilder`).
    private var warmup: Task<Void, Never>?
    /// Bumped on every change, so an older snapshot never overwrites a newer file.
    private var generation = 0
    private let saveLock = NSLock()
    private var savedGeneration = -1

    public init(store: BuildHistoryStore, historyLimit: @escaping @Sendable () -> Int = { BuildsConfig.historyLimit() }) {
        self.store = store
        self.historyLimit = historyLimit
    }

    // MARK: - Reading

    /// All builds, newest first.
    public func allRecords() -> [BuildRecord] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return records
    }

    public func record(_ id: UUID) -> BuildRecord? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return records.first { $0.id == id }
    }

    /// The log of a build. Finished builds are read from disk the first time.
    public func log(_ id: UUID) -> [String] {
        lock.lock()
        loadIfNeeded()
        if let lines = logs[id] {
            lock.unlock()
            return lines
        }
        let known = records.contains { $0.id == id }
        lock.unlock()
        guard known else { return [] }
        let lines = store.loadLog(for: id)
        lock.lock()
        // Keep the read copy only for finished builds, and only a few of them.
        if logs[id] == nil, records.first(where: { $0.id == id })?.status.isFinished == true {
            let cachedFinished = logs.keys.filter { key in tasks[key] == nil && key != id }
            if cachedFinished.count >= 8, let drop = cachedFinished.first { logs[drop] = nil }
            logs[id] = lines
        }
        lock.unlock()
        return lines
    }

    public var runningCount: Int {
        allRecords().filter { $0.status == .running }.count
    }

    // MARK: - Observing

    /// Calls `handler` on every change until the token is passed to `removeObserver`.
    @discardableResult
    public func addObserver(_ handler: @escaping Observer) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = handler
        lock.unlock()
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock()
        observers[token] = nil
        lock.unlock()
    }

    private func notify(_ event: BuildCenterEvent) {
        lock.lock()
        let handlers = Array(observers.values)
        lock.unlock()
        for handler in handlers { handler(event) }
    }

    // MARK: - Starting

    /// Starts a build in the background and returns its id. Lines go to the log only.
    @discardableResult
    public func start(_ options: BuildOptions, client: ContainerClient, origin: BuildOrigin, detail: String? = nil) -> UUID {
        let id = register(options, origin: origin, detail: detail)
        let task = Task.detached { [weak self] in
            guard let self else { return }
            _ = await self.run(id, options: options, client: client, sink: nil)
        }
        attach(task, to: id)
        return id
    }

    /// Starts a build and streams its lines to the caller, like `client.build`, while the
    /// build also shows on the Builds screen. Ending the stream early cancels the build.
    /// A build cancelled from the Builds screen ends the stream with `CancellationError`.
    public func track(_ options: BuildOptions, client: ContainerClient, origin: BuildOrigin, detail: String? = nil) -> AsyncThrowingStream<String, Error> {
        let id = register(options, origin: origin, detail: detail)
        return AsyncThrowingStream { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                let outcome = await self.run(id, options: options, client: client) { line in
                    continuation.yield(line)
                }
                switch outcome.status {
                case .succeeded:
                    continuation.finish()
                case .cancelled, .interrupted, .running:
                    continuation.finish(throwing: CancellationError())
                case .failed:
                    continuation.finish(throwing: outcome.error ?? DeckError.commandFailed(outcome.message ?? "The build failed."))
                }
            }
            self.attach(task, to: id)
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    /// Stops a running build. The build process is ended, BuildKit stops the work.
    public func cancel(_ id: UUID) {
        lock.lock()
        let task = tasks[id]
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Removing

    /// Removes finished builds and their logs. Running builds stay.
    public func remove(_ ids: [UUID]) {
        lock.lock()
        loadIfNeeded()
        let removable = Set(records.filter { ids.contains($0.id) && $0.status.isFinished }.map(\.id))
        records.removeAll { removable.contains($0.id) }
        for id in removable { logs[id] = nil }
        let snapshot = snapshotLocked()
        lock.unlock()
        guard !removable.isEmpty else { return }
        for id in removable { store.deleteLog(for: id) }
        persist(snapshot)
        notify(.removed(Array(removable)))
    }

    /// Removes every finished build.
    public func clearFinished() {
        remove(allRecords().filter { $0.status.isFinished }.map(\.id))
    }

    /// Applies the history limit now (after the setting changed).
    public func applyHistoryLimit() {
        lock.lock()
        loadIfNeeded()
        let removed = trimLocked()
        let snapshot = snapshotLocked()
        lock.unlock()
        guard !removed.isEmpty else { return }
        for id in removed { store.deleteLog(for: id) }
        persist(snapshot)
        notify(.removed(removed))
    }

    // MARK: - Internals

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        records = store.load()
    }

    /// Drops the oldest finished builds over the limit. Call with the lock held.
    private func trimLocked() -> [UUID] {
        let result = BuildHistoryStore.trim(records, limit: historyLimit())
        records = result.kept
        let removed = result.removed.map(\.id)
        for id in removed { logs[id] = nil }
        return removed
    }

    private func register(_ options: BuildOptions, origin: BuildOrigin, detail: String?) -> UUID {
        let record = BuildRecord(spec: BuildSpec(options), origin: origin, originDetail: CLIText.nonEmpty(detail))
        lock.lock()
        loadIfNeeded()
        records.insert(record, at: 0)
        logs[record.id] = []
        let removed = trimLocked()
        let snapshot = snapshotLocked()
        lock.unlock()
        for id in removed { store.deleteLog(for: id) }
        persist(snapshot)
        if !removed.isEmpty { notify(.removed(removed)) }
        notify(.changed(record.id))
        return record.id
    }

    private func attach(_ task: Task<Void, Never>, to id: UUID) {
        lock.lock()
        let finished = records.first(where: { $0.id == id })?.status.isFinished ?? true
        if !finished { tasks[id] = task }
        lock.unlock()
    }

    struct Outcome {
        var status: BuildStatus
        var message: String?
        var error: Error?
    }

    private func run(_ id: UUID, options: BuildOptions, client: ContainerClient, sink: ((String) -> Void)?) async -> Outcome {
        var failure: Error?
        await ensureBuilder(client)
        do {
            try Task.checkCancellation()
            for try await line in client.build(options) {
                append(line, to: id)
                sink?(line)
            }
        } catch {
            failure = error
        }
        let cancelled = Task.isCancelled
        return finish(id, cancelled: cancelled, error: failure)
    }

    /// `container build` starts the builder when it is missing, but builds started at the
    /// same moment race: each one creates the builder and all but one fail with
    /// "container with ID buildkit not found". So builds that start together share one
    /// check, and the builder is started once before any of them runs.
    private func ensureBuilder(_ client: ContainerClient) async {
        let task = warmupTask(client)
        await task.value
        clearWarmup(task)
    }

    private func warmupTask(_ client: ContainerClient) -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        if let warmup { return warmup }
        let task = Task.detached {
            guard let status = try? await client.builderStatus(), !status.isRunning else { return }
            try? await client.startBuilder()
        }
        warmup = task
        return task
    }

    private func clearWarmup(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if warmup == task { warmup = nil }
    }

    private func append(_ raw: String, to id: UUID) {
        guard let line = Self.clean(raw) else { return }
        let step = BuildProgressParser.step(in: line)
        lock.lock()
        var lines = logs[id] ?? []
        lines.append(line)
        if lines.count > BuildsConfig.maxLogLines {
            lines.removeFirst(lines.count - BuildsConfig.maxLogLines)
        }
        logs[id] = lines
        var stepChanged = false
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].logLineCount += 1
            if let step, step.title != records[index].lastStep {
                records[index].lastStep = step.title
                records[index].stepIndex = step.index
                records[index].stepCount = step.count
                stepChanged = true
            }
        }
        lock.unlock()
        notify(.log(id))
        if stepChanged { notify(.changed(id)) }
    }

    private func finish(_ id: UUID, cancelled: Bool, error: Error?) -> Outcome {
        lock.lock()
        let lines = logs[id] ?? []
        var outcome = Outcome(status: .succeeded)
        if cancelled {
            outcome.status = .cancelled
            outcome.message = "Stopped before it finished."
        } else if let error {
            outcome.status = .failed
            outcome.error = error
            outcome.message = BuildProgressParser.failureMessage(in: lines) ?? error.localizedDescription
        }
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].status = outcome.status
            records[index].finishedAt = Date()
            records[index].message = outcome.message
        }
        tasks[id] = nil
        let snapshot = snapshotLocked()
        lock.unlock()
        try? store.saveLog(lines, for: id)
        persist(snapshot)
        notify(.changed(id))
        return outcome
    }

    private func snapshotLocked() -> (records: [BuildRecord], generation: Int) {
        generation += 1
        return (records, generation)
    }

    private func persist(_ snapshot: (records: [BuildRecord], generation: Int)) {
        saveLock.lock(); defer { saveLock.unlock() }
        guard snapshot.generation > savedGeneration else { return }
        savedGeneration = snapshot.generation
        try? store.save(snapshot.records)
    }

    /// Removes color codes and blank lines.
    static func clean(_ line: String) -> String? {
        let text = CLIText.strippingANSI(line).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

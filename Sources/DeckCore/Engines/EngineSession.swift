import Foundation

/// What a stopped engine import is doing right now. Shown on the Import screen.
public enum EngineActivity: Sendable, Equatable {
    case checkingSpace
    case starting(String)
    case waiting(String)
    case listing(String)
    case pulling(index: Int, total: Int)
    case exporting(index: Int, total: Int)
    case stopping(String)

    public var title: String {
        switch self {
        case .checkingSpace: return "Checking free space"
        case .starting(let name): return "Starting \(name)"
        case .waiting(let name): return "Waiting for \(name)"
        case .listing: return "Listing images"
        case .pulling(let index, let total): return "Pulling \(index) of \(total)"
        case .exporting(let index, let total): return "Exporting \(index) of \(total)"
        case .stopping(let name): return "Stopping \(name)"
        }
    }
}

/// How the stop went.
public struct EngineStopResult: Sendable, Equatable {
    /// The engine no longer answers.
    public var stopped: Bool
    /// Something we could not undo, for people to read.
    public var warning: String?

    public init(stopped: Bool, warning: String? = nil) {
        self.stopped = stopped
        self.warning = warning
    }
}

/// Starts an engine only when it is not running, and stops it again only when we started it.
///
/// `probe` returns the running engines of the plan's family (empty when it is stopped).
/// `finish` always runs to the end, even when the calling task was cancelled.
public actor EngineSession {
    public typealias Probe = @Sendable () async -> [DetectedEngine]
    public typealias Activity = @Sendable (EngineActivity) async -> Void

    public let plan: EngineControlPlan
    let runner: any CommandRunning
    let probe: Probe

    /// We ran the start commands, so we own the stop.
    public private(set) var startedByUs = false
    /// The engine's app was open before we started (only checked when the plan has a pattern).
    public private(set) var appWasRunning = false
    /// When we ran the start commands.
    private var startedAt: Date?

    public init(plan: EngineControlPlan, runner: any CommandRunning = CancellableRunner(), probe: @escaping Probe) {
        self.plan = plan
        self.runner = runner
        self.probe = probe
    }

    /// The running engines of this family. Starts the engine first when it is stopped.
    public func ensureRunning(activity: @escaping Activity = { _ in }) async throws -> [DetectedEngine] {
        try Task.checkCancellation()
        let current = await probe()
        if !current.isEmpty { return current }
        try Task.checkCancellation()

        if let pattern = plan.appProcessPattern {
            let result = try? await runner.run(EngineControlPlan.pgrep, ["-f", pattern])
            appWasRunning = result?.succeeded ?? false
        }

        // Set before the first command, so a cancel or failure half way still stops it.
        startedByUs = true
        startedAt = Date()
        let name = plan.name
        let deadline = Date().addingTimeInterval(plan.startTimeout)
        let runner = self.runner

        for command in plan.start {
            await activity(.starting(name))
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0,
                  let result = try await Self.withTimeout(remaining, {
                      try await runner.run(command.executable, command.arguments)
                  })
            else { throw EngineControlError.startTimedOut(name, Int(plan.startTimeout.rounded(.up))) }
            if !result.succeeded {
                throw EngineControlError.startFailed(name, Self.shortMessage(result.failureMessage))
            }
        }

        await activity(.waiting(name))
        var engines: [DetectedEngine] = []
        while true {
            try Task.checkCancellation()
            if engines.isEmpty { engines = await probe() }
            if !engines.isEmpty, await Self.isReady(plan: plan, runner: runner) { return engines }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw EngineControlError.startTimedOut(name, Int(plan.startTimeout.rounded(.up))) }
            try await Task.sleep(for: .seconds(min(plan.pollInterval, remaining)))
        }
    }

    /// True when the plan has no ready check, or the check says the start is done.
    static func isReady(plan: EngineControlPlan, runner: any CommandRunning) async -> Bool {
        guard let ready = plan.ready else { return true }
        let result = try? await withTimeout(15) {
            try await runner.run(ready.executable, ready.arguments)
        }
        guard let result, result.succeeded else { return false }
        return plan.readyMarkers.contains { result.stdout.contains($0) }
    }

    /// Stops the engine when we started it. Safe to call more than once.
    /// Returns nil when there was nothing to stop.
    @discardableResult
    public func finish(activity: @escaping Activity = { _ in }) async -> EngineStopResult? {
        guard startedByUs else { return nil }
        startedByUs = false
        await activity(.stopping(plan.name))
        let plan = self.plan
        let runner = self.runner
        let probe = self.probe
        let quitApp = !appWasRunning
        let upSince = startedAt ?? Date()
        // Detached, so a cancelled import still stops the engine.
        return await Task.detached {
            await Self.stopSequence(plan: plan, runner: runner, probe: probe, quitApp: quitApp, upSince: upSince)
        }.value
    }

    static func stopSequence(
        plan: EngineControlPlan, runner: any CommandRunning, probe: Probe, quitApp: Bool, upSince: Date = .distantPast
    ) async -> EngineStopResult {
        var warning: String?

        // A stop sent while the engine is still starting does not stick. Wait for the
        // start to end first (it may never have answered, so this has a limit).
        if plan.ready != nil {
            let limit = Date().addingTimeInterval(plan.stopTimeout)
            while Date() < limit, !(await isReady(plan: plan, runner: runner)) {
                try? await Task.sleep(for: .seconds(plan.pollInterval))
            }
        }

        // Undo setting changes first. The engine API must answer for this, so try a few times.
        for command in plan.beforeStop {
            var done = false
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(plan.pollInterval)) }
                let result = try? await withTimeout(30) {
                    try await runner.run(command.executable, command.arguments)
                }
                if result?.succeeded == true {
                    done = true
                    break
                }
            }
            if !done {
                warning = "\(plan.name) may now open in the background. Change it in its settings."
            }
        }

        // Is it still up? Ask the engine's own status command when there is one.
        @Sendable func isUp() async -> Bool {
            if let status = plan.status {
                do {
                    let result = try await withTimeout(15) {
                        try await runner.run(status.executable, status.arguments)
                    }
                    // No answer in time: treat it as still up.
                    return result?.succeeded ?? true
                } catch {
                    // The status command could not run. Fall back to the probe.
                }
            }
            return !(await probe().isEmpty)
        }

        var stopped = false
        var since = upSince
        for _ in 0..<3 where !stopped {
            // Let it finish starting, or it may take the stop for a crash and come back.
            let young = plan.minimumUptime - Date().timeIntervalSince(since)
            if young > 0 { try? await Task.sleep(for: .seconds(young)) }

            for command in plan.stop {
                _ = try? await withTimeout(plan.stopTimeout) {
                    try await runner.run(command.executable, command.arguments)
                }
            }
            let deadline = Date().addingTimeInterval(plan.stopTimeout)
            repeat {
                if !(await isUp()) {
                    stopped = true
                    break
                }
                try? await Task.sleep(for: .seconds(plan.pollInterval))
            } while Date() < deadline
            guard stopped else { continue }

            // Quit the app we woke up, only once the engine is down.
            if quitApp, let pattern = plan.appProcessPattern {
                _ = try? await runner.run(EngineControlPlan.pkill, ["-f", pattern])
            }
            // Some engines bounce back right after a stop. Check again after a moment.
            try? await Task.sleep(for: .seconds(plan.settleTime))
            if await isUp() {
                stopped = false
                since = Date()
            }
        }

        if !stopped {
            warning = "\(plan.name) is still running. Stop it yourself."
        }
        return EngineStopResult(stopped: stopped, warning: warning)
    }

    /// Runs `operation`, or returns nil after `seconds`. The operation is cancelled on timeout.
    public static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: Optional<T>.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, seconds)))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return nil }
            return first
        }
    }

    static func shortMessage(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        return String(line.trimmingCharacters(in: .whitespaces).prefix(240))
    }
}

/// Lists and imports images from an engine that is stopped, by starting it in the
/// background just for the job and stopping it again after.
public struct StoppedEngineWorkflow: Sendable {
    public let plan: EngineControlPlan
    let runner: any CommandRunning
    let probe: EngineSession.Probe

    public init(plan: EngineControlPlan, runner: any CommandRunning = CancellableRunner(), probe: EngineSession.Probe? = nil) {
        self.plan = plan
        self.runner = runner
        self.probe = probe ?? Self.liveProbe(for: plan.family)
    }

    /// Running engines of one family, found with EngineDetector.
    public static func liveProbe(for family: EngineFamily) -> EngineSession.Probe {
        { await EngineDetector().detect().filter { $0.isRunning && family.matches($0) } }
    }

    // MARK: List

    public struct Listing: Sendable {
        /// The running engines the images came from. Their ids match `EngineImage.engineID`.
        public var engines: [DetectedEngine]
        public var images: [EngineImage]
        public var stop: EngineStopResult?
        /// The engine was already running, so we left it alone.
        public var wasRunning: Bool
    }

    /// Starts the engine if needed, lists its images, then stops it if we started it.
    public func listImages(
        activity: @escaping EngineSession.Activity = { _ in },
        list: @escaping @Sendable ([DetectedEngine]) async throws -> [EngineImage]
    ) async throws -> Listing {
        let session = EngineSession(plan: plan, runner: runner, probe: probe)
        do {
            let engines = try await session.ensureRunning(activity: activity)
            let started = await session.startedByUs
            await activity(.listing(plan.name))
            let images = try await list(engines)
            let stop = await session.finish(activity: activity)
            return Listing(engines: engines, images: images, stop: stop, wasRunning: !started)
        } catch {
            await session.finish(activity: activity)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // MARK: Import

    public struct Outcome: Sendable {
        /// Image id to a short line on how it moved.
        public var moved: [String: String] = [:]
        /// Image id to the error.
        public var failed: [String: String] = [:]
        public var cancelled = false
        public var stop: EngineStopResult?
        /// We started the engine for this import.
        public var startedEngine = false
    }

    /// Pulls registry images without the engine. Starts the engine only for the rest,
    /// exports them one by one, then stops the engine if we started it.
    /// Throws only when the disk space check fails, before anything starts.
    public func importImages(
        _ images: [EngineImage],
        neededBytes: UInt64,
        freeBytes: UInt64?,
        activity: @escaping EngineSession.Activity = { _ in },
        step: @escaping @Sendable (String, ImportStep) async -> Void = { _, _ in },
        pull: @escaping @Sendable (EngineImage) async throws -> Void,
        export: @escaping @Sendable (EngineImage, DetectedEngine) async throws -> Void
    ) async throws -> Outcome {
        await activity(.checkingSpace)
        try DiskSpaceCheck.verify(needed: neededBytes, free: freeBytes)

        var outcome = Outcome()
        var needEngine: [EngineImage] = []

        let pullable = images.filter(\.canPullFromRegistry)
        for (index, image) in pullable.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            await activity(.pulling(index: index + 1, total: pullable.count))
            do {
                try await pull(image)
                outcome.moved[image.id] = "Pulled from the registry"
                await step(image.id, .done(method: "Pulled from the registry"))
            } catch {
                if Self.isCancel(error) {
                    outcome.cancelled = true
                    break
                }
                // Offline or needs a login. Copy it from the engine instead.
                needEngine.append(image)
            }
        }
        if !outcome.cancelled {
            needEngine.append(contentsOf: images.filter { !$0.canPullFromRegistry })
        }

        if !needEngine.isEmpty && !outcome.cancelled {
            let session = EngineSession(plan: plan, runner: runner, probe: probe)
            do {
                let engines = try await session.ensureRunning(activity: activity)
                outcome.startedEngine = await session.startedByUs
                for (index, image) in needEngine.enumerated() {
                    try Task.checkCancellation()
                    await activity(.exporting(index: index + 1, total: needEngine.count))
                    let engine = engines.first(where: { $0.id == image.engineID }) ?? engines[0]
                    do {
                        try await export(image, engine)
                        let method = "Copied from \(plan.name)"
                        outcome.moved[image.id] = method
                        await step(image.id, .done(method: method))
                    } catch {
                        if Self.isCancel(error) { throw CancellationError() }
                        outcome.failed[image.id] = error.localizedDescription
                        await step(image.id, .failed(error.localizedDescription))
                    }
                }
            } catch {
                if Self.isCancel(error) {
                    outcome.cancelled = true
                } else {
                    // The engine did not start. Every image that needed it fails with that reason.
                    for image in needEngine where outcome.moved[image.id] == nil && outcome.failed[image.id] == nil {
                        outcome.failed[image.id] = error.localizedDescription
                        await step(image.id, .failed(error.localizedDescription))
                    }
                }
            }
            outcome.stop = await session.finish(activity: activity)
        }

        if outcome.cancelled {
            for image in images where outcome.moved[image.id] == nil && outcome.failed[image.id] == nil {
                await step(image.id, .cancelled)
            }
        }
        return outcome
    }

    static func isCancel(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }
}

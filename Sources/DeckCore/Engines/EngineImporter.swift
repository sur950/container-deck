import Foundation

/// Moves one image from another engine into Apple's container.
///
/// 1. Pull again from the registry when the image came from one (fast, keeps all platforms).
/// 2. Otherwise export it (Docker API, nerdctl save or podman save), make sure it is
///    an OCI layout tarball, and load it with `container image load`.
public struct EngineImporter: Sendable {
    public static let tar = "/usr/bin/tar"

    let client: ContainerClient
    let runner: any CommandRunning
    let workRoot: URL

    public init(client: ContainerClient, runner: any CommandRunning = CancellableRunner(), workRoot: URL = FileManager.default.temporaryDirectory) {
        self.client = client
        self.runner = runner
        self.workRoot = workRoot
    }

    // MARK: - Disk space

    /// About twice the image size: one copy for the export, one for the store.
    public static func requiredBytes(for images: [EngineImage]) -> UInt64 {
        images.reduce(UInt64(0)) { $0 + $1.sizeBytes } * 2
    }

    public static func availableBytes(at url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return UInt64(max(0, capacity))
    }

    /// Free bytes in the temp folder exports go to. nil when unknown.
    public var freeBytes: UInt64? { Self.availableBytes(at: workRoot) }

    public func checkDiskSpace(for images: [EngineImage]) throws {
        try DiskSpaceCheck.verify(needed: Self.requiredBytes(for: images), free: freeBytes)
    }

    // MARK: - Import

    /// Returns a short line that says how the image moved.
    @discardableResult
    public func importImage(
        _ image: EngineImage,
        from engine: DetectedEngine,
        progress: @escaping @Sendable (ImportStep) async -> Void
    ) async throws -> String {
        if image.canPullFromRegistry {
            do {
                try await pull(image, progress: progress)
                return "Pulled from the registry"
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // The registry may be offline or need a login. Copy it instead.
            }
        }
        try await exportAndLoad(image, from: engine, progress: progress)
        return "Copied from \(engine.name)"
    }

    /// Pulls the image again from its registry. No engine needed.
    public func pullFromRegistry(_ image: EngineImage, progress: @escaping @Sendable (ImportStep) async -> Void) async throws {
        try await pull(image, progress: progress)
    }

    /// Exports the image from a running engine and loads it. Never pulls.
    public func copy(_ image: EngineImage, from engine: DetectedEngine, progress: @escaping @Sendable (ImportStep) async -> Void) async throws {
        try await exportAndLoad(image, from: engine, progress: progress)
    }

    func pull(_ image: EngineImage, progress: @escaping @Sendable (ImportStep) async -> Void) async throws {
        await progress(.pulling("Starting"))
        for try await line in client.pullImage(image.normalizedReference) {
            try Task.checkCancellation()
            await progress(.pulling(line))
        }
        try Task.checkCancellation()
    }

    func exportAndLoad(_ image: EngineImage, from engine: DetectedEngine, progress: @escaping @Sendable (ImportStep) async -> Void) async throws {
        guard let endpoint = engine.endpoint, engine.isRunning else {
            throw DeckError.commandFailed("\(engine.name) is not running. Start it and try again.")
        }
        let fm = FileManager.default
        let work = workRoot.appendingPathComponent("ContainerDeck-Import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent("image.tar")
        await progress(.exporting(done: 0, total: image.sizeBytes))
        try await export(image, endpoint: endpoint, engine: engine, to: archive, progress: progress)
        try Task.checkCancellation()

        await progress(.converting)
        let loadable = try await prepare(archive, in: work, reference: image.reference)
        try Task.checkCancellation()

        await progress(.loading)
        try await client.loadImage(from: loadable)
    }

    func export(
        _ image: EngineImage, endpoint: EngineEndpoint, engine: DetectedEngine, to file: URL,
        progress: @escaping @Sendable (ImportStep) async -> Void
    ) async throws {
        let total = image.sizeBytes
        let reference = image.reference
        let runner = self.runner
        switch endpoint {
        case .dockerSocket(let socket):
            if engine.kind == .podman, let podman = engine.podmanBinary {
                var args: [String] = []
                if let connection = engine.podmanConnection { args += ["--connection", connection] }
                args += ["save", "--format", "oci-archive", "--output", file.path, reference]
                let podmanArgs = args
                do {
                    try await Self.withFileProgress(file, total: total, progress: progress) {
                        _ = try await runner.run(podman, podmanArgs).orThrow()
                    }
                    if Self.fileSize(file) > 0 { return }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                }
                // podman save did not work. Use the Docker API on the same socket.
                try? FileManager.default.removeItem(at: file)
            }
            let api = DockerAPI(socketPath: socket, runner: runner)
            try await Self.withFileProgress(file, total: total, progress: progress) {
                try await api.export(reference, to: file)
            }
        case .nerdctl(let binary, let namespace):
            let args = NerdctlEngine.saveArguments(namespace: namespace, reference: reference, to: file.path)
            try await Self.withFileProgress(file, total: total, progress: progress) {
                _ = try await runner.run(binary, args).orThrow()
            }
        }
        guard Self.fileSize(file) > 0 else {
            throw DeckError.commandFailed("\(engine.name) did not export \(reference).")
        }
    }

    /// Extracts the archive and returns an OCI layout tarball ready to load.
    func prepare(_ archive: URL, in work: URL, reference: String) async throws -> URL {
        let fm = FileManager.default
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await runner.run(Self.tar, ["-xf", archive.path, "-C", extracted.path]).orThrow()
        try? fm.removeItem(at: archive)

        let layout: URL
        switch OCIArchive.kind(ofExtracted: extracted) {
        case .ociLayout:
            try OCIArchive.normalizeOCILayout(at: extracted, reference: reference)
            layout = extracted
        case .dockerArchive:
            layout = work.appendingPathComponent("oci", isDirectory: true)
            try OCIArchive.convertDockerArchive(at: extracted, to: layout, fallbackReference: reference)
        case .unknown:
            throw DeckError.commandFailed("The exported file for \(reference) is not an image archive.")
        }
        try Task.checkCancellation()

        // Pack only the OCI files so the loader sees no extra or linked entries.
        let output = work.appendingPathComponent("oci-image.tar")
        try await runner.run("/usr/bin/env", Self.packArguments(layout: layout.path, output: output.path)).orThrow()
        try? fm.removeItem(at: extracted)
        if layout != extracted { try? fm.removeItem(at: layout) }
        return output
    }

    /// COPYFILE_DISABLE stops macOS tar from adding ._ files.
    public static func packArguments(layout: String, output: String) -> [String] {
        ["COPYFILE_DISABLE=1", tar, "-cf", output, "-C", layout, "oci-layout", "index.json", "blobs"]
    }

    static func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Runs `work` and reports the growing file size every half second.
    static func withFileProgress(
        _ file: URL, total: UInt64,
        progress: @escaping @Sendable (ImportStep) async -> Void,
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await work()
                return true
            }
            group.addTask {
                while !Task.isCancelled {
                    await progress(.exporting(done: EngineImporter.fileSize(file), total: total))
                    try await Task.sleep(for: .milliseconds(500))
                }
                return false
            }
            while let finished = try await group.next() {
                if finished {
                    group.cancelAll()
                    break
                }
            }
        }
    }
}

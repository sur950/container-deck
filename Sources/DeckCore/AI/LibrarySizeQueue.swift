import Foundation

/// A download size found for a Browse row, with what it is the size of ("latest", "MLX 4bit").
public struct LibrarySize: Codable, Sendable, Equatable {
    public var bytes: UInt64
    public var label: String?

    public init(bytes: UInt64, label: String? = nil) {
        self.bytes = bytes
        self.label = label
    }
}

/// Looks up Browse row sizes a few at a time, for the rows on screen.
/// - At most `maxConcurrent` lookups run at once. The rest wait in order.
/// - A row that scrolls away before its turn is taken off the queue (`withdraw`).
/// - Found sizes are saved in the library cache, so the next look is free.
/// - `cancelAll` drops the queue and stops running lookups (a new search or filter).
public actor LibrarySizeQueue {
    public typealias Lookup = @Sendable (String) async -> LibrarySize?
    /// Called with each answer. nil means the size could not be found.
    public typealias Report = @Sendable (String, LibrarySize?) async -> Void

    let maxConcurrent: Int
    let cache: LibraryCache?
    let lifetime: TimeInterval
    let lookup: Lookup
    private var report: Report?
    private var pending: [String] = []
    private var running: [String: Task<Void, Never>] = [:]
    private var answered: Set<String> = []
    private var generation = 0

    /// Lookups started (each may make a few HTTP requests).
    public private(set) var lookupsStarted = 0
    /// Answers that came from the cache.
    public private(set) var cacheHits = 0
    /// Most lookups that ran at the same time.
    public private(set) var peakRunning = 0

    public init(maxConcurrent: Int = 4, cache: LibraryCache?, lifetime: TimeInterval = OllamaLibraryClient.cacheLifetime,
                lookup: @escaping Lookup, report: Report? = nil) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.cache = cache
        self.lifetime = lifetime
        self.lookup = lookup
        self.report = report
    }

    public func setReport(_ report: @escaping Report) {
        self.report = report
    }

    static func cacheKey(_ key: String) -> String { "size-" + key }

    /// Asks for a size. Answers at once from the cache, else queues the lookup.
    public func request(_ key: String) {
        guard !answered.contains(key), running[key] == nil, !pending.contains(key) else { return }
        if let saved = cache?.read(Self.cacheKey(key), as: LibrarySize.self), saved.age < lifetime {
            answered.insert(key)
            cacheHits += 1
            let report = self.report
            Task { await report?(key, saved.value) }
            return
        }
        pending.append(key)
        pump()
    }

    /// Takes a key off the queue when it has not started yet (the row scrolled away).
    public func withdraw(_ key: String) {
        pending.removeAll { $0 == key }
    }

    /// Drops the queue and stops running lookups. Later answers from them are ignored.
    public func cancelAll() {
        generation += 1
        pending = []
        for task in running.values { task.cancel() }
        running = [:]
        answered = []
    }

    public var isIdle: Bool { pending.isEmpty && running.isEmpty }
    public func isRunning(_ key: String) -> Bool { running[key] != nil }
    public var waiting: Int { pending.count }

    /// For tests: waits until nothing is queued or running.
    public func waitUntilIdle(timeout: TimeInterval = 10) async {
        let end = Date().addingTimeInterval(timeout)
        while !isIdle && Date() < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func pump() {
        while running.count < maxConcurrent, !pending.isEmpty {
            let key = pending.removeFirst()
            lookupsStarted += 1
            let lookup = self.lookup
            let generation = self.generation
            running[key] = Task { [weak self] in
                let result = await lookup(key)
                await self?.finish(key, result, generation: generation)
            }
            peakRunning = max(peakRunning, running.count)
        }
    }

    private func finish(_ key: String, _ result: LibrarySize?, generation: Int) async {
        guard generation == self.generation else { return }
        running[key] = nil
        answered.insert(key)
        if let result { cache?.write(Self.cacheKey(key), result) }
        let report = self.report
        pump()
        await report?(key, result)
    }
}

/// Counts HTTP requests, so the app can log how many the size lookups make.
public final class CountingHTTPFetcher: AIHTTPFetching, @unchecked Sendable {
    let base: AIHTTPFetching
    private let lock = NSLock()
    private var total = 0

    public init(base: AIHTTPFetching = AIHTTPClient()) {
        self.base = base
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock(); total += 1; lock.unlock()
        return try await base.send(request)
    }
}

public extension OllamaLibraryClient {
    /// Size of a model's default tag: the registry manifest for "latest" (one small request),
    /// else the tags page.
    func defaultSize(_ name: String) async -> LibrarySize? {
        if let bytes = await registrySize(name, tag: "latest") { return LibrarySize(bytes: bytes, label: "latest") }
        guard let tags = try? await tags(name) else { return nil }
        let pick = tags.first { $0.tag == "latest" && $0.sizeBytes != nil } ?? tags.first { $0.sizeBytes != nil }
        return pick.flatMap { tag in tag.sizeBytes.map { LibrarySize(bytes: $0, label: tag.tag) } }
    }
}

public extension LMStudioCatalogClient {
    /// The smallest download option of a model: its model page, then the file lists of up to
    /// four of its Hugging Face repos. MLX repos count all their files, GGUF repos their smallest file.
    func smallestDownload(_ identifier: String, hub: HuggingFaceClient) async -> LibrarySize? {
        guard let detail = try? await detail(identifier) else { return nil }
        let variants = detail.variants.filter { $0.repo != nil }.prefix(4)
        let sizes: [LibrarySize] = await withTaskGroup(of: LibrarySize?.self) { group in
            for variant in variants {
                group.addTask {
                    guard let repo = variant.repo, let files = try? await hub.allFiles(repo) else { return nil }
                    return LMStudioCatalogParser.optionSize(variant, files: files)
                }
            }
            var found: [LibrarySize] = []
            for await size in group { if let size { found.append(size) } }
            return found
        }
        return sizes.min { $0.bytes < $1.bytes }
    }
}

public extension LMStudioCatalogParser {
    /// Size of one download option from its repo's files: the smallest GGUF file, or the MLX files together.
    static func optionSize(_ variant: LMStudioVariant, files: [HFFile]) -> LibrarySize? {
        let gguf = files.filter { $0.path.lowercased().hasSuffix(".gguf") && !$0.path.lowercased().contains("mmproj") && $0.size > 0 }
        if let smallest = gguf.min(by: { $0.size < $1.size }) {
            let quant = HTMLText.first(#"((?:I?Q[0-9]+(?:_[0-9A-Z]+)*)|F16|BF16)\.gguf$"#, in: smallest.path, options: [.caseInsensitive])
            return LibrarySize(bytes: smallest.size, label: ["GGUF", quant?.uppercased()].compactMap { $0 }.joined(separator: " "))
        }
        let total = files.filter { HuggingFaceClient.isNeeded($0.path) }.reduce(0) { $0 + $1.size }
        guard total > 0 else { return nil }
        return LibrarySize(bytes: total, label: ["MLX", variant.quantization].compactMap { $0 }.joined(separator: " "))
    }
}

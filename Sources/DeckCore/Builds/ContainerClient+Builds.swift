import Foundation

// MARK: - Models

/// The BuildKit builder container (`container builder status`).
public struct BuilderStatus: Sendable, Hashable {
    public enum State: String, Sendable {
        /// No builder yet. The first build starts one.
        case notCreated
        case running, stopped, stopping, unknown
    }

    public var state: State
    public var id: String
    public var image: String?
    public var cpus: Int?
    public var memoryBytes: UInt64?
    public var address: String?
    public var startedAt: Date?
    public var rosetta: Bool?

    public init(state: State, id: String = BuildsConfig.builderContainerID, image: String? = nil, cpus: Int? = nil,
                memoryBytes: UInt64? = nil, address: String? = nil, startedAt: Date? = nil, rosetta: Bool? = nil) {
        self.state = state
        self.id = id
        self.image = image
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.address = address
        self.startedAt = startedAt
        self.rosetta = rosetta
    }

    public var isRunning: Bool { state == .running }

    /// "builder-shim:0.13.2" from the full image name.
    public var shortImage: String? {
        guard let image else { return nil }
        return image.split(separator: "/").last.map(String.init) ?? image
    }
}

/// BuildKit cache use (`buildctl du`).
public struct BuildCacheUsage: Sendable, Hashable {
    public var totalBytes: UInt64
    public var reclaimableBytes: UInt64
    public var entries: Int
    public var inUseEntries: Int
    public var lastUsedAt: Date?

    public init(totalBytes: UInt64 = 0, reclaimableBytes: UInt64 = 0, entries: Int = 0, inUseEntries: Int = 0, lastUsedAt: Date? = nil) {
        self.totalBytes = totalBytes
        self.reclaimableBytes = reclaimableBytes
        self.entries = entries
        self.inUseEntries = inUseEntries
        self.lastUsedAt = lastUsedAt
    }
}

// MARK: - Parsing

public enum BuildsOutputParser {
    /// `container builder status --format json`. `[]` means no builder.
    /// Reads 1.6 (status is an object with `state`) and older shapes (status is a string).
    public static func builderStatus(_ json: String) throws -> BuilderStatus {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return BuilderStatus(state: .notCreated) }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw DeckError.parse("Could not read the builder status.")
        }
        let entry: [String: Any]?
        if let array = object as? [[String: Any]] {
            entry = array.first
        } else {
            entry = object as? [String: Any]
        }
        guard let entry else { return BuilderStatus(state: .notCreated) }

        let config = entry["configuration"] as? [String: Any] ?? [:]
        var stateText: String?
        var networks: [[String: Any]] = entry["networks"] as? [[String: Any]] ?? []
        var started: Date?
        if let status = entry["status"] as? [String: Any] {
            stateText = status["state"] as? String
            networks = status["networks"] as? [[String: Any]] ?? networks
            started = (status["startedDate"] as? String).flatMap(DeckDate.parse)
        } else {
            stateText = entry["status"] as? String
        }
        let image = (config["image"] as? [String: Any])?["reference"] as? String
        let resources = config["resources"] as? [String: Any] ?? [:]
        let address = networks.compactMap { ($0["ipv4Address"] as? String) ?? ($0["address"] as? String) }.first
            .map { $0.split(separator: "/").first.map(String.init) ?? $0 }
        return BuilderStatus(
            state: BuilderStatus.State(rawValue: stateText?.lowercased() ?? "") ?? .unknown,
            id: (entry["id"] as? String) ?? (config["id"] as? String) ?? BuildsConfig.builderContainerID,
            image: image,
            cpus: (resources["cpus"] as? NSNumber)?.intValue,
            memoryBytes: (resources["memoryInBytes"] as? NSNumber)?.uint64Value,
            address: address,
            startedAt: started,
            rosetta: config["rosetta"] as? Bool
        )
    }

    /// `buildctl du --format '{{json .}}'`: one JSON array of cache records.
    public static func cacheUsage(_ json: String) throws -> BuildCacheUsage {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return BuildCacheUsage() }
        guard let data = trimmed.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DeckError.parse("Could not read the build cache size.")
        }
        var usage = BuildCacheUsage()
        for record in array {
            let size = (record["size"] as? NSNumber)?.int64Value ?? 0
            let bytes = UInt64(max(0, size))
            let inUse = record["inUse"] as? Bool ?? false
            // Shared records are counted once by BuildKit as well.
            usage.totalBytes += bytes
            if inUse {
                usage.inUseEntries += 1
            } else {
                usage.reclaimableBytes += bytes
            }
            usage.entries += 1
            if let used = (record["lastUsedAt"] as? String).flatMap(DeckDate.parse) {
                usage.lastUsedAt = max(usage.lastUsedAt ?? used, used)
            }
        }
        return usage
    }
}

// MARK: - Calls

public extension ContainerClient {
    /// Like `build(_:)`, but the build also shows on the Builds screen with its log,
    /// can be cancelled there and is kept in the history.
    /// Compose calls this: `client.trackedBuild(build, origin: .compose, detail: service)`.
    func trackedBuild(_ options: BuildOptions, origin: BuildOrigin = .other, detail: String? = nil,
                      center: BuildCenter = .shared) -> AsyncThrowingStream<String, Error> {
        center.track(options, client: self, origin: origin, detail: detail)
    }

    func builderStatusArguments() -> [String] { ["builder", "status", "--format", "json"] }

    func builderStatus() async throws -> BuilderStatus {
        let result = try await run(builderStatusArguments())
        return try BuildsOutputParser.builderStatus(result.stdout)
    }

    /// `container builder start`. nil keeps the defaults from the system settings.
    func builderStartArguments(cpus: Int? = nil, memory: String? = nil) -> [String] {
        var args = ["builder", "start"]
        if let cpus, cpus > 0 { args += ["--cpus", String(cpus)] }
        if let memory = CLIText.nonEmpty(memory) { args += ["--memory", memory] }
        return args
    }

    func startBuilder(cpus: Int? = nil, memory: String? = nil) async throws {
        try await run(builderStartArguments(cpus: cpus, memory: memory))
    }

    func stopBuilder() async throws {
        try await run(["builder", "stop"])
    }

    func builderCacheArguments(builderID: String = BuildsConfig.builderContainerID) -> [String] {
        ["exec", builderID, "buildctl", "du", "--format", "{{json .}}"]
    }

    /// Cache size, read with `buildctl` inside the running builder.
    func builderCacheUsage(builderID: String = BuildsConfig.builderContainerID) async throws -> BuildCacheUsage {
        let result = try await run(builderCacheArguments(builderID: builderID))
        return try BuildsOutputParser.cacheUsage(result.stdout)
    }

    /// `all` also removes internal and frontend records.
    func pruneCacheArguments(all: Bool = false, builderID: String = BuildsConfig.builderContainerID) -> [String] {
        var args = ["exec", builderID, "buildctl", "prune"]
        if all { args.append("--all") }
        return args
    }

    func pruneBuilderCache(all: Bool = false, builderID: String = BuildsConfig.builderContainerID) async throws {
        try await run(pruneCacheArguments(all: all, builderID: builderID))
    }
}

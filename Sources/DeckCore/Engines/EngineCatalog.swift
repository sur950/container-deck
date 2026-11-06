import Foundation

/// nerdctl commands for Rancher Desktop in containerd mode.
public enum NerdctlEngine {
    public static func imagesArguments(namespace: String) -> [String] {
        ["--namespace", namespace, "images", "--format", "{{json .}}"]
    }

    public static func saveArguments(namespace: String, reference: String, to file: String) -> [String] {
        ["--namespace", namespace, "save", "--output", file, reference]
    }

    public struct Image: Sendable, Equatable {
        public var reference: String
        public var id: String
        public var digest: String
        public var sizeBytes: UInt64
        public var platform: String?
        public var createdAt: Date?
    }

    /// nerdctl prints one JSON object per line.
    public static func parseImages(_ text: String) -> [Image] {
        struct Line: Decodable {
            var Repository: String?
            var Tag: String?
            var ID: String?
            var Digest: String?
            var Size: String?
            var Platform: String?
            var CreatedAt: String?
        }
        var images: [Image] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"), let item = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)) else { continue }
            let repo = item.Repository ?? ""
            let tag = item.Tag ?? ""
            guard !repo.isEmpty, !ImageReference.isUntagged(repo), !ImageReference.isUntagged(tag) else { continue }
            // Skip digest only entries like "repo@sha256:..." that containerd keeps.
            if repo.contains("@") || tag.hasPrefix("sha256") { continue }
            images.append(Image(
                reference: tag.isEmpty ? repo : "\(repo):\(tag)",
                id: item.ID ?? item.Digest ?? "",
                digest: item.Digest ?? "",
                sizeBytes: DockerAPIParser.parseSize(item.Size ?? ""),
                platform: (item.Platform ?? "").isEmpty ? nil : item.Platform,
                createdAt: parseCreated(item.CreatedAt)
            ))
        }
        return images
    }

    /// "2024-05-01 10:20:30 +0000 UTC" style dates.
    static func parseCreated(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Keep "date time offset" and drop a trailing zone name like "UTC".
        let parts = raw.split(separator: " ").map(String.init)
        if parts.count >= 3 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            if let date = formatter.date(from: parts[0...2].joined(separator: " ")) { return date }
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

/// Lists images inside other engines.
public struct EngineCatalog: Sendable {
    let runner: any CommandRunning

    public init(runner: any CommandRunning = CancellableRunner()) {
        self.runner = runner
    }

    public func images(in engine: DetectedEngine) async throws -> [EngineImage] {
        guard engine.isRunning, let endpoint = engine.endpoint else { return [] }
        switch endpoint {
        case .dockerSocket(let socket):
            return try await dockerImages(engine: engine, socket: socket)
        case .nerdctl(let binary, let namespace):
            let result = try await runner.run(binary, NerdctlEngine.imagesArguments(namespace: namespace)).orThrow()
            return NerdctlEngine.parseImages(result.stdout).map { item in
                let parts = (item.platform ?? "").split(separator: "/").map(String.init)
                return EngineImage(
                    engineID: engine.id, engineName: engine.name, imageID: item.id, reference: item.reference,
                    // containerd keeps the registry digest for pulled images. We try a pull and fall back to save.
                    repoDigests: item.digest.isEmpty ? [] : ["\(item.reference)@\(item.digest)"],
                    sizeBytes: item.sizeBytes,
                    architecture: parts.count > 1 ? parts[1] : nil,
                    os: parts.first,
                    createdAt: item.createdAt
                )
            }
        }
    }

    func dockerImages(engine: DetectedEngine, socket: String) async throws -> [EngineImage] {
        let api = DockerAPI(socketPath: socket, runner: runner)
        let entries = try await api.images()

        // /images/json has no architecture, so inspect each image (a few at a time).
        let ids = Array(Set(entries.filter { !$0.repoTags.isEmpty }.map(\.id)))
        var details: [String: DockerImageInspect] = [:]
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + 8, ids.count)])
            start += 8
            let found: [(String, DockerImageInspect)] = await withTaskGroup(
                of: (String, DockerImageInspect)?.self,
                returning: [(String, DockerImageInspect)].self
            ) { group in
                for id in batch {
                    group.addTask {
                        guard let detail = try? await api.inspectImage(id) else { return nil }
                        return (id, detail)
                    }
                }
                var collected: [(String, DockerImageInspect)] = []
                for await item in group {
                    if let item { collected.append(item) }
                }
                return collected
            }
            for (id, detail) in found { details[id] = detail }
        }

        return Self.images(from: entries, details: details, engine: engine)
    }

    /// One EngineImage per tag. Pure, tested.
    public static func images(from entries: [DockerImageEntry], details: [String: DockerImageInspect], engine: DetectedEngine) -> [EngineImage] {
        var result: [EngineImage] = []
        for entry in entries {
            let detail = details[entry.id]
            for tag in entry.repoTags {
                result.append(EngineImage(
                    engineID: engine.id, engineName: engine.name, imageID: entry.id, reference: tag,
                    repoDigests: entry.repoDigests, sizeBytes: entry.size,
                    architecture: detail?.architecture, os: detail?.os, createdAt: entry.created
                ))
            }
        }
        return result
    }

    /// Shows each image once across engines and marks the ones already in
    /// Apple's container. Pass lists in engine order. The first engine wins.
    public static func merge(_ lists: [[EngineImage]], localReferences: [String]) -> [EngineImage] {
        let local = Set(localReferences.map { ImageReference.normalize($0) })
        var order: [String] = []
        var byKey: [String: EngineImage] = [:]
        for list in lists {
            for image in list {
                let key = image.normalizedReference
                if var existing = byKey[key] {
                    if existing.engineID != image.engineID && !existing.alsoIn.contains(image.engineName) {
                        existing.alsoIn.append(image.engineName)
                        byKey[key] = existing
                    }
                    continue
                }
                var copy = image
                copy.alreadyHere = local.contains(key)
                byKey[key] = copy
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

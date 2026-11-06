import Foundation

// Images over the direct API. The images service only lists references and
// index digests. Like `container image list`, the rest (platforms, sizes,
// configs) comes from the content store: `contentGet` returns the path of a
// blob, which we read. Blobs are content addressed, so they are cached.

/// One entry of `imageList`: `ImageDescription` {reference, descriptor}.
struct APIImageDescription: Sendable {
    var reference: String
    var digest: String
    /// The descriptor object as JSON, passed through unchanged.
    var descriptorJSON: Data
    var nameAnnotation: String?
}

extension DirectAPIClient {
    // MARK: Public operations

    /// `container image list`: builder and init images hidden, sorted by reference.
    public func listImages() async throws -> [ImageSummary] {
        let descriptions = try await imageDescriptions()
            .filter { !settings.isInfraImage($0.reference) }
            .sorted { $0.reference < $1.reference }
        var resources: [Any] = []
        for description in descriptions {
            // An image whose index cannot be read is skipped (the CLI warns and skips too).
            if let resource = try? await imageResource(description, includeUnknownPlatforms: false) {
                resources.append(resource)
            }
        }
        let text = try APIDecode.text(resources)
        do {
            return try ContainerOutputParser.images(text)
        } catch {
            throw APIError.malformedReply("imageList")
        }
    }

    /// `container image inspect <ref>`.
    public func inspectImage(_ reference: String) async throws -> ImageDetail {
        let description = try await resolveImage(reference)
        let resource = try await imageResource(description, includeUnknownPlatforms: true)
        let text = try APIDecode.text([resource])
        do {
            return try ContainerOutputParser.imageDetail(text, preferredArchitecture: ContainerClient.hostArchitecture)
        } catch {
            throw APIError.malformedReply("image inspect")
        }
    }

    /// `container image tag <source> <target>`.
    public func tagImage(_ source: String, as target: String) async throws {
        let description = try await resolveImage(source)
        guard let normalized = APIImageReference.normalize(target, defaultDomain: settings.registryDomain()) else {
            throw APIError.needsCLI("invalid reference \(target)")
        }
        var request = XPCRequest(route: APIRoute.imageTag)
        request.set(APIKey.imageReference, description.reference)
        request.set(APIKey.imageNewReference, normalized)
        _ = try await imageService.call(request, timeout: .seconds(30))
    }

    /// `container image delete <ref>`: delete, then clean up blobs nothing uses.
    /// Builder and init images are skipped without an error, like the CLI.
    public func deleteImage(_ reference: String) async throws {
        let description = try await resolveImage(reference, allowInfra: true)
        if settings.isInfraImage(description.reference) { return }
        var request = XPCRequest(route: APIRoute.imageDelete)
        request.set(APIKey.imageReference, description.reference)
        request.set(APIKey.garbageCollect, false)
        _ = try await imageService.call(request, timeout: APITimeouts.delete)
        _ = try await imageService.call(XPCRequest(route: APIRoute.imageCleanupOrphanedBlobs), timeout: .seconds(120))
    }

    // MARK: Store reads

    func imageDescriptions() async throws -> [APIImageDescription] {
        let reply = try await imageService.call(XPCRequest(route: APIRoute.imageList))
        guard let data = reply.data(APIKey.imageDescriptions) else {
            throw APIError.malformedReply("imageList \(APIKey.imageDescriptions)")
        }
        return try Self.parseImageDescriptions(data)
    }

    static func parseImageDescriptions(_ data: Data) throws -> [APIImageDescription] {
        try APIDecode.jsonArray(data, what: "imageList").compactMap { item -> APIImageDescription? in
            guard let object = item as? [String: Any],
                  let reference = CLIText.nonEmpty(object["reference"] as? String),
                  let descriptor = object["descriptor"] as? [String: Any],
                  let digest = CLIText.nonEmpty(descriptor["digest"] as? String),
                  let descriptorJSON = try? JSONSerialization.data(withJSONObject: descriptor) else { return nil }
            let annotations = descriptor["annotations"] as? [String: String]
            return APIImageDescription(reference: reference, digest: digest, descriptorJSON: descriptorJSON, nameAnnotation: annotations?[APILabel.imageName])
        }
    }

    /// Finds an image the way the CLI does: a local build by its name annotation
    /// first, then the exact or normalized reference. Not found goes to the CLI.
    func resolveImage(_ reference: String, allowInfra: Bool = false) async throws -> APIImageDescription {
        let all = try await imageDescriptions()
        guard let found = Self.resolve(reference, in: all, registryDomain: settings.registryDomain()) else {
            throw APIError.needsCLI("image \(reference) not found")
        }
        if !allowInfra, settings.isInfraImage(found.reference) {
            throw APIError.needsCLI("image \(reference) is a system image")
        }
        return found
    }

    static func resolve(_ reference: String, in all: [APIImageDescription], registryDomain: String) -> APIImageDescription? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        // `Reference.parse` + `normalize()` without a default domain, for the annotation.
        if var local = APIImageReference.normalize(trimmed, defaultDomain: "") {
            if local.hasPrefix("/") { local.removeFirst() }
            let matches = all.filter { $0.nameAnnotation == local }
            if matches.count == 1 { return matches[0] }
            if let tagged = matches.first(where: { $0.reference == local }) { return tagged }
        }
        let normalized = APIImageReference.normalize(trimmed, defaultDomain: registryDomain)
        return all.first { $0.reference == trimmed || $0.reference == normalized }
    }

    /// `ImageResource` JSON as the CLI prints it: {id, configuration, variants}.
    func imageResource(_ description: APIImageDescription, includeUnknownPlatforms: Bool) async throws -> [String: Any] {
        let index = try await contentJSON(description.digest)
        let manifests = index["manifests"] as? [[String: Any]] ?? []
        var variants: [Any] = []
        var earliest: Date?
        for entry in manifests {
            guard let platform = entry["platform"] as? [String: Any],
                  let digest = entry["digest"] as? String else { continue }
            if !includeUnknownPlatforms, (platform["os"] as? String) == "unknown" || (platform["architecture"] as? String) == "unknown" {
                continue
            }
            // Like the CLI, a variant whose manifest or config is not local is skipped.
            guard let manifest = try? await contentJSON(digest),
                  let configDescriptor = manifest["config"] as? [String: Any],
                  let configDigest = configDescriptor["digest"] as? String,
                  let config = try? await contentJSON(configDigest) else { continue }
            let layers = manifest["layers"] as? [[String: Any]] ?? []
            let size = Self.int64(entry["size"]) + Self.int64(configDescriptor["size"]) + layers.reduce(0) { $0 + Self.int64($1["size"]) }
            variants.append(["platform": platform, "digest": digest, "size": size, "config": config])
            if let created = (config["created"] as? String).flatMap(DeckDate.parse) {
                earliest = min(earliest ?? created, created)
            }
        }
        var configuration: [String: Any] = ["name": description.reference]
        if let descriptor = try? JSONSerialization.jsonObject(with: description.descriptorJSON) {
            configuration["descriptor"] = descriptor
        }
        if let earliest {
            configuration["creationDate"] = APIDecode.isoDate(sinceReferenceDate: earliest.timeIntervalSinceReferenceDate)
        }
        let hex = description.digest.split(separator: ":", maxSplits: 1).last.map(String.init) ?? description.digest
        return ["id": hex, "configuration": configuration, "variants": variants]
    }

    /// A blob from the content store as a JSON object.
    func contentJSON(_ digest: String) async throws -> [String: Any] {
        try APIDecode.jsonObject(try await contentData(digest), what: "content \(digest)")
    }

    func contentData(_ digest: String) async throws -> Data {
        if let cached = content.get(digest) { return cached }
        var request = XPCRequest(route: APIRoute.contentGet)
        request.set(APIKey.digest, digest)
        let reply = try await imageService.call(request)
        guard let path = reply.string(APIKey.contentPath) else {
            throw APIError.malformedReply("contentGet \(APIKey.contentPath)")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw APIError.malformedReply("content \(digest)")
        }
        content.put(digest, data)
        return data
    }

    static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }
}

/// Small cache of content blobs by digest. A digest names its bytes, so entries never go stale.
final class APIContentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var order: [String] = []
    private let limitBytes: Int
    private var totalBytes = 0

    init(limitBytes: Int = 32 * 1024 * 1024) {
        self.limitBytes = limitBytes
    }

    func get(_ digest: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[digest]
    }

    func put(_ digest: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard items[digest] == nil, data.count <= limitBytes / 4 else { return }
        items[digest] = data
        order.append(digest)
        totalBytes += data.count
        while totalBytes > limitBytes, !order.isEmpty {
            let oldest = order.removeFirst()
            totalBytes -= items.removeValue(forKey: oldest)?.count ?? 0
        }
    }
}

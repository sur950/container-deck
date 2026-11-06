import Foundation
import CryptoKit

/// Turns image tarballs from other engines into OCI layout tarballs that
/// `container image load` accepts.
///
/// - docker-archive (manifest.json only): we build blobs/sha256, an image
///   manifest, index.json and oci-layout ourselves.
/// - OCI layout (index.json + oci-layout): we keep it, add Apple's name
///   annotation when missing, and drop index entries whose blobs are not in the
///   archive (other platforms that were never pulled).
public enum OCIArchive {
    public static let indexMediaType = "application/vnd.oci.image.index.v1+json"
    public static let manifestMediaType = "application/vnd.oci.image.manifest.v1+json"
    public static let configMediaType = "application/vnd.oci.image.config.v1+json"
    public static let layerMediaType = "application/vnd.oci.image.layer.v1.tar"
    public static let layerGzipMediaType = "application/vnd.oci.image.layer.v1.tar+gzip"
    public static let layerZstdMediaType = "application/vnd.oci.image.layer.v1.tar+zstd"
    public static let dockerManifestListMediaType = "application/vnd.docker.distribution.manifest.list.v2+json"
    public static let dockerManifestMediaType = "application/vnd.docker.distribution.manifest.v2+json"

    public static let appleNameKey = "com.apple.containerization.image.name"
    public static let containerdNameKey = "io.containerd.image.name"
    public static let ociRefNameKey = "org.opencontainers.image.ref.name"

    // MARK: - Models

    public struct Platform: Codable, Sendable, Hashable {
        public var architecture: String
        public var os: String
        public var variant: String?

        public init(architecture: String, os: String, variant: String? = nil) {
            self.architecture = architecture
            self.os = os
            self.variant = variant
        }
    }

    public struct Descriptor: Codable, Sendable, Hashable {
        public var mediaType: String
        public var digest: String
        public var size: Int64
        public var platform: Platform?
        public var annotations: [String: String]?

        public init(mediaType: String, digest: String, size: Int64, platform: Platform? = nil, annotations: [String: String]? = nil) {
            self.mediaType = mediaType
            self.digest = digest
            self.size = size
            self.platform = platform
            self.annotations = annotations
        }
    }

    struct ImageManifest: Codable {
        var schemaVersion: Int
        var mediaType: String
        var config: Descriptor
        var layers: [Descriptor]
    }

    struct ImageIndex: Codable {
        var schemaVersion: Int
        var mediaType: String
        var manifests: [Descriptor]
    }

    /// One image in a docker-archive manifest.json.
    public struct DockerArchiveEntry: Decodable, Sendable, Equatable {
        public var config: String
        public var repoTags: [String]
        public var layers: [String]

        enum CodingKeys: String, CodingKey {
            case config = "Config"
            case repoTags = "RepoTags"
            case layers = "Layers"
        }

        public init(config: String, repoTags: [String], layers: [String]) {
            self.config = config
            self.repoTags = repoTags
            self.layers = layers
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            config = try container.decode(String.self, forKey: .config)
            repoTags = (try container.decodeIfPresent([String].self, forKey: .repoTags)) ?? []
            layers = (try container.decodeIfPresent([String].self, forKey: .layers)) ?? []
        }
    }

    public enum ArchiveKind: Equatable, Sendable {
        case ociLayout
        case dockerArchive
        case unknown
    }

    // MARK: - Pure helpers (tested)

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func sha256Digest(_ data: Data) -> String {
        "sha256:" + hex(SHA256.hash(data: data))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// "abc..." from "sha256:abc...".
    public static func encoded(_ digest: String) -> String {
        if let colon = digest.firstIndex(of: ":") {
            return String(digest[digest.index(after: colon)...])
        }
        return digest
    }

    public static func parseDockerManifest(_ data: Data) throws -> [DockerArchiveEntry] {
        guard let entries = try? JSONDecoder().decode([DockerArchiveEntry].self, from: data), !entries.isEmpty else {
            throw DeckError.parse("the image archive manifest")
        }
        return entries
    }

    /// Picks the layer media type from the first bytes of the layer file.
    public static func detectLayerMediaType(header: [UInt8]) -> String {
        if header.count >= 2, header[0] == 0x1F, header[1] == 0x8B { return layerGzipMediaType }
        if header.count >= 4, header[0] == 0x28, header[1] == 0xB5, header[2] == 0x2F, header[3] == 0xFD {
            return layerZstdMediaType
        }
        return layerMediaType
    }

    /// Reads architecture, os and variant from an image config.
    public static func platform(fromConfig data: Data) -> Platform? {
        struct Config: Decodable {
            var architecture: String?
            var os: String?
            var variant: String?
        }
        guard let config = try? JSONDecoder().decode(Config.self, from: data),
              let arch = config.architecture, let os = config.os, !arch.isEmpty, !os.isEmpty
        else { return nil }
        return Platform(architecture: arch, os: os, variant: (config.variant ?? "").isEmpty ? nil : config.variant)
    }

    /// The image manifest JSON bytes for a config and its layers.
    public static func imageManifest(config: Descriptor, layers: [Descriptor]) throws -> Data {
        let manifest = ImageManifest(schemaVersion: 2, mediaType: manifestMediaType, config: config, layers: layers)
        return try encoder().encode(manifest)
    }

    /// index.json bytes.
    public static func index(manifests: [Descriptor]) throws -> Data {
        try encoder().encode(ImageIndex(schemaVersion: 2, mediaType: indexMediaType, manifests: manifests))
    }

    public static func ociLayoutFile() -> Data {
        Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
    }

    /// Name annotations Apple's loader reads (it prefers its own key, then containerd's).
    public static func nameAnnotations(_ reference: String) -> [String: String] {
        let full = ImageReference.normalize(reference)
        return [appleNameKey: full, containerdNameKey: full, ociRefNameKey: full]
    }

    /// Index entry for one tag of a converted image.
    public static func indexEntry(manifestDigest: String, manifestSize: Int64, platform: Platform?, reference: String) -> Descriptor {
        Descriptor(
            mediaType: manifestMediaType, digest: manifestDigest, size: manifestSize,
            platform: platform, annotations: nameAnnotations(reference)
        )
    }

    /// Adds Apple's name annotation to index.json entries that only have a tag
    /// or no name. Returns nil when nothing needs to change.
    public static func patchedIndex(_ data: Data, reference: String) throws -> Data? {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var manifests = root["manifests"] as? [[String: Any]]
        else { throw DeckError.parse("the image archive index") }

        var changed = false
        var usedFallback = false
        for i in manifests.indices {
            var annotations = manifests[i]["annotations"] as? [String: String] ?? [:]
            if annotations[appleNameKey] != nil || annotations[containerdNameKey] != nil { continue }
            let refName = annotations[ociRefNameKey] ?? ""
            let name: String
            if refName.contains("/") || (refName.contains(":") && !refName.hasPrefix("sha256:")) {
                name = ImageReference.normalize(refName)
            } else if !usedFallback {
                name = ImageReference.normalize(reference)
                usedFallback = true
            } else {
                continue
            }
            annotations[appleNameKey] = name
            annotations[containerdNameKey] = name
            manifests[i]["annotations"] = annotations
            changed = true
        }
        guard changed else { return nil }
        root["manifests"] = manifests
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Drops manifests whose blobs are missing from an index blob.
    /// Returns nil when nothing changes or when nothing would be left.
    public static func prunedIndex(_ data: Data, blobExists: (String) -> Bool) throws -> Data? {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifests = root["manifests"] as? [[String: Any]]
        else { throw DeckError.parse("an image index") }
        let kept = manifests.filter { entry in
            guard let digest = entry["digest"] as? String else { return false }
            return blobExists(digest)
        }
        guard !kept.isEmpty, kept.count != manifests.count else { return nil }
        root["manifests"] = kept
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - File work

    /// What kind of archive was extracted into a folder.
    public static func kind(ofExtracted dir: URL) -> ArchiveKind {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("index.json").path),
           fm.fileExists(atPath: dir.appendingPathComponent("oci-layout").path) {
            return .ociLayout
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) {
            return .dockerArchive
        }
        return .unknown
    }

    /// Streams a file through SHA256.
    public static func sha256File(_ url: URL) throws -> (digest: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk: Data = try autoreleasepool {
                try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return ("sha256:" + hex(hasher.finalize()), size)
    }

    static func header(of url: URL) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4)) ?? Data()
        return [UInt8](data)
    }

    /// Converts an extracted docker-archive in `source` to an OCI layout in `output`.
    /// Layer files are moved, not copied, to save disk space.
    /// Returns the image references written to index.json.
    @discardableResult
    public static func convertDockerArchive(at source: URL, to output: URL, fallbackReference: String) throws -> [String] {
        let fm = FileManager.default
        let manifestData = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let entries = try parseDockerManifest(manifestData)

        let blobs = output.appendingPathComponent("blobs/sha256", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)

        func blobURL(_ digest: String) -> URL { blobs.appendingPathComponent(encoded(digest)) }

        func storeData(_ data: Data) throws -> (digest: String, size: Int64) {
            let digest = sha256Digest(data)
            let target = blobURL(digest)
            if !fm.fileExists(atPath: target.path) {
                try data.write(to: target)
            }
            return (digest, Int64(data.count))
        }

        var layerCache: [String: Descriptor] = [:]
        var indexEntries: [Descriptor] = []
        var references: [String] = []

        for entry in entries {
            let configURL = source.appendingPathComponent(entry.config).resolvingSymlinksInPath()
            let configData = try Data(contentsOf: configURL)
            let config = try storeData(configData)
            let configDescriptor = Descriptor(mediaType: configMediaType, digest: config.digest, size: config.size)
            let imagePlatform = Self.platform(fromConfig: configData)

            var layers: [Descriptor] = []
            for layerPath in entry.layers {
                if let cached = layerCache[layerPath] {
                    layers.append(cached)
                    continue
                }
                let layerURL = source.appendingPathComponent(layerPath).resolvingSymlinksInPath()
                if let cached = layerCache[layerURL.path] {
                    layerCache[layerPath] = cached
                    layers.append(cached)
                    continue
                }
                let mediaType = detectLayerMediaType(header: header(of: layerURL))
                let hashed = try sha256File(layerURL)
                let target = blobURL(hashed.digest)
                if !fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: layerURL, to: target)
                }
                let descriptor = Descriptor(mediaType: mediaType, digest: hashed.digest, size: hashed.size)
                layerCache[layerURL.path] = descriptor
                layerCache[layerPath] = descriptor
                layers.append(descriptor)
            }

            let manifestBytes = try imageManifest(config: configDescriptor, layers: layers)
            let manifest = try storeData(manifestBytes)

            var tags = entry.repoTags.filter { !ImageReference.isUntagged($0) }
            if tags.isEmpty { tags = [fallbackReference] }
            for tag in tags {
                indexEntries.append(indexEntry(manifestDigest: manifest.digest, manifestSize: manifest.size, platform: imagePlatform, reference: tag))
                references.append(ImageReference.normalize(tag))
            }
        }

        try ociLayoutFile().write(to: output.appendingPathComponent("oci-layout"))
        try index(manifests: indexEntries).write(to: output.appendingPathComponent("index.json"))
        return references
    }

    /// Fixes an extracted OCI layout in place. Returns true when a file changed.
    @discardableResult
    public static func normalizeOCILayout(at dir: URL, reference: String) throws -> Bool {
        let fm = FileManager.default
        let indexURL = dir.appendingPathComponent("index.json")
        let blobs = dir.appendingPathComponent("blobs/sha256", isDirectory: true)
        func exists(_ digest: String) -> Bool {
            fm.fileExists(atPath: blobs.appendingPathComponent(encoded(digest)).path)
        }

        var indexData = try Data(contentsOf: indexURL)
        var changed = false

        // Prune nested indexes that point at platforms not in the archive.
        if var root = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
           var manifests = root["manifests"] as? [[String: Any]] {
            var touched = false
            manifests = manifests.filter { entry in
                guard let digest = entry["digest"] as? String else { return false }
                if exists(digest) { return true }
                touched = true
                return false
            }
            for i in manifests.indices {
                let mediaType = manifests[i]["mediaType"] as? String ?? ""
                guard mediaType == indexMediaType || mediaType == dockerManifestListMediaType,
                      let digest = manifests[i]["digest"] as? String,
                      let nested = try? Data(contentsOf: blobs.appendingPathComponent(encoded(digest))),
                      let pruned = try prunedIndex(nested, blobExists: exists)
                else { continue }
                let newDigest = sha256Digest(pruned)
                try pruned.write(to: blobs.appendingPathComponent(encoded(newDigest)))
                manifests[i]["digest"] = newDigest
                manifests[i]["size"] = pruned.count
                touched = true
            }
            if touched {
                root["manifests"] = manifests
                indexData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
                changed = true
            }
        }

        if let patched = try patchedIndex(indexData, reference: reference) {
            indexData = patched
            changed = true
        }
        if changed {
            try indexData.write(to: indexURL)
        }
        return changed
    }
}

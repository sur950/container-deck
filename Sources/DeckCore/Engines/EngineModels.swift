import Foundation

/// Container engines we can bring images from.
public enum EngineKind: String, Sendable, Hashable, CaseIterable, Codable {
    case dockerDesktop
    case orbStack
    case rancherDesktop
    case rancherContainerd
    case podman
    case colima
    case lima
    case other

    public var title: String {
        switch self {
        case .dockerDesktop: return "Docker Desktop"
        case .orbStack: return "OrbStack"
        case .rancherDesktop: return "Rancher Desktop"
        case .rancherContainerd: return "Rancher Desktop (containerd)"
        case .podman: return "Podman"
        case .colima: return "Colima"
        case .lima: return "Lima"
        case .other: return "Docker engine"
        }
    }

    /// Engines we always list, so people see "Not found" for them.
    public static let wellKnown: [EngineKind] = [.dockerDesktop, .orbStack, .rancherDesktop, .podman, .colima]
}

public enum EngineState: String, Sendable, Hashable {
    case running
    case stopped
    case notFound

    public var title: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Found but stopped"
        case .notFound: return "Not found"
        }
    }
}

/// How we talk to an engine.
public enum EngineEndpoint: Sendable, Hashable {
    /// Docker Engine API on a unix socket (Docker, OrbStack, Rancher dockerd, Podman, Colima, Lima).
    case dockerSocket(String)
    /// Rancher Desktop in containerd mode, through its nerdctl.
    case nerdctl(binary: String, namespace: String)

    public var displayPath: String {
        switch self {
        case .dockerSocket(let path): return path
        case .nerdctl(let binary, let namespace): return "\(binary) -n \(namespace)"
        }
    }
}

public struct DetectedEngine: Identifiable, Sendable, Hashable {
    /// Stable id, for example "socket:/Users/me/.orbstack/run/docker.sock".
    public var id: String
    public var kind: EngineKind
    public var name: String
    public var state: EngineState
    public var endpoint: EngineEndpoint?
    public var version: String?
    /// Where we found it, or why it is stopped.
    public var note: String?
    /// Podman only: the podman binary and connection name, used for `podman save`.
    public var podmanBinary: String?
    public var podmanConnection: String?
    /// Filled after listing images.
    public var imageCount: Int?
    /// Daemon id from /info, used to spot one engine behind two sockets.
    public var engineUID: String?

    public init(
        id: String, kind: EngineKind, name: String, state: EngineState, endpoint: EngineEndpoint? = nil,
        version: String? = nil, note: String? = nil, podmanBinary: String? = nil, podmanConnection: String? = nil,
        imageCount: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.state = state
        self.endpoint = endpoint
        self.version = version
        self.note = note
        self.podmanBinary = podmanBinary
        self.podmanConnection = podmanConnection
        self.imageCount = imageCount
    }

    public var isRunning: Bool { state == .running }
}

/// One tagged image inside another engine.
public struct EngineImage: Identifiable, Sendable, Hashable {
    public var id: String { "\(engineID)|\(reference)" }
    public var engineID: String
    public var engineName: String
    /// Image id in that engine ("sha256:...").
    public var imageID: String
    /// The tag as the engine shows it, for example "nginx:latest".
    public var reference: String
    /// Full name, for example "docker.io/library/nginx:latest".
    public var normalizedReference: String
    public var repoDigests: [String]
    public var sizeBytes: UInt64
    /// "arm64" or "amd64". nil when unknown.
    public var architecture: String?
    public var os: String?
    public var createdAt: Date?
    /// The image already exists in Apple's container.
    public var alreadyHere: Bool
    /// Other engines that have the same image.
    public var alsoIn: [String]

    public init(
        engineID: String, engineName: String, imageID: String, reference: String, repoDigests: [String] = [],
        sizeBytes: UInt64 = 0, architecture: String? = nil, os: String? = nil, createdAt: Date? = nil,
        alreadyHere: Bool = false, alsoIn: [String] = []
    ) {
        self.engineID = engineID
        self.engineName = engineName
        self.imageID = imageID
        self.reference = reference
        self.normalizedReference = ImageReference.normalize(reference)
        self.repoDigests = repoDigests
        self.sizeBytes = sizeBytes
        self.architecture = architecture
        self.os = os
        self.createdAt = createdAt
        self.alreadyHere = alreadyHere
        self.alsoIn = alsoIn
    }

    public var isAmd64: Bool { architecture == "amd64" || architecture == "x86_64" }

    /// Came from a registry, so we can pull it again.
    public var canPullFromRegistry: Bool {
        guard !repoDigests.isEmpty else { return false }
        let domain = ImageReference.domain(of: normalizedReference)
        return domain != "localhost" && !domain.hasPrefix("localhost:") && !domain.hasPrefix("127.0.0.1")
    }

    /// "nginx" style short name for lists.
    public var shortName: String {
        ImageSummary(reference: normalizedReference).shortName
    }

    public var tag: String {
        ImageSummary(reference: normalizedReference).tag
    }
}

/// Helpers for image references like "nginx", "user/app:1" or "ghcr.io/a/b:tag".
public enum ImageReference {
    /// "nginx" becomes "docker.io/library/nginx:latest".
    public static func normalize(_ reference: String) -> String {
        var ref = reference.trimmingCharacters(in: .whitespaces)
        if ref.isEmpty { return ref }

        var digest = ""
        if let at = ref.firstIndex(of: "@") {
            digest = String(ref[at...])
            ref = String(ref[..<at])
        }

        var name = ref
        var tag = ""
        if let colon = ref.lastIndex(of: ":"), !ref[colon...].contains("/") {
            name = String(ref[..<colon])
            tag = String(ref[ref.index(after: colon)...])
        }

        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 || !looksLikeDomain(parts[0]) {
            name = "docker.io/" + name
        }
        if name.hasPrefix("index.docker.io/") {
            name = "docker.io/" + String(name.dropFirst("index.docker.io/".count))
        }
        let afterDomain = name.split(separator: "/", maxSplits: 1).map(String.init)
        if afterDomain.count == 2, afterDomain[0] == "docker.io", !afterDomain[1].contains("/") {
            name = "docker.io/library/" + afterDomain[1]
        }

        if tag.isEmpty && digest.isEmpty { tag = "latest" }
        var result = name
        if !tag.isEmpty { result += ":" + tag }
        result += digest
        return result
    }

    /// "ghcr.io" from "ghcr.io/a/b:tag". "docker.io" when there is no domain.
    public static func domain(of reference: String) -> String {
        let normalized = normalize(reference)
        return normalized.split(separator: "/").first.map(String.init) ?? "docker.io"
    }

    static func looksLikeDomain(_ part: String) -> Bool {
        part.contains(".") || part.contains(":") || part == "localhost"
    }

    /// Untagged images show as "<none>:<none>" in Docker.
    public static func isUntagged(_ reference: String) -> Bool {
        reference.isEmpty || reference.contains("<none>")
    }
}

/// Progress of one image move.
public enum ImportStep: Sendable, Equatable {
    case waiting
    case pulling(String)
    case exporting(done: UInt64, total: UInt64)
    case converting
    case loading
    case done(method: String)
    case failed(String)
    case cancelled

    public var title: String {
        switch self {
        case .waiting: return "Waiting"
        case .pulling: return "Pulling from the registry"
        case .exporting: return "Copying"
        case .converting: return "Preparing"
        case .loading: return "Loading"
        case .done(let method): return method
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }

    public var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .waiting, .done, .failed, .cancelled: return false
        default: return true
        }
    }

    /// 0...1 when known.
    public var fraction: Double? {
        if case .exporting(let done, let total) = self, total > 0 {
            return min(1, Double(done) / Double(total))
        }
        return nil
    }
}

import Foundation

/// An image reference split into its parts, like `ghcr.io/owner/app:1.2` or
/// `quay.io/org/tool@sha256:...`. Follows the Docker reference rules: the first
/// part is a registry only when it has a dot, a colon or is `localhost`.
public struct PullReference: Sendable, Hashable {
    public static let defaultRegistry = "docker.io"

    /// Registry host as typed, nil when none was typed (Docker Hub).
    public var registry: String?
    /// Path in the registry, like `library/nginx` or `owner/app`.
    public var repository: String
    public var tag: String?
    public var digest: String?

    public init(registry: String?, repository: String, tag: String? = nil, digest: String? = nil) {
        self.registry = registry
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// The registry calls go to.
    public var effectiveRegistry: String { registry ?? Self.defaultRegistry }

    public var isDockerHub: Bool {
        let host = effectiveRegistry.lowercased()
        return host == "docker.io" || host == "index.docker.io" || host == "registry-1.docker.io"
    }

    /// Full name with registry and tag, like `docker.io/library/nginx:latest`.
    public var canonical: String {
        var path = repository
        if isDockerHub && !path.contains("/") { path = "library/" + path }
        var text = "\(effectiveRegistry)/\(path)"
        if let digest {
            if let tag { text += ":\(tag)" }
            text += "@\(digest)"
        } else {
            text += ":\(tag ?? "latest")"
        }
        return text
    }

    /// Parses a reference. nil when it is not a valid image name.
    public static func parse(_ raw: String) -> PullReference? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // People paste `docker pull x` or a URL now and then.
        for prefix in ["docker pull ", "container image pull ", "container pull ", "podman pull "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        var digest: String?
        if let at = text.firstIndex(of: "@") {
            digest = String(text[text.index(after: at)...])
            text = String(text[..<at])
            guard let value = digest, value.range(of: #"^[a-z0-9]+(?:[.+_-][a-z0-9]+)*:[a-fA-F0-9]{32,}$"#, options: .regularExpression) != nil else {
                return nil
            }
        }

        var parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }

        var registry: String?
        if parts.count > 1, let first = parts.first,
           first.contains(".") || first.contains(":") || first == "localhost" {
            registry = first
            parts.removeFirst()
            guard first.range(of: #"^[a-zA-Z0-9.-]+(:[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        }

        var tag: String?
        if var last = parts.last, let colon = last.lastIndex(of: ":") {
            tag = String(last[last.index(after: colon)...])
            last = String(last[..<colon])
            parts[parts.count - 1] = last
            guard let value = tag, value.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else {
                return nil
            }
        }

        for part in parts {
            guard part.range(of: #"^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
                return nil
            }
        }
        return PullReference(registry: registry, repository: parts.joined(separator: "/"), tag: tag, digest: digest)
    }

    /// True when the text names a registry other than Docker Hub, or a digest:
    /// things a Docker Hub search cannot find.
    public static func looksLikeDirectPull(_ raw: String) -> Bool {
        guard let reference = parse(raw) else { return false }
        return (reference.registry != nil && !reference.isDockerHub) || reference.digest != nil
    }

    /// Registries people pull from most, for hints.
    public static let knownRegistries: [(host: String, name: String, example: String)] = [
        ("ghcr.io", "GitHub", "ghcr.io/owner/image:tag"),
        ("quay.io", "Quay", "quay.io/org/image:tag"),
        ("public.ecr.aws", "Amazon ECR Public", "public.ecr.aws/org/image:tag"),
        ("gcr.io", "Google", "gcr.io/project/image:tag"),
        ("mcr.microsoft.com", "Microsoft", "mcr.microsoft.com/repo/image:tag"),
        ("registry.gitlab.com", "GitLab", "registry.gitlab.com/group/project:tag")
    ]

    /// Friendly registry name, like "GitHub" for ghcr.io.
    public var registryDisplayName: String {
        if isDockerHub { return "Docker Hub" }
        let host = effectiveRegistry.lowercased()
        return Self.knownRegistries.first { $0.host == host }?.name ?? effectiveRegistry
    }
}

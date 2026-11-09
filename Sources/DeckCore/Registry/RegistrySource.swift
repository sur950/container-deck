import Foundation

/// What a registry can do for search. Picked from the host name.
public enum RegistryKind: String, Sendable, Hashable, CaseIterable {
    /// Docker Hub's own search API.
    case dockerHub
    /// Quay's public search API.
    case quay
    /// ghcr.io. No public search. With a saved token, GitHub's Packages API lists your packages.
    case github
    /// Amazon ECR (private and public). No search over the registry API.
    case amazon
    /// Google Artifact Registry and Container Registry. No search over the registry API.
    case google
    /// Any other registry: Harbor search when it is a Harbor, else `/v2/_catalog`.
    /// GitLab, Azure, Artifactory, Nexus and registry:2 land here.
    case generic

    public static func classify(host raw: String) -> RegistryKind {
        let host = DockerConfigFile.registryHost(from: raw)
        let name = host.split(separator: ":").first.map(String.init) ?? host
        if host == "docker.io" { return .dockerHub }
        if name == "quay.io" { return .quay }
        if name == "ghcr.io" { return .github }
        if name == "public.ecr.aws" || (name.contains(".dkr.ecr.") && name.hasSuffix(".amazonaws.com")) { return .amazon }
        if name == "gcr.io" || name.hasSuffix(".gcr.io") || name.hasSuffix("-docker.pkg.dev") || name == "pkg.dev" { return .google }
        return .generic
    }
}

/// One registry Explore searches: Docker Hub and Quay.io always, plus each
/// registry signed in with `container registry login`.
public struct RegistrySource: Sendable, Hashable, Identifiable {
    /// Short host, like "docker.io", "ghcr.io" or "registry.example.com:5000".
    public var host: String
    public var kind: RegistryKind
    /// The server name exactly as the container tool saved it in the keychain
    /// (for example "registry-1.docker.io"). nil when not signed in.
    public var keychainServer: String?
    /// The saved user name. Never a secret.
    public var username: String?

    public var id: String { host }
    public var isSignedIn: Bool { keychainServer != nil }

    public init(host: String, kind: RegistryKind? = nil, keychainServer: String? = nil, username: String? = nil) {
        let short = DockerConfigFile.registryHost(from: host)
        self.host = short
        self.kind = kind ?? RegistryKind.classify(host: short)
        self.keychainServer = keychainServer
        self.username = username
    }

    public static let dockerHub = RegistrySource(host: "docker.io", kind: .dockerHub)
    public static let quay = RegistrySource(host: "quay.io", kind: .quay)

    /// Friendly name for filters and pills.
    public var displayName: String { Self.displayName(for: host) }

    public static func displayName(for host: String) -> String {
        let short = DockerConfigFile.registryHost(from: host)
        switch short {
        case "docker.io": return "Docker Hub"
        case "quay.io": return "Quay.io"
        case "ghcr.io": return "GitHub"
        case "registry.gitlab.com": return "GitLab"
        case "public.ecr.aws": return "Amazon ECR Public"
        default: return short
        }
    }

    /// Docker Hub and Quay.io first (public search, no account), then every
    /// signed in registry in name order. A login for Docker Hub or Quay marks
    /// that entry as signed in instead of adding a second one.
    public static func sources(logins: [RegistryLogin]) -> [RegistrySource] {
        var list = [dockerHub, quay]
        for login in logins.sorted(by: { $0.displayHost < $1.displayHost }) {
            let host = login.displayHost
            guard !host.isEmpty else { continue }
            if let index = list.firstIndex(where: { $0.host == host }) {
                list[index].keychainServer = login.server
                list[index].username = login.username
            } else {
                list.append(RegistrySource(host: host, keychainServer: login.server, username: login.username))
            }
        }
        return list
    }

    /// The scheme the registry API uses. Plain HTTP only for this Mac.
    public var scheme: String {
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return ["localhost", "127.0.0.1", "::1"].contains(name) ? "http" : "https"
    }

    /// The host for registry API calls ("registry-1.docker.io" for Docker Hub).
    public var apiHost: String { kind == .dockerHub ? "registry-1.docker.io" : host }
}

/// One image found in a registry.
public struct RegistryImage: Sendable, Hashable, Identifiable {
    /// Short registry host, like "docker.io" or "quay.io".
    public var registry: String
    /// Path in the registry. Docker Hub official images have no "library/" part ("nginx").
    public var repository: String
    public var description: String
    public var starCount: Int
    public var pullCount: Int
    public var isOfficial: Bool
    /// True when the registry says the image needs a sign in to pull.
    public var isPrivate: Bool
    /// The page the registry itself gave for the image (GitHub packages).
    public var pageURL: URL?

    public init(registry: String, repository: String, description: String = "", starCount: Int = 0,
                pullCount: Int = 0, isOfficial: Bool = false, isPrivate: Bool = false, pageURL: URL? = nil) {
        self.registry = DockerConfigFile.registryHost(from: registry)
        self.repository = repository
        self.description = description
        self.starCount = starCount
        self.pullCount = pullCount
        self.isOfficial = isOfficial
        self.isPrivate = isPrivate
        self.pageURL = pageURL
    }

    public init(hub: HubRepository) {
        self.init(registry: "docker.io", repository: hub.fullName, description: hub.description,
                  starCount: hub.starCount, pullCount: hub.pullCount, isOfficial: hub.isOfficial)
    }

    public var id: String { "\(registry)/\(repository)" }
    public var isDockerHub: Bool { registry == "docker.io" }
    public var registryName: String { RegistrySource.displayName(for: registry) }

    /// The name to pull, without a tag: "nginx" for Docker Hub, "quay.io/org/app" elsewhere.
    public var reference: String { isDockerHub ? repository : "\(registry)/\(repository)" }

    /// "nginx:1.27" or "quay.io/org/app:v1".
    public func reference(tag: String) -> String { "\(reference):\(tag)" }

    /// Path for registry API calls ("library/nginx" for official Docker Hub images).
    public var apiRepository: String {
        isDockerHub && !repository.contains("/") ? "library/\(repository)" : repository
    }

    /// The image's page on the registry's website, when it has one.
    public var webURL: URL? {
        if let pageURL { return pageURL }
        switch RegistryKind.classify(host: registry) {
        case .dockerHub:
            let path = isOfficial && !repository.contains("/") ? "_/\(repository)" : "r/\(repository)"
            return URL(string: "https://hub.docker.com/\(path)")
        case .quay:
            return URL(string: "https://quay.io/repository/\(repository)")
        case .github:
            guard let owner = repository.split(separator: "/").first, repository.contains("/") else { return nil }
            return URL(string: "https://github.com/\(owner)?tab=packages")
        default:
            return nil
        }
    }
}

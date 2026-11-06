import Foundation

/// A name the person added by hand. `pattern` is one name (`api.test`) or every name
/// below a domain (`*.gateway.test`). Traffic goes to `container` on `port`
/// (nil means the container's own route port).
public struct ProxyAlias: Codable, Hashable, Sendable, Identifiable {
    public var pattern: String
    public var container: String
    public var port: Int?

    public var id: String { pattern }

    public init(pattern: String, container: String, port: Int? = nil) {
        self.pattern = HostName.normalize(pattern)
        self.container = container
        self.port = port
    }

    public var isWildcard: Bool { pattern.hasPrefix("*.") }
    /// True when macOS needs a resolver file before the name works (not below `.localhost`).
    public var needsResolver: Bool { HostName.needsResolver(pattern) }
}

/// Where a route's port came from. Shown in the routes table.
public enum RouteSource: String, Sendable, Hashable, Codable {
    case label, published, exposed, fallback, alias

    public var title: String {
        switch self {
        case .label: return "Label"
        case .published: return "Published port"
        case .exposed: return "Image port"
        case .fallback: return "Guess"
        case .alias: return "Alias"
        }
    }
}

/// One name the proxy answers for, and where it sends traffic.
public struct ProxyRoute: Hashable, Sendable, Identifiable {
    public var host: String
    public var container: String
    public var targetHost: String?
    public var targetPort: Int
    public var source: RouteSource
    public var isRunning: Bool

    public var id: String { host }
    public var isWildcard: Bool { host.hasPrefix("*.") }
    /// Running with an address, so the proxy can reach it.
    public var isReachable: Bool { isRunning && targetHost != nil }
    public var target: String { "\(targetHost ?? "no address"):\(targetPort)" }

    public init(host: String, container: String, targetHost: String?, targetPort: Int, source: RouteSource, isRunning: Bool = true) {
        self.host = host
        self.container = container
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.source = source
        self.isRunning = isRunning
    }

    /// `https://web.localhost:8443`. Port 443 is left out. Wildcards show an example name.
    public func url(port: UInt16) -> String {
        let name = isWildcard ? "app" + host.dropFirst() : Substring(host)
        return port == 443 ? "https://\(name)" : "https://\(name):\(port)"
    }

    /// Plain address of the container, for tunnels that skip the proxy.
    public var upstreamURL: String? {
        targetHost.map { "http://\($0):\(targetPort)" }
    }
}

/// Host name rules and matching. Pure, unit tested.
public enum HostName {
    public static func normalize(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// One DNS label: letters, digits, dashes, not starting or ending with a dash.
    static func isValidLabel<S: StringProtocol>(_ label: S) -> Bool {
        guard !label.isEmpty, label.count <= 63 else { return false }
        guard label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }

    /// A full name like `web.test`. At least two labels.
    public static func isValidName(_ value: String) -> Bool {
        let name = normalize(value)
        guard name.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy(isValidLabel)
    }

    /// A name, or `*.` followed by a name.
    public static func isValidPattern(_ value: String) -> Bool {
        let name = normalize(value)
        if name.hasPrefix("*.") { return isValidName(String(name.dropFirst(2))) }
        return isValidName(name)
    }

    /// `*.gateway.test` matches `a.gateway.test` and `a.b.gateway.test`, not `gateway.test`.
    public static func matches(pattern: String, host: String) -> Bool {
        let pattern = normalize(pattern), host = normalize(host)
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(1)) // ".gateway.test"
            return host.hasSuffix(suffix) && host.count > suffix.count
        }
        return pattern == host
    }

    public static func isBelowProxyDomain(_ value: String) -> Bool {
        let name = normalize(value)
        return name.hasSuffix("." + DomainsConfig.proxyDomain)
    }

    public static func needsResolver(_ pattern: String) -> Bool {
        !isBelowProxyDomain(pattern)
    }

    /// The domain a resolver file covers: the name itself, or the part after `*.`.
    public static func resolverDomain(_ pattern: String) -> String {
        let name = normalize(pattern)
        return name.hasPrefix("*.") ? String(name.dropFirst(2)) : name
    }

    /// Turns a container name into a DNS label: `My_App` becomes `my-app`.
    public static func label(for containerName: String) -> String? {
        var out = ""
        for ch in containerName.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 63 { out = String(out.prefix(63)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }
}

/// Builds the route table from containers and aliases. Pure, unit tested.
public enum RoutePlanner {
    /// Port for a container: label, then first published TCP port, then the image's
    /// first exposed TCP port, then 80.
    public static func port(for container: ContainerSummary, exposed: [Int] = []) -> (port: Int, source: RouteSource) {
        if let raw = container.labels[DomainsConfig.portLabel],
           let port = Int(raw.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) {
            return (port, .label)
        }
        if let published = container.ports.first(where: { $0.proto.lowercased() == "tcp" }) {
            return (published.containerPort, .published)
        }
        if let port = exposed.first {
            return (port, .exposed)
        }
        return (DomainsConfig.fallbackPort, .fallback)
    }

    /// Reads "80/tcp" style image ports. UDP ports are dropped.
    public static func exposedTCPPorts(_ values: [String]) -> [Int] {
        values.compactMap { value in
            let parts = value.lowercased().split(separator: "/")
            guard let first = parts.first, let port = Int(first), (1...65535).contains(port) else { return nil }
            if parts.count > 1 && parts[1] != "tcp" { return nil }
            return port
        }
        .sorted()
    }

    /// Automatic routes for every container plus the aliases. Containers with
    /// `deck.route=false` and system containers like buildkit get no automatic route.
    public static func routes(
        containers: [ContainerSummary],
        aliases: [ProxyAlias] = [],
        exposedPorts: [String: [Int]] = [:],
        domain: String = DomainsConfig.proxyDomain
    ) -> [ProxyRoute] {
        var routes: [ProxyRoute] = []
        var taken = Set<String>()
        let ordered = containers.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name < rhs.name
        }
        for container in ordered {
            guard container.labels[DomainsConfig.routeLabel]?.lowercased() != "false" else { continue }
            guard !systemContainers.contains(container.name) else { continue }
            guard let label = HostName.label(for: container.name) else { continue }
            let host = "\(label).\(domain)"
            guard !taken.contains(host) else { continue }
            taken.insert(host)
            let pick = port(for: container, exposed: exposedPorts[container.image] ?? [])
            routes.append(ProxyRoute(
                host: host, container: container.name, targetHost: container.ipAddress,
                targetPort: pick.port, source: pick.source, isRunning: container.isRunning
            ))
        }
        for alias in aliases where !taken.contains(alias.pattern) {
            taken.insert(alias.pattern)
            let container = containers.first { $0.name == alias.container || $0.id == alias.container }
            let auto = container.map { port(for: $0, exposed: exposedPorts[$0.image] ?? []).port } ?? DomainsConfig.fallbackPort
            routes.append(ProxyRoute(
                host: alias.pattern, container: alias.container, targetHost: container?.ipAddress,
                targetPort: alias.port ?? auto, source: .alias, isRunning: container?.isRunning ?? false
            ))
        }
        return routes
    }

    /// Exact names win, then the longest wildcard.
    public static func match(host: String, in routes: [ProxyRoute]) -> ProxyRoute? {
        let host = HostName.normalize(host)
        if let exact = routes.first(where: { !$0.isWildcard && $0.host == host }) { return exact }
        return routes
            .filter { $0.isWildcard && HostName.matches(pattern: $0.host, host: host) }
            .max { $0.host.count < $1.host.count }
    }

    /// Containers Apple's tool runs for itself.
    static let systemContainers: Set<String> = ["buildkit"]
}

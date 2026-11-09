import Foundation

// Request payloads and reply decoding for the direct API.
//
// Replies are JSON written by Apple's daemon with a default JSONEncoder, so dates
// are seconds since 2001 and shapes are the daemon's own types. We do not keep a
// second copy of Apple's models. Each reply is reshaped into the JSON the CLI
// prints for the same thing (`container list --format json` and friends), then
// read by the forgiving `ContainerOutputParser`. One parser, two transports, and
// the UI sees the same models either way.

// MARK: - Requests

/// `ContainerListFilters`. Labels are regexes the daemon matches against label values.
struct APIListFilters: Encodable, Equatable {
    var ids: [String] = []
    /// `RuntimeStatus` raw value ("running", "stopped"). Left out when nil.
    var status: String?
    var labels: [String: String] = [:]

    /// What `container list` asks for: machines are left out, and from 1.7 on cluster nodes too
    /// (`ContainerPlatformFeatures.listHidesClusterNodes`). Pass the daemon's version.
    static func cliList(all: Bool, features: ContainerPlatformFeatures) -> APIListFilters {
        let exclude = features.listHidesClusterNodes ? APILabel.excludeMachinesAndClusterNodes : APILabel.excludeMachines
        return APIListFilters(status: all ? nil : "running", labels: [APILabel.plugin: exclude])
    }

    /// Every cluster node, running or not, like the cluster plugin lists them.
    static let clusterNodes = APIListFilters(labels: [APILabel.plugin: APILabel.onlyClusterNodes])
}

/// `ContainerStopOptions`.
struct APIStopOptions: Encodable, Equatable {
    var timeoutInSeconds: Int32
    var signal: String?

}

/// `NetworkConfiguration` as `container network create` encodes it.
struct APINetworkConfiguration: Encodable, Equatable {
    var name: String
    var creationDate: Date
    var mode: String
    var ipv4Subnet: String?
    var ipv6Subnet: String?
    var labels: [String: String]
    var plugin: String
    var options: [String: String]

    init(name: String, subnet: String?, subnetV6: String?, internal isInternal: Bool, labels: [String: String], now: Date = Date()) {
        self.name = name
        self.creationDate = now
        self.mode = isInternal ? "hostOnly" : "nat"
        self.ipv4Subnet = CLIText.nonEmpty(subnet)
        self.ipv6Subnet = CLIText.nonEmpty(subnetV6)
        self.labels = labels.filter { !$0.key.isEmpty }
        self.plugin = APILabel.defaultNetworkPlugin
        self.options = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case name, creationDate, mode, ipv4Subnet, ipv6Subnet, labels, plugin, options
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(creationDate, forKey: .creationDate)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(ipv4Subnet, forKey: .ipv4Subnet)
        try c.encodeIfPresent(ipv6Subnet, forKey: .ipv6Subnet)
        try c.encode(labels, forKey: .labels)
        try c.encode(plugin, forKey: .plugin)
        try c.encode(options, forKey: .options)
    }
}

// MARK: - Health

/// The `ping` reply.
public struct APIHealth: Sendable, Equatable {
    public var version: String
    public var commit: String
    public var build: String
    public var appName: String
    public var appRoot: String
    public var installRoot: String
    public var logRoot: String?

    public init(version: String, commit: String = "", build: String = "", appName: String = "", appRoot: String = "", installRoot: String = "", logRoot: String? = nil) {
        self.version = version
        self.commit = commit
        self.build = build
        self.appName = appName
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.logRoot = logRoot
    }

    public var semanticVersion: SemanticVersion? { SemanticVersion.firstMatch(in: version) }
}

// MARK: - Replies

enum APIDecode {
    /// Keys that hold dates in the daemon's JSON.
    static let dateKeys: Set<String> = ["creationDate", "startedDate", "createdAt", "modificationDate"]

    static func health(_ reply: XPCReply) throws -> APIHealth {
        guard let version = CLIText.nonEmpty(reply.string(APIKey.apiServerVersion)) else {
            throw APIError.malformedReply("ping \(APIKey.apiServerVersion)")
        }
        return APIHealth(
            version: version,
            commit: reply.string(APIKey.apiServerCommit) ?? "",
            build: reply.string(APIKey.apiServerBuild) ?? "",
            appName: reply.string(APIKey.apiServerAppName) ?? "",
            appRoot: path(reply.string(APIKey.appRoot)),
            installRoot: path(reply.string(APIKey.installRoot)),
            logRoot: CLIText.nonEmpty(path(reply.string(APIKey.logRoot)))
        )
    }

    /// The daemon sends roots as file URLs ("file:///usr/local/"). Plain paths pass through.
    static func path(_ text: String?) -> String {
        guard let text = CLIText.nonEmpty(text) else { return "" }
        if text.hasPrefix("file:"), let url = URL(string: text) { return url.path(percentEncoded: false) }
        return text
    }

    // MARK: Containers

    /// `[ContainerSnapshot]` from `containerList`, reshaped like `container list --format json`.
    static func containerListJSON(_ data: Data?) throws -> String {
        guard let data else { return "[]" }
        let snapshots = try jsonArray(data, what: "containerList")
        return try text(snapshots.map(managedContainer))
    }

    static func containers(_ data: Data?) throws -> [ContainerSummary] {
        try ContainerOutputParser.containers(containerListJSON(data))
    }

    static func containerDetails(_ data: Data?) throws -> [ContainerDetail] {
        try ContainerOutputParser.containerDetails(containerListJSON(data))
    }

    /// `{configuration, status: "running", networks, startedDate}` (snapshot) to
    /// `{id, configuration, status: {state, networks, startedDate}}` (what the CLI prints).
    /// The state stays text, so a state this app does not know reads as unknown.
    static func managedContainer(_ value: Any) -> Any {
        guard var snapshot = value as? [String: Any] else { return value }
        snapshot = withISODates(snapshot) as? [String: Any] ?? snapshot
        if snapshot["status"] is [String: Any] { return snapshot }   // already the new shape
        var status: [String: Any] = [:]
        if let state = snapshot["status"] { status["state"] = state }
        if let networks = snapshot["networks"] { status["networks"] = networks }
        if let started = snapshot["startedDate"] { status["startedDate"] = started }
        var result: [String: Any] = [:]
        if let configuration = snapshot["configuration"] {
            result["configuration"] = configuration
            if let id = (configuration as? [String: Any])?["id"] { result["id"] = id }
        }
        result["status"] = status
        return result
    }

    static func stats(_ data: Data?, cache: CPUSampleCache, now: Date = Date()) throws -> [ContainerStats] {
        guard let data else { throw APIError.malformedReply("containerStats \(APIKey.statistics)") }
        guard let text = String(data: data, encoding: .utf8) else { throw APIError.malformedReply("containerStats") }
        do {
            return try ContainerOutputParser.stats(text, cache: cache, now: now)
        } catch {
            throw APIError.malformedReply("containerStats")
        }
    }

    // MARK: Volumes, networks, disk usage

    /// `[VolumeConfiguration]` to `[{id, configuration}]` like `container volume list --format json`.
    static func volumes(_ data: Data?) throws -> [VolumeSummary] {
        guard let data else { return [] }
        let items = try jsonArray(data, what: "volumeList").map { item -> Any in
            guard let config = withISODates(item) as? [String: Any] else { return item }
            var wrapped: [String: Any] = ["configuration": config]
            if let name = config["name"] { wrapped["id"] = name }
            return wrapped
        }
        return try parse("volumeList") { try ContainerOutputParser.volumes(try text(items)) }
    }

    /// `[NetworkResource]` is already `{id, configuration, status}`.
    static func networks(_ data: Data?) throws -> [NetworkSummary] {
        guard let data else { return [] }
        let items = try jsonArray(data, what: "networkList").map(withISODates)
        return try parse("networkList") { try ContainerOutputParser.networks(try text(items)) }
    }

    static func diskUsage(_ data: Data?) throws -> DiskUsage {
        guard let data, let text = String(data: data, encoding: .utf8) else {
            throw APIError.malformedReply("systemDiskUsage \(APIKey.diskUsageStats)")
        }
        return try parse("systemDiskUsage") { try ContainerOutputParser.diskUsage(text) }
    }

    // MARK: Helpers

    static func jsonArray(_ data: Data, what: String) throws -> [Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw APIError.malformedReply(what)
        }
        if let list = root as? [Any] { return list }
        if root is NSNull { return [] }
        throw APIError.malformedReply(what)
    }

    static func jsonObject(_ data: Data, what: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.malformedReply(what)
        }
        return object
    }

    static func text(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            throw APIError.malformedReply("JSON")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse<T>(_ what: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.malformedReply(what)
        }
    }

    /// Date numbers (seconds since 2001, Swift's default) become ISO 8601 text with
    /// fractional seconds, the way the CLI prints them, so every date is read the same.
    static func withISODates(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            for (key, inner) in object {
                if dateKeys.contains(key), let number = inner as? NSNumber, !isBool(number) {
                    object[key] = isoDate(sinceReferenceDate: number.doubleValue)
                } else {
                    object[key] = withISODates(inner)
                }
            }
            return object
        }
        if let list = value as? [Any] {
            return list.map(withISODates)
        }
        return value
    }

    static func isoDate(sinceReferenceDate seconds: Double) -> String {
        isoFormatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
    }

    /// Made once: building a formatter costs more than using it, and lists are read every second.
    /// ISO8601DateFormatter is safe to share between threads once configured.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

// MARK: - Image references

/// Image reference rules from Apple's `Reference.parse` and `normalize()`
/// (containerization), used to find an image by the name a person typed.
enum APIImageReference {
    static let dockerHosts: Set<String> = ["docker.io", "registry-1.docker.io"]
    /// Compiled once. NSRegularExpression is immutable and safe to share.
    nonisolated(unsafe) private static let pathTagRegex = try? NSRegularExpression(pattern: pathTagPattern)
    private static let pathTagPattern = #"^((?:[a-z0-9]+(?:[._]|__|-|/)?)*[a-z0-9]+)(?::([\w][\w.-]{0,127}))?(?:@(sha256:[0-9a-fA-F]{64}))?$"#

    /// "nginx" to "docker.io/library/nginx:latest". nil when the text is not a valid reference.
    static func normalize(_ reference: String, defaultDomain: String = "docker.io") -> String? {
        let text = reference.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 255 else { return nil }
        var domain: String?
        var remainder = text
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].hasPrefix("localhost") || parts[0].contains(".") || parts[0].contains(":") {
            domain = parts[0]
            remainder = parts[1]
        } else if parts.count < 2, text.hasPrefix("localhost") {
            return nil
        }
        guard let regex = pathTagRegex else { return nil }
        let ns = remainder as NSString
        guard let match = regex.firstMatch(in: remainder, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        guard var path = group(1) else { return nil }
        let tag = group(2)
        let digest = group(3)
        let host = domain ?? defaultDomain
        if dockerHosts.contains(host), !path.contains("/") {
            path = "library/" + path
        }
        let name = "\(host)/\(path)"
        if let digest { return "\(name)@\(digest)" }
        return "\(name):\(tag ?? "latest")"
    }
}

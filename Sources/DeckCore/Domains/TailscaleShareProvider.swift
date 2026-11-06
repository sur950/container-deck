import Foundation

/// Tailscale Funnel: `tailscale funnel --https=<443|8443|10000> http://127.0.0.1:<published port>`.
///
/// Runs in the foreground on purpose. Tailscale removes a foreground funnel by itself when the
/// command ends, so the link dies with the app, and funnels the person set up are never touched.
/// Before starting we read `tailscale status --json` (signed in, HTTPS on, version) and
/// `tailscale funnel status --json` (ports in use) and take a free Funnel port.
public struct TailscaleFunnelProvider: ShareProvider {
    public init() {}

    public let id = "tailscale"
    public let title = "Tailscale Funnel"
    public let summary = "Shares a published port on your tailnet name."
    public let binaryName = "tailscale"

    static let admin = "https://login.tailscale.com/admin"

    /// Homebrew or /usr/local first (the open source CLI, or the one the app installs), then
    /// the CLI inside Tailscale.app (Mac App Store and Standalone builds).
    public func candidatePaths(searchPaths: [String], toolsDirectory: String, includeAppBundle: Bool) -> [String] {
        searchPaths.map { "\($0)/\(binaryName)" } + (includeAppBundle ? [DomainsConfig.tailscaleAppBinary] : [])
    }

    public var installOptions: [ShareInstallOption] {
        [.webPage(URL(string: DomainsConfig.tailscaleDownloadPage)!)]
    }

    public var setupLink: URL? { URL(string: DomainsConfig.tailscaleFunnelDocs) }

    public func readiness(executable: String, context: ShareContext) async -> ShareReadiness {
        do {
            let status = try await status(executable, context: context)
            if let failure = status.blockingFailure { return .needsSetup(failure) }
            if status.funnelAllowed == false {
                return .needsSetup(ShareFailure(.notAllowed, "Funnel is not allowed yet.",
                                                fix: "Share once and Tailscale gives you a link to allow it.",
                                                link: URL(string: "\(Self.admin)/acls/file")))
            }
            return .ready(detail: status.dnsName.map { "Shares as \($0)." } ?? "Signed in.")
        } catch let failure as ShareFailure {
            return .needsSetup(failure)
        } catch {
            return .needsSetup(ShareFailure(.notRunning, "Tailscale did not answer.", fix: "Open the Tailscale app, then try again."))
        }
    }

    public func blocker(for route: ProxyRoute, publishedPort: Int?) -> ShareFailure? {
        guard route.isReachable, !route.isWildcard else { return .containerStopped(route.container) }
        guard publishedPort != nil else {
            return ShareFailure(.needsPublishedPort, "Funnel only shares ports on this Mac.",
                                fix: "Publish a port for \(route.container), like -p 8080:80.")
        }
        return nil
    }

    public func arguments(funnelPort: Int, publishedPort: Int) -> [String] {
        ["funnel", "--https=\(funnelPort)", TailscaleFunnelPlanner.target(publishedPort: publishedPort)]
    }

    public func prepare(route: ProxyRoute, publishedPort: Int?, executable: String, context: ShareContext,
                        reservedPorts: Set<Int>) async throws -> ShareLaunch {
        if let blocker = blocker(for: route, publishedPort: publishedPort) { throw blocker }
        let published = publishedPort ?? 0
        let status = try await status(executable, context: context)
        if let failure = status.blockingFailure { throw failure }
        let config = await funnelConfig(executable, context: context) ?? FunnelServeConfig()
        let port = try TailscaleFunnelPlanner.choosePort(status: status, config: config, reserved: reservedPorts)
        return ShareLaunch(
            providerID: id, executable: executable,
            arguments: arguments(funnelPort: port, publishedPort: published),
            reservedPort: port,
            target: TailscaleFunnelPlanner.target(publishedPort: published),
            publicHost: status.dnsName,
            expectedURL: status.dnsName.map { TailscaleFunnelPlanner.publicURL(dnsName: $0, port: port) }
        )
    }

    public func publicURL(in output: String, launch: ShareLaunch?) -> String? {
        guard let marker = output.range(of: "Available on the internet:") else { return nil }
        let rest = String(output[marker.upperBound...])
        if let range = rest.range(of: #"https://[A-Za-z0-9.-]+(:\d+)?/?"#, options: .regularExpression) { return String(rest[range]) }
        return launch?.expectedURL
    }

    /// Funnel not turned on: the CLI prints a link and waits for it.
    public func earlyFailure(in output: String) -> ShareFailure? {
        output.contains("login.tailscale.com/f/") ? classify(output) : nil
    }

    public func classify(_ output: String) -> ShareFailure? {
        if let range = output.range(of: #"https://login\.tailscale\.com/f/[^\s"]+"#, options: .regularExpression) {
            let url = URL(string: String(output[range]))
            if output.contains("does not include the one you are using") {
                return ShareFailure(.notAllowed, "Your tailnet policy does not allow Funnel on this Mac.",
                                    fix: "Open the link to allow it, then share again.", link: url)
            }
            return ShareFailure(.notAllowed, "Funnel is not turned on for your tailnet.",
                                fix: "Open the link to turn it on, then share again.", link: url)
        }
        if output.contains("HTTPS must be enabled") {
            return ShareFailure(.notAllowed, "HTTPS certificates are off in your tailnet.",
                                fix: "Turn on HTTPS on the DNS page of the admin console.", link: URL(string: "\(Self.admin)/dns"))
        }
        if output.contains("node attribute not set") {
            return ShareFailure(.notAllowed, "Your tailnet policy does not allow Funnel on this Mac.",
                                fix: "Add the funnel node attribute in Access controls.", link: URL(string: "\(Self.admin)/acls/file"))
        }
        if let port = Self.firstMatch(#"port (\d+) is not allowed for funnel"#, in: output) {
            return ShareFailure(.notAllowed, "Your tailnet does not allow Funnel on port \(port).",
                                fix: "Allow 443, 8443 or 10000 for Funnel in Access controls.", link: URL(string: "\(Self.admin)/acls/file"))
        }
        if let port = Self.firstMatch(#"listener already exists for port (\d+)"#, in: output) {
            return ShareFailure(.busy, "Port \(port) on your tailnet name is already shared.",
                                fix: "Stop the other share or funnel on that port, then try again.")
        }
        if output.contains("already serving TCP") || output.contains("Another client is changing the serve config") {
            return ShareFailure(.busy, "Another Tailscale share is changing at the same time.", fix: "Try again in a moment.")
        }
        if output.contains("Failed to connect to local Tailscale daemon") || output.contains("failed to connect to local tailscaled")
            || output.contains("doesn't appear to be running") {
            return ShareFailure(.notRunning, "Tailscale is not running.", fix: "Open the Tailscale app, then try again.")
        }
        if output.contains("Logged out.") {
            return ShareFailure(.needsSetup, "Sign in to Tailscale first.", fix: "Open Tailscale and sign in, then try again.")
        }
        if output.contains("Tailscale is stopped.") {
            return ShareFailure(.notRunning, "Tailscale is turned off.", fix: "Connect in the Tailscale menu, then try again.")
        }
        if output.contains("not yet approved by tailnet admin") {
            return ShareFailure(.notAllowed, "This Mac waits for approval in your tailnet.",
                                fix: "Ask your tailnet admin to approve it.", link: URL(string: "\(Self.admin)/machines"))
        }
        if output.contains("the CLI for serve and funnel has changed") || output.contains("flag provided but not defined") {
            return Self.outdated
        }
        return nil
    }

    static let outdated = ShareFailure(.outdated, "This Tailscale is too old for Funnel.",
                                       fix: "Update Tailscale to \(TailscaleStatus.minimumVersion) or later.",
                                       link: URL(string: DomainsConfig.tailscaleDownloadPage))

    /// If our exact funnel (our port, our target) is still in the background config after the
    /// share ended, turn off that one port. Nothing else is changed, and `reset` is never used.
    @discardableResult
    public func cleanUp(after launch: ShareLaunch, context: ShareContext) async -> Bool {
        guard let port = launch.reservedPort, let target = launch.target, let host = launch.publicHost,
              let config = await funnelConfig(launch.executable, context: context),
              config.backgroundProxy(host: host, port: port) == target else { return false }
        let result = try? await context.call(launch.executable, ["funnel", "--https=\(port)", "off"])
        return result?.succeeded == true
    }

    // MARK: CLI reads

    public func status(_ executable: String, context: ShareContext) async throws -> TailscaleStatus {
        let result: CommandResult
        do {
            result = try await context.call(executable, ["status", "--json"])
        } catch let failure as ShareFailure {
            throw failure
        } catch {
            throw ShareFailure(.notRunning, "Tailscale did not answer.", fix: "Open the Tailscale app, then try again.")
        }
        if let status = TailscaleStatus.parse(Data(result.stdout.utf8)) { return status }
        throw classify(result.stderr + "\n" + result.stdout)
            ?? ShareFailure(.notRunning, "Tailscale did not answer.", fix: "Open the Tailscale app, then try again.")
    }

    public func funnelConfig(_ executable: String, context: ShareContext) async -> FunnelServeConfig? {
        guard let result = try? await context.call(executable, ["funnel", "status", "--json"]), result.succeeded else { return nil }
        return FunnelServeConfig.parse(Data(result.stdout.utf8))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// The parts of `tailscale status --json` we use.
public struct TailscaleStatus: Decodable, Sendable, Equatable {
    /// `tailscale funnel --https=<port> <target>` came in 1.52.
    public static let minimumVersion = "1.52"

    public struct Node: Decodable, Sendable, Equatable {
        public var DNSName: String?
        public var CapMap: [String: Ignored]?
        public var Capabilities: [String]?
    }

    public struct Tailnet: Decodable, Sendable, Equatable {
        public var Name: String?
        public var MagicDNSSuffix: String?
        public var MagicDNSEnabled: Bool?
    }

    /// A JSON value we skip.
    public struct Ignored: Decodable, Sendable, Equatable {
        public init(from decoder: Decoder) throws {}
    }

    public var Version: String?
    public var BackendState: String
    public var AuthURL: String?
    public var node: Node?
    public var CurrentTailnet: Tailnet?

    enum CodingKeys: String, CodingKey {
        case Version, BackendState, AuthURL, CurrentTailnet
        case node = "Self"
    }

    public static func parse(_ data: Data) -> TailscaleStatus? {
        try? JSONDecoder().decode(TailscaleStatus.self, from: data)
    }

    public var dnsName: String? {
        guard var name = node?.DNSName, !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    private var capabilities: Set<String> {
        Set((node?.CapMap.map { Array($0.keys) } ?? []) + (node?.Capabilities ?? []))
    }

    /// Nil when this client does not list capabilities, so we cannot tell.
    public var httpsEnabled: Bool? { capabilities.isEmpty ? nil : capabilities.contains("https") }
    public var funnelAllowed: Bool? { capabilities.isEmpty ? nil : capabilities.contains("funnel") }

    /// Funnel ports the tailnet allows. 443, 8443 and 10000 unless the policy narrows them.
    public var funnelPorts: [Int] {
        let prefix = "https://tailscale.com/cap/funnel-ports?ports="
        let defaults = DomainsConfig.funnelPorts
        guard let attr = capabilities.first(where: { $0.hasPrefix(prefix) }) else { return defaults }
        var ports: [Int] = []
        for part in attr.dropFirst(prefix.count).split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1 { ports.append(bounds[0]) }
            if bounds.count == 2, bounds[0] <= bounds[1] { ports += defaults.filter { (bounds[0]...bounds[1]).contains($0) } }
        }
        let allowed = defaults.filter(ports.contains)
        return allowed.isEmpty ? defaults : allowed
    }

    public var isOutdated: Bool {
        guard let text = Version, let version = SemanticVersion.firstMatch(in: text),
              let minimum = SemanticVersion.firstMatch(in: TailscaleStatus.minimumVersion) else { return false }
        return version < minimum
    }

    /// Problems that stop any share, read from the status alone.
    public var blockingFailure: ShareFailure? {
        let provider = TailscaleFunnelProvider()
        switch BackendState {
        case "NeedsLogin":
            return ShareFailure(.needsSetup, "Sign in to Tailscale first.", fix: "Open Tailscale and sign in, then try again.",
                                link: AuthURL.flatMap { $0.isEmpty ? nil : URL(string: $0) })
        case "Stopped":
            return provider.classify("Tailscale is stopped.")
        case "NeedsMachineAuth":
            return provider.classify("not yet approved by tailnet admin")
        case "NoState":
            return provider.classify("Failed to connect to local Tailscale daemon")
        default:
            break
        }
        if isOutdated { return TailscaleFunnelProvider.outdated }
        if httpsEnabled == false { return provider.classify("HTTPS must be enabled") }
        return nil
    }
}

/// `tailscale funnel status --json`: the serve config, the background part plus foreground sessions.
public struct FunnelServeConfig: Decodable, Sendable, Equatable {
    public struct TCPHandler: Decodable, Sendable, Equatable {
        public var HTTPS: Bool?
        public var HTTP: Bool?
        public var TCPForward: String?
    }
    public struct WebServer: Decodable, Sendable, Equatable {
        public var Handlers: [String: Handler]?
    }
    public struct Handler: Decodable, Sendable, Equatable {
        public var Proxy: String?
        public var Path: String?
        public var Text: String?
    }

    public var TCP: [String: TCPHandler]?
    public var Web: [String: WebServer]?
    public var AllowFunnel: [String: Bool]?
    public var Foreground: [String: FunnelServeConfig]?

    public init() {}

    public static func parse(_ data: Data) -> FunnelServeConfig? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "null" || text == "{}" { return FunnelServeConfig() }
        return try? JSONDecoder().decode(FunnelServeConfig.self, from: data)
    }

    /// Ports served or funneled by anyone, in the background or in a foreground session.
    public var usedPorts: Set<Int> {
        var ports = Set((TCP ?? [:]).keys.compactMap { Int($0) })
        for key in (Web ?? [:]).keys {
            if let port = key.split(separator: ":").last.flatMap({ Int($0) }) { ports.insert(port) }
        }
        for session in (Foreground ?? [:]).values { ports.formUnion(session.usedPorts) }
        return ports
    }

    /// The proxy target on `/` for one host and port, background config only.
    public func backgroundProxy(host: String, port: Int) -> String? {
        Web?["\(host):\(port)"]?.Handlers?["/"]?.Proxy
    }
}

public enum TailscaleFunnelPlanner {
    /// First Funnel port nobody uses. Never takes a port another funnel or serve has.
    public static func choosePort(status: TailscaleStatus, config: FunnelServeConfig, reserved: Set<Int> = []) throws -> Int {
        let used = config.usedPorts.union(reserved)
        if let port = status.funnelPorts.first(where: { !used.contains($0) }) { return port }
        let list = status.funnelPorts.map(String.init).joined(separator: ", ")
        throw ShareFailure(.busy, "Every Funnel port on this Mac is in use (\(list)).",
                           fix: "Stop a share, or turn off a funnel you set up yourself, then try again.")
    }

    public static func publicURL(dnsName: String, port: Int) -> String {
        port == 443 ? "https://\(dnsName)/" : "https://\(dnsName):\(port)/"
    }

    /// Funnel only proxies to this Mac.
    public static func target(publishedPort: Int) -> String { "http://127.0.0.1:\(publishedPort)" }
}

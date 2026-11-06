import Foundation

/// How a call reaches Apple's container services.
public enum ContainerBackend: String, Sendable, Hashable {
    /// XPC straight to the daemon (`DirectAPIClient`).
    case directAPI
    /// The `container` command line tool (`ContainerClient`).
    case cli

    public var displayName: String {
        switch self {
        case .directAPI: return "Direct API"
        case .cli: return "Command line"
        }
    }
}

/// Groups of calls that fall back together. Two failures in a row in one family
/// move only that family to the CLI.
public enum OperationFamily: String, Sendable, Hashable, CaseIterable, Comparable {
    case containerList, containerLifecycle, stats, logs, images, volumes, networks, system

    public static func < (lhs: OperationFamily, rhs: OperationFamily) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    /// Plain words for Settings.
    public var displayName: String {
        switch self {
        case .containerList: return "container lists"
        case .containerLifecycle: return "start and stop"
        case .stats: return "stats"
        case .logs: return "logs"
        case .images: return "images"
        case .volumes: return "volumes"
        case .networks: return "networks"
        case .system: return "disk use"
        }
    }
}

/// Read only status for Settings, Platform.
public struct BackendStatus: Sendable, Equatable {
    public enum Service: String, Sendable {
        case running, stopped, notAnswering, unknown
    }

    /// What calls use right now (families moved to the CLI are listed in `cliFamilies`).
    public var backend: ContainerBackend
    public var service: Service
    /// `apiServerVersion` from the last ping.
    public var daemonVersion: String?
    public var versionSupported: Bool
    public var forcedCLI: Bool
    /// Families that failed twice in a row and use the CLI for this session.
    public var cliFamilies: [OperationFamily]
    /// Calls that failed on the direct API and were done through the CLI.
    public var fallbackCounts: [OperationFamily: Int]

    public init(backend: ContainerBackend, service: Service, daemonVersion: String? = nil, versionSupported: Bool = false,
                forcedCLI: Bool = false, cliFamilies: [OperationFamily] = [], fallbackCounts: [OperationFamily: Int] = [:]) {
        self.backend = backend
        self.service = service
        self.daemonVersion = daemonVersion
        self.versionSupported = versionSupported
        self.forcedCLI = forcedCLI
        self.cliFamilies = cliFamilies
        self.fallbackCounts = fallbackCounts
    }

    public var totalFallbacks: Int { fallbackCounts.values.reduce(0, +) }

    /// True when calls in `family` go straight to the daemon right now.
    public func isDirect(_ family: OperationFamily) -> Bool {
        backend == .directAPI && !cliFamilies.contains(family)
    }

    /// One line for Settings, Platform. Short, plain words.
    public var summary: String {
        let version = daemonVersion.map { " (container \($0))" } ?? ""
        let command = "Uses the container command"
        if forcedCLI { return "\(command) (chosen in Settings)" }
        switch service {
        case .stopped: return "The container services are not running"
        case .notAnswering: return "\(command) (the service did not answer)"
        case .unknown: return "Not checked yet"
        case .running: break
        }
        if !versionSupported {
            return "\(command) (container \(daemonVersion ?? "version") is not tested yet)"
        }
        if backend == .cli { return "\(command) (direct calls failed)" }
        var text = "Talks to Apple's container service directly\(version)"
        if !cliFamilies.isEmpty {
            text += ". Uses the container command for \(cliFamilies.map(\.displayName).joined(separator: ", "))"
        }
        if totalFallbacks > 0 {
            text += ". \(totalFallbacks) " + (totalFallbacks == 1 ? "call" : "calls") + " used the container command"
        }
        return text
    }
}

/// Picks the backend per call.
///
/// - `forceCLI` (UserDefaults "forceCLIBackend") sends everything to the CLI.
/// - Otherwise the daemon is pinged (2 s limit). The answer is reused for
///   `recheckInterval`, and a ping runs again after any connection problem.
/// - A daemon version outside `supportedVersions` uses the CLI.
/// - Two direct failures in a row in one family, while ping still works, move that
///   family to the CLI for the session. A new daemon version clears this.
/// - A daemon that is not running is reported as stopped. That is not a reason to
///   use the CLI (it cannot reach a stopped daemon either) and is not counted.
public actor BackendSelector {
    public enum Decision: Equatable, Sendable {
        case direct
        case cli
        case serviceStopped
    }

    public typealias Ping = @Sendable (Duration) async throws -> String

    private let ping: Ping
    private let supportedVersions: Range<SemanticVersion>
    private let forceCLI: @Sendable () -> Bool
    private let failureLimit: Int
    private let recheckInterval: TimeInterval
    private let pingTimeout: Duration
    private let now: @Sendable () -> Date

    private var service: BackendStatus.Service = .unknown
    private var version: String?
    private var lastPing: Date?
    private var inFlight: Task<Void, Never>?
    private var consecutiveFailures: [OperationFamily: Int] = [:]
    private var fallbackCounts: [OperationFamily: Int] = [:]
    private var cliFamilies: Set<OperationFamily> = []

    public init(
        ping: @escaping Ping,
        supportedVersions: Range<SemanticVersion> = AppConfig.apiSupportedVersions,
        forceCLI: @escaping @Sendable () -> Bool = BackendSelector.userDefaultsForceCLI,
        failureLimit: Int = 2,
        recheckInterval: TimeInterval = 30,
        pingTimeout: Duration = APITimeouts.ping,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ping = ping
        self.supportedVersions = supportedVersions
        self.forceCLI = forceCLI
        self.failureLimit = failureLimit
        self.recheckInterval = recheckInterval
        self.pingTimeout = pingTimeout
        self.now = now
    }

    /// Pings the daemon through a direct client.
    public init(client: DirectAPIClient, supportedVersions: Range<SemanticVersion> = AppConfig.apiSupportedVersions,
                forceCLI: @escaping @Sendable () -> Bool = BackendSelector.userDefaultsForceCLI) {
        self.init(ping: { timeout in try await client.ping(timeout: timeout).version },
                  supportedVersions: supportedVersions, forceCLI: forceCLI)
    }

    /// Reads the support switch each time, so turning it on or off applies at once.
    public static let userDefaultsForceCLI: @Sendable () -> Bool = {
        forceCLI(in: .standard)
    }

    /// The support switch as stored in `defaults`. Tests pass their own suite.
    public static func forceCLI(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: AppConfig.forceCLIBackendKey)
    }

    /// The support switch is on.
    public nonisolated var forcesCLI: Bool { forceCLI() }

    // MARK: Decisions

    public func decision(for family: OperationFamily) async -> Decision {
        if forceCLI() { return .cli }
        await refreshIfNeeded()
        switch service {
        case .stopped: return .serviceStopped
        case .notAnswering, .unknown: return .cli
        case .running: break
        }
        guard isSupported(version) else { return .cli }
        return cliFamilies.contains(family) ? .cli : .direct
    }

    public func recordSuccess(_ family: OperationFamily) {
        consecutiveFailures[family] = 0
    }

    /// A direct call failed on the transport and was retried through the CLI.
    public func recordFailure(_ family: OperationFamily) async {
        fallbackCounts[family, default: 0] += 1
        consecutiveFailures[family, default: 0] += 1
        // Something went wrong: check the daemon again on the next call.
        lastPing = nil
        guard consecutiveFailures[family, default: 0] >= failureLimit else { return }
        // Only give up on the family when the daemon itself still answers.
        await refresh()
        if service == .running {
            cliFamilies.insert(family)
        }
    }

    /// A direct call found no service. Pings again and says whether it is really stopped.
    public func confirmServiceStopped() async -> Bool {
        await refresh()
        return service == .stopped
    }

    /// The connection dropped (daemon restart, maybe a new version). Ping on the next call.
    public func connectionChanged() {
        lastPing = nil
    }

    /// Pings now.
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.runPing() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    public func status() -> BackendStatus {
        let forced = forceCLI()
        let supported = isSupported(version)
        let usesDirect = !forced && service == .running && supported && cliFamilies.count < OperationFamily.allCases.count
        return BackendStatus(
            backend: usesDirect ? .directAPI : .cli,
            service: service,
            daemonVersion: version,
            versionSupported: supported,
            forcedCLI: forced,
            cliFamilies: cliFamilies.sorted(),
            fallbackCounts: fallbackCounts
        )
    }

    // MARK: Ping

    private func refreshIfNeeded() async {
        // A stopped or silent daemon is checked on every call (a ping fails in about a millisecond).
        if service == .running, let lastPing, now().timeIntervalSince(lastPing) < recheckInterval { return }
        await refresh()
    }

    private func runPing() async {
        do {
            let answer = try await ping(pingTimeout)
            if answer != version {
                // New daemon version: earlier failures may not apply any more.
                consecutiveFailures.removeAll()
                cliFamilies.removeAll()
            }
            version = answer
            service = .running
        } catch let error as APIError {
            if case .serviceUnavailable = error {
                service = .stopped
            } else {
                service = .notAnswering
            }
        } catch {
            service = .notAnswering
        }
        lastPing = now()
    }

    private func isSupported(_ version: String?) -> Bool {
        guard let version, let parsed = SemanticVersion.firstMatch(in: version) else { return false }
        return supportedVersions.contains(parsed)
    }
}

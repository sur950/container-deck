import Foundation

// Starting and stopping another engine so its images can be imported while it is stopped.
//
// Every engine keeps its images inside a Linux VM disk (ext4, btrfs or xfs) that macOS
// cannot read, so we cannot read them from disk. Instead we start the engine headless,
// use its own API to list and export, and stop it again, but only when we started it.
// See docs/ARCHITECTURE.md, Engine Import.

/// One command line, for example `orbctl start`.
public struct EngineCommand: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// For logs and command hints.
    public var commandLine: String {
        ([executable] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// Engines we know how to start and stop.
public enum EngineFamily: Sendable, Hashable {
    case dockerDesktop
    case orbStack
    case rancherDesktop
    case podman(machine: String)
    case colima(profile: String)

    public var title: String {
        switch self {
        case .dockerDesktop: return "Docker Desktop"
        case .orbStack: return "OrbStack"
        case .rancherDesktop: return "Rancher Desktop"
        case .podman(let machine):
            return machine == EngineControlPlanner.defaultPodmanMachine ? "Podman" : "Podman (\(machine))"
        case .colima(let profile):
            return profile == "default" ? "Colima" : "Colima (\(profile))"
        }
    }

    /// True when a detected engine belongs to this family.
    public func matches(_ engine: DetectedEngine) -> Bool {
        switch self {
        case .dockerDesktop: return engine.kind == .dockerDesktop
        case .orbStack: return engine.kind == .orbStack
        case .rancherDesktop: return engine.kind == .rancherDesktop || engine.kind == .rancherContainerd
        case .podman: return engine.kind == .podman
        case .colima(let profile):
            guard engine.kind == .colima else { return false }
            return EngineControlPlanner.colimaProfile(of: engine) == profile
        }
    }
}

/// What to run to bring one engine up and down again. Pure data, built by EngineControlPlanner.
public struct EngineControlPlan: Sendable, Hashable {
    public var family: EngineFamily
    /// Run in order. The engine may still be booting when they return.
    public var start: [EngineCommand]
    /// Run before `stop`, only when we started the engine. Undoes setting changes the start made.
    public var beforeStop: [EngineCommand]
    public var stop: [EngineCommand]
    /// Exits 0 while the engine runs, non zero once it is stopped. Used to confirm a stop,
    /// because touching the docker socket while OrbStack shuts down starts it again.
    public var status: EngineCommand?
    /// Says when the engine has finished starting. Its output must contain one of
    /// `readyMarkers`. Stopping an engine that is still starting does not stick.
    public var ready: EngineCommand?
    public var readyMarkers: [String]
    /// Extended regex for `pgrep -f`. When the engine's app was not running before we
    /// started the engine, we quit the app after the stop so nothing is left behind.
    public var appProcessPattern: String?
    /// Seconds to wait for the engine to answer after start.
    public var startTimeout: TimeInterval
    /// Seconds to wait for the engine to go away after stop.
    public var stopTimeout: TimeInterval
    /// Seconds between checks while waiting.
    public var pollInterval: TimeInterval
    /// Seconds the engine must have been up before we stop it. OrbStack treats a stop
    /// during its first seconds as a crash and starts itself again.
    public var minimumUptime: TimeInterval
    /// Seconds to wait after a stop before checking that it stayed stopped.
    public var settleTime: TimeInterval

    public init(
        family: EngineFamily, start: [EngineCommand], beforeStop: [EngineCommand] = [], stop: [EngineCommand],
        status: EngineCommand? = nil, ready: EngineCommand? = nil, readyMarkers: [String] = [], appProcessPattern: String? = nil, startTimeout: TimeInterval, stopTimeout: TimeInterval = 120,
        pollInterval: TimeInterval = 2, minimumUptime: TimeInterval = 0, settleTime: TimeInterval? = nil
    ) {
        self.family = family
        self.start = start
        self.beforeStop = beforeStop
        self.stop = stop
        self.status = status
        self.ready = ready
        self.readyMarkers = readyMarkers
        self.appProcessPattern = appProcessPattern
        self.startTimeout = startTimeout
        self.stopTimeout = stopTimeout
        self.pollInterval = pollInterval
        self.minimumUptime = minimumUptime
        self.settleTime = settleTime ?? pollInterval
    }

    public var name: String { family.title }

    public static let pgrep = "/usr/bin/pgrep"
    public static let pkill = "/usr/bin/pkill"

    /// Stops the engine without async, for app quit. Best effort, waits up to `limit` seconds.
    public func stopBlocking(limit: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(limit)
        for command in beforeStop + stop {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning { process.terminate() }
        }
    }
}

/// Builds start and stop plans from what is installed on this Mac. Pure apart from file reads.
public struct EngineControlPlanner: Sendable {
    public static let defaultPodmanMachine = "podman-machine-default"

    let env: EngineEnvironment

    public init(environment: EngineEnvironment = .live()) {
        self.env = environment
    }

    // MARK: Binaries

    var orbctlPaths: [String] {
        ["/usr/local/bin/orbctl", "/opt/homebrew/bin/orbctl", env.home + "/.orbstack/bin/orbctl",
         "/Applications/OrbStack.app/Contents/MacOS/bin/orbctl"]
    }

    var rdctlPaths: [String] {
        [env.home + "/.rd/bin/rdctl", "/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/bin/rdctl"]
    }

    /// The docker CLI inside Docker Desktop comes first, it always has the `desktop` plugin.
    var dockerPaths: [String] {
        ["/Applications/Docker.app/Contents/Resources/bin/docker", "/usr/local/bin/docker", env.home + "/.docker/bin/docker"]
    }

    /// Only real Colima installs. Wrappers in ~/.local/bin are skipped on purpose.
    var colimaPaths: [String] { ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"] }

    func firstExecutable(_ paths: [String]) -> String? {
        paths.first(where: env.files.isExecutable)
    }

    public var rancherSettingsPath: String {
        env.home + "/Library/Preferences/rancher-desktop/settings.json"
    }

    // MARK: Family

    /// Which family a stopped (or running) engine belongs to. nil for Lima and unknown engines.
    public func family(for engine: DetectedEngine) -> EngineFamily? {
        switch engine.kind {
        case .dockerDesktop: return .dockerDesktop
        case .orbStack: return .orbStack
        case .rancherDesktop, .rancherContainerd: return .rancherDesktop
        case .podman:
            if let connection = engine.podmanConnection, !connection.isEmpty { return .podman(machine: connection) }
            if engine.id.hasPrefix("podman-machine:") {
                return .podman(machine: String(engine.id.dropFirst("podman-machine:".count)))
            }
            return .podman(machine: Self.defaultPodmanMachine)
        case .colima: return .colima(profile: Self.colimaProfile(of: engine))
        case .lima, .other: return nil
        }
    }

    /// "default" for "Colima", "work" for "Colima (work)" or a ~/.colima/work/docker.sock socket.
    public static func colimaProfile(of engine: DetectedEngine) -> String {
        if case .dockerSocket(let path)? = engine.endpoint, let range = path.range(of: "/.colima/") {
            let rest = path[range.upperBound...]
            if let profile = rest.split(separator: "/").first, !profile.isEmpty { return String(profile) }
        }
        if let open = engine.name.firstIndex(of: "("), let close = engine.name.lastIndex(of: ")"), open < close {
            return String(engine.name[engine.name.index(after: open)..<close])
        }
        return "default"
    }

    // MARK: Plans

    /// How to start and stop this engine, or nil when we cannot (not installed or unsupported).
    public func plan(for engine: DetectedEngine) -> EngineControlPlan? {
        guard engine.state != .notFound, let family = family(for: engine) else { return nil }
        return plan(for: family, podmanBinary: engine.podmanBinary)
    }

    public func plan(for family: EngineFamily, podmanBinary: String? = nil) -> EngineControlPlan? {
        switch family {
        case .orbStack:
            guard let orbctl = firstExecutable(orbctlPaths) else { return nil }
            // `orbctl start` boots the VM with no window in about a second. `orbctl stop`
            // stops the VM but leaves the app running in the background, so we quit it
            // too when it was not open before. OrbStack starts again when something
            // connects to its docker socket, so the stop is confirmed with `orbctl status`.
            // A stop in its first seconds counts as a crash and it comes back, so it gets
            // 10 seconds of uptime first. Measured on OrbStack 2.2.5: 8 seconds was enough.
            return EngineControlPlan(
                family: family,
                start: [EngineCommand(orbctl, ["start"])],
                stop: [EngineCommand(orbctl, ["stop"])],
                status: EngineCommand(orbctl, ["status"]),
                appProcessPattern: #"OrbStack\.app/Contents/MacOS/OrbStack( |$)"#,
                startTimeout: 90, stopTimeout: 60, pollInterval: 1, minimumUptime: 10, settleTime: 4
            )

        case .rancherDesktop:
            guard let rdctl = firstExecutable(rdctlPaths) else { return nil }
            // `rdctl start` saves start-in-background in Rancher's settings. Put the old
            // value back before shutdown so the app opens as it did before. The docker
            // socket answers while vmState still reads STARTING, and a shutdown sent then
            // is held until the start ends, so we wait for STARTED (or DISABLED when
            // Kubernetes is off) before listing and before stopping.
            let wasBackground = Self.rancherStartsInBackground(env.readFile(rancherSettingsPath))
            let restore = wasBackground ? [] : [EngineCommand(rdctl, ["set", "--application.start-in-background=false"])]
            return EngineControlPlan(
                family: family,
                start: [EngineCommand(rdctl, ["start", "--application.start-in-background", "--no-modal-dialogs"])],
                beforeStop: restore,
                stop: [EngineCommand(rdctl, ["shutdown"])],
                ready: EngineCommand(rdctl, ["api", "/v1/backend_state"]),
                readyMarkers: ["STARTED", "DISABLED", "ERROR"],
                startTimeout: 240, stopTimeout: 120, pollInterval: 2
            )

        case .dockerDesktop:
            guard let docker = firstExecutable(dockerPaths) else { return nil }
            // Docker Desktop 4.37 and later. `docker desktop stop` quits the whole app.
            return EngineControlPlan(
                family: family,
                start: [EngineCommand(docker, ["desktop", "start"])],
                stop: [EngineCommand(docker, ["desktop", "stop"])],
                startTimeout: 180, stopTimeout: 120, pollInterval: 2
            )

        case .podman(let machine):
            guard let podman = podmanBinary ?? EngineDetector.podmanPaths.first(where: env.files.isExecutable) else { return nil }
            return EngineControlPlan(
                family: family,
                start: [EngineCommand(podman, ["machine", "start", machine])],
                stop: [EngineCommand(podman, ["machine", "stop", machine])],
                startTimeout: 180, stopTimeout: 90, pollInterval: 2
            )

        case .colima(let profile):
            guard let colima = firstExecutable(colimaPaths) else { return nil }
            return EngineControlPlan(
                family: family,
                start: [EngineCommand(colima, ["start", "--profile", profile])],
                stop: [EngineCommand(colima, ["stop", "--profile", profile])],
                status: EngineCommand(colima, ["status", "--profile", profile]),
                startTimeout: 240, stopTimeout: 120, pollInterval: 2
            )
        }
    }

    /// Reads `application.startInBackground` from Rancher Desktop's settings.json.
    public static func rancherStartsInBackground(_ data: Data?) -> Bool {
        struct Settings: Decodable {
            struct Application: Decodable { var startInBackground: Bool? }
            var application: Application?
        }
        guard let data, let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return false }
        return settings.application?.startInBackground ?? false
    }
}

// MARK: - Errors

public enum EngineControlError: LocalizedError, Equatable {
    case startFailed(String, String)
    case startTimedOut(String, Int)
    case notEnoughSpace(needed: UInt64, free: UInt64)
    case notSupported(String)

    public var errorDescription: String? {
        switch self {
        case .startFailed(let name, let detail):
            return detail.isEmpty ? "Could not start \(name)." : "Could not start \(name). \(detail)"
        case .startTimedOut(let name, let seconds):
            return "\(name) did not start within \(seconds) seconds."
        case .notEnoughSpace(let needed, let free):
            let style = ByteCountFormatter.CountStyle.file
            let neededText = ByteCountFormatter.string(fromByteCount: Int64(clamping: needed), countStyle: style)
            let freeText = ByteCountFormatter.string(fromByteCount: Int64(clamping: free), countStyle: style)
            return "Not enough free disk space. The import needs about \(neededText) and \(freeText) is free."
        case .notSupported(let name):
            return "\(AppConfig.appName) cannot start \(name) by itself. Start it, then scan again."
        }
    }
}

/// Free space check before an export. Pure, tested.
public enum DiskSpaceCheck {
    /// Throws when `free` is known and smaller than `needed`.
    public static func verify(needed: UInt64, free: UInt64?) throws {
        guard needed > 0, let free else { return }
        if free < needed { throw EngineControlError.notEnoughSpace(needed: needed, free: free) }
    }
}

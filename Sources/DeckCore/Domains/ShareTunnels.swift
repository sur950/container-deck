import Foundation

/// Where share tools are installed.
public struct ShareToolLocator: Sendable {
    let searchPaths: [String]
    let toolsDirectory: String
    let includeAppBundle: Bool
    let isExecutable: @Sendable (String) -> Bool

    public init(
        searchPaths: [String] = DomainsConfig.toolSearchPaths,
        toolsDirectory: String = DomainsConfig.toolsDirectory().path,
        includeAppBundle: Bool = true,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.searchPaths = searchPaths
        self.toolsDirectory = toolsDirectory
        self.includeAppBundle = includeAppBundle
        self.isExecutable = isExecutable
    }

    /// Only the tools in one folder. For tests and for debug builds pointed at stand in tools.
    public static func only(_ directory: String) -> ShareToolLocator {
        ShareToolLocator(searchPaths: [directory], toolsDirectory: directory, includeAppBundle: false)
    }

    public func path(for provider: any ShareProvider) -> String? {
        provider.candidatePaths(searchPaths: searchPaths, toolsDirectory: toolsDirectory, includeAppBundle: includeAppBundle)
            .first(where: isExecutable)
    }

    /// Installed providers by id, with the program path.
    public func installed(_ providers: [any ShareProvider] = ShareProviders.all) -> [String: String] {
        var found: [String: String] = [:]
        for provider in providers {
            if let path = path(for: provider) { found[provider.id] = path }
        }
        return found
    }

    public var homebrewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: isExecutable)
    }
}

/// One running share. Starts the tool, finds the public link, stops with one call.
public final class TunnelSession: @unchecked Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case starting
        case live(String)
        case failed(ShareFailure)
        case stopped
    }

    public let id = UUID()
    public let provider: any ShareProvider
    public let routeHost: String
    public let startedAt = Date()
    /// Give up and stop when no link shows up in this time.
    public var linkTimeout: TimeInterval = DomainsConfig.shareLinkTimeout
    /// When to ask the provider's `lookupURL` if the output has no link yet.
    public var fallbackDelay: TimeInterval = DomainsConfig.shareLookupDelay
    /// Called on a background queue whenever the state changes.
    public var onChange: (@Sendable (State) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var output = ""
    private var stoppedByUser = false
    private var failure: ShareFailure?
    private var secrets: [String] = []
    private var _launch: ShareLaunch?
    private var _state: State = .starting

    public init(provider: any ShareProvider, routeHost: String) {
        self.provider = provider
        self.routeHost = routeHost
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var launch: ShareLaunch? {
        lock.lock(); defer { lock.unlock() }
        return _launch
    }

    public var publicURL: String? {
        if case .live(let url) = state { return url }
        return nil
    }

    /// Runs the tool under a small shell guard that stops it when `parent` exits, so a
    /// public link never outlives the app, even after a crash or a forced quit.
    static let guardScript = [
        "parent=$1; shift",
        "\"$@\" & child=$!",
        "stop() { kill -TERM $child 2>/dev/null; (sleep 3; kill -KILL $child 2>/dev/null) & wait $child; exit 0; }",
        "trap stop INT TERM",
        "while kill -0 $parent 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done",
        "if kill -0 $child 2>/dev/null; then stop; fi",
        "wait $child",
    ].joined(separator: "\n")

    public func start(_ launch: ShareLaunch, parent: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        lock.lock()
        _launch = launch
        lock.unlock()
        try start(executable: launch.executable, arguments: launch.arguments, environment: launch.environment,
                  secrets: launch.secrets, parent: parent)
    }

    /// Extra `environment` goes to the tool only. Secrets travel there, never in arguments,
    /// and are blanked out of everything the tool prints.
    public func start(executable: String, arguments: [String], environment extra: [String: String] = [:],
                      secrets: [String] = [],
                      parent: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.guardScript, "deck-share", String(parent), executable] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        // A token from the person's own shell never leaks in. Ours comes from `extra`.
        environment.removeValue(forKey: NgrokSetup.tokenEnvironmentKey)
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.append(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] proc in
            // Give the reader a moment for the last lines, so they make it into the message.
            // Never block on the pipe: a child the tool left behind may still hold it open.
            let status = proc.terminationStatus
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.finished(status: status)
            }
        }
        lock.lock()
        self.process = process
        self.secrets = secrets.filter { !$0.isEmpty }
        lock.unlock()
        do {
            try process.run()
        } catch {
            throw DeckError.launchFailed(executable, error.localizedDescription)
        }
        scheduleChecks()
    }

    /// Stops the tool. The public link stops working right away.
    public func stop() {
        lock.lock()
        stoppedByUser = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { set(.stopped); return }
        process.terminate() // the guard stops the tool, then exits
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true
    }

    /// Waits until the tool and its guard are gone, up to `timeout` seconds.
    public func waitUntilExit(timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Last lines the tool printed, for error messages. Secrets are blanked.
    public var outputTail: String {
        lock.lock(); defer { lock.unlock() }
        return Self.tail(output)
    }

    private var currentOutput: String {
        lock.lock(); defer { lock.unlock() }
        return output
    }

    static func tail(_ text: String, lines: Int = 6) -> String {
        text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••") }
    }

    // MARK: Output

    private func append(_ text: String) {
        lock.lock()
        output += Self.redact(text, secrets: secrets)
        if output.count > 64_000 { output = String(output.suffix(32_000)) }
        let waiting = _state == .starting && failure == nil
        // Only whole lines, so a link split across two reads is never taken half way.
        let complete = output.lastIndex(of: "\n").map { String(output[...$0]) } ?? ""
        let launch = _launch
        lock.unlock()
        guard waiting, !complete.isEmpty else { return }
        if let url = provider.publicURL(in: complete, launch: launch) {
            set(.live(url))
        } else if let early = provider.earlyFailure(in: complete) {
            fail(early)
        }
    }

    private func scheduleChecks() {
        let timeout = linkTimeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.state == .starting, self.isRunning else { return }
            let text = self.outputTail
            self.fail(self.provider.classify(text) ?? .noLink(self.provider, seconds: Int(timeout)))
        }
        guard provider.hasLookup else { return }
        let provider = self.provider
        let delay = fallbackDelay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.state == .starting, self.isRunning else { return }
            if let url = await provider.lookupURL(output: self.currentOutput), self.state == .starting {
                self.set(.live(url))
            }
        }
    }

    /// Reports a failure and stops the tool.
    private func fail(_ failure: ShareFailure) {
        lock.lock()
        guard self.failure == nil, !stoppedByUser else { lock.unlock(); return }
        self.failure = failure
        let process = self.process
        lock.unlock()
        set(.failed(failure))
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func finished(status: Int32) {
        lock.lock()
        let byUser = stoppedByUser
        let earlier = failure
        let text = output
        lock.unlock()
        if byUser {
            set(.stopped)
        } else if earlier == nil {
            let failure = provider.classify(text) ?? .exited(provider, status: status, tail: Self.tail(text))
            lock.lock()
            self.failure = failure
            lock.unlock()
            set(.failed(failure))
        }
    }

    private func set(_ state: State) {
        lock.lock()
        _state = state
        let callback = onChange
        lock.unlock()
        callback?(state)
    }
}

/// Every share in the app: starts them, follows them, stops them and cleans up after them.
public final class ShareManager: @unchecked Sendable {
    /// Called on a background queue for every change of every share.
    public var onChange: (@Sendable (_ host: String, _ session: TunnelSession, _ state: TunnelSession.State) -> Void)?

    public let locator: ShareToolLocator
    public let context: ShareContext
    private let parent: Int32
    private let linkTimeout: TimeInterval
    private let fallbackDelay: TimeInterval
    private let lock = NSLock()
    private var sessions: [String: TunnelSession] = [:]

    public init(locator: ShareToolLocator = ShareToolLocator(), context: ShareContext = ShareContext(),
                parent: Int32 = ProcessInfo.processInfo.processIdentifier,
                linkTimeout: TimeInterval = DomainsConfig.shareLinkTimeout,
                fallbackDelay: TimeInterval = DomainsConfig.shareLookupDelay) {
        self.locator = locator
        self.context = context
        self.parent = parent
        self.linkTimeout = linkTimeout
        self.fallbackDelay = fallbackDelay
    }

    public func session(for host: String) -> TunnelSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[host]
    }

    public var activeHosts: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.keys)
    }

    /// Ready, needs setup or not installed, for every provider.
    public func readiness(of provider: any ShareProvider) async -> ShareReadiness {
        guard let path = locator.path(for: provider) else { return .notInstalled }
        return await provider.readiness(executable: path, context: context)
    }

    /// Starts sharing one route. Replaces an earlier share of the same route.
    @discardableResult
    public func share(_ route: ProxyRoute, with provider: any ShareProvider, publishedPort: Int?) async throws -> TunnelSession {
        guard let path = locator.path(for: provider) else { throw ShareFailure.notInstalled(provider) }
        if let blocker = provider.blocker(for: route, publishedPort: publishedPort) { throw blocker }
        await stop(route.host)
        let launch = try await provider.prepare(route: route, publishedPort: publishedPort, executable: path,
                                                context: context, reservedPorts: reservedPorts(for: provider.id))
        let session = TunnelSession(provider: provider, routeHost: route.host)
        session.linkTimeout = linkTimeout
        session.fallbackDelay = fallbackDelay
        let host = route.host
        session.onChange = { [weak self, weak session] state in
            guard let self, let session else { return }
            self.changed(host: host, session: session, state: state)
        }
        insert(host, session)
        do {
            try session.start(launch, parent: parent)
        } catch {
            remove(host, session)
            throw error
        }
        return session
    }

    /// Stops one share, waits for the tool to exit, then cleans up after it.
    public func stop(_ host: String) async {
        guard let session = take(host) else { return }
        session.stop()
        await session.waitUntilExit()
        if let launch = session.launch { await session.provider.cleanUp(after: launch, context: context) }
    }

    public func stopAll() async {
        for host in activeHosts { await stop(host) }
    }

    /// At quit. Signals every tool at once. The guards finish the job, and Tailscale drops
    /// foreground funnels by itself when their command ends.
    public func stopAllNow() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        for session in all { session.stop() }
    }

    private func reservedPorts(for providerID: String) -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return Set(sessions.values.filter { $0.provider.id == providerID }.compactMap { $0.launch?.reservedPort })
    }

    private func insert(_ host: String, _ session: TunnelSession) {
        lock.lock()
        sessions[host] = session
        lock.unlock()
    }

    private func take(_ host: String) -> TunnelSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions.removeValue(forKey: host)
    }

    private func remove(_ host: String, _ session: TunnelSession) {
        lock.lock()
        if sessions[host] === session { sessions.removeValue(forKey: host) }
        lock.unlock()
    }

    private func changed(host: String, session: TunnelSession, state: TunnelSession.State) {
        if case .failed = state, let launch = session.launch {
            // The tool ended or was stopped on a failure. Make sure nothing of ours is left behind.
            let context = self.context
            Task {
                await session.waitUntilExit()
                await session.provider.cleanUp(after: launch, context: context)
            }
        }
        if state == .stopped { remove(host, session) }
        onChange?(host, session, state)
    }
}

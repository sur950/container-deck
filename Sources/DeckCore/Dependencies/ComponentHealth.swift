import Foundation

/// One read only check of a feature the app needs from a tool, like "Kubernetes clusters can be listed".
public struct HealthCheck: Sendable, Equatable, Codable, Identifiable {
    public enum Outcome: String, Sendable, Codable {
        case passed
        case failed
        /// Could not run now, like the container service is stopped or Ollama is not running.
        /// Never counts as broken.
        case skipped
    }

    /// Stable key, like "container.clusters". Failures screens report start with "use.".
    public var id: String
    /// The feature as a short name, for "<title> didn't work with ...": "Kubernetes cluster list".
    public var title: String?
    /// What the app needs, in plain words: "Kubernetes clusters can be listed".
    public var feature: String
    /// The same when it fails: "Kubernetes clusters can't be listed".
    public var failure: String
    public var outcome: Outcome
    /// Why it failed or was skipped, short.
    public var detail: String?

    public init(id: String, title: String? = nil, feature: String, failure: String, outcome: Outcome, detail: String? = nil) {
        self.id = id
        self.title = title ?? HealthCheck.titles[id]
        self.feature = feature
        self.failure = failure
        self.outcome = outcome
        self.detail = detail
    }

    /// The line shown in Settings: the failure for failed checks, the feature otherwise.
    public var text: String { outcome == .failed ? failure : feature }

    /// A failure a screen reported while it was used, not a health check.
    public var isReported: Bool { id.hasPrefix("use.") }

    /// Short names of the health checks.
    static let titles: [String: String] = [
        "container.service.cli": "The container command", "container.service.api": "The direct connection to the container service",
        "container.containers": "The container list", "container.images": "The image list", "container.volumes": "The volume list",
        "container.networks": "The network list", "container.properties": "Reading system settings",
        "container.clusters": "The Kubernetes cluster list", "container.kernel": "The Linux kernel",
        "ollama.cli": "The ollama command", "ollama.version": "Ollama's server", "ollama.models": "The Ollama model list",
        "ollama.loaded": "The list of loaded Ollama models",
        "mlx.import": "Loading mlx-lm", "mlx.server": "Starting the MLX server",
        "lmstudio.cli": "The lms command", "lmstudio.daemon": "LM Studio's service status", "lmstudio.models": "The LM Studio model list",
        "lmstudio.loaded": "The list of loaded LM Studio models", "lmstudio.server": "The LM Studio server status",
        "uv.version": "uv", "uv.install": "Installing the MLX runtime",
        "cloudflared.version": "cloudflared", "cloudflared.tunnel": "Cloudflare sharing",
        "ngrok.version": "ngrok", "ngrok.http": "ngrok sharing", "tailscale.version": "Tailscale", "tailscale.funnel": "Tailscale Funnel sharing",
        "kubectl.version": "kubectl", "kubectl.portForward": "Kubernetes port forwards", "kubectl.global": "kubectl with the app's cluster settings",
        "kubectl.apply": "Applying Kubernetes manifests", "helm.version": "Helm",
        "agent.version": "Reading the agent's version", "agent.config": "Reading the agent's settings", "agent.sessions": "Reading the agent's sessions"
    ]

    /// "<title>" for messages, falling back to the feature line.
    public var name: String { title ?? feature }
}

/// The checks of one tool at one version.
public struct ComponentHealthReport: Sendable, Equatable, Codable {
    public var componentID: String
    /// Installed version when the checks ran.
    public var version: String?
    public var checks: [HealthCheck]
    public var checkedAt: Date

    public init(componentID: String, version: String?, checks: [HealthCheck], checkedAt: Date = Date()) {
        self.componentID = componentID
        self.version = version
        self.checks = checks
        self.checkedAt = checkedAt
    }

    public var failed: [HealthCheck] { checks.filter { $0.outcome == .failed } }
    public var passed: [HealthCheck] { checks.filter { $0.outcome == .passed } }
    public var skipped: [HealthCheck] { checks.filter { $0.outcome == .skipped } }

    /// Nothing failed and at least one check really ran. Only then is the version "good".
    public var allPassed: Bool { failed.isEmpty && !passed.isEmpty }

    /// A check that passed at the last good version and is now skipped because what it reads is
    /// gone (a moved config folder) counts as failed.
    public func comparing(with lastGood: ComponentHealthReport?) -> ComponentHealthReport {
        guard let lastGood else { return self }
        var copy = self
        let passedBefore = Set(lastGood.passed.map(\.id))
        for index in copy.checks.indices where copy.checks[index].outcome == .skipped
            && copy.checks[index].detail == HealthCheck.missingDetail && passedBefore.contains(copy.checks[index].id) {
            copy.checks[index].outcome = .failed
            copy.checks[index].detail = "It was there with the last good version."
        }
        return copy
    }
}

public extension HealthCheck {
    /// Detail of a skipped check whose file or folder does not exist (yet).
    static let missingDetail = "Not found on this Mac."
}

/// Each tool's last good versions: the versions where every check passed. Kept in the app's data
/// folder (`component-health.json`) so a downgrade knows where to go back to.
public final class ComponentHealthStore: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        /// Versions where every check passed, oldest first, at most `maxVersions`.
        var good: [String] = []
        /// The report of the newest good version.
        var goodReport: ComponentHealthReport?
        /// The last report of any outcome.
        var last: ComponentHealthReport?
    }

    public let file: URL?
    static let maxVersions = 8
    private let lock = NSLock()
    private var entries: [String: Entry]

    public init(file: URL? = ComponentHealthStore.defaultFile()) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
        } else {
            entries = [:]
        }
    }

    /// Application Support/<data id>/component-health.json.
    public static func defaultFile() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppConfig.dataID, isDirectory: true).appendingPathComponent("component-health.json")
    }

    /// Keeps the report. A report where every check passed adds its version to the good list.
    public func record(_ report: ComponentHealthReport) {
        lock.lock()
        var entry = entries[report.componentID] ?? Entry()
        entry.last = report
        if report.allPassed, let text = report.version, let version = ToolVersion(text) {
            var good = entry.good.compactMap(ToolVersion.init).filter { $0 != version }
            good.append(version)
            good.sort()
            entry.good = good.suffix(Self.maxVersions).map(\.description)
            if let newest = good.last, newest == version { entry.goodReport = report }
        }
        entries[report.componentID] = entry
        let snapshot = entries
        lock.unlock()
        save(snapshot)
    }

    /// Adds a failure a screen reported to the last report of this version (a new report when the
    /// version changed). Returns the report.
    @discardableResult
    public func recordFailure(_ check: HealthCheck, componentID: String, version: String?) -> ComponentHealthReport {
        lock.lock()
        var entry = entries[componentID] ?? Entry()
        var report = entry.last.flatMap { $0.version == version ? $0 : nil }
            ?? ComponentHealthReport(componentID: componentID, version: version, checks: [])
        report.checks.removeAll { $0.id == check.id }
        report.checks.append(check)
        report.checkedAt = Date()
        entry.last = report
        entries[componentID] = entry
        let snapshot = entries
        lock.unlock()
        save(snapshot)
        return report
    }

    /// The newest version where every check passed.
    public func lastGood(_ id: String) -> ToolVersion? {
        goodVersions(id).max()
    }

    public func goodVersions(_ id: String) -> [ToolVersion] {
        lock.lock(); defer { lock.unlock() }
        return (entries[id]?.good ?? []).compactMap(ToolVersion.init)
    }

    public func lastReport(_ id: String) -> ComponentHealthReport? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.last
    }

    public func goodReport(_ id: String) -> ComponentHealthReport? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.goodReport
    }

    private func save(_ snapshot: [String: Entry]) {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// Turns a row plus its health report into what Settings shows: "Not working with this version"
/// and, when the installed version is not the tested one, the release to switch to. Pure.
public enum ComponentHealthAssessment {
    /// - Parameters:
    ///   - row: the row from `ComponentChecker`.
    ///   - report: the checks and reported failures of the installed version, nil when none ran.
    ///   - tested: the tested version.
    ///   - published: every published version the switch can pick from (may be empty).
    public static func apply(to row: ComponentInfo, report: ComponentHealthReport?, tested: ComponentGate.Tested?,
                             published: [ToolVersion]) -> ComponentInfo {
        var row = row
        row.health = report
        let failed = report?.failed ?? []
        guard !failed.isEmpty, let installedText = row.installed else { return row }
        row.status = .notWorking
        row.target = nil
        if let installed = ToolVersion(installedText), let tested, !tested.matches(installed),
           let target = tested.target(published: published), target != installed {
            row.switchTarget = ComponentChecker.display(target, kind: row.kind)
            row.note = "\(failed[0].name) didn't work with version \(installedText). It works with \(row.switchTarget!)."
            if failed.count == 2 { row.note! += " 1 more feature isn't working." }
            if failed.count > 2 { row.note! += " \(failed.count - 1) more features aren't working." }
        } else {
            row.switchTarget = nil
            row.note = failed.count == 1 ? "1 feature isn't working with version \(installedText)."
                : "\(failed.count) features aren't working with version \(installedText)."
            if tested != nil, row.matchesTested { row.note! += " This is the tested version, so something else on this Mac is likely the cause." }
        }
        return row
    }

    /// "Kubernetes cluster list didn't work with Apple container 1.8.0."
    public static func headline(_ row: ComponentInfo) -> String {
        let version = row.installed.map { " \($0)" } ?? ""
        guard let first = row.failedChecks.first else { return "\(row.name)\(version) isn't working fully." }
        let more = row.failedChecks.count > 1 ? " (and \(row.failedChecks.count - 1) more)" : ""
        return "\(first.name)\(more) didn't work with \(row.name)\(version)."
    }

    /// "It works with 0.16.2." for the switch offer.
    public static func offer(_ row: ComponentInfo) -> String? {
        row.switchTarget.map { "It works with \($0)." }
    }
}

/// A failure while a feature was used, like the cluster list not parsing.
public struct ComponentFailure: Sendable, Equatable {
    /// Component id: "container", "ollama", "agent:claude".
    public var componentID: String
    /// The feature as a short name: "Kubernetes cluster list".
    public var feature: String
    public var detail: String
}

/// Lets screens report a real failure at use time. Only failures that look like the tool's
/// version changed count: output in a new format, an unknown command or flag, a missing API
/// route. The app turns them into "Not working with this version" and the switch offer.
public enum ComponentHealth {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var receiver: (@Sendable (ComponentFailure) -> Void)?

    /// The app's handler (ComponentsCenter). Tests set their own.
    public static func setReceiver(_ handler: (@Sendable (ComponentFailure) -> Void)?) {
        lock.lock(); receiver = handler; lock.unlock()
    }

    /// Reports `error` for a feature of a component when it looks like a version problem.
    /// Returns true when it was reported.
    @discardableResult
    public static func report(component id: String, feature: String, error: Error) -> Bool {
        report(component: id, feature: feature, message: error.localizedDescription, error: error)
    }

    @discardableResult
    public static func report(component kind: ComponentKind, feature: String, error: Error) -> Bool {
        report(component: kind.rawValue, feature: feature, error: error)
    }

    /// For failures that arrive as text (a server log, a version line).
    @discardableResult
    public static func report(component id: String, feature: String, message: String, error: Error? = nil) -> Bool {
        guard error.map(isVersionProblem) ?? isVersionProblem(message) else { return false }
        lock.lock(); let handler = receiver; lock.unlock()
        handler?(ComponentFailure(componentID: id, feature: feature, detail: String(message.prefix(300))))
        return true
    }

    /// A parse error, an unknown command, flag or route: what a changed tool version causes.
    /// Ordinary failures (a container that does not exist, a refused connection) do not count.
    public static func isVersionProblem(_ error: Error) -> Bool {
        if case DeckError.parse = error { return true }
        if error is DecodingError { return true }
        return isVersionProblem(error.localizedDescription)
    }

    public static func isVersionProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        let marks = ["unknown command", "unknown subcommand", "not a valid subcommand", "unknown option", "unknown flag",
                     "unrecognized arguments", "unrecognized option", "unexpected argument", "no such option",
                     "could not parse", "couldn't parse", "can't parse", "cannot parse", "failed to parse", "could not read the",
                     "the data couldn’t be read", "the data couldn't be read", "isn't in the correct format", "is not in the correct format",
                     "modulenotfounderror", "importerror", "no module named", "command not found", "404 page not found", "http 404"]
        return marks.contains { lower.contains($0) }
    }

    /// Stable check id for a reported feature: "use.kubernetes-cluster-list".
    public static func checkID(_ feature: String) -> String {
        "use." + feature.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    /// The failed check a report becomes.
    public static func check(for failure: ComponentFailure) -> HealthCheck {
        HealthCheck(id: checkID(failure.feature), title: failure.feature, feature: "\(failure.feature) works",
                    failure: "\(failure.feature) didn't work", outcome: .failed, detail: failure.detail)
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Diagnostics: one place that collects versions, backend, kernel, Rosetta, disk and
// recent errors, and turns them into text people can paste into a bug report.
// No secrets: home paths become ~, and anything that looks like a token is hidden.

/// Recent errors the app showed. Thread safe, newest last, capped.
public final class DiagnosticsLog: @unchecked Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: UUID
        public var date: Date
        public var message: String
        public var source: String?

        public init(date: Date = Date(), message: String, source: String? = nil) {
            self.id = UUID()
            self.date = date
            self.message = message
            self.source = source
        }
    }

    public static let shared = DiagnosticsLog()
    public static let capacity = 50

    private let lock = NSLock()
    private var items: [Entry] = []

    public init() {}

    public func record(_ message: String, source: String? = nil, date: Date = Date()) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // The same error many times in a row (a poll that keeps failing) is one entry.
        if let last = items.last, last.message == trimmed, date.timeIntervalSince(last.date) < 60 {
            items[items.count - 1].date = date
            return
        }
        items.append(Entry(date: date, message: trimmed, source: source))
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }

    public func record(_ error: Error, source: String? = nil) {
        if error is CancellationError { return }
        record(error.localizedDescription, source: source)
    }

    public var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        items = []
    }
}

/// `container system status --format json`.
public struct SystemStatusInfo: Sendable, Hashable {
    public var status: String
    public var clientVersion: String?
    public var clientCommit: String?
    public var serverVersion: String?
    public var serverCommit: String?
    public var hostOS: String?
    public var appRoot: String?
    public var installRoot: String?
    public var containersRunning: Int?
    public var containersTotal: Int?
    public var images: Int?

    public init(status: String = "unknown", clientVersion: String? = nil, clientCommit: String? = nil, serverVersion: String? = nil,
                serverCommit: String? = nil, hostOS: String? = nil, appRoot: String? = nil, installRoot: String? = nil,
                containersRunning: Int? = nil, containersTotal: Int? = nil, images: Int? = nil) {
        self.status = status
        self.clientVersion = clientVersion
        self.clientCommit = clientCommit
        self.serverVersion = serverVersion
        self.serverCommit = serverCommit
        self.hostOS = hostOS
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.containersRunning = containersRunning
        self.containersTotal = containersTotal
        self.images = images
    }

    private struct Raw: Decodable {
        struct Part: Decodable { var version: String?; var commit: String? }
        struct Host: Decodable { var operatingSystem: String? }
        struct Paths: Decodable { var appRoot: String?; var installRoot: String? }
        struct Resources: Decodable { var containersRunning: Int?; var containersTotal: Int?; var images: Int? }
        var status: String?
        var client: Part?
        var server: Part?
        var host: Host?
        var paths: Paths?
        var resources: Resources?
    }

    public static func parse(_ text: String) -> SystemStatusInfo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(trimmed.utf8)) else { return nil }
        return SystemStatusInfo(
            status: raw.status ?? "unknown",
            clientVersion: raw.client?.version,
            clientCommit: raw.client?.commit,
            serverVersion: raw.server?.version,
            serverCommit: raw.server?.commit,
            hostOS: raw.host?.operatingSystem,
            appRoot: raw.paths?.appRoot,
            installRoot: raw.paths?.installRoot,
            containersRunning: raw.resources?.containersRunning,
            containersTotal: raw.resources?.containersTotal,
            images: raw.resources?.images
        )
    }
}

/// Everything the Diagnostics view shows.
public struct DiagnosticsReport: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public enum Level: String, Sendable { case ok, warning, problem, info }
        public var key: String
        public var value: String
        public var level: Level
        public var id: String { key }

        public init(_ key: String, _ value: String, level: Level = .info) {
            self.key = key
            self.value = value
            self.level = level
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var title: String
        public var items: [Item]
        public var id: String { title }

        public init(_ title: String, _ items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public var date: Date
    public var sections: [Section]
    public var errors: [DiagnosticsLog.Entry]
    public var compatibility: VersionCompatibility

    public init(date: Date = Date(), sections: [Section], errors: [DiagnosticsLog.Entry] = [], compatibility: VersionCompatibility) {
        self.date = date
        self.sections = sections
        self.errors = errors
        self.compatibility = compatibility
    }

    public func value(_ key: String) -> String? {
        for section in sections {
            if let item = section.items.first(where: { $0.key == key }) { return item.value }
        }
        return nil
    }

    /// Plain text for a bug report. Secrets and home paths are taken out.
    public func text(home: String = NSHomeDirectory()) -> String {
        var lines: [String] = []
        lines.append("\(AppConfig.appName) diagnostics")
        lines.append("Made \(Self.stamp(date))")
        for section in sections {
            lines.append("")
            lines.append("## \(section.title)")
            for item in section.items {
                lines.append("\(item.key): \(item.value)")
            }
        }
        lines.append("")
        lines.append("## Recent errors")
        if errors.isEmpty {
            lines.append("None")
        } else {
            for entry in errors.suffix(20) {
                let source = entry.source.map { " [\($0)]" } ?? ""
                lines.append("\(Self.stamp(entry.date))\(source) \(entry.message)")
            }
        }
        return DiagnosticsRedactor.redact(lines.joined(separator: "\n"), home: home)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Takes secrets and personal paths out of text.
public enum DiagnosticsRedactor {
    public static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        var result = text
        if !home.isEmpty && home != "/" {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        let patterns: [(String, String)] = [
            // Authorization headers.
            (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 <hidden>"),
            // key=value or key: value where the key names a secret.
            (#"(?i)\b([A-Z0-9_.-]*(?:token|secret|password|passwd|api[_-]?key|access[_-]?key|auth)[A-Z0-9_.-]*)\s*([=:])\s*("[^"]*"|'[^']*'|\S+)"#, "$1$2<hidden>"),
            // Well known token shapes.
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, "<hidden>"),
            (#"\bsk-[A-Za-z0-9_-]{16,}\b"#, "<hidden>"),
            (#"\bhf_[A-Za-z0-9]{20,}\b"#, "<hidden>"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "<hidden>"),
            // user:password@ in URLs.
            (#"(?i)([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1<hidden>@")
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}

/// Facts about this Mac that do not need the container tool.
public enum HostFacts {
    public static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
        #else
        return nil
        #endif
    }

    public static var chip: String { sysctlString("machdep.cpu.brand_string") ?? "Unknown" }
    public static var model: String { sysctlString("hw.model") ?? "Unknown" }

    public static var macOS: String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return version.replacingOccurrences(of: "Version ", with: "")
    }

    /// Rosetta's runtime is on disk once Rosetta is installed.
    public static var rosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// Free space on the volume that holds `path`.
    public static func freeSpace(at path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free > 0 {
            return UInt64(free)
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.uint64Value
        }
        return nil
    }

    /// Target of the `default.kernel-arm64` link, like "vmlinux-6.18.35-197".
    public static func defaultKernel(appRoot: String) -> String? {
        let link = URL(fileURLWithPath: appRoot).appendingPathComponent("kernels/default.kernel-arm64").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            return FileManager.default.fileExists(atPath: link) ? "default.kernel-arm64" : nil
        }
        return (target as NSString).lastPathComponent
    }
}

/// Inputs the app passes in (the parts DeckCore cannot know).
public struct DiagnosticsContext: Sendable {
    public var appVersion: String
    public var appBuild: String
    public var cliPath: String?
    public var backend: BackendStatus?
    public var setupChecks: [SetupCheck]
    public var errors: [DiagnosticsLog.Entry]

    public init(appVersion: String, appBuild: String, cliPath: String?, backend: BackendStatus?,
                setupChecks: [SetupCheck] = [], errors: [DiagnosticsLog.Entry] = []) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.cliPath = cliPath
        self.backend = backend
        self.setupChecks = setupChecks
        self.errors = errors
    }
}

public enum DiagnosticsCollector {
    /// Collects the report. Every step is best effort: a failing call leaves a note, never throws.
    public static func collect(client: ContainerClient?, context: DiagnosticsContext) async -> DiagnosticsReport {
        var cliVersion: SemanticVersion?
        var cliVersionText = "Not found"
        var status: SystemStatusInfo?
        var properties: [SystemProperty] = []
        var usage: DiskUsage?
        var machineCount: Int?

        if let client {
            if let result = try? await client.runner.run(client.cli.path, ["--version"]), result.succeeded {
                let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                cliVersion = SemanticVersion.firstMatch(in: text)
                cliVersionText = cliVersion.map { "\($0)" } ?? text
                if let commit = text.range(of: #"commit: ([0-9a-f]+)"#, options: .regularExpression) {
                    cliVersionText += " (" + text[commit].replacingOccurrences(of: "commit: ", with: "commit ") + ")"
                }
            } else {
                cliVersionText = "Could not run \(client.cli.path)"
            }
            if let result = try? await client.runner.run(client.cli.path, ["system", "status", "--format", "json"]) {
                status = SystemStatusInfo.parse(result.stdout)
                if status == nil, !result.succeeded { status = SystemStatusInfo(status: "stopped") }
            }
            if status?.status == "running" {
                properties = (try? await client.systemProperties()) ?? []
                usage = try? await client.diskUsage()
                if let result = try? await client.runner.run(client.cli.path, ["machine", "list", "--quiet"]), result.succeeded {
                    machineCount = result.stdout.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                }
            }
        }

        let daemonVersion = (status?.serverVersion).flatMap { SemanticVersion.firstMatch(in: $0) }
            ?? context.backend?.daemonVersion.flatMap { SemanticVersion.firstMatch(in: $0) }
        let compatibility = VersionCompatibility(cliVersion: cliVersion, daemonVersion: daemonVersion)
        let property = { (key: String) -> String? in properties.first { $0.key == key }?.value }
        let appRoot = status?.appRoot ?? MachineBootConfig.defaultAppRoot

        var sections: [DiagnosticsReport.Section] = []

        sections.append(.init("App", [
            .init("App", "\(AppConfig.appName) \(context.appVersion) (\(context.appBuild))"),
            .init("macOS", HostFacts.macOS),
            .init("Mac", "\(HostFacts.model), \(HostFacts.chip)"),
            .init("Memory", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
        ]))

        let versionLevel: DiagnosticsReport.Item.Level = {
            switch compatibility.verdict {
            case .supported: return .ok
            case .tooOld, .serviceMismatch: return .problem
            case .olderThanTested, .newerThanTested: return .warning
            case .unknown: return .info
            }
        }()
        var platform: [DiagnosticsReport.Item] = [
            .init("Container command", cliVersionText, level: cliVersion == nil ? .problem : versionLevel),
            .init("Command path", context.cliPath ?? client?.cli.path ?? "Not found"),
            .init("Service", status.map { $0.status == "running" ? "Running" : "Stopped" } ?? "Unknown",
                  level: status?.status == "running" ? .ok : .problem),
            .init("Service version", status?.serverVersion ?? context.backend?.daemonVersion ?? "Unknown",
                  level: compatibility.verdict == .serviceMismatch ? .problem : .info),
            .init("Tested versions", compatibility.testedRangeText),
            .init("Version check", compatibility.title, level: versionLevel)
        ]
        if let backend = context.backend {
            let direct = backend.backend == .directAPI && backend.versionSupported && !backend.forcedCLI && backend.service == .running
            platform.append(.init("Backend", direct ? "Direct API" : "Container command", level: direct ? .ok : .warning))
            platform.append(.init("Backend reason", backend.summary))
            if !backend.fallbackCounts.isEmpty {
                let parts = backend.fallbackCounts.sorted { $0.key < $1.key }.map { "\($0.key.displayName) \($0.value)" }
                platform.append(.init("Fallbacks", parts.joined(separator: ", "), level: .warning))
            }
        }
        sections.append(.init("Container platform", platform))

        var kernel: [DiagnosticsReport.Item] = []
        if let name = HostFacts.defaultKernel(appRoot: appRoot) {
            kernel.append(.init("Default kernel", name, level: .ok))
        } else {
            kernel.append(.init("Default kernel", "Not installed", level: .problem))
        }
        if let url = property("kernel.url") {
            kernel.append(.init("Kernel source", url))
        }
        let rosetta = HostFacts.rosettaInstalled
        kernel.append(.init("Rosetta", rosetta ? "Installed" : "Not installed. amd64 images will not run.", level: rosetta ? .ok : .warning))
        if let builder = property("build.rosetta") {
            kernel.append(.init("Rosetta in builds", builder == "true" ? "On" : "Off"))
        }
        if let machines = machineCount {
            kernel.append(.init("Machines", "\(machines)"))
        }
        sections.append(.init("Kernel and Rosetta", kernel))

        var disk: [DiagnosticsReport.Item] = []
        if let free = HostFacts.freeSpace(at: appRoot) {
            let low = free < 10 * 1_073_741_824
            disk.append(.init("Free space", ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file) + (low ? ", low" : ""),
                              level: low ? .warning : .ok))
        }
        if let usage {
            let format = { (value: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
            disk.append(.init("Images", "\(format(usage.images.sizeBytes)), \(usage.images.total) total"))
            disk.append(.init("Containers", "\(format(usage.containers.sizeBytes)), \(usage.containers.total) total"))
            disk.append(.init("Volumes", "\(format(usage.volumes.sizeBytes)), \(usage.volumes.total) total"))
            disk.append(.init("Reclaimable", format(usage.reclaimableBytes)))
        }
        if let running = status?.containersRunning, let total = status?.containersTotal {
            disk.append(.init("Containers running", "\(running) of \(total)"))
        }
        disk.append(.init("Data folder", appRoot))
        sections.append(.init("Disk", disk))

        let failing = context.setupChecks.filter { !$0.state.isPassing }
        if !failing.isEmpty {
            sections.append(.init("Setup checks", failing.map {
                .init($0.title, $0.state.message, level: $0.isOptional ? .warning : .problem)
            }))
        }

        return DiagnosticsReport(sections: sections, errors: context.errors, compatibility: compatibility)
    }
}

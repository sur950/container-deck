import Foundation

// Container machines. Keep these signatures stable, the Machines screen relies on them.
// Commands follow Apple's `container machine` CLI:
//   machine list --format json, machine inspect <id>, machine create [opts] <image>,
//   machine run --name <id> -- <cmd>, machine stop <id>, machine delete <id>,
//   machine set-default <id>, machine set --name <id> key=value..., machine logs [--boot] [-f] [-n N] <id>

public extension ContainerClient {
    func listMachines() async throws -> [MachineSummary] {
        let result: CommandResult
        do {
            result = try await run(["machine", "list", "--format", "json"])
        } catch {
            throw MachineParser.explain(error)
        }
        let listed = try MachineParser.parseList(result.stdout)

        // The list output has no image or home mount, so ask inspect for those.
        // People have a handful of machines, so one call at a time is fine.
        var details: [String: MachineDetail] = [:]
        for machine in listed {
            if let detail = try? await machineDetail(machine.name) {
                details[machine.name] = detail
            }
        }

        return listed.map { machine in
            guard let detail = details[machine.name] else { return machine }
            var merged = detail.summary
            merged.isDefault = machine.isDefault
            if merged.ipAddress == nil { merged.ipAddress = machine.ipAddress }
            if merged.cpus == nil { merged.cpus = machine.cpus }
            if merged.memoryBytes == nil { merged.memoryBytes = machine.memoryBytes }
            return merged
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createMachine(_ options: MachineOptions) async throws {
        do {
            try await run(createMachineArguments(options))
        } catch {
            throw MachineParser.explain(error)
        }
    }

    func bootMachine(_ name: String) async throws {
        do {
            try await run(bootMachineArguments(name))
        } catch {
            throw MachineParser.explain(error)
        }
    }

    func stopMachine(_ name: String) async throws {
        try await run(["machine", "stop", name])
    }

    func deleteMachine(_ name: String) async throws {
        try await run(["machine", "delete", name])
    }

    func setDefaultMachine(_ name: String) async throws {
        try await run(["machine", "set-default", name])
    }

    func inspectMachine(_ name: String) async throws -> String {
        let result = try await run(["machine", "inspect", name])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func machineLogs(_ name: String, follow: Bool = true) -> AsyncThrowingStream<String, Error> {
        stream(machineLogArguments(name, follow: follow, boot: false))
    }

    /// Shell command a terminal app runs to log in to the machine.
    func machineShellCommand(_ name: String) -> String {
        let path = cli.path.contains(" ") ? "'\(cli.path)'" : cli.path
        return "\(path) machine run --name \(name)"
    }
}

// MARK: - More machine calls

public extension ContainerClient {
    /// `container machine create` arguments (without the leading "container").
    func createMachineArguments(_ options: MachineOptions) -> [String] {
        var args = ["machine", "create"]
        let name = options.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { args += ["--name", name] }
        if let cpus = options.cpus { args += ["--cpus", String(cpus)] }
        if let memory = options.memory?.trimmingCharacters(in: .whitespaces), !memory.isEmpty {
            args += ["--memory", memory]
        }
        if ["rw", "ro", "none"].contains(options.homeMount) {
            args += ["--home-mount", options.homeMount]
        }
        if !options.boot { args.append("--no-boot") }
        args.append(options.image.trimmingCharacters(in: .whitespaces))
        return args
    }

    /// There is no `machine boot` command. `machine run` boots the machine
    /// first, so we run `true` and return.
    func bootMachineArguments(_ name: String) -> [String] {
        ["machine", "run", "--name", name, "--", "true"]
    }

    /// `container machine set` arguments. Changes apply on the next boot.
    func setMachineArguments(_ name: String, cpus: Int?, memory: String?, homeMount: String?) -> [String] {
        var args = ["machine", "set", "--name", name]
        if let cpus { args.append("cpus=\(cpus)") }
        if let memory = memory?.trimmingCharacters(in: .whitespaces), !memory.isEmpty {
            args.append("memory=\(memory)")
        }
        if let homeMount, ["rw", "ro", "none"].contains(homeMount) {
            args.append("home-mount=\(homeMount)")
        }
        return args
    }

    func machineLogArguments(_ name: String, follow: Bool, boot: Bool, tail: Int? = 1000) -> [String] {
        var args = ["machine", "logs"]
        if boot { args.append("--boot") }
        if follow { args.append("--follow") }
        if let tail { args += ["-n", String(tail)] }
        args.append(name)
        return args
    }

    /// Changes CPUs, memory or the home mount. Takes effect on the next boot.
    func setMachineConfig(_ name: String, cpus: Int?, memory: String?, homeMount: String?) async throws {
        let args = setMachineArguments(name, cpus: cpus, memory: memory, homeMount: homeMount)
        guard args.count > 4 else { return }
        try await run(args)
    }

    /// The boot log (kernel and init output).
    func machineBootLogs(_ name: String, follow: Bool = true) -> AsyncThrowingStream<String, Error> {
        stream(machineLogArguments(name, follow: follow, boot: true))
    }

    /// Parsed `container machine inspect` output.
    func machineDetail(_ name: String) async throws -> MachineDetail {
        let raw = try await inspectMachine(name)
        return try MachineParser.parseInspect(raw)
    }

}

// MARK: - Models

/// Everything `container machine inspect` tells us about one machine.
public struct MachineDetail: Sendable, Hashable {
    public var summary: MachineSummary
    public var containerID: String?
    public var diskSizeBytes: UInt64?
    public var createdAt: Date?
    public var startedAt: Date?
    /// "linux/arm64".
    public var platform: String
    public var imageDigest: String?
    public var username: String?
    public var guestHome: String?
    public var rawJSON: String

    public init(
        summary: MachineSummary, containerID: String? = nil, diskSizeBytes: UInt64? = nil,
        createdAt: Date? = nil, startedAt: Date? = nil, platform: String = "linux/arm64",
        imageDigest: String? = nil, username: String? = nil, guestHome: String? = nil, rawJSON: String = ""
    ) {
        self.summary = summary
        self.containerID = containerID
        self.diskSizeBytes = diskSizeBytes
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.platform = platform
        self.imageDigest = imageDigest
        self.username = username
        self.guestHome = guestHome
        self.rawJSON = rawJSON
    }
}

/// Images known to work as machines (they ship /sbin/init).
public enum MachineImages {
    public static let recommended = "alpine:3.22"
    public static let suggestions = ["alpine:3.22", "alpine:latest"]

    /// Machine names follow container name rules.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 63 else { return false }
        return name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    /// "alpine-3.22" for "alpine:3.22", like the CLI picks when no name is given.
    public static func suggestedName(for image: String) -> String {
        let summary = ImageSummary(reference: image.trimmingCharacters(in: .whitespaces))
        let base = summary.shortName.split(separator: "/").last.map(String.init) ?? "machine"
        let raw = "\(base)-\(summary.tag)"
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let cleaned = String(raw.filter { allowed.contains($0) }.prefix(63))
        return isValidName(cleaned) ? cleaned : "machine"
    }

    /// DNS name the platform gives every machine.
    public static func dnsName(for name: String) -> String {
        "\(name.lowercased()).machine"
    }
}

// MARK: - Parsing

public enum MachineParser {
    struct ListEntry: Decodable {
        var id: String
        var status: String?
        var isDefault: Bool?
        var ipAddress: String?
        var cpus: Int?
        var memory: UInt64?
        var diskSize: UInt64?
        var createdDate: String?

        enum CodingKeys: String, CodingKey {
            case id, status, ipAddress, cpus, memory, diskSize, createdDate
            case isDefault = "default"
        }
    }

    struct InspectEntry: Decodable {
        struct Descriptor: Decodable { var digest: String? }
        struct Image: Decodable {
            var reference: String?
            var descriptor: Descriptor?
        }
        struct Platform: Decodable {
            var os: String?
            var architecture: String?
            var variant: String?
        }
        struct UserSetup: Decodable {
            var username: String?
            var home: String?
        }
        var id: String
        var image: Image?
        var platform: Platform?
        var userSetup: UserSetup?
        var status: String?
        var startedDate: String?
        var createdDate: String?
        var containerId: String?
        var cpus: Int?
        var memory: UInt64?
        var homeMount: String?
        var diskSize: UInt64?
        var ipAddress: String?
    }

    /// Parses `container machine list --format json`.
    public static func parseList(_ text: String) throws -> [MachineSummary] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let entries: [ListEntry]
        do {
            entries = try JSONDecoder().decode([ListEntry].self, from: Data(trimmed.utf8))
        } catch {
            throw DeckError.parse("container machine list")
        }
        return entries.map { entry in
            MachineSummary(
                name: entry.id,
                state: runState(entry.status),
                cpus: entry.cpus,
                memoryBytes: entry.memory,
                ipAddress: cleanIP(entry.ipAddress),
                hostname: MachineImages.dnsName(for: entry.id),
                isDefault: entry.isDefault ?? false
            )
        }
    }

    /// Parses `container machine inspect <id>`. The output is an array with one item.
    public static func parseInspect(_ text: String) throws -> MachineDetail {
        let data = Data(text.utf8)
        let entry: InspectEntry
        if let list = try? JSONDecoder().decode([InspectEntry].self, from: data), let first = list.first {
            entry = first
        } else if let single = try? JSONDecoder().decode(InspectEntry.self, from: data) {
            entry = single
        } else {
            throw DeckError.parse("container machine inspect")
        }

        var platform = "\(entry.platform?.os ?? "linux")/\(entry.platform?.architecture ?? "arm64")"
        if let variant = entry.platform?.variant, !variant.isEmpty { platform += "/\(variant)" }

        let summary = MachineSummary(
            name: entry.id,
            image: entry.image?.reference ?? "",
            state: runState(entry.status),
            cpus: entry.cpus,
            memoryBytes: entry.memory,
            ipAddress: cleanIP(entry.ipAddress),
            hostname: MachineImages.dnsName(for: entry.id),
            isDefault: false,
            homeMount: entry.homeMount
        )
        return MachineDetail(
            summary: summary,
            containerID: entry.containerId,
            diskSizeBytes: entry.diskSize,
            createdAt: parseDate(entry.createdDate),
            startedAt: parseDate(entry.startedDate),
            platform: platform,
            imageDigest: entry.image?.descriptor?.digest,
            username: entry.userSetup?.username,
            guestHome: entry.userSetup?.home,
            rawJSON: text
        )
    }

    static func runState(_ raw: String?) -> ContainerRunState {
        ContainerRunState(rawValue: (raw ?? "").lowercased()) ?? .unknown
    }

    /// "192.168.64.3/24" becomes "192.168.64.3".
    static func cleanIP(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let slash = raw.firstIndex(of: "/") { return String(raw[..<slash]) }
        return raw
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }

    /// True when the error says this CLI has no `machine` command (releases
    /// before machines shipped). The screen shows an update note then.
    public static func isUnsupported(_ error: Error) -> Bool {
        isUnsupportedText(error.localizedDescription)
    }

    public static func isUnsupportedText(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("no machine support") { return true }
        let unknown = lower.contains("unknown command") || lower.contains("unexpected argument")
            || lower.contains("not a valid subcommand")
        return unknown && lower.contains("machine")
    }

    /// Turns raw CLI errors into messages people can act on.
    public static func explain(_ error: Error) -> Error {
        let text = error.localizedDescription
        if let friendly = friendlyMessage(for: text) {
            return DeckError.commandFailed("\(friendly)\n\nDetails: \(text)")
        }
        return error
    }

    public static func friendlyMessage(for text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("sbin/init") || lower.contains("no init") {
            return "This image has no init system at /sbin/init, so it cannot run as a machine. Try \(MachineImages.recommended), or build an image that includes an init system such as systemd."
        }
        if lower.contains("failed to create user") {
            return "The machine user could not be set up. The image needs /bin/sh, getent, date, chown, mkdir, cp and tr."
        }
        let unknownCommand = lower.contains("unexpected argument") || lower.contains("unknown command")
            || lower.contains("not a valid subcommand")
        if unknownCommand && lower.contains("machine") {
            return "This version of the container tool has no machine support. Update the container tool to use machines."
        }
        return nil
    }
}

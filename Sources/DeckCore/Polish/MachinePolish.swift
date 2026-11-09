import Foundation

// Machines v2: nested virtualisation, custom kernel, account options, init system
// check, Apply and Restart, and live stats read from /proc inside the machine.
// Flags checked against `container machine create --help` and `machine set --help` (1.6.1).

/// Create options the base `MachineOptions` does not carry.
public struct MachineCreateExtras: Sendable, Hashable {
    /// `--virtualization`: nested virtualisation (M3 or newer, kernel with KVM).
    public var virtualization: Bool
    /// `--kernel <path>`: custom kernel binary. Must be an absolute path.
    public var kernelPath: String?
    /// `--user <name|uid[:gid]>`: account name in the machine. Default is the Mac user.
    public var user: String?
    public var uid: Int?
    public var gid: Int?
    /// `--home <path>`: home folder of the account. Default /home/<user>.
    public var home: String?
    /// `--platform`, for example linux/amd64.
    public var platform: String?
    /// `--set-default`.
    public var setDefault: Bool

    public init(virtualization: Bool = false, kernelPath: String? = nil, user: String? = nil, uid: Int? = nil,
                gid: Int? = nil, home: String? = nil, platform: String? = nil, setDefault: Bool = false) {
        self.virtualization = virtualization
        self.kernelPath = kernelPath
        self.user = user
        self.uid = uid
        self.gid = gid
        self.home = home
        self.platform = platform
        self.setDefault = setDefault
    }

    /// Flags in the order the CLI documents them. Empty values are left out.
    public var arguments: [String] {
        var args: [String] = []
        if let platform = Self.clean(platform) { args += ["--platform", platform] }
        if let user = Self.clean(user) { args += ["--user", user] }
        if let uid { args += ["--uid", String(uid)] }
        if let gid { args += ["--gid", String(gid)] }
        if let home = Self.clean(home) { args += ["--home", home] }
        if setDefault { args.append("--set-default") }
        if virtualization { args.append("--virtualization") }
        if let kernel = Self.clean(kernelPath) { args += ["--kernel", kernel] }
        return args
    }

    /// Problems that stop a create. Empty when all is fine.
    public var problems: [String] {
        var list: [String] = []
        if let kernel = Self.clean(kernelPath), !kernel.hasPrefix("/") {
            list.append("The kernel path must start with /.")
        }
        if let home = Self.clean(home), !home.hasPrefix("/") {
            list.append("The home folder must start with /.")
        }
        if let user = Self.clean(user), !MachineAccount.isValidUser(user) {
            list.append("Use a user name like dev, or a number like 1000 or 1000:1000.")
        }
        return list
    }

    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public enum MachineAccount {
    /// "dev", "1000" or "1000:1000".
    public static func isValidUser(_ text: String) -> Bool {
        if text.range(of: #"^[0-9]+(:[0-9]+)?$"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"^[a-z_][a-z0-9_.-]{0,31}$"#, options: .regularExpression) != nil
    }
}

/// A change to a machine's boot settings (`container machine set`).
public struct MachineConfigChange: Sendable, Hashable {
    public var cpus: Int?
    public var memory: String?
    /// "rw", "ro" or "none".
    public var homeMount: String?
    public var virtualization: Bool?
    /// Absolute path of a kernel binary. The 1.6.1 CLI cannot clear it, so going back
    /// to the system kernel means pointing at `kernels/default.kernel-arm64`.
    public var kernelPath: String?

    public init(cpus: Int? = nil, memory: String? = nil, homeMount: String? = nil, virtualization: Bool? = nil, kernelPath: String? = nil) {
        self.cpus = cpus
        self.memory = memory
        self.homeMount = homeMount
        self.virtualization = virtualization
        self.kernelPath = kernelPath
    }

    public var isEmpty: Bool { settings.isEmpty }

    /// key=value pairs for `machine set`.
    public var settings: [String] {
        var list: [String] = []
        if let cpus { list.append("cpus=\(cpus)") }
        if let memory = MachineCreateExtras.clean(memory) { list.append("memory=\(memory)") }
        if let homeMount, ["rw", "ro", "none"].contains(homeMount) { list.append("home-mount=\(homeMount)") }
        if let virtualization { list.append("virtualization=\(virtualization)") }
        if let kernel = MachineCreateExtras.clean(kernelPath) { list.append("kernel=\(kernel)") }
        return list
    }
}

/// What `machines/<id>/boot-config.json` says. The inspect output has no
/// virtualisation or kernel fields, so the app reads this file (read only).
public struct MachineBootConfig: Sendable, Hashable, Decodable {
    public var virtualization: Bool?
    public var kernelPath: String?
    public var homeMount: String?
    public var cpus: Int?
    public var memory: String?

    public init(virtualization: Bool? = nil, kernelPath: String? = nil, homeMount: String? = nil, cpus: Int? = nil, memory: String? = nil) {
        self.virtualization = virtualization
        self.kernelPath = kernelPath
        self.homeMount = homeMount
        self.cpus = cpus
        self.memory = memory
    }

    public static func parse(_ text: String) -> MachineBootConfig? {
        try? JSONDecoder().decode(MachineBootConfig.self, from: Data(text.utf8))
    }

    /// `<appRoot>/plugin-state/machine-apiserver/machines/<name>/boot-config.json`.
    public static func fileURL(appRoot: String, machine: String) -> URL {
        URL(fileURLWithPath: appRoot)
            .appendingPathComponent("plugin-state/machine-apiserver/machines")
            .appendingPathComponent(machine)
            .appendingPathComponent("boot-config.json")
    }

    /// Default app root of Apple's container service.
    public static var defaultAppRoot: String {
        ContainerAppRoot.current()
    }

    /// True when the kernel is the system one (no custom path or the default link).
    public var usesSystemKernel: Bool {
        guard let kernelPath, !kernelPath.isEmpty else { return true }
        return (kernelPath as NSString).lastPathComponent.hasPrefix("default.kernel")
    }
}

/// Checks an image for an init system before it becomes a machine.
public enum MachineInitCheck {
    public enum Result: Sendable, Hashable {
        case ok
        case missing
        /// The image has no /bin/sh, which the machine account setup also needs.
        case noShell
        case failed(String)

        public var title: String {
            switch self {
            case .ok: return "Init system found"
            case .missing: return "No init system"
            case .noShell: return "No shell in the image"
            case .failed: return "Could not check the image"
            }
        }

        public var message: String {
            switch self {
            case .ok:
                return "The image has /sbin/init, so it can boot as a machine."
            case .missing:
                return "The image has no /sbin/init, so it cannot boot as a machine. Use \(MachineImages.recommended), or an image with systemd or OpenRC."
            case .noShell:
                return "The image has no /bin/sh. Machines need it to set up your account. Use \(MachineImages.recommended) or a full distribution image."
            case .failed(let detail):
                return "The check could not run. \(detail)"
            }
        }

        public var canCreate: Bool {
            switch self {
            case .missing, .noShell: return false
            default: return true
            }
        }
    }

    /// Exit codes of the check script.
    static let foundCode: Int32 = 0
    static let missingCode: Int32 = 3

    /// A throwaway container that tests for /sbin/init (a file or a link, as busybox has).
    public static func arguments(image: String, platform: String? = nil) -> [String] {
        var args = ["run", "--rm", "--progress", "none"]
        if let platform = MachineCreateExtras.clean(platform) { args += ["--platform", platform] }
        args += ["--entrypoint", "/bin/sh", image.trimmingCharacters(in: .whitespaces),
                 "-c", "if [ -x /sbin/init ] || [ -L /sbin/init ]; then exit 0; else exit 3; fi"]
        return args
    }

    public static func interpret(_ result: CommandResult) -> Result {
        if result.exitCode == foundCode { return .ok }
        if result.exitCode == missingCode { return .missing }
        let text = (result.stderr + "\n" + result.stdout)
        let lower = text.lowercased()
        if lower.contains("/bin/sh") && (lower.contains("not found") || lower.contains("failed to find")) {
            return .noShell
        }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("[") }
        return .failed(line.map { String($0) } ?? "Exit code \(result.exitCode).")
    }
}

// MARK: - Live stats from /proc

/// One reading of the machine's /proc files.
public struct MachineProcSample: Sendable, Hashable {
    /// Sum of all jiffies on the "cpu" line, and the idle plus iowait part.
    public var cpuTotal: UInt64
    public var cpuIdle: UInt64
    public var cpuCount: Int
    public var memoryTotalBytes: UInt64
    public var memoryAvailableBytes: UInt64
    public var load1: Double
    public var processes: Int
    public var netRxBytes: UInt64
    public var netTxBytes: UInt64
    public var diskReadBytes: UInt64
    public var diskWriteBytes: UInt64
    public var date: Date

    public init(cpuTotal: UInt64 = 0, cpuIdle: UInt64 = 0, cpuCount: Int = 0, memoryTotalBytes: UInt64 = 0,
                memoryAvailableBytes: UInt64 = 0, load1: Double = 0, processes: Int = 0, netRxBytes: UInt64 = 0,
                netTxBytes: UInt64 = 0, diskReadBytes: UInt64 = 0, diskWriteBytes: UInt64 = 0, date: Date = Date()) {
        self.cpuTotal = cpuTotal
        self.cpuIdle = cpuIdle
        self.cpuCount = cpuCount
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.load1 = load1
        self.processes = processes
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.date = date
    }

    public var memoryUsedBytes: UInt64 {
        memoryTotalBytes > memoryAvailableBytes ? memoryTotalBytes - memoryAvailableBytes : 0
    }

    /// Busy CPU since `previous`, where 100 means one full core (like `container stats`).
    public func cpuPercent(since previous: MachineProcSample?) -> Double? {
        guard let previous, cpuTotal > previous.cpuTotal else { return nil }
        let total = Double(cpuTotal - previous.cpuTotal)
        let idle = Double(cpuIdle >= previous.cpuIdle ? cpuIdle - previous.cpuIdle : 0)
        let busy = max(0, min(1, (total - idle) / total))
        return busy * Double(max(1, cpuCount)) * 100
    }
}

public enum MachineProcStats {
    /// Marker printed before the readings. The CLI drops the first line a
    /// non interactive `machine run` prints (seen on 1.6.1), so the script starts with blank lines.
    public static let marker = "__deck_proc__"

    public static let script = "echo; echo \(marker); cat /proc/stat; cat /proc/meminfo; cat /proc/loadavg; cat /proc/net/dev; cat /proc/diskstats"

    public static func arguments(machine: String) -> [String] {
        ["machine", "run", "--name", machine, "--", "sh", "-c", script]
    }

    public static func parse(_ text: String, date: Date = Date()) -> MachineProcSample? {
        var sample = MachineProcSample(date: date)
        var sawCPU = false
        var sawMemory = false
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) {
            lines = Array(lines[(index + 1)...])
        }
        var inNet = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("|bytes") {
                inNet = true
                continue
            }
            if inNet {
                // "eth0: 142 1 ..." or "eth0:12345678 ..." (wide counters touch the colon).
                if let colon = line.firstIndex(of: ":") {
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                    let numbers = line[line.index(after: colon)...].split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { UInt64($0) }
                    if name != "lo", numbers.count >= 9 {
                        sample.netRxBytes += numbers[0]
                        sample.netTxBytes += numbers[8]
                    }
                    continue
                }
                inNet = false
            }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = fields.first else { continue }
            if first == "cpu" {
                let values = fields.dropFirst().compactMap { UInt64($0) }
                guard values.count >= 4 else { continue }
                // user nice system idle iowait irq softirq steal (guest is already in user).
                let counted = Array(values.prefix(8))
                sample.cpuTotal = counted.reduce(0, +)
                sample.cpuIdle = values[3] + (values.count > 4 ? values[4] : 0)
                sawCPU = true
            } else if first.hasPrefix("cpu"), Int(first.dropFirst(3)) != nil {
                sample.cpuCount += 1
            } else if first == "MemTotal:", fields.count >= 2, let kb = UInt64(fields[1]) {
                sample.memoryTotalBytes = kb * 1024
                sawMemory = true
            } else if first == "MemAvailable:", fields.count >= 2, let kb = UInt64(fields[1]) {
                sample.memoryAvailableBytes = kb * 1024
            } else if first == "procs_running" || first == "procs_blocked" {
                continue
            } else if fields.count == 5, fields[3].contains("/"), let load = Double(first) {
                // loadavg: "0.00 0.00 0.00 1/85 58"
                sample.load1 = load
                if let total = fields[3].split(separator: "/").last.flatMap({ Int($0) }) { sample.processes = total }
            } else if fields.count >= 10, UInt64(fields[0]) != nil, UInt64(fields[1]) != nil, isWholeDisk(fields[2]) {
                // /proc/diskstats: major minor name reads merged sectorsRead ms writes merged sectorsWritten
                sample.diskReadBytes += (UInt64(fields[5]) ?? 0) * 512
                sample.diskWriteBytes += (UInt64(fields[9]) ?? 0) * 512
            }
        }
        return sawCPU || sawMemory ? sample : nil
    }

    /// Virtio and NVMe disks, not partitions, loop or ram devices.
    static func isWholeDisk(_ name: String) -> Bool {
        if name.range(of: #"^vd[a-z]+$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"^sd[a-z]+$"#, options: .regularExpression) != nil { return true }
        return name.range(of: #"^nvme[0-9]+n[0-9]+$"#, options: .regularExpression) != nil
    }
}

// MARK: - Client calls

public extension ContainerClient {
    /// `machine create` with the v2 options, which go before the image.
    func createMachineArguments(_ options: MachineOptions, extras: MachineCreateExtras) -> [String] {
        var args = createMachineArguments(options)
        guard let image = args.popLast() else { return args }
        args += extras.arguments
        args.append(image)
        return args
    }

    func createMachine(_ options: MachineOptions, extras: MachineCreateExtras) async throws {
        do {
            try await run(createMachineArguments(options, extras: extras))
        } catch {
            throw MachineParser.explain(error)
        }
    }

    func setMachineArguments(_ name: String, change: MachineConfigChange) -> [String] {
        ["machine", "set", "--name", name] + change.settings
    }

    /// Saves the change. With `restart` a running machine is stopped and booted
    /// again so the change applies now.
    func applyMachineConfig(_ name: String, change: MachineConfigChange, restart: Bool) async throws {
        if !change.isEmpty {
            do {
                try await run(setMachineArguments(name, change: change))
            } catch {
                throw MachineParser.explain(error)
            }
        }
        if restart {
            try await stopMachine(name)
            try await bootMachine(name)
        }
    }

    /// Boot settings from the service's own file. nil when it cannot be read.
    func machineBootConfig(_ name: String, appRoot: String = MachineBootConfig.defaultAppRoot) -> MachineBootConfig? {
        let url = MachineBootConfig.fileURL(appRoot: appRoot, machine: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MachineBootConfig.parse(text)
    }

    /// Runs the init system check. Pulls the image when it is not here yet.
    func checkMachineImage(_ image: String, platform: String? = nil) async -> MachineInitCheck.Result {
        do {
            let result = try await runner.run(cli.path, MachineInitCheck.arguments(image: image, platform: platform))
            return MachineInitCheck.interpret(result)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// One /proc reading from a running machine. Never call it for a stopped
    /// machine: `machine run` boots it.
    func machineProcSample(_ name: String) async throws -> MachineProcSample {
        let result = try await runner.run(cli.path, MachineProcStats.arguments(machine: name))
        guard result.exitCode == 0, let sample = MachineProcStats.parse(result.stdout) else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DeckError.commandFailed(detail.isEmpty ? "The machine did not answer." : detail)
        }
        return sample
    }
}

/// What this Mac can do for machines.
public enum MachineHost {
    /// Nested virtualisation needs an M3 or newer chip.
    public static func supportsNestedVirtualization(chip: String = HostFacts.chip) -> Bool {
        guard let range = chip.range(of: #"M(\d+)"#, options: .regularExpression) else { return false }
        let digits = chip[range].dropFirst()
        return (Int(digits) ?? 0) >= 3
    }
}

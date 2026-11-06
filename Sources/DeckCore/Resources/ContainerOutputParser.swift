import Foundation

/// Turns `container` command output into the shared models.
/// Pure functions, so tests can feed recorded output without the platform.
public enum ContainerOutputParser {

    // MARK: Containers

    /// `container list --all --format json`
    public static func containers(_ output: String) throws -> [ContainerSummary] {
        try CLIJSON.decodeList(CLIContainer.self, from: output, what: "container list")
            .compactMap(summary(from:))
    }

    /// `container inspect <id>` (pretty printed JSON array).
    public static func containerDetails(_ output: String) throws -> [ContainerDetail] {
        let items = try CLIJSON.decodeList(CLILenient<CLIContainer>.self, from: output, what: "container inspect")
        let raw = CLIJSON.prettyItems(output)
        var details: [ContainerDetail] = []
        for (index, item) in items.enumerated() {
            guard let container = item.value, let mapped = Self.summary(from: container) else { continue }
            details.append(Self.detail(from: container, summary: mapped, rawJSON: index < raw.count ? raw[index] : ""))
        }
        return details
    }

    static func summary(from item: CLIContainer) -> ContainerSummary? {
        let config = item.configuration
        guard let id = CLIText.nonEmpty(config?.id) ?? CLIText.nonEmpty(item.id) else { return nil }

        let attachment = item.networks.first
        let ip = attachment?.ipv4Address.flatMap { CLIText.nonEmpty(CLIText.withoutCIDRSuffix($0)) }
        let hostname = (CLIText.nonEmpty(attachment?.hostname) ?? CLIText.nonEmpty(config?.networks.first?.hostname))
            .map { CLIText.withoutTrailingDot($0) }

        var command: [String] = []
        if let process = config?.initProcess {
            if let executable = CLIText.nonEmpty(process.executable) { command.append(executable) }
            command += process.arguments
        }

        return ContainerSummary(
            id: id,
            name: id,
            image: config?.imageReference ?? "",
            state: runState(item.state),
            ipAddress: ip,
            hostname: hostname,
            ports: ports(config?.publishedPorts ?? []),
            platform: config?.platform?.text ?? "linux/arm64",
            cpus: config?.cpus,
            memoryBytes: config?.memoryBytes,
            createdAt: config?.creationDate,
            labels: config?.labels ?? [:],
            command: command,
            startedAt: item.startedDate
        )
    }

    static func detail(from item: CLIContainer, summary: ContainerSummary, rawJSON: String) -> ContainerDetail {
        let config = item.configuration
        let process = config?.initProcess

        let env = (process?.environment ?? []).map { line -> EnvVar in
            if let equals = line.firstIndex(of: "=") {
                return EnvVar(key: String(line[..<equals]), value: String(line[line.index(after: equals)...]))
            }
            return EnvVar(key: line, value: "")
        }

        let mounts = (config?.mounts ?? []).map { fs in
            MountInfo(
                type: fs.displayKind,
                source: fs.volumeName ?? fs.source ?? "",
                destination: fs.destination ?? "",
                readOnly: fs.options.contains("ro")
            )
        }

        var networks: [NetworkAttachment] = item.networks.map { attachment in
            NetworkAttachment(
                network: attachment.network ?? "default",
                ipAddress: attachment.ipv4Address.map { CLIText.withoutCIDRSuffix($0) },
                gateway: attachment.ipv4Gateway.map { CLIText.withoutCIDRSuffix($0) },
                macAddress: attachment.macAddress,
                hostname: attachment.hostname.map { CLIText.withoutTrailingDot($0) }
            )
        }
        if networks.isEmpty {
            // Stopped containers have no live attachments. Show what they ask for.
            networks = (config?.networks ?? []).map { wanted in
                NetworkAttachment(
                    network: wanted.network ?? "default",
                    macAddress: wanted.macAddress,
                    hostname: wanted.hostname.map { CLIText.withoutTrailingDot($0) }
                )
            }
        }

        var entrypoint: [String] = []
        if let executable = CLIText.nonEmpty(process?.executable) { entrypoint = [executable] }

        return ContainerDetail(
            summary: summary,
            entrypoint: entrypoint,
            workingDir: CLIText.nonEmpty(process?.workingDirectory),
            env: env,
            mounts: mounts,
            networks: networks,
            rosetta: config?.rosetta ?? false,
            rawJSON: rawJSON,
            arguments: process?.arguments ?? [],
            user: process?.user,
            readOnlyRootfs: config?.readOnly ?? false
        )
    }

    static func runState(_ text: String?) -> ContainerRunState {
        switch (text ?? "").lowercased() {
        case "running": return .running
        case "stopped", "exited", "created": return .stopped
        case "stopping": return .stopping
        default: return .unknown
        }
    }

    /// Port ranges (`count` above 1) become one mapping per port, up to 64.
    static func ports(_ items: [CLIPublishPort]) -> [PortMapping] {
        var result: [PortMapping] = []
        for item in items {
            guard let hostPort = item.hostPort, let containerPort = item.containerPort else { continue }
            var host = CLIText.nonEmpty(item.hostAddress)
            if host == "0.0.0.0" { host = nil }
            let proto = CLIText.nonEmpty(item.proto)?.lowercased() ?? "tcp"
            let count = min(max(item.count ?? 1, 1), 64)
            for offset in 0..<count {
                result.append(PortMapping(hostAddress: host, hostPort: hostPort + offset, containerPort: containerPort + offset, proto: proto))
            }
        }
        return result
    }

    /// The id printed by `container run --detach` (last line of stdout).
    public static func runOutputID(_ stdout: String) -> String? {
        stdout
            .split(whereSeparator: \.isNewline)
            .map { CLIText.strippingANSI(String($0)).trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    // MARK: Stats

    /// `container stats --no-stream --format json`.
    /// Newer CLIs include `cpuUtilization` (fraction of one core). Older ones only
    /// give cumulative `cpuUsageUsec`, so the percent comes from the previous
    /// sample kept in `cache`. The first sample of a container reads 0.
    public static func stats(_ output: String, cache: CPUSampleCache, now: Date = Date()) throws -> [ContainerStats] {
        let items = try CLIJSON.decodeList(CLIStats.self, from: output, what: "container stats")
        return items.compactMap { item in
            guard let id = CLIText.nonEmpty(item.id) else { return nil }
            let fromCache = item.cpuUsageUsec.flatMap { cache.percent(id: id, usageUsec: $0, at: now) }
            let percent: Double
            if let utilization = item.cpuUtilization {
                percent = max(0, utilization * 100)
            } else {
                percent = fromCache ?? 0
            }
            return ContainerStats(
                id: id,
                cpuPercent: percent,
                memoryUsageBytes: item.memoryUsageBytes ?? 0,
                memoryLimitBytes: item.memoryLimitBytes ?? 0,
                netRxBytes: item.networkRxBytes ?? 0,
                netTxBytes: item.networkTxBytes ?? 0,
                blockReadBytes: item.blockReadBytes ?? 0,
                blockWriteBytes: item.blockWriteBytes ?? 0,
                pids: item.numProcesses ?? 0,
                timestamp: now,
                cpuUsageUsec: item.cpuUsageUsec,
                reportedCPUPercent: item.cpuUtilization.map { max(0, $0 * 100) }
            )
        }
    }

    // MARK: Images

    /// `container image list --format json`
    /// `sizeBytes` is the size for `preferredArchitecture` (like `image ls -v` and Docker),
    /// not the sum of every platform in the index.
    public static func images(_ output: String, preferredArchitecture: String = ImagePlatform.hostArchitecture) throws -> [ImageSummary] {
        try CLIJSON.decodeList(CLIImage.self, from: output, what: "image list").compactMap {
            imageSummary(from: $0, preferredArchitecture: preferredArchitecture)
        }
    }

    static func imageSummary(from image: CLIImage, preferredArchitecture: String = ImagePlatform.hostArchitecture) -> ImageSummary? {
        guard let reference = CLIText.nonEmpty(image.reference) else { return nil }
        let variants = image.platformVariants
        var platforms: [String] = []
        for variant in variants {
            if let text = variant.platform?.text, !platforms.contains(text) { platforms.append(text) }
        }
        let preferred = variants.first { $0.platform?.architecture == preferredArchitecture && $0.platform?.os != "windows" }
        var size = (preferred ?? variants.first)?.size ?? 0
        if size == 0, let text = image.fullSize {
            size = parseByteCount(text) ?? 0
        }
        var created = image.creationDate
        if created == nil {
            // Earliest variant creation time.
            created = variants.compactMap { $0.config?.created.flatMap(DeckDate.parse) }.min()
        }
        return ImageSummary(
            reference: reference,
            digest: image.descriptor?.digest ?? "",
            sizeBytes: size,
            createdAt: created,
            platforms: platforms
        )
    }

    /// `container image inspect <ref>`. `preferredArchitecture` picks the variant for layers and config.
    public static func imageDetail(_ output: String, preferredArchitecture: String = "arm64") throws -> ImageDetail {
        let items = try CLIJSON.decodeList(CLILenient<CLIImage>.self, from: output, what: "image inspect")
        let raw = CLIJSON.prettyItems(output)
        guard let index = items.firstIndex(where: { $0.value != nil }),
              let image = items[index].value,
              let summary = imageSummary(from: image, preferredArchitecture: preferredArchitecture) else {
            throw DeckError.parse("image inspect")
        }
        let variants = image.platformVariants
        let chosen = variants.first { $0.platform?.architecture == preferredArchitecture } ?? variants.first
        let oci = chosen?.config

        var config = ImageConfigInfo()
        if let c = oci?.config {
            config = ImageConfigInfo(
                entrypoint: c.entrypoint,
                cmd: c.cmd,
                env: c.env.map(envVar),
                workingDir: CLIText.nonEmpty(c.workingDir),
                exposedPorts: c.exposedPorts,
                labels: c.labels,
                user: CLIText.nonEmpty(c.user)
            )
        }

        // diff_ids line up with the history entries that made a layer.
        let layerHistory = (oci?.history ?? []).filter { !$0.emptyLayer }
        let layers = (oci?.diffIDs ?? []).enumerated().map { offset, digest in
            ImageLayer(
                digest: digest,
                sizeBytes: 0,
                createdBy: offset < layerHistory.count ? cleanCreatedBy(layerHistory[offset].createdBy) : nil
            )
        }

        return ImageDetail(summary: summary, layers: layers, config: config, rawJSON: index < raw.count ? raw[index] : "")
    }

    static func envVar(_ line: String) -> EnvVar {
        guard let equals = line.firstIndex(of: "=") else { return EnvVar(key: line, value: "") }
        return EnvVar(key: String(line[..<equals]), value: String(line[line.index(after: equals)...]))
    }

    /// Drops the "/bin/sh -c #(nop) " noise Docker puts in front of metadata steps.
    static func cleanCreatedBy(_ text: String?) -> String? {
        guard var value = CLIText.nonEmpty(text) else { return nil }
        for prefix in ["/bin/sh -c #(nop) ", "/bin/sh -c #(nop)"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// "45.2 MB" or "1.1 GB" (decimal units, as ByteCountFormatter prints) to bytes.
    static func parseByteCount(_ text: String) -> UInt64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard let first = parts.first, let number = Double(first.replacingOccurrences(of: ",", with: "")) else {
            return nil
        }
        let unit = parts.count > 1 ? parts[1].uppercased() : "B"
        let scale: Double
        switch unit {
        case "KB": scale = 1e3
        case "MB": scale = 1e6
        case "GB": scale = 1e9
        case "TB": scale = 1e12
        case "KIB": scale = 1024
        case "MIB": scale = 1024 * 1024
        case "GIB": scale = 1024 * 1024 * 1024
        default: scale = 1
        }
        let value = number * scale
        guard value.isFinite, value >= 0, value < 1.8e19 else { return nil }
        return UInt64(value)
    }

    /// Sizes as `container` writes them ("10G", "512m", "2048mb", "1gib"). All units are binary.
    static func parseBinarySize(_ text: String) -> UInt64? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = value.prefix(while: { $0.isNumber || $0 == "." })
        guard let number = Double(digits) else { return nil }
        let unit = value.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let power: Double
        switch unit {
        case "", "b": power = 0
        case "k", "kb", "kib": power = 1
        case "m", "mb", "mib": power = 2
        case "g", "gb", "gib": power = 3
        case "t", "tb", "tib": power = 4
        case "p", "pb", "pib": power = 5
        default: return nil
        }
        let bytes = number * pow(1024, power)
        guard bytes.isFinite, bytes >= 0, bytes < 1.8e19 else { return nil }
        return UInt64(bytes)
    }

    // MARK: Volumes and networks

    /// `container volume list --format json`
    public static func volumes(_ output: String) throws -> [VolumeSummary] {
        try CLIJSON.decodeList(CLIVolume.self, from: output, what: "volume list").compactMap { volume in
            guard let name = CLIText.nonEmpty(volume.name) else { return nil }
            var size = volume.sizeInBytes
            if size == nil, let text = volume.options["size"] { size = parseBinarySize(text) }
            return VolumeSummary(
                name: name,
                sizeBytes: size,
                createdAt: volume.creationDate,
                labels: volume.labels,
                backingPath: CLIText.nonEmpty(volume.source),
                isAnonymous: volume.labels["com.apple.container.resource.anonymous"] != nil
            )
        }
    }

    /// `container network list --format json`
    public static func networks(_ output: String) throws -> [NetworkSummary] {
        try CLIJSON.decodeList(CLINetwork.self, from: output, what: "network list").compactMap { network in
            guard let name = CLIText.nonEmpty(network.name) else { return nil }
            let role = network.labels["com.apple.container.resource.role"]
            return NetworkSummary(
                name: name,
                subnet: CLIText.nonEmpty(network.statusSubnet) ?? CLIText.nonEmpty(network.configSubnet),
                gateway: network.gateway.map { CLIText.withoutCIDRSuffix($0) },
                isInternal: (network.mode ?? "").lowercased() == "hostonly",
                state: CLIText.nonEmpty(network.state) ?? (network.statusSubnet != nil ? "running" : "created"),
                labels: network.labels,
                // The status IPv6 value is the gateway address with its prefix ("fd00::1/64"),
                // so the configured prefix wins when there is one.
                ipv6Subnet: CLIText.nonEmpty(network.configSubnetV6) ?? CLIText.nonEmpty(network.statusSubnetV6),
                createdAt: network.creationDate,
                isBuiltin: role == "builtin" || name == "default"
            )
        }
    }

    /// Volume names used by each container (for `VolumeSummary.usedBy`).
    public static func volumeUsers(_ details: [ContainerDetail]) -> [String: [String]] {
        var users: [String: [String]] = [:]
        for detail in details {
            for mount in detail.mounts where mount.type == "volume" && !mount.source.isEmpty {
                users[mount.source, default: []].append(detail.summary.id)
            }
        }
        return users
    }

    /// Container ids per network name (for `NetworkSummary.attachedContainers`).
    /// Stopped containers list their configured networks, so they count too.
    public static func networkUsers(_ details: [ContainerDetail]) -> [String: [String]] {
        var users: [String: [String]] = [:]
        for detail in details {
            var seen = Set<String>()
            for attachment in detail.networks where !attachment.network.isEmpty && seen.insert(attachment.network).inserted {
                users[attachment.network, default: []].append(detail.summary.id)
            }
        }
        return users
    }

    /// `container system dns list --format json` prints `["test", "dev.local"]`.
    /// nil when the output is not that shape (older CLIs print only the table).
    public static func dnsDomains(_ output: String) -> [String]? {
        guard let list = CLIJSON.object(output) as? [Any] else { return nil }
        return list.compactMap { item -> String? in
            let raw: String?
            if let text = item as? String {
                raw = text
            } else if let entry = item as? [String: Any] {
                raw = entry["domain"] as? String ?? entry["name"] as? String ?? entry["id"] as? String
            } else {
                raw = nil
            }
            guard let raw else { return nil }
            var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if domain.hasSuffix(".") { domain.removeLast() }
            return domain.isEmpty ? nil : domain
        }
    }

    // MARK: System

    /// `container system df --format json`
    public static func diskUsage(_ output: String) throws -> DiskUsage {
        let usage = try CLIJSON.decode(CLIDiskUsage.self, from: output, what: "system df")
        return DiskUsage(
            images: usage.images?.bucket ?? UsageBucket(),
            containers: usage.containers?.bucket ?? UsageBucket(),
            volumes: usage.volumes?.bucket ?? UsageBucket()
        )
    }

    /// `container system property list --format json`.
    /// 1.x prints nested tables (`{"build": {"cpus": 2}}`), which become "build.cpus".
    /// Older releases printed `[{id, value, description}]`. Both are read.
    public static func systemProperties(_ output: String) throws -> [SystemProperty] {
        guard let root = CLIJSON.object(output) else { throw DeckError.parse("system property list") }
        var result: [SystemProperty] = []
        if let table = root as? [String: Any] {
            flatten(table, prefix: "", into: &result)
        } else if let list = root as? [Any] {
            for case let entry as [String: Any] in list {
                guard let key = entry["id"] as? String ?? entry["key"] as? String else { continue }
                let value = entry["value"].map { CLIJSON.scalarText($0) } ?? ""
                let note = CLIText.nonEmpty(entry["description"] as? String) ?? propertyDescriptions[key]
                result.append(SystemProperty(key: key, value: value, description: note))
            }
        } else {
            throw DeckError.parse("system property list")
        }
        return result.sorted { $0.key < $1.key }
    }

    private static func flatten(_ table: [String: Any], prefix: String, into result: inout [SystemProperty]) {
        for (name, value) in table {
            let key = prefix.isEmpty ? name : "\(prefix).\(name)"
            if let nested = value as? [String: Any] {
                flatten(nested, prefix: key, into: &result)
            } else {
                result.append(SystemProperty(key: key, value: CLIJSON.scalarText(value), description: propertyDescriptions[key]))
            }
        }
    }

    /// Short help for the keys in `config.toml` (from Apple's config reference).
    public static let propertyDescriptions: [String: String] = [
        "build.cpus": "CPUs for the builder VM",
        "build.memory": "Memory for the builder VM",
        "build.rosetta": "Builder can build amd64 images with Rosetta",
        "build.image": "Builder image",
        "container.cpus": "Default CPUs per container",
        "container.memory": "Default memory per container",
        "machine.cpus": "CPUs for new machines",
        "machine.memory": "Memory for new machines",
        "machine.homeMount": "How machines mount your home folder (rw, ro or none)",
        "machine.virtualization": "Nested virtualization in machines",
        "dns.domain": "Local domain for container names, like web.test",
        "kernel.binaryPath": "Kernel file inside the kernel archive",
        "kernel.url": "Kernel archive to download",
        "kernel.digest": "Expected digest of the kernel archive",
        "network.subnet": "Default IPv4 subnet for new networks",
        "network.subnetv6": "Default IPv6 subnet for new networks",
        "registry.domain": "Registry used when an image name has none",
        "vminit.image": "Init image that boots container VMs"
    ]

    /// `container registry list --format json`, or the table when JSON is not supported.
    public static func registries(_ output: String) -> [String] {
        if let items = try? CLIJSON.decodeList(CLIRegistry.self, from: output, what: "registry list"),
           CLIJSON.payload(output) != nil {
            return items.compactMap { CLIText.nonEmpty($0.name) }
        }
        // Table: first column, skip the header.
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let column = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map { String($0) }
                guard let first = column, first.uppercased() != "HOSTNAME", first.uppercased() != "REGISTRY" else { return nil }
                return first
            }
    }

    // MARK: Files

    /// Marker printed before `ls -la` output when `stat` is not available.
    static let lsMarker = "__DECK_LS__"

    /// Script for `listFiles`. Works with busybox and GNU coreutils.
    /// Prints "type|size|mtime|mode|name" per entry, then "LDIR|name" for
    /// symlinks that point at folders. Falls back to `ls -la`.
    static let listFilesScript = """
    cd "$1" || exit 2
    if stat -c %n . >/dev/null 2>&1; then
      stat -c '%F|%s|%Y|%A|%n' -- .[!.]* ..?* * 2>/dev/null
      for f in .[!.]* ..?* *; do
        if [ -L "$f" ] && [ -d "$f" ]; then printf 'LDIR|%s\\n' "$f"; fi
      done
      exit 0
    fi
    echo \(lsMarker)
    ls -la
    """

    /// Output of `listFilesScript` for folder `path`.
    public static func fileEntries(_ output: String, in path: String) -> [FileEntry] {
        let lines = output.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if let marker = lines.firstIndex(of: lsMarker) {
            return lsEntries(Array(lines[(marker + 1)...]), in: path)
        }
        var symlinkDirs = Set<String>()
        for line in lines where line.hasPrefix("LDIR|") {
            symlinkDirs.insert(String(line.dropFirst(5)))
        }
        var entries: [FileEntry] = []
        for line in lines where !line.isEmpty && !line.hasPrefix("LDIR|") {
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5 else { continue }
            let name = parts[4]
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            let type = parts[0].lowercased()
            let isLink = type.contains("symbolic link")
            let isDir = type == "directory" || (isLink && symlinkDirs.contains(name))
            let mtime = Double(parts[2]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            entries.append(FileEntry(
                name: name,
                path: join(path, name),
                isDirectory: isDir,
                isSymlink: isLink,
                sizeBytes: UInt64(parts[1]) ?? 0,
                modified: mtime,
                permissions: parts[3]
            ))
        }
        return sortEntries(entries)
    }

    /// `ls -la` output. Dates are not read (formats differ between images).
    static func lsEntries(_ lines: [String], in path: String) -> [FileEntry] {
        var entries: [FileEntry] = []
        for line in lines {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 9, let kind = fields[0].first, "-dlcbps".contains(kind) else { continue }
            var name = fields[8...].joined(separator: " ")
            if kind == "l", let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            guard name != ".", name != ".." else { continue }
            entries.append(FileEntry(
                name: name,
                path: join(path, name),
                isDirectory: kind == "d",
                isSymlink: kind == "l",
                sizeBytes: UInt64(fields[4]) ?? 0,
                modified: nil,
                permissions: fields[0]
            ))
        }
        return sortEntries(entries)
    }

    static func join(_ folder: String, _ name: String) -> String {
        if folder.isEmpty { return "/" + name }
        return folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// Folders first, then by name.
    static func sortEntries(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Keeps the last cumulative CPU sample per container, so repeated `stats()`
/// calls can turn `cpuUsageUsec` into a percent on CLIs that do not print one.
public final class CPUSampleCache: @unchecked Sendable {
    public static let shared = CPUSampleCache()

    private struct Sample {
        var usageUsec: UInt64
        var time: Date
        var percent: Double?
    }

    private let lock = NSLock()
    private var samples: [String: Sample] = [:]

    public init() {}

    /// Records this sample and returns the percent since the previous one
    /// (100 means one full core). nil for the first sample.
    public func percent(id: String, usageUsec: UInt64, at time: Date) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = samples[id], usageUsec >= previous.usageUsec else {
            // First sample, or the container restarted and its counter reset.
            samples[id] = Sample(usageUsec: usageUsec, time: time, percent: nil)
            return nil
        }
        let elapsed = time.timeIntervalSince(previous.time)
        // Several screens poll at once. A reading right after another one
        // repeats the last percent instead of reading 0.
        guard elapsed > 0.5 else { return previous.percent }
        let usedSeconds = Double(usageUsec - previous.usageUsec) / 1_000_000
        let percent = max(0, usedSeconds / elapsed * 100)
        samples[id] = Sample(usageUsec: usageUsec, time: time, percent: percent)
        return percent
    }

    public func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

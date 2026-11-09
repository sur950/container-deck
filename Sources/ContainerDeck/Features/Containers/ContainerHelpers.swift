import SwiftUI
import AppKit
import DeckCore

// Shared helpers for the Containers screens, the Run sheet and the Dashboard.

/// Things a person can do to a container from a list, menu or header.
enum ContainerOp: String, CaseIterable, Identifiable {
    case start, stop, restart, kill, delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        case .kill: return "Kill"
        case .delete: return "Delete"
        }
    }

    var icon: DeckIconName {
        switch self {
        case .start: return .play
        case .stop: return .stop
        case .restart: return .restart
        case .kill: return .kill
        case .delete: return .trash
        }
    }

    /// True when the op ends a running container on purpose.
    var endsContainer: Bool { self != .start }

    func doneMessage(count: Int, name: String?) -> String {
        let subject = count == 1 ? (name ?? "the container") : "\(count) containers"
        switch self {
        case .start: return "Started \(subject)"
        case .stop: return "Stopped \(subject)"
        case .restart: return "Restarted \(subject)"
        case .kill: return "Killed \(subject)"
        case .delete: return "Deleted \(subject)"
        }
    }

    /// The CLI command for this op, shown as a hint.
    func commandLine(_ ids: [String], client: ContainerClient) -> String {
        switch self {
        case .start: return client.commandLine(["start"] + ids)
        case .stop: return client.commandLine(["stop"] + ids)
        case .kill: return client.commandLine(["kill"] + ids)
        case .delete: return client.commandLine(["delete", "--force"] + ids)
        case .restart:
            return client.commandLine(["stop"] + ids) + " && " + client.commandLine(["start"] + ids)
        }
    }
}

/// Runs container ops with feedback, so every screen behaves the same.
@MainActor
enum ContainerOps {
    /// Runs `op` on every id. Returns true when all of them worked.
    @discardableResult
    static func perform(_ op: ContainerOp, ids: [String], names: [String: String] = [:], state: AppState) async -> Bool {
        guard let client = state.client, !ids.isEmpty else { return false }
        var failed = false
        for id in ids {
            if op.endsContainer {
                BackgroundServices.shared.noteUserAction(stopping: id)
            }
            do {
                switch op {
                case .start: try await client.startContainer(id)
                case .stop: try await client.stopContainer(id)
                case .restart: try await client.restartContainer(id)
                case .kill: try await client.killContainer(id)
                case .delete:
                    try await client.deleteContainer(id, force: true)
                    removeAutoStart(id)
                }
            } catch {
                failed = true
                state.showError(error)
            }
        }
        state.resourcesChanged()
        if !failed {
            let name = ids.count == 1 ? (names[ids[0]] ?? ids[0]) : nil
            state.showToast(op.doneMessage(count: ids.count, name: name), style: .success)
        }
        return !failed
    }

    /// Removes stopped containers. Skips Apple's builder container, which
    /// `container build` needs, so `container prune` is not used here.
    static func prune(state: AppState) async {
        guard let client = state.client else { return }
        let targets: [ContainerSummary]
        do {
            targets = try await client.listContainers(all: true).filter {
                !$0.isRunning && !ContainersStore.isBuilder($0) && !ContainersStore.isHelper($0)
            }
        } catch {
            state.showError(error)
            return
        }
        guard !targets.isEmpty else {
            state.showToast("No stopped containers to remove")
            return
        }
        var removed = 0
        for item in targets {
            do {
                try await client.deleteContainer(item.id)
                removeAutoStart(item.id)
                removed += 1
            } catch {
                state.showError(error)
            }
        }
        if removed > 0 {
            state.showToast(removed == 1 ? "Removed 1 stopped container" : "Removed \(removed) stopped containers", style: .success)
        }
        state.resourcesChanged()
    }

    /// Shell Terminal opens in a container: the image's shell when the app
    /// kept the container running for it, otherwise `/bin/sh`.
    static func terminalShell(_ id: String) -> String {
        BackgroundServices.shared.container(id).map(BareShell.terminalShell(for:)) ?? BareShell.defaultShell
    }

    /// `container exec -it <id> <shell>` for hints.
    static func terminalCommandLine(_ id: String, client: ContainerClient) -> String {
        client.commandLine(client.shellArguments(id, shell: terminalShell(id)))
    }

    /// Opens a shell in the terminal app chosen in Settings.
    static func openTerminal(_ id: String, state: AppState) {
        guard let client = state.client else { return }
        do {
            try TerminalLauncher.open(command: client.shellCommand(id, shell: terminalShell(id))) { error in
                state.showError(error)
            }
        } catch {
            state.showError(error)
        }
    }

    /// Saves the container's file system as a tar file the person picks.
    static func exportFilesystem(_ id: String, name: String, state: AppState) async {
        guard let client = state.client else { return }
        let panel = NSSavePanel()
        panel.title = "Export File System"
        panel.message = "Save the files of \(name) as a tar archive."
        panel.nameFieldStringValue = "\(name).tar"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.showToast("Exporting \(name)…")
        do {
            try await client.exportContainer(id, to: url)
            state.showToast("Saved \(url.lastPathComponent)", style: .success)
        } catch {
            state.showError(error)
        }
    }

    /// Opens the Run sheet filled in with this container's settings.
    static func editAndRecreate(_ id: String, state: AppState) async {
        guard let client = state.client else { return }
        do {
            // Full capture (user, read only root, DNS, limits and more), with
            // image and system defaults left out. See DeckCore ContainerRecreate.
            let capture = try await client.captureForRecreate(id)
            state.runRequest = RunRequest(options: capture.options, replacing: capture.id)
        } catch {
            state.showError(error)
        }
    }

    /// One click fix for a container that stopped because it ran a bare
    /// shell: recreates it with `sleep infinity` through the safe recreate
    /// flow. When the checks find a problem, the Edit and Recreate sheet
    /// opens with the command filled in, so the person can fix it there.
    static func keepRunning(_ id: String, shell: String, state: AppState) async {
        guard let client = state.client else { return }
        do {
            let plan = try await client.keepRunningPlan(id, shell: shell)
            let issues = await client.checkRecreate(plan)
            if !issues.isEmpty {
                state.runRequest = RunRequest(options: plan.new, replacing: plan.old.id)
                return
            }
            let keepAutoStart = isAutoStart(id)
            BackgroundServices.shared.noteUserAction(stopping: id)
            let outcome = try await client.performRecreate(plan)
            state.resourcesChanged()
            switch outcome {
            case .recreated(let newID):
                let finalID = newID.isEmpty ? id : newID
                if finalID != id { removeAutoStart(id) }
                if keepAutoStart { setAutoStart(finalID, true) }
                state.showToast("\(finalID) keeps running now. Use Terminal to open a shell.", style: .success)
            case .restored(let failure, _):
                state.showError(DeckError.commandFailed("The new container did not start, so \(id) was put back. \(failure)"))
            case .notRestored(let failure, let restoreFailure, let command):
                state.showError(DeckError.commandFailed(
                    "The new container did not start, and \(id) could not be put back. \(failure) \(restoreFailure) Run this to make it again: \(command)"
                ))
            }
        } catch {
            state.showError(error)
        }
    }

    // MARK: Auto start

    static func isAutoStart(_ id: String) -> Bool {
        Prefs.autoStartContainers.contains(id)
    }

    static func setAutoStart(_ id: String, _ on: Bool) {
        var list = Prefs.autoStartContainers.filter { $0 != id }
        if on { list.append(id) }
        Prefs.autoStartContainers = list
    }

    static func removeAutoStart(_ id: String) {
        if isAutoStart(id) { setAutoStart(id, false) }
    }
}

/// Small text helpers.
enum ContainerText {
    /// Joins arguments into one line, quoting the ones with spaces.
    static func shellJoin(_ args: [String]) -> String {
        args.map { arg in
            if arg.isEmpty { return "''" }
            if arg.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "\t" }) {
                return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return arg
        }.joined(separator: " ")
    }

    /// Splits a command line into arguments. Handles single and double quotes.
    static func shellSplit(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escaping = false
        for ch in text {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    escaping = true
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\\" {
                escaping = true
                hasToken = true
            } else if ch == "'" || ch == "\"" {
                quote = ch
                hasToken = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if hasToken {
                    result.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    /// Joins a folder path and a name.
    static func joinPath(_ base: String, _ name: String) -> String {
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }

    /// Parent folder of a path, never above "/".
    static func parentPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// "8080 → 80/tcp" style label for a port.
    static func portLabel(_ port: PortMapping) -> String {
        port.hostPort == port.containerPort
            ? "\(port.hostPort)/\(port.proto)"
            : "\(port.hostPort):\(port.containerPort)/\(port.proto)"
    }

    /// Browser link for a published port.
    static func portURL(_ port: PortMapping) -> URL? {
        guard port.proto.lowercased() == "tcp" else { return nil }
        var host = port.hostAddress ?? "localhost"
        if host.isEmpty || host == "0.0.0.0" || host == "::" { host = "localhost" }
        let scheme = (port.containerPort == 443 || port.hostPort == 443) ? "https" : "http"
        return URL(string: "\(scheme)://\(host):\(port.hostPort)")
    }

    /// Short image name, like "nginx:latest".
    static func shortImage(_ reference: String) -> String {
        let image = ImageSummary(reference: reference)
        return "\(image.shortName):\(image.tag)"
    }
}

/// Ports as small badges. Click one to open it in the browser.
struct ContainerPortBadges: View {
    let ports: [PortMapping]
    var limit: Int = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ports.prefix(limit).enumerated()), id: \.offset) { _, port in
                if let url = ContainerText.portURL(port) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Pill(ContainerText.portLabel(port), tint: DS.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(url.absoluteString)")
                } else {
                    Pill(ContainerText.portLabel(port), tint: DS.stopped)
                }
            }
            if ports.count > limit {
                Pill("+\(ports.count - limit)", tint: DS.stopped)
            }
        }
    }
}

/// One stats reading turned into rates, for live charts.
struct ContainerStatsSample: Identifiable, Hashable {
    var date: Date
    var cpuPercent: Double
    var memoryBytes: Double
    var memoryLimitBytes: Double
    var netRxPerSec: Double
    var netTxPerSec: Double
    var diskReadPerSec: Double
    var diskWritePerSec: Double
    var pids: Int
    /// False until two readings exist. CPU then reads 0 but the UI shows "Measuring".
    var cpuMeasured = true

    var id: Date { date }

    /// From a shared sampler reading. Rates that need an earlier reading start at 0.
    init(_ reading: StatsReading) {
        self.init(
            date: reading.date,
            cpuPercent: reading.cpuPercent ?? 0,
            memoryBytes: Double(reading.memoryBytes),
            memoryLimitBytes: Double(reading.memoryLimitBytes),
            netRxPerSec: reading.netRxPerSec ?? 0,
            netTxPerSec: reading.netTxPerSec ?? 0,
            diskReadPerSec: reading.diskReadPerSec ?? 0,
            diskWritePerSec: reading.diskWritePerSec ?? 0,
            pids: reading.pids,
            cpuMeasured: reading.cpuPercent != nil
        )
    }

    init(date: Date, cpuPercent: Double, memoryBytes: Double, memoryLimitBytes: Double, netRxPerSec: Double,
         netTxPerSec: Double, diskReadPerSec: Double, diskWritePerSec: Double, pids: Int, cpuMeasured: Bool = true) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.netRxPerSec = netRxPerSec
        self.netTxPerSec = netTxPerSec
        self.diskReadPerSec = diskReadPerSec
        self.diskWritePerSec = diskWritePerSec
        self.pids = pids
        self.cpuMeasured = cpuMeasured
    }

    /// Builds a sample. Rates need the reading before this one.
    static func make(_ current: ContainerStats, previous: ContainerStats?) -> ContainerStatsSample {
        var rx = 0.0, tx = 0.0, rd = 0.0, wr = 0.0
        if let previous {
            let seconds = current.timestamp.timeIntervalSince(previous.timestamp)
            if seconds > 0.2 {
                rx = rate(current.netRxBytes, previous.netRxBytes, seconds)
                tx = rate(current.netTxBytes, previous.netTxBytes, seconds)
                rd = rate(current.blockReadBytes, previous.blockReadBytes, seconds)
                wr = rate(current.blockWriteBytes, previous.blockWriteBytes, seconds)
            }
        }
        return ContainerStatsSample(
            date: current.timestamp,
            cpuPercent: max(0, current.cpuPercent),
            memoryBytes: Double(current.memoryUsageBytes),
            memoryLimitBytes: Double(current.memoryLimitBytes),
            netRxPerSec: rx,
            netTxPerSec: tx,
            diskReadPerSec: rd,
            diskWritePerSec: wr,
            pids: current.pids
        )
    }

    private static func rate(_ now: UInt64, _ before: UInt64, _ seconds: Double) -> Double {
        guard now >= before else { return 0 }
        return Double(now - before) / seconds
    }
}

/// Number formatting used by the container charts.
enum ContainerFormat {
    /// "1.2 MB/s" for a byte rate.
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    /// Bytes from a chart value.
    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return Format.bytes(UInt64(0)) }
        // ByteCountFormatter spells small values out ("750 bytes"). Keep the short unit like the rest.
        if value < 1000 { return "\(Int(value.rounded())) B" }
        return Format.bytes(UInt64(min(value, 1e18)))
    }
}

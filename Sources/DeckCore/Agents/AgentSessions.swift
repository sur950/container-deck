import Foundation
import Darwin

// MARK: - Process list

/// One line of `ps -axww -o pid=,ppid=,etime=,%cpu=,rss=,args=`.
public struct ProcessRow: Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    /// Seconds since the process started.
    public var elapsed: TimeInterval
    /// Percent of one core.
    public var cpu: Double
    public var rssKB: UInt64
    /// The command line as ps prints it (arguments joined by spaces).
    public var command: String

    public init(pid: Int32, ppid: Int32, elapsed: TimeInterval, cpu: Double, rssKB: UInt64, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.elapsed = elapsed
        self.cpu = cpu
        self.rssKB = rssKB
        self.command = command
    }
}

public enum ProcessListParser {
    public static let psArguments = ["-axww", "-o", "pid=,ppid=,etime=,%cpu=,rss=,args="]

    /// Rows that read cleanly. Bad lines are skipped.
    public static func parse(_ text: String) -> [ProcessRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count >= 5, let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  let elapsed = elapsedSeconds(String(fields[2])),
                  let cpu = Double(fields[3].replacingOccurrences(of: ",", with: ".")),
                  let rss = UInt64(fields[4]) else { return nil }
            let command = fields.count > 5 ? String(fields[5]) : ""
            return ProcessRow(pid: pid, ppid: ppid, elapsed: elapsed, cpu: cpu, rssKB: rss, command: command)
        }
    }

    /// `[[dd-]hh:]mm:ss` to seconds.
    public static func elapsedSeconds(_ text: String) -> TimeInterval? {
        var days = 0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            guard let value = Int(rest[..<dash]) else { return nil }
            days = value
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        var seconds = 0
        for value in values { seconds = seconds * 60 + value }
        return TimeInterval(days * 86_400 + seconds)
    }

    /// The folder from `lsof -a -d cwd -p PID -Fn` output.
    public static func lsofFolder(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    }
}

// MARK: - Process details

/// Reads a process's executable, arguments and working folder. Tests use a fake.
public protocol ProcessInspecting: Sendable {
    func executablePath(_ pid: Int32) -> String?
    func arguments(_ pid: Int32) -> [String]?
    func workingDirectory(_ pid: Int32) -> String?
}

/// libproc and sysctl. Works for processes of the same user, which is every agent session.
public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Self.parseProcArgs(Array(buffer.prefix(size)))
    }

    public func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let expected = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, expected) == expected else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }

    /// `KERN_PROCARGS2` layout: argc (Int32), the exec path, NUL padding, then argc NUL ended strings.
    public static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard argc > 0, argc < 100_000 else { return nil }
        var index = 4
        while index < bytes.count && bytes[index] != 0 { index += 1 }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc && index < bytes.count {
            let start = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            args.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return args.isEmpty ? nil : args
    }
}

// MARK: - Sessions

/// A stdio MCP server process an agent session started.
public struct AgentSessionChild: Sendable, Hashable, Identifiable {
    public var pid: Int32
    /// Server name from the agent's config, when the command matches one.
    public var name: String?
    /// Command line with secrets masked.
    public var command: String
    public var cpu: Double
    public var memoryBytes: UInt64
    public var id: Int32 { pid }
}

/// A running agent process.
public struct AgentSession: Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var tool: AgentTool
    public var executable: String
    /// Command line with secrets masked.
    public var command: String
    public var folder: String?
    public var started: Date
    public var cpu: Double
    public var memoryBytes: UInt64
    public var mcpServers: [AgentSessionChild]
    public var id: Int32 { pid }
}

/// Decides which processes are sessions of an agent tool, and which of their children are MCP servers.
public enum AgentProcessMatcher {
    /// Programs that run a script named in their arguments.
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "sh", "bash", "zsh", "dash"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "login"]

    /// Folder names inside a package install that only the tool has.
    public static func packageMarkers(_ tool: AgentTool) -> [String] {
        switch tool {
        case .claude: return ["/@anthropic-ai/claude-code/"]
        case .codex: return ["/@openai/codex/"]
        case .gemini: return ["/@google/gemini-cli/", "/Cellar/gemini-cli/"]
        case .opencode: return ["/opencode-ai/"]
        case .qwen: return ["/@qwen-code/qwen-code/"]
        case .amp: return ["/@sourcegraph/amp/"]
        case .aider: return ["/site-packages/aider/"]
        default: return []
        }
    }

    /// The tool path as found and with links resolved.
    public static func toolPaths(_ path: String) -> Set<String> {
        [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
    }

    static func isInterpreter(_ executable: String) -> Bool {
        let name = (executable as NSString).lastPathComponent
        return interpreters.contains(name) || name.hasPrefix("python3.")
    }

    public static func matches(_ tool: AgentTool, toolPaths: Set<String>, executable: String, arguments: [String],
                               useMarkers: Bool = true) -> Bool {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        if toolPaths.contains(executable) || toolPaths.contains(resolved) { return true }
        let markers = useMarkers ? packageMarkers(tool) : []
        if markers.contains(where: { resolved.contains($0) }) { return true }
        guard isInterpreter(executable) else { return false }
        // `node /path/to/claude ...`: the first argument that is not an option is the script.
        guard let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return false }
        if toolPaths.contains(script) { return true }
        if script.hasPrefix("/") {
            let scriptResolved = URL(fileURLWithPath: script).resolvingSymlinksInPath().path
            if toolPaths.contains(scriptResolved) { return true }
            if markers.contains(where: { script.contains($0) || scriptResolved.contains($0) }) { return true }
        }
        return useMarkers && tool.binaries.contains((script as NSString).lastPathComponent)
    }

    /// Server name when the child runs one of the agent's configured servers or one of ours.
    /// `.some(nil)` for an MCP server that is not in the config, nil for other programs.
    public static func mcpServer(arguments: [String], servers: [MCPServerEntry]) -> String?? {
        guard let first = arguments.first else { return nil }
        let entry = MCPServerEntry(name: "", transport: .stdio, command: first, args: Array(arguments.dropFirst()))
        if let managed = MCPLaunch.managedServerName(in: entry) { return .some(managed) }
        // `npx -y pkg` runs as `node /path/to/npx -y pkg`: also compare from the script on.
        var forms = [arguments]
        if isInterpreter(first), let script = arguments.indices.dropFirst().first(where: { !arguments[$0].hasPrefix("-") }) {
            forms.append(Array(arguments[script...]))
        }
        for form in forms {
            guard let program = form.first else { continue }
            let name = (program as NSString).lastPathComponent
            for server in servers where server.transport == .stdio {
                guard let command = server.command, !command.isEmpty else { continue }
                guard command == program || (command as NSString).lastPathComponent == name else { continue }
                let rest = Array(form.dropFirst())
                let expected = Array(server.args.prefix(3))
                if rest.count >= expected.count, Array(rest.prefix(expected.count)) == expected { return .some(server.name) }
            }
        }
        // A shell running a command line (an agent's own tool call) is not a server.
        if shells.contains((first as NSString).lastPathComponent), arguments.contains("-c") { return nil }
        if arguments.joined(separator: " ").lowercased().contains("mcp") { return .some(nil) }
        return nil
    }

    /// Sessions of `tool` among `rows`. `details` gives the executable and arguments of a pid.
    /// `useMarkers` off matches only the exact tool path (stand in tools in automation runs).
    public static func sessions(rows: [ProcessRow], tool: AgentTool, toolPath: String, servers: [MCPServerEntry], now: Date = Date(),
                                useMarkers: Bool = true,
                                details: (Int32) -> (executable: String?, arguments: [String]?)) -> [AgentSession] {
        let paths = toolPaths(toolPath)
        var info: [Int32: (executable: String, arguments: [String])] = [:]
        func lookup(_ row: ProcessRow) -> (executable: String, arguments: [String]) {
            if let cached = info[row.pid] { return cached }
            let found = details(row.pid)
            let args = found.arguments ?? row.command.split(separator: " ").map(String.init)
            let value = (found.executable ?? args.first ?? "", args)
            info[row.pid] = value
            return value
        }
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let matched = Set(rows.filter { row in
            // Cheap check on the ps line first, then the real executable.
            let hint = row.command.lowercased()
            guard tool.binaries.contains(where: { hint.contains($0) }) || packageMarkers(tool).contains(where: { hint.contains($0.lowercased()) })
                    || paths.contains(where: { hint.contains($0.lowercased()) }) else { return false }
            let found = lookup(row)
            return matches(tool, toolPaths: paths, executable: found.executable, arguments: found.arguments, useMarkers: useMarkers)
        }.map(\.pid))

        // Keep the top process of each session (agents start helpers of themselves).
        func hasMatchedAncestor(_ pid: Int32) -> Bool {
            var current = byPID[pid]?.ppid
            var steps = 0
            while let parent = current, parent > 1, steps < 64 {
                if matched.contains(parent) { return true }
                current = byPID[parent]?.ppid
                steps += 1
            }
            return false
        }

        let children = Dictionary(grouping: rows, by: \.ppid)
        return rows.filter { matched.contains($0.pid) && !hasMatchedAncestor($0.pid) }.map { row in
            let found = lookup(row)
            var mcp: [AgentSessionChild] = []
            var queue: [(Int32, Int)] = [(row.pid, 0)]
            while !queue.isEmpty {
                let (parent, depth) = queue.removeFirst()
                for child in children[parent] ?? [] where !matched.contains(child.pid) {
                    let childInfo = lookup(child)
                    if let name = mcpServer(arguments: childInfo.arguments, servers: servers) {
                        mcp.append(AgentSessionChild(pid: child.pid, name: name, command: masked(childInfo.arguments),
                                                     cpu: child.cpu, memoryBytes: child.rssKB * 1024))
                    } else if depth < 3 {
                        queue.append((child.pid, depth + 1))
                    }
                }
            }
            return AgentSession(pid: row.pid, tool: tool, executable: found.executable, command: masked(found.arguments),
                                folder: nil, started: now.addingTimeInterval(-row.elapsed), cpu: row.cpu,
                                memoryBytes: row.rssKB * 1024, mcpServers: mcp.sorted { $0.pid < $1.pid })
        }.sorted { $0.started > $1.started }
    }

    static func masked(_ arguments: [String]) -> String {
        guard let first = arguments.first else { return "" }
        let program = (first as NSString).lastPathComponent
        return ([program] + MCPServerEntry.maskSecrets(Array(arguments.dropFirst()))).map { arg in
            arg.contains(" ") ? "'\(arg)'" : arg
        }.joined(separator: " ")
    }
}

/// Finds running sessions of agent tools on this Mac.
public struct AgentProcessScanner: Sendable {
    let runner: any CommandRunning
    let inspector: any ProcessInspecting
    public var useMarkers: Bool

    public init(runner: any CommandRunning = ProcessRunner(), inspector: any ProcessInspecting = SystemProcessInspector(),
                useMarkers: Bool = true) {
        self.runner = runner
        self.inspector = inspector
        self.useMarkers = useMarkers
    }

    /// Sessions per tool. `tools` maps each tool to its executable path.
    public func scan(tools: [AgentTool: String], servers: [AgentTool: [MCPServerEntry]] = [:]) async -> [AgentTool: [AgentSession]] {
        guard !tools.isEmpty, let result = try? await runner.run("/bin/ps", ProcessListParser.psArguments), result.succeeded else { return [:] }
        let rows = ProcessListParser.parse(result.stdout)
        let ownPID = getpid()
        let inspector = self.inspector
        var found: [AgentTool: [AgentSession]] = [:]
        for (tool, path) in tools {
            var sessions = AgentProcessMatcher.sessions(rows: rows.filter { $0.pid != ownPID }, tool: tool, toolPath: path,
                                                        servers: servers[tool] ?? [], useMarkers: useMarkers) { pid in
                (inspector.executablePath(pid), inspector.arguments(pid))
            }
            for index in sessions.indices {
                var folder = inspector.workingDirectory(sessions[index].pid)
                if folder == nil, let lsof = try? await runner.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", String(sessions[index].pid), "-Fn"]) {
                    folder = ProcessListParser.lsofFolder(lsof.stdout)
                }
                sessions[index].folder = folder
            }
            if !sessions.isEmpty { found[tool] = sessions }
        }
        return found
    }

    public enum StopOutcome: Sendable, Equatable {
        case alreadyGone, terminated, killed
    }

    /// SIGTERM, then SIGKILL when the process is still there after `timeout`. Checks the pid
    /// still runs the same program before each signal, so a reused pid is never hit.
    public func stop(_ session: AgentSession, timeout: TimeInterval = AgentsConfig.stopTimeout) async throws -> StopOutcome {
        func same() -> Bool {
            guard let current = inspector.executablePath(session.pid) else { return false }
            return current == session.executable
        }
        guard same() else { return .alreadyGone }
        guard kill(session.pid, SIGTERM) == 0 else {
            if errno == ESRCH { return .alreadyGone }
            throw DeckError.commandFailed("Could not stop process \(session.pid). \(String(cString: strerror(errno)))")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !same() { return .terminated }
        }
        guard same() else { return .terminated }
        guard kill(session.pid, SIGKILL) == 0 else {
            if errno == ESRCH { return .terminated }
            throw DeckError.commandFailed("Could not stop process \(session.pid). \(String(cString: strerror(errno)))")
        }
        return .killed
    }
}

// MARK: - Recent sessions

/// Metadata of a saved session. Never holds transcript text.
public struct AgentSessionRecord: Sendable, Hashable, Identifiable {
    public var tool: AgentTool
    public var sessionID: String
    public var folder: String?
    public var lastActivity: Date
    public var messageCount: Int
    /// The session's own title (Claude Code's generated or custom title, Codex's thread name).
    public var title: String?
    public var file: String
    public var id: String { tool.rawValue + "|" + sessionID }

    public init(tool: AgentTool, sessionID: String, folder: String?, lastActivity: Date, messageCount: Int, title: String?, file: String) {
        self.tool = tool
        self.sessionID = sessionID
        self.folder = folder
        self.lastActivity = lastActivity
        self.messageCount = messageCount
        self.title = title
        self.file = file
    }
}

/// Reads session metadata from the files agents keep. Formats checked on 6 Nov 2026:
/// - Claude Code: `<config>/projects/<encoded folder>/<session id>.jsonl`. One JSON object per line.
///   `cwd` on message lines, titles in `ai-title` (`aiTitle`), `custom-title` (`customTitle`) and older `summary` lines.
///   Resume: `claude --resume <id>` (checked with `claude --help`, 2.x).
/// - Codex: `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-*.jsonl`. First line `session_meta` with `id` and `cwd`,
///   messages are `event_msg` lines of type `user_message` and `agent_message`. Titles in `session_index.jsonl`
///   (`id`, `thread_name`). Resume: `codex resume <id>` (checked with `codex resume --help`, 0.164).
public enum AgentSessionHistory {
    public static let supported: [AgentTool] = [.claude, .codex]

    public static func sessions(for tool: AgentTool, resolver: AgentPathResolver, limit: Int = AgentsConfig.recentSessionLimit,
                                cache: AgentSessionCache? = nil) -> [AgentSessionRecord] {
        guard let folder = resolver.sessionsFolder(tool)?.path else { return [] }
        let files = recentFiles(in: folder, recursive: tool == .codex, limit: limit)
        let titles = tool == .codex ? codexTitles(indexPath: resolver.codexSessionIndex) : [:]
        return files.compactMap { file in
            if let cached = cache?.record(for: file.path, modified: file.modified, size: file.size) {
                var record = cached
                if tool == .codex, let title = titles[record.sessionID] { record.title = title }
                return record
            }
            guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
            var record: AgentSessionRecord?
            switch tool {
            case .claude: record = parseClaude(data, file: file.path, modified: file.modified)
            case .codex: record = parseCodex(data, file: file.path, modified: file.modified, titles: titles)
            default: record = nil
            }
            if let record { cache?.store(record, for: file.path, modified: file.modified, size: file.size) }
            return record
        }
    }

    struct FileInfo { var path: String; var modified: Date; var size: Int }

    static func recentFiles(in folder: String, recursive: Bool, limit: Int) -> [FileInfo] {
        let url = URL(fileURLWithPath: folder)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var found: [FileInfo] = []
        func add(_ file: URL) {
            guard file.pathExtension == "jsonl",
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return }
            found.append(FileInfo(path: file.path, modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0))
        }
        let fm = FileManager.default
        if recursive {
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
            for case let file as URL in walker { add(file) }
        } else {
            // Claude Code: one level of project folders, session files directly inside.
            let projects = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for project in projects {
                let files = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
                files.forEach(add)
            }
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Lines of a JSONL file, as byte slices.
    static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    }

    static func object(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    static func contains(_ line: Data, _ needle: String) -> Bool {
        line.range(of: Data(needle.utf8)) != nil
    }

    public static func parseClaude(_ data: Data, file: String, modified: Date) -> AgentSessionRecord? {
        // The file name is the id `claude --resume` takes.
        let sessionID = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        var folder: String?
        var aiTitle: String?
        var customTitle: String?
        var summary: String?
        var prompts = 0
        var replies = Set<String>()
        for line in lines(data) {
            if contains(line, "\"type\":\"ai-title\"") {
                aiTitle = object(line)?["aiTitle"] as? String ?? aiTitle
            } else if contains(line, "\"type\":\"custom-title\"") {
                customTitle = object(line)?["customTitle"] as? String ?? customTitle
            } else if contains(line, "\"type\":\"summary\"") {
                summary = object(line)?["summary"] as? String ?? summary
            } else if contains(line, "\"type\":\"user\"") || contains(line, "\"type\":\"assistant\"") {
                if contains(line, "\"isSidechain\":true") || contains(line, "\"isMeta\":true") { continue }
                if folder == nil, let value = object(line) {
                    folder = value["cwd"] as? String
                }
                if contains(line, "\"type\":\"user\"") {
                    if !contains(line, "\"toolUseResult\"") && !contains(line, "\"tool_result\"") { prompts += 1 }
                } else if let id = requestID(line) {
                    replies.insert(id)
                } else {
                    replies.insert(UUID().uuidString)
                }
            }
        }
        let count = prompts + replies.count
        guard count > 0 || aiTitle != nil || customTitle != nil else { return nil }
        let title = [customTitle, aiTitle, summary].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return AgentSessionRecord(tool: .claude, sessionID: sessionID, folder: folder, lastActivity: modified,
                                  messageCount: count, title: title, file: file)
    }

    /// `"requestId":"req_..."` without parsing the whole line.
    static func requestID(_ line: Data) -> String? {
        guard let range = line.range(of: Data("\"requestId\":\"".utf8)) else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
    }

    public static func parseCodex(_ data: Data, file: String, modified: Date, titles: [String: String] = [:]) -> AgentSessionRecord? {
        var sessionID: String?
        var folder: String?
        var count = 0
        for line in lines(data) {
            if sessionID == nil, contains(line, "\"type\":\"session_meta\""),
               let payload = object(line)?["payload"] as? [String: Any] {
                sessionID = payload["id"] as? String
                folder = payload["cwd"] as? String
            } else if contains(line, "\"type\":\"event_msg\"")
                        && (contains(line, "\"type\":\"user_message\"") || contains(line, "\"type\":\"agent_message\"")) {
                count += 1
            }
        }
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return AgentSessionRecord(tool: .codex, sessionID: sessionID, folder: folder, lastActivity: modified,
                                  messageCount: count, title: titles[sessionID], file: file)
    }

    /// Thread names by session id. Later lines win.
    public static func codexTitles(indexPath: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: indexPath) else { return [:] }
        var titles: [String: String] = [:]
        for line in lines(data) {
            guard let value = object(line), let id = value["id"] as? String,
                  let name = value["thread_name"] as? String, !name.isEmpty else { continue }
            titles[id] = name
        }
        return titles
    }

    /// Shell line that resumes the session in its folder. nil for tools without a checked resume flag.
    public static func resumeCommand(_ record: AgentSessionRecord, executable: String) -> String? {
        let q = MCPLaunch.shellQuote
        let run: String
        switch record.tool {
        case .claude: run = "\(q(executable)) --resume \(q(record.sessionID))"
        case .codex: run = "\(q(executable)) resume \(q(record.sessionID))"
        default: return nil
        }
        guard let folder = record.folder, !folder.isEmpty else { return run }
        return "cd \(q(folder)) && \(run)"
    }
}

/// Parsed session files keyed by path, size and date, so a refresh only reads files that changed.
public final class AgentSessionCache: @unchecked Sendable {
    private var items: [String: (modified: Date, size: Int, record: AgentSessionRecord)] = [:]
    private let lock = NSLock()

    public init() {}

    func record(for path: String, modified: Date, size: Int) -> AgentSessionRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let item = items[path], item.modified == modified, item.size == size else { return nil }
        return item.record
    }

    func store(_ record: AgentSessionRecord, for path: String, modified: Date, size: Int) {
        lock.lock(); defer { lock.unlock() }
        items[path] = (modified, size, record)
    }
}

import Foundation

// Chat history lives in container volumes. The JSON files in Application Support are a
// local cache that the screens read and write right away. ChatVolumeSync moves changes
// between the cache and the volume in one round trip per sync: it writes the queued files,
// then lists every file in the volume. Through a short lived helper container that mounts
// the volume, or through `container exec` when a running sandbox already mounts it.

/// How to reach a chat volume.
public enum ChatSyncTransport: Sendable, Equatable {
    /// A `--rm` helper container that mounts the volume.
    case helper(volume: String, labels: [String: String])
    /// A running container that mounts the volume at `directory`.
    case exec(containerID: String, directory: String)
}

/// One queued change for the volume.
public struct ChatSyncOp: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case put(Data)
        case delete
    }

    public var file: String
    public var kind: Kind

    public init(file: String, kind: Kind) {
        self.file = file
        self.kind = kind
    }
}

/// Changes waiting for the volume, kept on disk next to the cache so nothing is lost
/// when the container service is stopped or the app quits.
public struct ChatSyncState: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable { case put, delete }

    public struct Pending: Codable, Sendable, Equatable {
        public var op: Op
        /// Goes up on every change, so a sync only clears what it really sent.
        public var generation: Int

        public init(op: Op, generation: Int) {
            self.op = op
            self.generation = generation
        }
    }

    public var pending: [String: Pending] = [:]
    /// True after the first sync copied the files that were here before volumes.
    public var migrated = false
    public var lastSync: Date?

    public init(pending: [String: Pending] = [:], migrated: Bool = false, lastSync: Date? = nil) {
        self.pending = pending
        self.migrated = migrated
        self.lastSync = lastSync
    }

    public mutating func mark(_ file: String, _ op: Op) {
        let next = (pending[file]?.generation ?? 0) + 1
        pending[file] = Pending(op: op, generation: next)
    }
}

/// What a finished sync changes in the cache.
public struct ChatSyncPlan: Sendable, Equatable {
    /// Files the volume has that differ from the cache (the volume wins).
    public var writeLocal: [String: Data] = [:]
    /// Cache files the volume no longer has.
    public var deleteLocal: [String] = []
    /// Queued changes that were sent and not changed again since.
    public var sent: [String] = []

    public init(writeLocal: [String: Data] = [:], deleteLocal: [String] = [], sent: [String] = []) {
        self.writeLocal = writeLocal
        self.deleteLocal = deleteLocal
        self.sent = sent
    }

    public var changedFiles: Set<String> { Set(writeLocal.keys).union(deleteLocal) }
}

public enum ChatVolumeSync {
    /// The AI Models chat volume.
    public static let volumeName = "deck-chat-history"
    public static let roleLabel = "deck.role"
    public static let roleValue = "chat-history"
    /// Label on helper containers, so lists can hide them.
    public static let helperLabel = "deck.helper"
    public static let helperLabelValue = "chat-sync"
    /// Same small image the volume browser uses.
    public static let helperImage = "docker.io/library/alpine:latest"
    public static let helperMount = "/data"

    public static var modelVolumeLabels: [String: String] { [roleLabel: roleValue] }

    /// Chat history volumes. Cleanups leave them alone even when no container mounts them.
    public static func isKept(_ volume: VolumeSummary) -> Bool {
        volume.name == volumeName || volume.labels[roleLabel] == roleValue
    }

    /// `<sandbox>-chat`.
    public static func sandboxVolume(_ sandbox: String) -> String { "\(sandbox)-chat" }

    public static func sandboxVolumeLabels(_ sandbox: String) -> [String: String] {
        [SandboxConfig.label: sandbox, roleLabel: roleValue]
    }

    // MARK: Plans

    /// Queued changes as operations. Before the first sync every cached file is sent once.
    public static func operations(state: ChatSyncState, local: [String: Data]) -> [ChatSyncOp] {
        var files = Set(state.pending.keys)
        if !state.migrated { files.formUnion(local.keys) }
        return files.sorted().compactMap { file in
            guard isSafeName(file) else { return nil }
            if let data = local[file] { return ChatSyncOp(file: file, kind: .put(data)) }
            // Gone from the cache: a clear, or a put whose file was removed since.
            return ChatSyncOp(file: file, kind: .delete)
        }
    }

    /// Merges the volume's files into the cache. The volume is the source of truth, except for
    /// files changed again in the cache while the sync ran: those keep their newer content.
    public static func merge(remote: [String: Data], local: [String: Data], sentState: ChatSyncState, currentState: ChatSyncState) -> ChatSyncPlan {
        var plan = ChatSyncPlan()
        func changedSince(_ file: String) -> Bool {
            guard let now = currentState.pending[file] else { return false }
            return now != sentState.pending[file]
        }
        for (file, data) in remote where isSafeName(file) && !changedSince(file) && local[file] != data {
            plan.writeLocal[file] = data
        }
        for file in local.keys where remote[file] == nil && !changedSince(file) {
            plan.deleteLocal.append(file)
        }
        plan.deleteLocal.sort()
        plan.sent = sentState.pending.keys.filter { !changedSince($0) }.sorted()
        return plan
    }

    // MARK: Commands

    /// Writes the ops read from stdin, then lists every file. `$1` is the folder.
    public static let script = """
    dir="$1"
    mkdir -p "$dir" || exit 3
    while IFS=' ' read -r op name data; do
      case "$name" in ""|*/*|.*) continue ;; esac
      case "$op" in
        PUT) printf '%s' "$data" | base64 -d > "$dir/.$name.tmp" && mv "$dir/.$name.tmp" "$dir/$name" || exit 4 ;;
        DEL) rm -f "$dir/$name" ;;
        END) break ;;
      esac
    done
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      printf 'FILE %s ' "${f##*/}"
      base64 < "$f" | tr -d '\\n'
      echo
    done
    echo DONE
    """

    /// Lines for the script's stdin.
    public static func input(_ ops: [ChatSyncOp]) -> Data {
        var lines: [String] = []
        for op in ops where isSafeName(op.file) {
            switch op.kind {
            case .put(let data): lines.append("PUT \(op.file) \(data.base64EncodedString())")
            case .delete: lines.append("DEL \(op.file) -")
            }
        }
        lines.append("END - -")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Files from the script's output. Throws when the listing did not finish, so a cut off
    /// answer never removes cached conversations.
    public static func parseListing(_ text: String) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var finished = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "DONE" { finished = true; continue }
            guard line.hasPrefix("FILE ") else { continue }
            let parts = line.dropFirst(5).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first.map(String.init), isSafeName(name) else { continue }
            let encoded = parts.count > 1 ? String(parts[1]) : ""
            guard let data = Data(base64Encoded: encoded) else { continue }
            files[name] = data
        }
        guard finished else { throw DeckError.parse("the chat history in the volume") }
        return files
    }

    /// `container run --rm --interactive ... alpine sh -c <script> deck-chat /data`.
    public static func helperArguments(volume: String, name: String) -> [String] {
        ["run", "--rm", "--interactive", "--name", name,
         "--label", "\(helperLabel)=\(helperLabelValue)", "--label", "deck.volume=\(volume)",
         "--volume", "\(volume):\(helperMount)",
         helperImage, "/bin/sh", "-c", script, "deck-chat", helperMount]
    }

    /// `container exec --interactive <id> /bin/sh -c <script> deck-chat <dir>`.
    public static func execArguments(containerID: String, directory: String) -> [String] {
        ["exec", "--interactive", containerID, "/bin/sh", "-c", script, "deck-chat", directory]
    }

    public static func helperName() -> String {
        "deck-chat-sync-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// File names the cache and the volume use: letters, digits, dot, dash and underscore, ending in .json.
    public static func isSafeName(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return name.hasSuffix(".json") && !name.hasPrefix(".") && name.count <= 120 && name.allSatisfy { allowed.contains($0) }
    }
}

public extension ContainerClient {
    /// One sync round trip: sends the ops, returns every file in the volume. The volume must
    /// exist (see `chatVolumeExists`). A missing volume is never made here, so a volume someone
    /// removed stays removed until they choose to make it again.
    func syncChatVolume(_ ops: [ChatSyncOp], transport: ChatSyncTransport) async throws -> [String: Data] {
        let arguments: [String]
        switch transport {
        case .helper(let volume, _):
            arguments = ChatVolumeSync.helperArguments(volume: volume, name: ChatVolumeSync.helperName())
        case .exec(let id, let directory):
            arguments = ChatVolumeSync.execArguments(containerID: id, directory: directory)
        }
        let result = try await runner.run(cli.path, arguments, stdin: ChatVolumeSync.input(ops))
        try result.orThrow()
        return try ChatVolumeSync.parseListing(result.stdout)
    }

    /// True when the volume exists. Throws when the container service does not answer.
    func chatVolumeExists(_ name: String) async throws -> Bool {
        try await listVolumes().contains { $0.name == name }
    }

    /// Creates the volume with its labels when it does not exist yet.
    func ensureVolume(_ name: String, labels: [String: String]) async throws {
        guard try await !chatVolumeExists(name) else { return }
        try await createVolume(name: name, labels: labels)
    }
}

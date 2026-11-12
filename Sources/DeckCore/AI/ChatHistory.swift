import Foundation

/// One saved chat message. Holds the text and speed numbers only, never API keys.
public struct SavedChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: UUID
    public var role: Role
    public var text: String
    public var reasoning: String?
    public var failed: Bool?
    /// Model that wrote an answer.
    public var model: String?
    /// ModelServerKind raw value of the server that answered.
    public var server: String?
    public var started: Date?
    public var firstToken: Date?
    public var finished: Date?
    public var tokens: Int?
    /// The server stopped the answer at its length limit.
    public var cutOff: Bool?

    public init(id: UUID = UUID(), role: Role, text: String, reasoning: String? = nil, failed: Bool? = nil, model: String? = nil,
                server: String? = nil, started: Date? = nil, firstToken: Date? = nil, finished: Date? = nil, tokens: Int? = nil,
                cutOff: Bool? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.failed = failed
        self.model = model
        self.server = server
        self.started = started
        self.firstToken = firstToken
        self.finished = finished
        self.tokens = tokens
        self.cutOff = cutOff
    }
}

/// Saved conversations, one JSON file each in Application Support/<bundle id>/AI/chats.
/// One conversation per server and model for AI Models, one per sandbox for Sandbox chat.
public struct ChatHistory: Sendable {
    /// Messages kept per conversation. Older ones are dropped when saving.
    public static let maxMessages = 200

    public let directory: URL

    public init(directory: URL = AIPaths().chats) {
        self.directory = directory
    }

    // MARK: Keys

    /// AI Models conversation: one per server (kind and port) and model.
    public static func key(server: ModelServerKind, port: Int, model: String) -> String {
        "model-\(server.rawValue)-\(port)-\(model)"
    }

    /// Sandbox conversation.
    public static func sandboxKey(_ name: String) -> String {
        "sandbox-\(name)"
    }

    /// File for a key: safe characters only, plus a short hash so different keys never share a file.
    public func url(for key: String) -> URL {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let safe = String(key.map { allowed.contains($0) ? $0 : "_" }.prefix(80))
        return directory.appendingPathComponent("\(safe)-\(Self.hash(key)).json")
    }

    // MARK: Reading and writing

    /// The saved messages, or none when there is no file or it cannot be read.
    public func load(_ key: String) -> [SavedChatMessage] {
        guard let data = try? Data(contentsOf: url(for: key)),
              let file = try? Self.decoder.decode(SavedChatFile.self, from: data), file.key == key else { return [] }
        return file.messages
    }

    /// Saves the last `maxMessages` messages. An empty conversation deletes the file.
    public func save(_ key: String, messages: [SavedChatMessage]) throws {
        let kept = Self.capped(messages)
        guard !kept.isEmpty else {
            clear(key)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(SavedChatFile(key: key, updated: Date(), messages: kept))
        let target = url(for: key)
        try data.write(to: target, options: [.atomic])
        // Only this user can read it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        queue(target.lastPathComponent, .put)
    }

    /// Removes the conversation from the cache, and queues its removal from the volume.
    public func clear(_ key: String) {
        let target = url(for: key)
        let existed = FileManager.default.fileExists(atPath: target.path)
        try? FileManager.default.removeItem(at: target)
        if existed || syncState().pending[target.lastPathComponent] != nil || syncState().migrated {
            queue(target.lastPathComponent, .delete)
        }
    }

    // MARK: Volume sync

    /// Queued changes, next to the cache. Hidden, so it is never taken for a conversation.
    public var syncStateURL: URL { directory.appendingPathComponent(".sync-state.json") }

    public func syncState() -> ChatSyncState {
        guard let data = try? Data(contentsOf: syncStateURL),
              let state = try? Self.decoder.decode(ChatSyncState.self, from: data) else { return ChatSyncState() }
        return state
    }

    public func saveSyncState(_ state: ChatSyncState) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: syncStateURL, options: [.atomic])
    }

    private func queue(_ file: String, _ op: ChatSyncState.Op) {
        var state = syncState()
        state.mark(file, op)
        saveSyncState(state)
    }

    /// Every cached conversation file, by file name.
    public func localFiles() -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var files: [String: Data] = [:]
        for name in names where ChatVolumeSync.isSafeName(name) {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) { files[name] = data }
        }
        return files
    }

    /// Applies a finished sync to the cache, without queueing anything.
    public func apply(_ plan: ChatSyncPlan, sentState: ChatSyncState) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in plan.writeLocal where ChatVolumeSync.isSafeName(name) {
            let target = directory.appendingPathComponent(name)
            try? data.write(to: target, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        for name in plan.deleteLocal where ChatVolumeSync.isSafeName(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        var state = syncState()
        for name in plan.sent where state.pending[name] == sentState.pending[name] {
            state.pending[name] = nil
        }
        state.migrated = true
        state.lastSync = Date()
        saveSyncState(state)
    }

    /// Deletes the cache folder (a removed sandbox).
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    public static func capped(_ messages: [SavedChatMessage]) -> [SavedChatMessage] {
        messages.count > maxMessages ? Array(messages.suffix(maxMessages)) : messages
    }

    // MARK: Helpers

    struct SavedChatFile: Codable {
        var version = 1
        var key: String
        var updated: Date
        var messages: [SavedChatMessage]
    }

    /// FNV-1a, 64 bit, as 12 hex characters. Stable across launches, unlike `hashValue`.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return String(String(value, radix: 16).suffix(12))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

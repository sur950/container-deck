import Foundation
import CryptoKit

/// A change to one agent config file, ready to preview. Nothing is written until `apply`.
public struct ConfigChangePlan: Sendable, Identifiable {
    public enum Action: String, Sendable, Codable { case add, replace, remove }

    public var id = UUID()
    public var agent: AgentKind
    public var scope: AgentConfigScope
    public var path: String
    public var serverName: String
    public var action: Action
    /// File text before the change. nil when the file does not exist yet.
    public var original: String?
    public var updated: String
    public var diff: [DiffLine]
    /// The server is reached through the `mcp-remote` stdio bridge.
    public var bridged: Bool

    public var title: String {
        switch action {
        case .add: return "Add \(serverName) to \(agent.title)"
        case .replace: return "Update \(serverName) in \(agent.title)"
        case .remove: return "Remove \(serverName) from \(agent.title)"
        }
    }
}

/// A change that was written, kept so it can be undone.
public struct ConfigChangeRecord: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var agent: AgentKind
    public var path: String
    public var serverName: String
    public var action: ConfigChangePlan.Action
    /// Copy of the file before the change. nil when the change created the file.
    public var backupPath: String?
    public var writtenHash: String
    public var undone: Bool

    public var summary: String {
        switch action {
        case .add: return "Added \(serverName) to \(agent.title)"
        case .replace: return "Updated \(serverName) in \(agent.title)"
        case .remove: return "Removed \(serverName) from \(agent.title)"
        }
    }
}

public enum AgentConfigWriteError: Error, LocalizedError, Equatable {
    case fileChanged(String)
    case unreadable(String, String)
    case notPresent(String)
    case verifyFailed(String)
    case changedSinceWrite(String)

    public var errorDescription: String? {
        switch self {
        case .fileChanged(let path): return "\(path) changed after the preview. Open the preview again."
        case let .unreadable(path, reason): return "Could not read \(path). \(reason)"
        case .notPresent(let name): return "\(name) is not in this config."
        case .verifyFailed(let path): return "The new \(path) did not read back correctly, so nothing was written."
        case .changedSinceWrite(let path): return "\(path) changed after this edit. Undo would drop those newer changes."
        }
    }
}

/// Writes MCP server entries into agent configs with a timestamped backup and undo.
public struct AgentConfigWriter: Sendable {
    public var locations: AgentConfigLocations
    /// Folder for backups and the change log.
    public var backupsFolder: URL

    public init(locations: AgentConfigLocations = AgentConfigLocations(), backupsFolder: URL? = nil) {
        self.locations = locations
        self.backupsFolder = backupsFolder ?? AgentConfigWriter.defaultBackupsFolder
    }

    public static var defaultBackupsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AgentsConfig.supportFolder).appendingPathComponent(AgentsConfig.backupsFolder)
    }

    // MARK: Plans

    public func planConnect(_ entry: MCPServerEntry, agent: AgentKind, scope: AgentConfigScope = .user) throws -> ConfigChangePlan {
        let path = locations.file(for: agent, scope: scope)
        let original = try readIfPresent(path)
        let text = original ?? ""
        let updated: String
        let existed: Bool
        if agent.isTOML {
            var editor = TOMLEditor(text: text)
            existed = editor.hasServer(entry.name)
            editor.setServer(entry.name, values: AgentEntryFormat.toml(entry))
            updated = editor.text
            guard TOMLEditor(text: updated).mcpServers().contains(where: { $0.name == entry.name }) else {
                throw AgentConfigWriteError.verifyFailed(path)
            }
        } else {
            var editor = JSONCEditor(text: text)
            let keyPath = agent.serversPath(scope: scope)
            do {
                existed = try editor.object(at: keyPath)?[entry.name] != nil
                try editor.set(AgentEntryFormat.json(entry, for: agent), forKey: entry.name, in: keyPath)
            } catch {
                throw AgentConfigWriteError.unreadable(path, error.localizedDescription)
            }
            updated = editor.text
            guard (try? JSONCEditor(text: updated).object(at: keyPath)?[entry.name]) != nil else {
                throw AgentConfigWriteError.verifyFailed(path)
            }
        }
        return ConfigChangePlan(
            agent: agent, scope: scope, path: path, serverName: entry.name,
            action: existed ? .replace : .add, original: original, updated: updated,
            diff: LineDiff.diff(text, updated), bridged: AgentEntryFormat.needsBridge(entry, for: agent)
        )
    }

    public func planDisconnect(_ name: String, agent: AgentKind, scope: AgentConfigScope = .user) throws -> ConfigChangePlan {
        let path = locations.file(for: agent, scope: scope)
        guard let original = try readIfPresent(path) else { throw AgentConfigWriteError.notPresent(name) }
        let updated: String
        if agent.isTOML {
            var editor = TOMLEditor(text: original)
            guard editor.removeServer(name) else { throw AgentConfigWriteError.notPresent(name) }
            updated = editor.text
        } else {
            var editor = JSONCEditor(text: original)
            let removed: Bool
            do {
                removed = try editor.remove(key: name, in: agent.serversPath(scope: scope))
            } catch {
                throw AgentConfigWriteError.unreadable(path, error.localizedDescription)
            }
            guard removed else { throw AgentConfigWriteError.notPresent(name) }
            updated = editor.text
            guard (try? JSONCEditor(text: updated).foundationValue()) != nil else { throw AgentConfigWriteError.verifyFailed(path) }
        }
        return ConfigChangePlan(agent: agent, scope: scope, path: path, serverName: name, action: .remove,
                                original: original, updated: updated, diff: LineDiff.diff(original, updated), bridged: false)
    }

    // MARK: Apply and undo

    /// Writes the plan. The file must still match the preview. A backup is made first.
    @discardableResult
    public func apply(_ plan: ConfigChangePlan) throws -> ConfigChangeRecord {
        let current = try readIfPresent(plan.path)
        guard current == plan.original else { throw AgentConfigWriteError.fileChanged(plan.path) }
        let fm = FileManager.default
        try fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var backupPath: String?
        if let original = plan.original {
            let stamp = AgentConfigWriter.stampFormatter.string(from: Date())
            let fileName = (plan.path as NSString).lastPathComponent
            let backup = backupsFolder.appendingPathComponent("\(plan.agent.rawValue)-\(stamp)-\(plan.id.uuidString.prefix(6))-\(fileName)")
            try Data(original.utf8).write(to: backup, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            backupPath = backup.path
        }
        try write(plan.updated, to: plan.path)
        let record = ConfigChangeRecord(
            id: plan.id, date: Date(), agent: plan.agent, path: plan.path, serverName: plan.serverName,
            action: plan.action, backupPath: backupPath, writtenHash: AgentConfigWriter.hash(plan.updated), undone: false
        )
        var log = history()
        log.insert(record, at: 0)
        saveHistory(log)
        return record
    }

    /// True when the file still holds exactly what the change wrote.
    public func isUnchangedSinceWrite(_ record: ConfigChangeRecord) -> Bool {
        guard let current = try? readIfPresent(record.path) else { return false }
        return AgentConfigWriter.hash(current) == record.writtenHash
    }

    /// Puts the file back as it was before the change. Refuses when the file changed since,
    /// unless `force` is set.
    public func undo(_ record: ConfigChangeRecord, force: Bool = false) throws {
        if !force, !isUnchangedSinceWrite(record) { throw AgentConfigWriteError.changedSinceWrite(record.path) }
        if let backup = record.backupPath {
            guard let data = FileManager.default.contents(atPath: backup) else {
                throw AgentConfigWriteError.unreadable(backup, "The backup is missing.")
            }
            try write(String(decoding: data, as: UTF8.self), to: record.path)
        } else {
            try FileManager.default.removeItem(atPath: AgentConfigWriter.resolved(record.path))
        }
        var log = history()
        if let index = log.firstIndex(where: { $0.id == record.id }) { log[index].undone = true }
        saveHistory(log)
    }

    // MARK: Change log

    public func history() -> [ConfigChangeRecord] {
        let url = backupsFolder.appendingPathComponent(AgentsConfig.changeLogFile)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ConfigChangeRecord].self, from: data)) ?? []
    }

    func saveHistory(_ records: [ConfigChangeRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(records.prefix(200))) else { return }
        try? data.write(to: backupsFolder.appendingPathComponent(AgentsConfig.changeLogFile), options: .atomic)
    }

    // MARK: Files

    func readIfPresent(_ path: String) throws -> String? {
        let real = AgentConfigWriter.resolved(path)
        guard FileManager.default.fileExists(atPath: real) else { return nil }
        guard let data = FileManager.default.contents(atPath: real) else {
            throw AgentConfigWriteError.unreadable(path, "Permission denied.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Atomic write that keeps the file's permissions. Follows symlinks (dotfile managers).
    func write(_ text: String, to path: String) throws {
        let real = AgentConfigWriter.resolved(path)
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: real)
        try fm.createDirectory(atPath: (real as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: real), options: .atomic)
        if let permissions = attributes?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: real)
        }
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

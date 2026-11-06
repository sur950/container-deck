import Foundation

/// One saved login from `container registry list --format json`.
///
/// The CLI keeps logins in the keychain under the resolved host, so a login to
/// "docker.io" is listed as "registry-1.docker.io". `server` is that raw name
/// (pass it to `registryLogout`), `displayHost` is the short name people know.
public struct RegistryLogin: Sendable, Hashable, Identifiable {
    public var id: String { server }
    public var server: String
    public var username: String?
    public var createdAt: Date?
    public var modifiedAt: Date?

    public init(server: String, username: String? = nil, createdAt: Date? = nil, modifiedAt: Date? = nil) {
        self.server = server
        self.username = username
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// "docker.io" for any Docker Hub host, else the server lowercased.
    public var displayHost: String { DockerConfigFile.registryHost(from: server) }

    /// True when this login is for `host` (any spelling of Docker Hub matches).
    public func matches(_ host: String) -> Bool {
        displayHost == DockerConfigFile.registryHost(from: host)
    }

    /// Parses `[{id, name, username, creationDate, modificationDate, labels}]`.
    /// nil when the text is not a JSON list.
    public static func parseList(_ output: String) -> [RegistryLogin]? {
        guard let list = CLIJSON.object(output) as? [Any] else { return nil }
        return list.compactMap { item -> RegistryLogin? in
            guard let entry = item as? [String: Any] else { return nil }
            let rawName = entry["name"] as? String ?? entry["hostname"] as? String ?? entry["id"] as? String
            guard let server = CLIText.nonEmpty(rawName) else { return nil }
            return RegistryLogin(
                server: server,
                username: CLIText.nonEmpty(entry["username"] as? String),
                createdAt: date(entry["creationDate"]),
                modifiedAt: date(entry["modificationDate"])
            )
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return DeckDate.parse(text) }
        if let number = value as? NSNumber { return DeckDate.parse(number.stringValue) }
        return nil
    }
}

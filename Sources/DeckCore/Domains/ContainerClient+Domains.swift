import Foundation

/// A local DNS domain from `container system dns`. When `localhostAddress` is set, the
/// domain is a host alias: containers reach services on this Mac by that name.
public struct LocalDomain: Sendable, Hashable, Identifiable {
    public var name: String
    public var localhostAddress: String?

    public var id: String { name }
    public var isHostAlias: Bool { localhostAddress != nil }

    public init(name: String, localhostAddress: String? = nil) {
        self.name = name
        self.localhostAddress = localhostAddress
    }

    /// Reads `options localhost:203.0.113.113` from a resolver file Apple's tool wrote.
    public static func localhostAddress(inResolver text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("options") else { continue }
            for part in trimmed.split(separator: " ") where part.hasPrefix("localhost:") {
                let value = String(part.dropFirst("localhost:".count))
                if isIPv4(value) { return value }
            }
        }
        return nil
    }

    public static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }

    /// Domain names Apple's tool accepts: lowercase labels joined by dots.
    public static func isValidName(_ value: String) -> Bool {
        let name = HostName.normalize(value)
        guard !name.isEmpty, name.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(HostName.isValidLabel)
    }
}

public extension ContainerClient {
    /// System property that holds the default DNS domain (`[dns] domain` in config.toml).
    static let defaultDomainProperty = "dns.domain"

    /// Domains with their host alias address, read from /etc/resolver (no admin needed).
    func localDomains(resolverDirectory: String = "/etc/resolver") async throws -> [LocalDomain] {
        let names = try await dnsDomains()
        return names.sorted().map { name in
            let file = "\(resolverDirectory)/containerization.\(name)"
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            return LocalDomain(name: name, localhostAddress: LocalDomain.localhostAddress(inResolver: text))
        }
    }

    /// Needs admin. A domain that points at this Mac, so containers reach Mac services by name.
    func createHostAlias(_ name: String, address: String = DomainsConfig.hostAliasAddress) async throws {
        guard LocalDomain.isIPv4(address) else { throw DeckError.commandFailed("\(address) is not an IPv4 address.") }
        try await createDNSDomain(name, localhost: address)
    }

    /// Default domain the service uses now, and the one saved for the next start.
    func defaultDNSDomain() async throws -> (active: String?, saved: String?) {
        let properties = try await systemProperties()
        let active = Self.cleanDomainValue(properties.first { $0.key == Self.defaultDomainProperty }?.value)
        let saved = Self.cleanDomainValue(SystemConfigFile.value(Self.defaultDomainProperty)) ?? active
        return (active, saved)
    }

    func setDefaultDNSDomain(_ name: String) async throws {
        try await setSystemProperty(Self.defaultDomainProperty, value: name)
    }

    /// Strips quotes and treats empty or "nil" as not set.
    static func cleanDomainValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        if value.isEmpty || ["nil", "null", "<nil>", "*undefined*"].contains(value) { return nil }
        return value
    }
}

/// Checks for something listening on a loopback port.
public enum LoopbackPortCheck {
    public static func isListening(_ port: UInt16, host: String = "127.0.0.1") -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

import Foundation
import Security

/// Where secrets live. The real one is the login Keychain. Tests use `MemorySecretStore`.
public protocol SecretStore: Sendable {
    func value(service: String, account: String) async throws -> String?
    func set(_ value: String, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
    func contains(service: String, account: String) -> Bool
}

public enum SecretStoreError: Error, LocalizedError, Equatable {
    case status(Int32)
    case invalidValue

    public var errorDescription: String? {
        switch self {
        case .status(let code):
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "error \(code)"
            return "Keychain: \(message)"
        case .invalidValue: return "The value is empty or has a line break."
        }
    }
}

/// Generic password items in the login Keychain, written and read through `/usr/bin/security`.
/// The stdio launch line an agent runs reads server secrets with the same tool, so no prompt
/// appears, and a rebuilt app (new signature) still reads its items.
public struct KeychainSecretStore: SecretStore {
    public static let securityTool = "/usr/bin/security"
    let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func value(service: String, account: String) async throws -> String? {
        let result = try await runner.run(Self.securityTool, ["find-generic-password", "-s", service, "-a", account, "-w"])
        guard result.succeeded else { return nil }
        var value = result.stdout
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    public func set(_ value: String, service: String, account: String) async throws {
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { throw SecretStoreError.invalidValue }
        guard Self.isSafeName(service), Self.isSafeName(account) else { throw SecretStoreError.invalidValue }
        try await delete(service: service, account: account)
        // `security -i` reads the command from stdin, so the value never shows up in the process list.
        // Created by /usr/bin/security with itself trusted, so the launch line an agent runs can read it
        // without a prompt (the "apple-tool" partition), and so can this app through the same tool.
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let label = "\(AppConfig.appName): \(account)"
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -l \"\(label)\" -T \(Self.securityTool) -X \(hex)\n"
        let result = try await runner.run(Self.securityTool, ["-i"], stdin: Data(command.utf8))
        guard result.succeeded, contains(service: service, account: account) else {
            throw DeckError.commandFailed("Could not save to the Keychain. \(result.failureMessage)")
        }
    }

    /// Names that are safe inside the quoted `security -i` command.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("\"") && !name.contains("\\") && !name.contains("\n")
    }

    public func delete(service: String, account: String) async throws {
        guard contains(service: service, account: account) else { return }
        let result = try await runner.run(Self.securityTool, ["delete-generic-password", "-s", service, "-a", account])
        if !result.succeeded {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.status(status) }
        }
    }

    /// Checks the item exists without reading its value (no prompt).
    public func contains(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

}

/// In memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    private func withItems<T>(_ body: (inout [String: String]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&items)
    }

    public func value(service: String, account: String) async throws -> String? {
        withItems { $0[service + "|" + account] }
    }

    public func set(_ value: String, service: String, account: String) async throws {
        guard !value.isEmpty, !value.contains("\n") else { throw SecretStoreError.invalidValue }
        withItems { $0[service + "|" + account] = value }
    }

    public func delete(service: String, account: String) async throws {
        withItems { $0[service + "|" + account] = nil }
    }

    public func contains(service: String, account: String) -> Bool {
        withItems { $0[service + "|" + account] != nil }
    }
}

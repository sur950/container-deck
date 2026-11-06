import Foundation
import Security

/// API keys for sandboxes, kept in the login Keychain (generic passwords).
/// Account is the sandbox name. Nothing is written to disk in plain text.
public struct SandboxKeychain: Sendable {
    public enum KeychainError: LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
                return "Keychain: \(text)"
            }
        }
    }

    public let service: String

    public init(service: String = SandboxConfig.keychainService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Saves or replaces the key for a sandbox.
    public func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(AppConfig.appName) sandbox \(account)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// The key for a sandbox, or nil when none is stored.
    public func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the key. No error when there is none.
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

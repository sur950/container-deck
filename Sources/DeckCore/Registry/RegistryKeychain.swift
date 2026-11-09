import Foundation
import Security

/// A registry login read from the keychain. Lives in memory only. Its
/// description never shows the secret, so it cannot leak into a log by accident.
public struct RegistryCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var username: String
    public var secret: String

    public init(username: String, secret: String) {
        self.username = username
        self.secret = secret
    }

    public var basicHeader: String {
        "Basic " + Data("\(username):\(secret)".utf8).base64EncodedString()
    }

    public var description: String { "RegistryCredential(redacted)" }
    public var debugDescription: String { description }
}

/// What a keychain lookup found.
public enum RegistryCredentialLookup: Sendable, Equatable {
    case found(RegistryCredential)
    /// No saved login for that server.
    case none
    /// A login exists, but macOS asks before Container Deck may read it.
    case needsPermission
    case failed(String)
}

/// Reads saved registry logins. Tests use a fake.
public protocol RegistryCredentialReading: Sendable {
    /// `interactive` false never shows a macOS prompt. True may show one, and is
    /// only used after the person asks for it.
    func credential(server: String, interactive: Bool) async -> RegistryCredentialLookup
}

/// Logins saved by `container registry login`.
///
/// Apple's tool (ContainerizationOS `KeychainQuery`, `Constants.keychainID`) saves
/// each login as an internet password in the login keychain:
/// class `kSecClassInternetPassword`, security domain "com.apple.container.registry",
/// server = the resolved host ("registry-1.docker.io" for docker.io), account = user name,
/// data = the password or token. The item's access list trusts only the `container`
/// tool, so another app gets the macOS keychain prompt the first time. A quiet read
/// with user interaction turned off fails at once instead of prompting, which is how
/// the app knows to ask first.
public struct ContainerRegistryKeychain: RegistryCredentialReading {
    public static let securityDomain = "com.apple.container.registry"

    public init() {}

    public func credential(server: String, interactive: Bool) async -> RegistryCredentialLookup {
        await Task.detached(priority: .userInitiated) {
            Self.read(server: server, interactive: interactive)
        }.value
    }

    /// One read at a time: the quiet read turns keychain prompts off for the whole process.
    private static let lock = NSLock()

    static func read(server: String, interactive: Bool) -> RegistryCredentialLookup {
        lock.lock()
        defer { lock.unlock() }
        guard exists(server: server) else { return .none }
        if !interactive {
            guard let toggle = InteractionToggle.load() else { return .needsPermission }
            let previous = toggle.current()
            toggle.set(false)
            defer { toggle.set(previous) }
            return copy(server: server, quiet: true)
        }
        return copy(server: server, quiet: false)
    }

    private static func baseQuery(server: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: securityDomain,
            kSecAttrServer as String: server,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    /// Attributes only, which never prompts.
    private static func exists(server: String) -> Bool {
        var query = baseQuery(server: server)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func copy(server: String, quiet: Bool) -> RegistryCredentialLookup {
        var query = baseQuery(server: server)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let fields = item as? [String: Any],
                  let data = fields[kSecValueData as String] as? Data,
                  let secret = String(data: data, encoding: .utf8),
                  let account = fields[kSecAttrAccount as String] as? String else {
                return .failed("The saved login could not be read.")
            }
            return .found(RegistryCredential(username: account, secret: secret))
        case errSecItemNotFound:
            return .none
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return quiet ? .needsPermission : .failed("Keychain access was not allowed.")
        case errSecUserCanceled:
            return .failed("Keychain access was not allowed.")
        default:
            return quiet ? .needsPermission : .failed("The keychain answered with error \(status).")
        }
    }
}

/// `SecKeychainGetUserInteractionAllowed` and `SecKeychainSetUserInteractionAllowed`,
/// looked up at run time. They are the only switch that stops the legacy keychain
/// prompt (`kSecUseAuthenticationUIFail` does not, tested on macOS 27). Looked up
/// by name so the deprecation does not warn on every build.
private struct InteractionToggle {
    typealias Getter = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    typealias Setter = @convention(c) (DarwinBoolean) -> OSStatus

    let getter: Getter
    let setter: Setter

    static func load() -> InteractionToggle? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_NOLOAD) ?? dlopen(nil, RTLD_NOW),
              let get = dlsym(handle, "SecKeychainGetUserInteractionAllowed"),
              let set = dlsym(handle, "SecKeychainSetUserInteractionAllowed") else { return nil }
        return InteractionToggle(getter: unsafeBitCast(get, to: Getter.self), setter: unsafeBitCast(set, to: Setter.self))
    }

    func current() -> Bool {
        var value: DarwinBoolean = true
        return getter(&value) == errSecSuccess ? value.boolValue : true
    }

    func set(_ allowed: Bool) {
        _ = setter(DarwinBoolean(allowed))
    }
}

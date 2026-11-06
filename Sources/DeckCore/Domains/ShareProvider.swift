import Foundation
import Security

/// A service that puts one route on the public internet: Cloudflare Tunnel, ngrok, Tailscale Funnel.
///
/// Each provider is one type behind this protocol and one entry in `ShareProviders.all`.
/// Views and `ShareManager` only talk to the protocol, so a new provider is one new file
/// plus one line in that list.
public protocol ShareProvider: Sendable {
    /// Stable id, saved in preferences. Also the Keychain account prefix.
    var id: String { get }
    var title: String { get }
    /// One line under the title before the provider is checked, like "No account needed".
    var summary: String { get }
    /// Program name searched in the tool folders.
    var binaryName: String { get }
    /// Where the program may live, in order.
    func candidatePaths(searchPaths: [String], toolsDirectory: String, includeAppBundle: Bool) -> [String]
    /// Ways to install it. Nothing is installed unless the person picks one.
    var installOptions: [ShareInstallOption] { get }
    /// Settings the person can fill in, like an authtoken. Empty when there is nothing to set.
    var setupFields: [ShareSetupField] { get }
    /// Page where the person finds what the setup fields ask for.
    var setupLink: URL? { get }

    /// Ready, or what is missing, checked with short read only CLI calls.
    func readiness(executable: String, context: ShareContext) async -> ShareReadiness
    /// Why this route cannot use this provider, before anything runs. Nil when it can.
    func blocker(for route: ProxyRoute, publishedPort: Int?) -> ShareFailure?
    /// Command, arguments and environment for one share.
    func prepare(route: ProxyRoute, publishedPort: Int?, executable: String, context: ShareContext,
                 reservedPorts: Set<Int>) async throws -> ShareLaunch
    /// The public link in the output so far (whole lines only), if it is there yet.
    func publicURL(in output: String, launch: ShareLaunch?) -> String?
    /// A failure visible while the tool still runs. The share stops right away.
    func earlyFailure(in output: String) -> ShareFailure?
    /// A failure read from the output after the tool ended or timed out.
    func classify(_ output: String) -> ShareFailure?
    /// Another way to find the link when the output has none, like a local API. Nil when there is none.
    func lookupURL(output: String) async -> String?
    /// True when `lookupURL` is worth calling.
    var hasLookup: Bool { get }
    /// After a share ends: remove anything of ours the tool left behind. Never touches anything else.
    @discardableResult
    func cleanUp(after launch: ShareLaunch, context: ShareContext) async -> Bool
    /// Runs one install option (Homebrew or a direct download). Web pages are opened by the app.
    func install(_ option: ShareInstallOption, context: ShareContext, brew: String?) async throws
    /// Checks a setup value. Returns a short message when it is wrong.
    func validate(field: ShareSetupField, value: String) -> String?
}

public extension ShareProvider {
    func candidatePaths(searchPaths: [String], toolsDirectory: String, includeAppBundle: Bool) -> [String] {
        searchPaths.map { "\($0)/\(binaryName)" }
    }
    var setupFields: [ShareSetupField] { [] }
    var setupLink: URL? { nil }
    func blocker(for route: ProxyRoute, publishedPort: Int?) -> ShareFailure? {
        route.isReachable && !route.isWildcard ? nil : .containerStopped(route.container)
    }
    func earlyFailure(in output: String) -> ShareFailure? { nil }
    func classify(_ output: String) -> ShareFailure? { nil }
    func lookupURL(output: String) async -> String? { nil }
    var hasLookup: Bool { false }
    @discardableResult
    func cleanUp(after launch: ShareLaunch, context: ShareContext) async -> Bool { false }
    func install(_ option: ShareInstallOption, context: ShareContext, brew: String?) async throws {
        switch option {
        case .homebrew(let name, let cask):
            guard let brew else { throw DeckError.commandFailed("Homebrew is not installed.") }
            try await context.runner.run(brew, cask ? ["install", "--cask", name] : ["install", name]).orThrow()
        case .webPage:
            break
        case .direct:
            throw DeckError.notImplemented("Direct install for \(title)")
        }
    }
    func validate(field: ShareSetupField, value: String) -> String? { nil }

}

/// Every provider the app offers, in the order the picker shows them.
public enum ShareProviders {
    public static let all: [any ShareProvider] = [
        CloudflareShareProvider(),
        NgrokShareProvider(),
        TailscaleFunnelProvider(),
    ]

    public static func provider(id: String) -> (any ShareProvider)? {
        all.first { $0.id == id }
    }
}

// MARK: - Supporting types

/// Where a provider stands on this Mac.
public enum ShareReadiness: Equatable, Sendable {
    case ready(detail: String)
    case needsSetup(ShareFailure)
    case notInstalled

    public var isReady: Bool { if case .ready = self { return true } else { return false } }
}

public enum ShareInstallOption: Equatable, Sendable, Identifiable {
    /// `brew install <name>`, or `brew install --cask <name>`.
    case homebrew(String, cask: Bool = false)
    /// A download the provider runs and checks itself.
    case direct(title: String)
    /// A page the app opens in the browser.
    case webPage(URL)

    public var id: String { title }

    public var title: String {
        switch self {
        case .homebrew: return "With Homebrew"
        case .direct(let title): return title
        case .webPage: return "Download Page"
        }
    }

    /// The command, shown as a hint.
    public var command: String? {
        if case .homebrew(let name, let cask) = self { return cask ? "brew install --cask \(name)" : "brew install \(name)" }
        return nil
    }
}

/// One setting a provider needs, like an authtoken. Secrets go to the Keychain,
/// other values to preferences.
public struct ShareSetupField: Equatable, Sendable, Identifiable {
    public var key: String
    public var title: String
    public var isSecret: Bool
    public var isOptional: Bool
    public var placeholder: String
    public var note: String
    public var id: String { key }

    public init(key: String, title: String, isSecret: Bool, isOptional: Bool = false, placeholder: String = "", note: String = "") {
        self.key = key
        self.title = title
        self.isSecret = isSecret
        self.isOptional = isOptional
        self.placeholder = placeholder
        self.note = note
    }
}

/// What providers may use: a runner for short CLI calls, the saved setup values, and the home folder.
public struct ShareContext: Sendable {
    public var runner: any CommandRunning
    public var secret: @Sendable (_ provider: String, _ key: String) -> String?
    public var setting: @Sendable (_ provider: String, _ key: String) -> String?
    public var homeDirectory: String
    public var callTimeout: TimeInterval

    public init(runner: any CommandRunning = ProcessRunner(),
                secret: @escaping @Sendable (String, String) -> String? = { ShareKeychain().read(provider: $0, key: $1) },
                setting: @escaping @Sendable (String, String) -> String? = { UserDefaults.standard.string(forKey: DomainsConfig.shareSettingKey(provider: $0, key: $1)) },
                homeDirectory: String = NSHomeDirectory(),
                callTimeout: TimeInterval = 10) {
        self.runner = runner
        self.secret = secret
        self.setting = setting
        self.homeDirectory = homeDirectory
        self.callTimeout = callTimeout
    }

    /// Runs a short command and gives up after `callTimeout`, so a stuck CLI never blocks a share.
    public func call(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        let runner = self.runner
        let timeout = callTimeout
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task {
                do { once.resume(.success(try await runner.run(executable, arguments))) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.resume(.failure(ShareFailure(.notRunning, "\(name) did not answer in \(Int(timeout)) seconds.",
                                                  fix: "Open the app, then try again.")))
            }
        }
    }
}

/// Resumes a continuation once, whichever side finishes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?

    init(_ continuation: CheckedContinuation<CommandResult, Error>) { self.continuation = continuation }

    func resume(_ result: Result<CommandResult, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Everything needed to start one share and clean up after it.
public struct ShareLaunch: Sendable, Equatable {
    public var providerID: String
    public var executable: String
    public var arguments: [String]
    /// Extra environment for the tool only, like NGROK_AUTHTOKEN. Never on the command line.
    public var environment: [String: String]
    /// Values blanked out of everything the tool prints.
    public var secrets: [String]
    /// A port this share holds (a Funnel port), so two shares never take the same one.
    public var reservedPort: Int?
    /// Where the tool sends traffic, as the tool records it.
    public var target: String?
    /// Our public host name, when the provider knows it up front.
    public var publicHost: String?
    /// The link we expect, when it is known before the tool prints it.
    public var expectedURL: String?

    public init(providerID: String, executable: String, arguments: [String], environment: [String: String] = [:],
                secrets: [String] = [], reservedPort: Int? = nil, target: String? = nil, publicHost: String? = nil,
                expectedURL: String? = nil) {
        self.providerID = providerID
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.secrets = secrets
        self.reservedPort = reservedPort
        self.target = target
        self.publicHost = publicHost
        self.expectedURL = expectedURL
    }
}

// MARK: - Failures

/// Why a share did not start, in plain words, with the fix and where to fix it.
public struct ShareFailure: Error, LocalizedError, Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        case notInstalled
        case containerStopped
        case needsPublishedPort
        /// Missing or wrong sign in, token or credential.
        case needsSetup
        /// A policy or account setting does not allow it.
        case notAllowed
        /// Already in use, or over a plan limit.
        case busy
        /// The service cannot be reached. Often a blocked network.
        case offline
        case outdated
        /// The provider's own app or service is not running.
        case notRunning
        /// No link in time.
        case noLink
        case exited
    }

    public var kind: Kind
    /// What happened.
    public var message: String
    /// What to do about it.
    public var fix: String
    /// Where to fix it, when that is a web page.
    public var link: URL?
    /// Code the tool printed, like ERR_NGROK_4018.
    public var code: String?
    /// The fix is in the app: the provider's setup fields (like an authtoken).
    public var opensSetup: Bool

    public init(_ kind: Kind, _ message: String, fix: String, link: URL? = nil, code: String? = nil, opensSetup: Bool = false) {
        self.kind = kind
        self.message = message
        self.fix = fix
        self.link = link
        self.code = code
        self.opensSetup = opensSetup
    }

    public var errorDescription: String? { fix.isEmpty ? message : "\(message) \(fix)" }

    /// Another provider may work where this one did not (blocked network, account or policy problems).
    public var otherProviderMayWork: Bool {
        switch kind {
        case .containerStopped: return false
        default: return true
        }
    }

    public static func notInstalled(_ provider: any ShareProvider) -> ShareFailure {
        let hint = provider.installOptions.compactMap(\.command).first.map { "Install it with \($0)." } ?? "Install it first."
        return ShareFailure(.notInstalled, "\(provider.title) is not installed.", fix: hint)
    }

    public static func containerStopped(_ container: String) -> ShareFailure {
        ShareFailure(.containerStopped, "\(container) is not running.", fix: "Start it, then share again.")
    }

    public static func noLink(_ provider: any ShareProvider, seconds: Int) -> ShareFailure {
        ShareFailure(.noLink, "\(provider.title) gave no public link after \(seconds) seconds.",
                     fix: "Your network may block it. Try another provider.")
    }

    public static func exited(_ provider: any ShareProvider, status: Int32, tail: String) -> ShareFailure {
        let last = tail.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        let message = (last?.isEmpty == false) ? last! : "\(provider.title) stopped (exit code \(status))."
        return ShareFailure(.exited, message, fix: "Try again, or try another provider.")
    }
}

// MARK: - Keychain

/// Provider secrets (like the ngrok authtoken) in the login Keychain, one generic password per
/// provider and field. They never go into a file or onto a command line.
public struct ShareKeychain: Sendable {
    public let service: String

    public init(service: String = DomainsConfig.keychainService) {
        self.service = service
    }

    public static func account(provider: String, key: String) -> String { "\(provider).\(key)" }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func save(_ value: String, provider: String, key: String) throws {
        let account = Self.account(provider: provider, key: key)
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(AppConfig.appName) \(provider) \(key)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    public func read(provider: String, key: String) -> String? {
        var request = query(Self.account(provider: provider, key: key))
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    public func delete(provider: String, key: String) throws {
        let status = SecItemDelete(query(Self.account(provider: provider, key: key)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    private static func error(_ status: OSStatus) -> DeckError {
        DeckError.commandFailed("Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))
    }
}

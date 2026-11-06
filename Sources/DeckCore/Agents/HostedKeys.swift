import Foundation

/// Hosted AI providers whose API keys we keep in the Keychain.
public enum HostedProvider: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case anthropic, openai, gemini

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        }
    }

    /// The variable agents and SDKs read.
    public var environmentVariable: String {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .gemini: return "AIza…"
        }
    }

    public var consoleURL: String {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .gemini: return "https://aistudio.google.com/apikey"
        }
    }

    /// A cheap authenticated call that lists models.
    func checkRequest(key: String) -> URLRequest {
        var request: URLRequest
        switch self {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 15
        return request
    }
}

public enum KeyCheckResult: Sendable, Equatable {
    case valid
    case rejected
    case failed(String)

    public var title: String {
        switch self {
        case .valid: return "Key works"
        case .rejected: return "Key was rejected"
        case .failed(let message): return message
        }
    }
}

/// API keys for hosted providers. Values never leave this type except through `environment(for:)`,
/// which callers (like Sandboxes) use only when a person asks to inject keys.
public struct HostedKeyStore: Sendable {
    let store: any SecretStore
    let service: String

    public init(store: any SecretStore = KeychainSecretStore(), service: String = AgentsConfig.providerKeyService) {
        self.store = store
        self.service = service
    }

    public func hasKey(_ provider: HostedProvider) -> Bool {
        store.contains(service: service, account: provider.rawValue)
    }

    public func savedProviders() -> [HostedProvider] {
        HostedProvider.allCases.filter(hasKey)
    }

    public func save(_ key: String, for provider: HostedProvider) async throws {
        try await store.set(key.trimmingCharacters(in: .whitespacesAndNewlines), service: service, account: provider.rawValue)
    }

    public func remove(_ provider: HostedProvider) async throws {
        try await store.delete(service: service, account: provider.rawValue)
    }

    /// Env variables with the saved keys of these providers. Missing keys are skipped.
    public func environment(for providers: [HostedProvider]) async throws -> [EnvVar] {
        var vars: [EnvVar] = []
        for provider in providers {
            if let key = try await store.value(service: service, account: provider.rawValue), !key.isEmpty {
                vars.append(EnvVar(key: provider.environmentVariable, value: key))
            }
        }
        return vars
    }

    /// Asks the provider whether the saved key works. The key is only sent to the provider.
    public func check(_ provider: HostedProvider, session: URLSession = .shared) async -> KeyCheckResult {
        do {
            guard let key = try await store.value(service: service, account: provider.rawValue) else {
                return .failed("No key saved")
            }
            let (_, response) = try await session.data(for: provider.checkRequest(key: key))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: return .valid
            case 400, 401, 403: return .rejected
            default: return .failed("The provider answered \(code)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

import Foundation
import DeckCore

/// Model servers found by the AI Models area, offered as quick picks in the sandbox form.
struct DiscoveredModelSource: SandboxModelSource {
    let endpoint: ModelEndpoint

    var title: String { endpoint.name }
    var kind: SandboxModelKind { endpoint.kind == .ollama ? .ollama : .openAI }
    /// Ollama wants its root URL, every other server the OpenAI style /v1 URL.
    var baseURL: URL { endpoint.kind == .ollama ? (endpoint.nativeURL ?? endpoint.baseURL) : endpoint.baseURL }
    var apiKey: String? { nil }
    var defaultModel: String? { endpoint.models.first(where: \.isLoaded)?.id ?? endpoint.models.first?.id }

    /// Running servers right now, Ollama first.
    static func current() async -> [any SandboxModelSource] {
        await ModelEndpoints.running()
            .sorted { ($0.kind == .ollama ? 0 : 1) < ($1.kind == .ollama ? 0 : 1) }
            .map { DiscoveredModelSource(endpoint: $0) }
    }
}

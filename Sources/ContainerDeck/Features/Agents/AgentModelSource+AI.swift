import Foundation
import DeckCore

/// Model servers found by the AI Models area, used by the Agents area for "point at a local model".
/// Falls back to probing the usual ports when discovery finds nothing.
struct DiscoveredAgentModelSource: AgentModelEndpointSource {
    func endpoints() async -> [AgentModelEndpoint] {
        let found = await ModelEndpoints.running().map { endpoint in
            AgentModelEndpoint(
                name: endpoint.name,
                kind: Self.kind(endpoint.kind),
                baseURL: endpoint.baseURL.absoluteString,
                models: endpoint.models.map(\.id)
            )
        }
        if !found.isEmpty { return found }
        return await ProbingModelEndpointSource().endpoints()
    }

    private static func kind(_ kind: ModelServerKind) -> AgentModelEndpoint.Kind {
        switch kind {
        case .ollama: return .ollama
        case .lmStudio: return .lmStudio
        case .mlxLM, .oMLX: return .mlx
        default: return .other
        }
    }
}

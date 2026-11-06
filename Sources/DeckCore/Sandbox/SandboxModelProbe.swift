import Foundation

/// Asks a model server on this Mac which models it has (OpenAI style `/models`).
/// Used by the create form to fill the model picker. Never sends the key anywhere else.
public enum SandboxModelProbe {
    public static func models(baseURL: URL, kind: SandboxModelKind, apiKey: String?, timeout: TimeInterval = 4) async throws -> [String] {
        guard let url = URL(string: SandboxChat.modelsURL(base: baseURL, kind: kind)) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DeckError.commandFailed("The server answered \(http.statusCode).")
        }
        return SandboxChat.parseModels(String(decoding: data, as: UTF8.self)).sorted()
    }
}

import Foundation

/// One chat turn.
public struct SandboxChatMessage: Sendable, Hashable, Identifiable, Codable {
    public enum Role: String, Sendable, Hashable, Codable {
        case system, user, assistant
    }

    public var id = UUID()
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    enum CodingKeys: String, CodingKey { case role, content }
}

/// Chat with the sandbox model, sent from inside the container so it takes the same
/// network path an agent would (relay, proxy and allow list included).
public enum SandboxChat {
    public enum ChatError: LocalizedError {
        case server(String)
        case badReply(String)

        public var errorDescription: String? {
            switch self {
            case .server(let message): return "The model said: \(message)"
            case .badReply(let text): return "Unexpected reply from the model. \(text)"
            }
        }
    }

    /// OpenAI style chat completions URL for a sandbox model. Ollama serves the same API under /v1.
    public static func completionsURL(base: URL, kind: SandboxModelKind) -> String {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if kind == .ollama && !text.hasSuffix("/v1") { text += "/v1" }
        return text + "/chat/completions"
    }

    /// OpenAI style models URL.
    public static func modelsURL(base: URL, kind: SandboxModelKind) -> String {
        completionsURL(base: base, kind: kind).replacingOccurrences(of: "/chat/completions", with: "/models")
    }

    /// JSON body for a non streaming chat request.
    public static func requestBody(model: String, messages: [SandboxChatMessage]) throws -> Data {
        struct Body: Encodable {
            var model: String
            var messages: [SandboxChatMessage]
            var stream = false
        }
        return try JSONEncoder().encode(Body(model: model, messages: messages))
    }

    /// The reply text, or the server's error message.
    public static func parseReply(_ text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.badReply(String(text.prefix(200)))
        }
        if let error = object["error"] {
            if let dict = error as? [String: Any], let message = dict["message"] as? String { throw ChatError.server(message) }
            throw ChatError.server("\(error)")
        }
        if let choices = object["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any], let content = message["content"] as? String { return content }
            if let content = first["text"] as? String { return content }
        }
        if let message = object["message"] as? [String: Any], let content = message["content"] as? String { return content }
        throw ChatError.badReply(String(text.prefix(200)))
    }

    /// Model ids from an OpenAI style `/models` reply.
    public static func parseModels(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let list = object["data"] as? [[String: Any]] {
            return list.compactMap { $0["id"] as? String }
        }
        if let list = object["models"] as? [[String: Any]] {
            return list.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
        }
        return []
    }

    /// Shell script run inside the container. Reads the JSON body from stdin and posts it
    /// with curl, wget or python, whichever the image has. The key is read from the tmpfs file.
    /// `$1` is the URL. GET when stdin is empty.
    public static let postScript = """
    url="$1"
    body="$(cat)"
    key="$(cat \(SandboxConfig.apiKeyFile) 2>/dev/null || true)"
    [ -n "$key" ] || key="${OPENAI_API_KEY:-\(SandboxConfig.localKeyPlaceholder)}"
    if command -v curl >/dev/null 2>&1; then
      if [ -n "$body" ]; then
        exec curl -sS -m 300 -H "Content-Type: application/json" -H "Authorization: Bearer $key" --data-binary "$body" "$url"
      else
        exec curl -sS -m 30 -H "Authorization: Bearer $key" "$url"
      fi
    elif command -v wget >/dev/null 2>&1 && wget --help 2>&1 | grep -q post-data; then
      if [ -n "$body" ]; then
        exec wget -q -O- -T 300 --header "Content-Type: application/json" --header "Authorization: Bearer $key" --post-data "$body" "$url"
      else
        exec wget -q -O- -T 30 --header "Authorization: Bearer $key" "$url"
      fi
    elif command -v python3 >/dev/null 2>&1; then
      DECK_BODY="$body" DECK_KEY="$key" exec python3 -c '
    import os, sys, urllib.request, urllib.error
    body = os.environ.get("DECK_BODY", "")
    req = urllib.request.Request(sys.argv[1], data=body.encode() if body else None)
    req.add_header("Authorization", "Bearer " + os.environ.get("DECK_KEY", ""))
    if body: req.add_header("Content-Type", "application/json")
    try:
        sys.stdout.write(urllib.request.urlopen(req, timeout=300).read().decode())
    except urllib.error.HTTPError as e:
        sys.stdout.write(e.read().decode())
    ' "$url"
    elif command -v node >/dev/null 2>&1; then
      DECK_BODY="$body" DECK_KEY="$key" exec node -e '
    const b = process.env.DECK_BODY || "";
    const h = { Authorization: "Bearer " + process.env.DECK_KEY };
    if (b) h["Content-Type"] = "application/json";
    fetch(process.argv[1], b ? { method: "POST", headers: h, body: b } : { headers: h })
      .then(r => r.text()).then(t => process.stdout.write(t)).catch(e => { console.error(String(e)); process.exit(1); });
    ' "$url"
    else
      echo "No curl, wget, python3 or node in this image." >&2
      exit 127
    fi
    """
}

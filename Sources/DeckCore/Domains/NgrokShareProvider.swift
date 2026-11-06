import Foundation

/// ngrok agent 3: `ngrok http <ip>:<port> --log stdout --log-format json [--url https://<domain>]`.
/// Needs an ngrok account. The authtoken comes from the Keychain through `NGROK_AUTHTOKEN`,
/// or from the person's own ngrok config. We never write ngrok's config.
public struct NgrokShareProvider: ShareProvider {
    public init() {}

    public let id = "ngrok"
    public let title = "ngrok"
    public let summary = "Uses your ngrok account. The free plan works."
    public let binaryName = "ngrok"

    public static let tokenKey = "authtoken"
    public static let domainKey = "domain"

    public var installOptions: [ShareInstallOption] {
        [.homebrew("ngrok"), .webPage(URL(string: DomainsConfig.ngrokDownloadPage)!)]
    }

    public var setupFields: [ShareSetupField] {
        [
            ShareSetupField(key: Self.tokenKey, title: "Authtoken", isSecret: true, placeholder: "Paste your authtoken",
                            note: "Find it on your ngrok dashboard. A free account is enough."),
            ShareSetupField(key: Self.domainKey, title: "Domain", isSecret: false, isOptional: true, placeholder: "demo.ngrok.app",
                            note: "Optional. A domain you reserved in ngrok. Empty gives a new link each time."),
        ]
    }

    public var setupLink: URL? { URL(string: DomainsConfig.ngrokAuthtokenPage) }

    public func validate(field: ShareSetupField, value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        switch field.key {
        case Self.tokenKey:
            return NgrokSetup.looksLikeToken(trimmed) ? nil : "That does not look like an ngrok authtoken. Copy it again from the dashboard."
        case Self.domainKey:
            return NgrokSetup.normalizedDomain(trimmed) == nil ? "Use a plain domain name, like demo.ngrok.app." : nil
        default:
            return nil
        }
    }

    public func readiness(executable: String, context: ShareContext) async -> ShareReadiness {
        let version = await (try? context.call(executable, ["version"])).flatMap { $0.succeeded ? NgrokSetup.version(from: $0.stdout + $0.stderr) : nil }
        let prefix = version.map { "Version \($0). " } ?? ""
        if context.secret(id, Self.tokenKey) != nil { return .ready(detail: prefix + "Authtoken in your Keychain.") }
        if NgrokSetup.configHasAuthtoken(paths: NgrokSetup.configPaths(home: context.homeDirectory)) {
            return .ready(detail: prefix + "Uses the authtoken in your ngrok config.")
        }
        return .needsSetup(ShareFailure(.needsSetup, "Add your ngrok authtoken.", fix: "A free ngrok account is enough.",
                                        link: setupLink, opensSetup: true))
    }

    public func arguments(for route: ProxyRoute, domain: String? = nil) -> [String]? {
        guard let host = route.targetHost else { return nil }
        var args = ["http", "\(host):\(route.targetPort)", "--log", "stdout", "--log-format", "json"]
        if let domain = domain.flatMap(NgrokSetup.normalizedDomain) { args += ["--url", "https://\(domain)"] }
        return args
    }

    public func prepare(route: ProxyRoute, publishedPort: Int?, executable: String, context: ShareContext,
                        reservedPorts: Set<Int>) async throws -> ShareLaunch {
        guard let args = arguments(for: route, domain: context.setting(id, Self.domainKey)) else {
            throw ShareFailure.containerStopped(route.container)
        }
        var launch = ShareLaunch(providerID: id, executable: executable, arguments: args)
        if let token = context.secret(id, Self.tokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            launch.environment[NgrokSetup.tokenEnvironmentKey] = token
            launch.secrets = [token]
        }
        return launch
    }

    public func publicURL(in output: String, launch: ShareLaunch?) -> String? {
        if let url = NgrokLog.publicURL(in: output) { return url }
        // Older agents without JSON logs.
        let pattern = #"https://[A-Za-z0-9.-]+\.ngrok(-free)?\.(app|dev|io)"#
        return output.range(of: pattern, options: .regularExpression).map { String(output[$0]) }
    }

    public func earlyFailure(in output: String) -> ShareFailure? {
        NgrokLog.errorCode(in: output) != nil ? classify(output) : nil
    }

    public func classify(_ output: String) -> ShareFailure? {
        let tokenPage = setupLink
        if let code = NgrokLog.errorCode(in: output) {
            let tag = "ERR_NGROK_\(code)"
            switch code {
            case 4018:
                return ShareFailure(.needsSetup, "ngrok needs an authtoken.", fix: "Add your authtoken from the ngrok dashboard.",
                                    link: tokenPage, code: tag, opensSetup: true)
            case 105:
                return ShareFailure(.needsSetup, "This is not a valid ngrok authtoken.", fix: "Copy it again from the ngrok dashboard.",
                                    link: tokenPage, code: tag, opensSetup: true)
            case 107:
                return ShareFailure(.needsSetup, "ngrok did not accept this authtoken.",
                                    fix: "It may have been reset. Copy the current one from the ngrok dashboard.",
                                    link: tokenPage, code: tag, opensSetup: true)
            case 108:
                return ShareFailure(.busy, "Your ngrok plan allows one agent at a time.",
                                    fix: "Stop the other ngrok share or ngrok running elsewhere, then try again.",
                                    link: URL(string: "https://dashboard.ngrok.com/agents"), code: tag)
            case 334:
                return ShareFailure(.busy, "This ngrok address is already online.",
                                    fix: "Stop the other share that uses it, or clear the ngrok domain.", code: tag, opensSetup: true)
            case 120, 121:
                return ShareFailure(.outdated, "This ngrok version is too old for your account.",
                                    fix: "Update it with brew upgrade ngrok.", link: URL(string: DomainsConfig.ngrokDownloadPage), code: tag)
            default:
                let line = NgrokLog.errorMessage(in: output).map(Self.firstLine) ?? "ngrok stopped with \(tag)."
                return ShareFailure(.exited, line, fix: "See the ngrok page for this error.",
                                    link: URL(string: "https://ngrok.com/docs/errors/err_ngrok_\(code)"), code: tag)
            }
        }
        let lower = output.lowercased()
        if lower.contains("failed to dial ngrok server") || lower.contains("no such host") || lower.contains("network is unreachable")
            || lower.contains("i/o timeout") {
            return ShareFailure(.offline, "ngrok cannot reach its servers.", fix: "Your network may block it. Try another provider.")
        }
        return nil
    }

    public var hasLookup: Bool { true }

    public func lookupURL(output: String) async -> String? {
        guard let address = NgrokLog.webAddress(in: output) else { return nil }
        return await NgrokAgentAPI.fetchPublicURL(address: address)
    }

    private static func firstLine(_ text: String) -> String {
        (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text).trimmingCharacters(in: .whitespaces)
    }
}

/// Reads `ngrok ... --log stdout --log-format json`: one JSON object per line.
public enum NgrokLog {
    public struct Line: Equatable, Sendable {
        public var level: String
        public var message: String
        public var url: String?
        public var addr: String?
        public var error: String?
    }

    public static func parse(_ line: String) -> Line? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else { return nil }
        return Line(level: object["lvl"] as? String ?? "", message: object["msg"] as? String ?? "",
                    url: object["url"] as? String, addr: object["addr"] as? String, error: object["err"] as? String)
    }

    /// Link from the "started tunnel" line. Works for any domain, including your own.
    public static func publicURL(in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            if let line = parse(String(raw)), line.message == "started tunnel",
               let url = line.url, url.hasPrefix("https://") || url.hasPrefix("http://") {
                return url
            }
        }
        return nil
    }

    /// Address of the agent's local web service: 127.0.0.1:4040, or the next port when that is busy.
    public static func webAddress(in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            if let line = parse(String(raw)), line.message == "starting web service", let addr = line.addr { return addr }
        }
        return nil
    }

    public static func errorCode(in text: String) -> Int? {
        guard let range = text.range(of: #"ERR_NGROK_\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst("ERR_NGROK_".count))
    }

    /// First error text ngrok logged, without the "authentication failed:" style prefix.
    public static func errorMessage(in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            if let line = parse(String(raw)), let error = line.error, line.level == "eror" || line.level == "crit" {
                let parts = error.split(separator: ":", maxSplits: 1)
                return (parts.count == 2 ? String(parts[1]) : error).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// The agent's local API, `GET http://127.0.0.1:4040/api/tunnels`, used when the log has no link.
public enum NgrokAgentAPI {
    public static func publicURL(fromTunnelsJSON data: Data) -> String? {
        struct Payload: Decodable {
            struct Tunnel: Decodable { let public_url: String? }
            let tunnels: [Tunnel]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let urls = payload.tunnels.compactMap(\.public_url)
        return urls.first { $0.hasPrefix("https://") } ?? urls.first
    }

    /// Loopback only.
    public static func fetchPublicURL(address: String, session: URLSession = .shared) async -> String? {
        guard address.hasPrefix("127.0.0.1:") || address.hasPrefix("localhost:"),
              let url = URL(string: "http://\(address)/api/tunnels") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return publicURL(fromTunnelsJSON: data)
    }
}

/// ngrok's own settings. We only read them, to tell whether an authtoken is set.
public enum NgrokSetup {
    public static let tokenEnvironmentKey = "NGROK_AUTHTOKEN"

    public static func configPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/Library/Application Support/ngrok/ngrok.yml", // ngrok 3 on macOS
            "\(home)/.config/ngrok/ngrok.yml",
            "\(home)/.ngrok2/ngrok.yml",                           // ngrok 2
        ]
    }

    /// True when an `authtoken:` line with a value is there (top level in v2, under `agent:` in v3).
    public static func configHasAuthtoken(_ text: String) -> Bool {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("authtoken:") else { continue }
            let value = line.dropFirst("authtoken:".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value != "\"\"", value != "''", !value.hasPrefix("#") { return true }
        }
        return false
    }

    public static func configHasAuthtoken(paths: [String],
                                          read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Bool {
        paths.contains { read($0).map(configHasAuthtoken) == true }
    }

    /// Light check before saving. ngrok tokens are long and have no spaces.
    public static func looksLikeToken(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count >= 20 && value.count <= 200 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// `ngrok version` prints "ngrok version 3.39.13".
    public static func version(from text: String) -> String? {
        SemanticVersion.firstMatch(in: text).map { "\($0)" }
    }

    /// Accepts "demo.ngrok.app" or "https://demo.ngrok.app/".
    public static func normalizedDomain(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty, !value.hasPrefix("*."), HostName.isValidPattern(value) else { return nil }
        return value
    }
}

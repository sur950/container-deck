import Foundation
import Yams

/// The parts of a kubeconfig the app needs to reach one cluster's API.
public struct KubeConfigFile: Sendable, Hashable {
    public struct Credentials: Sendable, Hashable {
        public var server: URL
        /// DER bytes of the cluster CA. nil means the system trust store.
        public var certificateAuthority: Data?
        public var clientCertificatePEM: Data?
        public var clientKeyPEM: Data?
        public var token: String?
        public var insecureSkipTLSVerify: Bool
        public var namespace: String?

        public init(
            server: URL, certificateAuthority: Data? = nil, clientCertificatePEM: Data? = nil,
            clientKeyPEM: Data? = nil, token: String? = nil, insecureSkipTLSVerify: Bool = false, namespace: String? = nil
        ) {
            self.server = server
            self.certificateAuthority = certificateAuthority
            self.clientCertificatePEM = clientCertificatePEM
            self.clientKeyPEM = clientKeyPEM
            self.token = token
            self.insecureSkipTLSVerify = insecureSkipTLSVerify
            self.namespace = namespace
        }
    }

    public var path: String
    public var currentContext: String?
    public var contexts: [String]
    private var entries: [String: Credentials]

    public init(path: String, currentContext: String?, contexts: [String], entries: [String: Credentials]) {
        self.path = path
        self.currentContext = currentContext
        self.contexts = contexts
        self.entries = entries
    }

    /// Credentials for a context. nil picks the current context, then the only one.
    public func credentials(context: String? = nil) -> Credentials? {
        if let context { return entries[context] }
        if let current = currentContext, let match = entries[current] { return match }
        return contexts.count == 1 ? entries[contexts[0]] : nil
    }

    public static func load(_ file: URL) throws -> KubeConfigFile {
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw DeckError.commandFailed("Could not read the kubeconfig at \(file.path).")
        }
        return try parse(text, path: file.path)
    }

    public static func parse(_ text: String, path: String = "") throws -> KubeConfigFile {
        guard let root = (try? Yams.load(yaml: text)) as? [String: Any] else {
            throw DeckError.parse("the kubeconfig")
        }
        let clusters = named(root["clusters"], key: "cluster")
        let users = named(root["users"], key: "user")
        let contexts = named(root["contexts"], key: "context")
        var entries: [String: Credentials] = [:]
        var order: [String] = []
        for (name, context) in contexts {
            guard let clusterName = context["cluster"] as? String,
                  let cluster = clusters.first(where: { $0.name == clusterName })?.value,
                  let serverText = cluster["server"] as? String,
                  let server = URL(string: serverText) else { continue }
            let user = (context["user"] as? String).flatMap { userName in users.first(where: { $0.name == userName })?.value } ?? [:]
            entries[name] = Credentials(
                server: server,
                certificateAuthority: (cluster["certificate-authority-data"] as? String).flatMap(decodeCertificate),
                clientCertificatePEM: (user["client-certificate-data"] as? String).flatMap { Data(base64Encoded: clean($0)) },
                clientKeyPEM: (user["client-key-data"] as? String).flatMap { Data(base64Encoded: clean($0)) },
                token: user["token"] as? String,
                insecureSkipTLSVerify: (cluster["insecure-skip-tls-verify"] as? Bool) ?? false,
                namespace: context["namespace"] as? String
            )
            order.append(name)
        }
        guard !entries.isEmpty else {
            throw DeckError.commandFailed("The kubeconfig has no usable cluster.")
        }
        return KubeConfigFile(path: path, currentContext: root["current-context"] as? String, contexts: order, entries: entries)
    }

    private static func named(_ value: Any?, key: String) -> [(name: String, value: [String: Any])] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return (name, item[key] as? [String: Any] ?? [:])
        }
    }

    private static func clean(_ base64: String) -> String {
        base64.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// base64 of a PEM file to the DER bytes of its first certificate.
    static func decodeCertificate(_ base64: String) -> Data? {
        guard let pem = Data(base64Encoded: clean(base64)) else { return nil }
        return PEM.firstBlock(in: pem, label: "CERTIFICATE")
    }

    // MARK: - File helpers

    /// Adds `current-context: <name>` to a file that has none.
    public static func setCurrentContextIfMissing(_ name: String, in file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        guard currentContext(inText: text) == nil else { return }
        try? withCurrentContext(name, text: text).write(to: file, atomically: true, encoding: .utf8)
    }

    /// Makes `name` the current context of a kubeconfig file (like `kubectl config use-context`).
    public static func setCurrentContext(_ name: String, in file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        try withCurrentContext(name, text: text).write(to: file, atomically: true, encoding: .utf8)
    }

    /// The top level `current-context` value, nil when missing or empty.
    static func currentContext(inText text: String) -> String? {
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("current-context:") {
            let value = line.dropFirst("current-context:".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty || value == "null" ? nil : value
        }
        return nil
    }

    /// The text with one top level `current-context: <name>` line.
    static func withCurrentContext(_ name: String, text: String) -> String {
        var lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("current-context:") }
        while lines.last == "" { lines.removeLast() }
        lines.append("current-context: \(name)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Only you can read the file (it holds the cluster admin key).
    public static func makePrivate(_ file: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)
    }
}

/// Small PEM reader.
enum PEM {
    /// DER bytes of the first block with this label ("CERTIFICATE", "RSA PRIVATE KEY").
    static func firstBlock(in pem: Data, label: String) -> Data? {
        blocks(in: pem).first(where: { $0.label == label })?.der
    }

    static func blocks(in pem: Data) -> [(label: String, der: Data)] {
        let text = String(decoding: pem, as: UTF8.self)
        var result: [(String, Data)] = []
        var label: String?
        var body = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
                label = String(line.dropFirst("-----BEGIN ".count).dropLast(5))
                body = ""
            } else if line.hasPrefix("-----END ") {
                if let current = label, let der = Data(base64Encoded: body) {
                    result.append((current, der))
                }
                label = nil
            } else if label != nil {
                body += line
            }
        }
        return result
    }
}

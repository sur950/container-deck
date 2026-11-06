import Foundation
import Network

/// Tiny DNS answers for proxy aliases outside `.localhost`, like `api.test` or
/// `*.gateway.test`. macOS sends queries for those names here because of a file in
/// /etc/resolver that the person adds once (admin). Every known name answers 127.0.0.1,
/// so the browser reaches the proxy. Pure message code is unit tested.
public enum AliasDNSMessage {
    /// The question in a query: name (lowercase, no trailing dot) and type.
    public struct Question: Equatable, Sendable {
        public var id: UInt16
        public var name: String
        public var type: UInt16
        public var recursionDesired: Bool
        /// Bytes of the question section, copied into the answer.
        var raw: Data
    }

    public static let typeA: UInt16 = 1
    public static let typeAAAA: UInt16 = 28

    public static func parseQuery(_ data: Data) -> Question? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }
        let id = UInt16(b[0]) << 8 | UInt16(b[1])
        let isResponse = b[2] & 0x80 != 0
        let qdcount = Int(b[4]) << 8 | Int(b[5])
        guard !isResponse, qdcount == 1 else { return nil }
        var offset = 12
        var labels: [String] = []
        while true {
            guard offset < b.count else { return nil }
            let length = Int(b[offset])
            offset += 1
            if length == 0 { break }
            guard length < 64, offset + length <= b.count else { return nil } // no compression in questions
            guard let label = String(bytes: b[offset..<(offset + length)], encoding: .ascii) else { return nil }
            labels.append(label.lowercased())
            offset += length
        }
        guard offset + 4 <= b.count else { return nil }
        let type = UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
        let raw = Data(b[12..<(offset + 4)])
        return Question(id: id, name: labels.joined(separator: "."), type: type, recursionDesired: b[2] & 0x01 != 0, raw: raw)
    }

    /// The reply: an A record with `address` for known names, an empty answer for
    /// other record types of known names, and "no such name" for the rest.
    public static func answer(_ question: Question, known: Bool, address: [UInt8] = [127, 0, 0, 1], ttl: UInt32 = 5) -> Data {
        var out = Data()
        out.append(UInt8(question.id >> 8)); out.append(UInt8(question.id & 0xFF))
        let rcode: UInt8 = known ? 0 : 3
        out.append(0x84 | (question.recursionDesired ? 0x01 : 0x00)) // response, authoritative
        out.append(rcode)
        let answers: UInt16 = (known && question.type == typeA) ? 1 : 0
        out.append(contentsOf: [0, 1, 0, UInt8(answers), 0, 0, 0, 0])
        out.append(question.raw)
        if answers == 1 {
            out.append(contentsOf: [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01])
            out.append(contentsOf: [UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF)])
            out.append(contentsOf: [0x00, 0x04])
            out.append(contentsOf: address)
        }
        return out
    }
}

/// UDP server for `AliasDNSMessage` on 127.0.0.1.
public final class AliasDNSResponder: @unchecked Sendable {
    public let port: UInt16
    private let queue = DispatchQueue(label: AppConfig.bundleID + ".aliasdns")
    private var listener: NWListener?
    private var patterns: [String] = []

    public init(port: UInt16 = DomainsConfig.dnsResponderPort) {
        self.port = port
    }

    public func update(patterns: [String]) {
        queue.async { self.patterns = patterns.map(HostName.normalize) }
    }

    public func start(patterns: [String]) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        queue.sync {
            self.listener?.cancel()
            self.patterns = patterns.map(HostName.normalize)
            self.listener = listener
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    public func knows(_ name: String) -> Bool {
        patterns.contains { HostName.matches(pattern: $0, host: name) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            if let data, let question = AliasDNSMessage.parseQuery(data) {
                let reply = AliasDNSMessage.answer(question, known: self.knows(question.name))
                connection.send(content: reply, completion: .contentProcessed { _ in })
            }
            self.receive(on: connection)
        }
    }
}

/// Files in /etc/resolver that send one name (and every name below it) to the responder.
/// Writing and removing them needs admin, so they run through `PrivilegedRunner`.
public enum AliasResolverFiles {
    public static let directory = "/etc/resolver"

    public static func path(for pattern: String) -> String {
        directory + "/" + HostName.resolverDomain(pattern)
    }

    public static func contents(port: UInt16 = DomainsConfig.dnsResponderPort) -> String {
        "\(DomainsConfig.resolverMarker)\nnameserver 127.0.0.1\nport \(port)\n"
    }

    /// Shell commands that add the file. Refuses to touch a file we did not write.
    /// One line scripts (no new lines), because they pass through AppleScript.
    public static func installCommands(for pattern: String, port: UInt16 = DomainsConfig.dnsResponderPort) -> [[String]] {
        let script = [
            "set -e",
            "mkdir -p \(directory)",
            "if [ -e \"$1\" ] && ! grep -qF \"$2\" \"$1\"; then echo \"$1 belongs to another app\" >&2; exit 3; fi",
            "printf '%s\\nnameserver 127.0.0.1\\nport %s\\n' \"$2\" \"$3\" > \"$1\"",
            "chmod 644 \"$1\"",
            "killall -HUP mDNSResponder || true",
        ].joined(separator: "; ")
        return [["/bin/sh", "-c", script, "deck-resolver", path(for: pattern), DomainsConfig.resolverMarker, String(port)]]
    }

    /// Shell commands that remove the file, only when we wrote it.
    public static func removeCommands(for pattern: String) -> [[String]] {
        let script = [
            "if [ -e \"$1\" ] && grep -qF \"$2\" \"$1\"; then rm -f \"$1\"; fi",
            "killall -HUP mDNSResponder || true",
        ].joined(separator: "; ")
        return [["/bin/sh", "-c", script, "deck-resolver", path(for: pattern), DomainsConfig.resolverMarker]]
    }

    /// True when our file for this pattern is in place.
    public static func isInstalled(_ pattern: String, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Bool {
        read(path(for: pattern))?.contains(DomainsConfig.resolverMarker) == true
    }
}

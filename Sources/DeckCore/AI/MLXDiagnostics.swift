import Foundation
import Darwin

// Reading what went wrong with an MLX server, checking a bind address before start, and
// checking whether the installed mlx-lm can load a model. All pure or file based, unit tested.

/// A model the MLX server could not load, read from its output.
public struct MLXModelLoadFailure: Sendable, Equatable {
    /// "qwen3_5_mtp", from "Model type X not supported" or "No module named 'mlx_lm.models.X'".
    public var modelType: String?
    /// mlx_lm.server keeps answering HTTP after this, but every chat fails.
    public var generationThreadDied: Bool
    /// The raw error lines, for a Details disclosure.
    public var details: [String]

    public init(modelType: String?, generationThreadDied: Bool, details: [String]) {
        self.modelType = modelType
        self.generationThreadDied = generationThreadDied
        self.details = details
    }
}

/// Plain words for a load failure, and whether updating mlx-lm can help.
public struct MLXFailureMessage: Sendable, Equatable {
    public var text: String
    /// True when a newer mlx-lm may load it (or the newest version is not known).
    public var offerUpdate: Bool
}

/// Parses mlx_lm.server output.
public enum MLXServerOutput {
    /// "Model type qwen3_5_mtp not supported." gives "qwen3_5_mtp". The ModuleNotFoundError form works too.
    public static func unsupportedModelType(_ line: String) -> String? {
        if let type = firstMatch(#"Model type ([A-Za-z0-9_\-.]+?) not supported"#, in: line) { return type }
        return firstMatch(#"No module named '?mlx_lm\.models\.([A-Za-z0-9_\-]+)'?"#, in: line)
    }

    /// A failed model load in the output, nil when there is none.
    public static func modelLoadFailure(_ lines: [String]) -> MLXModelLoadFailure? {
        var type: String?
        var died = false
        var start: Int?
        for (index, line) in lines.enumerated() {
            if line.contains("generation thread died") {
                died = true
                if start == nil { start = index }
            }
            if let found = unsupportedModelType(line) {
                if type == nil { type = found }
                if start == nil { start = index }
            }
        }
        guard died || type != nil, let start else { return nil }
        let details = lines[start...]
            .filter { !isAccessLine($0) }
            .prefix(120)
        return MLXModelLoadFailure(modelType: type, generationThreadDied: died, details: Array(details))
    }

    /// `OSError: [Errno 49] Can't assign requested address`: the --host address is not on this Mac.
    public static func isBindFailure(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("Errno 49") || $0.contains("Can't assign requested address") }
    }

    /// `127.0.0.1 - - [06/Nov/2026 21:49:11] "GET /v1/models HTTP/1.1" 200 -`.
    public static func isAccessLine(_ line: String) -> Bool {
        line.contains("\" 200 -") && (line.contains("\"GET ") || line.contains("\"POST "))
    }

    /// The message for a load failure. `installed` and `latest` are mlx-lm versions, nil when unknown.
    public static func message(_ failure: MLXModelLoadFailure, installed: String?, latest: String?) -> MLXFailureMessage {
        guard let type = failure.modelType else {
            return MLXFailureMessage(text: "The model could not load. Open Details to see why.", offerUpdate: false)
        }
        if let installed, let latest, PackageVersion.compare(installed, latest) != .orderedAscending {
            return MLXFailureMessage(text: "mlx-lm doesn't support model type \(type) yet. Pick another model.", offerUpdate: false)
        }
        return MLXFailureMessage(text: "This model needs a newer mlx-lm (model type \(type)).", offerUpdate: true)
    }

    /// A chat to an MLX server failed (often a 404 or "generation thread died"). When the server's
    /// own output shows a failed model load, that is the real reason.
    public static func chatFailure(errorText: String, serverLog: [String]) -> MLXModelLoadFailure? {
        guard var failure = modelLoadFailure(serverLog) else { return nil }
        let raw = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { failure.details.insert("Server answer: \(raw)", at: 0) }
        return failure
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Versions

/// Compares package versions like "0.32.2" and "0.33.0rc1". Numbers first, and a release beats
/// a pre-release of the same numbers.
public enum PackageVersion {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let x = index < left.numbers.count ? left.numbers[index] : 0
            let y = index < right.numbers.count ? right.numbers[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (left.preRelease, right.preRelease) {
        case (true, false): return .orderedAscending
        case (false, true): return .orderedDescending
        default: return .orderedSame
        }
    }

    private static func parts(_ version: String) -> (numbers: [Int], preRelease: Bool) {
        var numbers: [Int] = []
        var preRelease = false
        for piece in version.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "v" }).split(separator: ".") {
            let digits = piece.prefix(while: \.isNumber)
            guard let value = Int(digits) else { preRelease = true; break }
            numbers.append(value)
            if digits.count < piece.count { preRelease = true; break }
        }
        return (numbers, preRelease)
    }
}

/// The newest version of a package on PyPI, cached for a while.
public actor PyPILatestVersion {
    public static let shared = PyPILatestVersion()
    private let http: AIHTTPFetching
    private var cache: [String: (version: String, date: Date)] = [:]

    public init(http: AIHTTPFetching = AIHTTPClient()) {
        self.http = http
    }

    /// `https://pypi.org/pypi/<package>/json`, `info.version`. nil when offline.
    public func latest(_ package: String = AIConfig.mlxPackage, maxAge: TimeInterval = AIConfig.pypiCacheLifetime) async -> String? {
        if let hit = cache[package], Date().timeIntervalSince(hit.date) < maxAge { return hit.version }
        guard let url = URL(string: "https://pypi.org/pypi/\(package)/json"),
              let (data, status) = try? await http.get(url, timeout: 10), status == 200,
              let version = Self.parseLatest(data) else { return cache[package]?.version }
        cache[package] = (version, Date())
        return version
    }

    public static func parseLatest(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["info"] as? [String: Any], let version = info["version"] as? String, !version.isEmpty else { return nil }
        return version
    }
}

// MARK: - Bind address

/// Addresses on this Mac's network interfaces right now.
public enum NetworkInterfaces {
    /// Every IPv4 and IPv6 address assigned to an interface (getifaddrs).
    public static func assignedAddresses() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(cString: host)
            // "fe80::1%lo0": drop the zone.
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            result.insert(text)
        }
        return result
    }

    public static func isAssigned(_ address: String, in assigned: Set<String> = assignedAddresses()) -> Bool {
        assigned.contains(address)
    }
}

extension MLXBind {
    /// The bind to use now. A gateway address that is not on any interface (the container network
    /// is down) falls back to this Mac only, so the server never fails with Errno 49.
    public func resolved(assigned: Set<String>) -> (bind: MLXBind, fellBack: Bool) {
        switch self {
        case .mac: return (.mac, false)
        case .containers(let gateway):
            return assigned.contains(gateway) ? (self, false) : (.mac, true)
        }
    }
}

// MARK: - Model support

/// `model_type` and `architectures` from a model's config.json.
public struct MLXModelConfig: Sendable, Equatable {
    public var modelType: String
    public var architectures: [String]

    public init(modelType: String, architectures: [String] = []) {
        self.modelType = modelType
        self.architectures = architectures
    }

    public static func parse(_ data: Data) -> MLXModelConfig? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["model_type"] as? String, !type.isEmpty else { return nil }
        let architectures: [String]
        if let list = object["architectures"] as? [String] { architectures = list }
        else if let one = object["architectures"] as? String { architectures = [one] }
        else { architectures = [] }
        return MLXModelConfig(modelType: type, architectures: architectures)
    }

    /// config.json in a downloaded model folder.
    public static func load(modelFolder: String) -> MLXModelConfig? {
        let url = URL(fileURLWithPath: AIConfig.expand(modelFolder)).appendingPathComponent("config.json")
        return (try? Data(contentsOf: url)).flatMap(parse)
    }
}

/// Which model types the installed mlx-lm can load. Read from its files, no Python process:
/// one module per type in mlx_lm/models, plus the remapping tables in mlx_lm/utils.py.
public struct MLXModelSupport: Sendable, Equatable {
    public var version: String?
    public var moduleTypes: Set<String>
    /// MODEL_REMAPPING: "mistral" loads with "llama".
    public var remapping: [String: String]
    /// MODEL_ARCHITECTURE_REMAPPING: model type and architecture to module.
    public var architectureRemapping: [String: String]

    public init(version: String? = nil, moduleTypes: Set<String>, remapping: [String: String] = [:], architectureRemapping: [String: String] = [:]) {
        self.version = version
        self.moduleTypes = moduleTypes
        self.remapping = remapping
        self.architectureRemapping = architectureRemapping
    }

    /// The module mlx-lm would import for this config, following its own lookup order.
    public func module(for config: MLXModelConfig) -> String {
        for architecture in config.architectures {
            if let mapped = architectureRemapping[Self.architectureKey(config.modelType, architecture)] { return mapped }
        }
        return remapping[config.modelType] ?? config.modelType
    }

    public func supports(_ config: MLXModelConfig) -> Bool {
        moduleTypes.contains(module(for: config))
    }

    static func architectureKey(_ type: String, _ architecture: String) -> String { type + "|" + architecture }

    /// Reads the mlx_lm package folder (site-packages/mlx_lm).
    public static func load(package: URL, version: String? = nil) -> MLXModelSupport? {
        let models = package.appendingPathComponent("models", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: models.path) else { return nil }
        let types = Set(names.filter { $0.hasSuffix(".py") && $0 != "__init__.py" }.map { String($0.dropLast(3)) })
        guard !types.isEmpty else { return nil }
        let source = (try? String(contentsOf: package.appendingPathComponent("utils.py"), encoding: .utf8)) ?? ""
        let tables = parseRemapping(source)
        return MLXModelSupport(version: version, moduleTypes: types, remapping: tables.types, architectureRemapping: tables.architectures)
    }

    /// The `MODEL_REMAPPING = {...}` and `MODEL_ARCHITECTURE_REMAPPING = {...}` tables in utils.py.
    public static func parseRemapping(_ source: String) -> (types: [String: String], architectures: [String: String]) {
        var types: [String: String] = [:]
        var architectures: [String: String] = [:]
        if let body = block("MODEL_REMAPPING", in: source) {
            for match in matches(#""([^"]+)"\s*:\s*"([^"]+)""#, in: body) where match.count == 2 {
                types[match[0]] = match[1]
            }
        }
        if let body = block("MODEL_ARCHITECTURE_REMAPPING", in: source) {
            for match in matches(#"\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)\s*:\s*"([^"]+)""#, in: body) where match.count == 3 {
                architectures[architectureKey(match[0], match[1])] = match[2]
            }
        }
        return (types, architectures)
    }

    /// Our own install: <tools>/mlx-lm/lib/python3.x/site-packages/mlx_lm.
    public static func findPackage(paths: AIPaths) -> URL? {
        let lib = paths.tools.appendingPathComponent(AIConfig.mlxPackage, isDirectory: true).appendingPathComponent("lib", isDirectory: true)
        guard let pythons = try? FileManager.default.contentsOfDirectory(atPath: lib.path) else { return nil }
        for python in pythons.sorted().reversed() where python.hasPrefix("python") {
            let package = lib.appendingPathComponent(python).appendingPathComponent("site-packages/mlx_lm", isDirectory: true)
            if FileManager.default.fileExists(atPath: package.appendingPathComponent("models").path) { return package }
        }
        return nil
    }

    private static func block(_ name: String, in source: String) -> Substring? {
        guard let start = source.range(of: name + " = {") ?? source.range(of: name + "={"),
              let end = source[start.upperBound...].range(of: "\n}") else { return nil }
        return source[start.upperBound..<end.lowerBound]
    }

    private static func matches(_ pattern: String, in text: Substring) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = String(text)
        return regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: string).map { String(string[$0]) } }
        }
    }
}

// MARK: - Display names

public enum ModelDisplayName {
    /// Short name for a model id: the last path part of a local path, the repo name of
    /// "org/name", else the id as is ("qwen3:0.6b").
    public static func short(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("/") else { return trimmed }
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return last.isEmpty ? trimmed : last
    }
}

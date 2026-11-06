import Foundation

/// Talks to a Docker Engine API socket with /usr/bin/curl.
/// Works with Docker Desktop, OrbStack, Rancher (dockerd), Podman, Colima and Lima.
public struct DockerAPI: Sendable {
    public static let curl = "/usr/bin/curl"

    public let socketPath: String
    let runner: any CommandRunning

    public init(socketPath: String, runner: any CommandRunning) {
        self.socketPath = socketPath
        self.runner = runner
    }

    /// curl arguments for one GET. Tests use this to build mock keys.
    public static func arguments(socket: String, path: String, timeout: Int) -> [String] {
        [
            "--silent", "--show-error", "--fail",
            "--connect-timeout", "3",
            "--max-time", String(timeout),
            "--unix-socket", socket,
            "http://localhost" + path
        ]
    }

    /// curl arguments that save a response body to a file (no time limit).
    public static func downloadArguments(socket: String, path: String, to file: String) -> [String] {
        [
            "--silent", "--show-error", "--fail",
            "--connect-timeout", "5",
            "--unix-socket", socket,
            "--output", file,
            "http://localhost" + path
        ]
    }

    public func get(_ path: String, timeout: Int = 10) async throws -> String {
        let result = try await runner.run(Self.curl, Self.arguments(socket: socketPath, path: path, timeout: timeout))
        guard result.succeeded else {
            throw DeckError.commandFailed(result.failureMessage)
        }
        return result.stdout
    }

    public func ping() async -> Bool {
        guard let body = try? await get("/_ping", timeout: 3) else { return false }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "OK"
    }

    public func version() async throws -> DockerVersion {
        try DockerAPIParser.parseVersion(await get("/version", timeout: 5))
    }

    public func info() async throws -> DockerInfo {
        try DockerAPIParser.parseInfo(await get("/info", timeout: 8))
    }

    public func images() async throws -> [DockerImageEntry] {
        try DockerAPIParser.parseImages(await get("/images/json", timeout: 30))
    }

    public func inspectImage(_ id: String) async throws -> DockerImageInspect {
        let path = "/images/" + DockerAPIParser.escapePath(id) + "/json"
        return try DockerAPIParser.parseImageInspect(await get(path, timeout: 10))
    }

    /// Streams `docker save` style output for one reference into a file.
    public func export(_ reference: String, to file: URL) async throws {
        let path = "/images/get?names=" + DockerAPIParser.escapeQuery(reference)
        let args = Self.downloadArguments(socket: socketPath, path: path, to: file.path)
        let result = try await runner.run(Self.curl, args)
        guard result.succeeded else {
            throw DeckError.commandFailed("Could not export \(reference). \(result.failureMessage)")
        }
    }
}

// MARK: - API models

public struct DockerVersion: Sendable, Equatable {
    public var version: String
    public var apiVersion: String
    public var platformName: String
    public var components: [String]

    public init(version: String = "", apiVersion: String = "", platformName: String = "", components: [String] = []) {
        self.version = version
        self.apiVersion = apiVersion
        self.platformName = platformName
        self.components = components
    }

    public var isPodman: Bool {
        platformName.lowercased().contains("podman") || components.contains { $0.lowercased().contains("podman") }
    }
}

public struct DockerInfo: Sendable, Equatable {
    /// Unique daemon id. Two sockets with the same id are one engine.
    public var id: String
    public var name: String
    public var operatingSystem: String
    public var serverVersion: String
    public var images: Int?

    public init(id: String = "", name: String = "", operatingSystem: String = "", serverVersion: String = "", images: Int? = nil) {
        self.id = id
        self.name = name
        self.operatingSystem = operatingSystem
        self.serverVersion = serverVersion
        self.images = images
    }
}

public struct DockerImageEntry: Sendable, Equatable {
    public var id: String
    public var repoTags: [String]
    public var repoDigests: [String]
    public var created: Date?
    public var size: UInt64

    public init(id: String, repoTags: [String] = [], repoDigests: [String] = [], created: Date? = nil, size: UInt64 = 0) {
        self.id = id
        self.repoTags = repoTags
        self.repoDigests = repoDigests
        self.created = created
        self.size = size
    }
}

public struct DockerImageInspect: Sendable, Equatable {
    public var architecture: String?
    public var os: String?
    public var variant: String?

    public init(architecture: String? = nil, os: String? = nil, variant: String? = nil) {
        self.architecture = architecture
        self.os = os
        self.variant = variant
    }
}

// MARK: - Parsing (pure, tested)

public enum DockerAPIParser {
    private struct VersionJSON: Decodable {
        struct PlatformJSON: Decodable { var Name: String? }
        struct ComponentJSON: Decodable { var Name: String? }
        var Version: String?
        var ApiVersion: String?
        var Platform: PlatformJSON?
        var Components: [ComponentJSON]?
    }

    private struct InfoJSON: Decodable {
        var ID: String?
        var Name: String?
        var OperatingSystem: String?
        var ServerVersion: String?
        var Images: Int?
    }

    private struct ImageJSON: Decodable {
        var Id: String
        var RepoTags: [String]?
        var RepoDigests: [String]?
        var Created: Double?
        var Size: Double?
    }

    private struct InspectJSON: Decodable {
        var Architecture: String?
        var Os: String?
        var Variant: String?
    }

    public static func parseVersion(_ text: String) throws -> DockerVersion {
        guard let json = try? JSONDecoder().decode(VersionJSON.self, from: Data(text.utf8)) else {
            throw DeckError.parse("the engine version")
        }
        return DockerVersion(
            version: json.Version ?? "",
            apiVersion: json.ApiVersion ?? "",
            platformName: json.Platform?.Name ?? "",
            components: (json.Components ?? []).compactMap(\.Name)
        )
    }

    public static func parseInfo(_ text: String) throws -> DockerInfo {
        guard let json = try? JSONDecoder().decode(InfoJSON.self, from: Data(text.utf8)) else {
            throw DeckError.parse("the engine info")
        }
        return DockerInfo(
            id: json.ID ?? "",
            name: json.Name ?? "",
            operatingSystem: json.OperatingSystem ?? "",
            serverVersion: json.ServerVersion ?? "",
            images: json.Images
        )
    }

    public static func parseImages(_ text: String) throws -> [DockerImageEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return [] }
        guard let list = try? JSONDecoder().decode([ImageJSON].self, from: Data(trimmed.utf8)) else {
            throw DeckError.parse("the engine image list")
        }
        return list.map { item in
            DockerImageEntry(
                id: item.Id,
                repoTags: (item.RepoTags ?? []).filter { !ImageReference.isUntagged($0) },
                repoDigests: (item.RepoDigests ?? []).filter { !$0.contains("<none>") },
                created: item.Created.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                size: item.Size.map { UInt64(max(0, $0)) } ?? 0
            )
        }
    }

    public static func parseImageInspect(_ text: String) throws -> DockerImageInspect {
        guard let json = try? JSONDecoder().decode(InspectJSON.self, from: Data(text.utf8)) else {
            throw DeckError.parse("the engine image details")
        }
        return DockerImageInspect(architecture: json.Architecture, os: json.Os, variant: json.Variant)
    }

    /// Escapes a value for use in a URL query.
    public static func escapeQuery(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Escapes an image name or id for use in a URL path. Slashes stay.
    public static func escapePath(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/:@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Turns sizes like "8.5MB", "1.2 GiB" or "512kB" into bytes (nerdctl output).
    public static func parseSize(_ text: String) -> UInt64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var number = ""
        var unit = ""
        for char in trimmed {
            if char.isNumber || char == "." {
                if unit.isEmpty { number.append(char) }
            } else if char != " " {
                unit.append(char)
            }
        }
        guard let value = Double(number) else { return 0 }
        let multipliers: [String: Double] = [
            "B": 1,
            "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000, "TB": 1_000_000_000_000,
            "KIB": 1_024, "MIB": 1_048_576, "GIB": 1_073_741_824, "TIB": 1_099_511_627_776
        ]
        let factor = multipliers[unit.uppercased()] ?? 1
        return UInt64(max(0, value * factor))
    }
}

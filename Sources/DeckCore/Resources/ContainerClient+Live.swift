import Foundation

// Cheap list calls for polling, commit, and the streamed stats table.

public extension ContainerClient {
    // MARK: Cheap lists (no inspect)

    /// `volume list` only. `usedBy` stays empty. For counts and polling.
    func listVolumeSummaries() async throws -> [VolumeSummary] {
        if let router { return try await router.listVolumeSummaries() }
        let result = try await run(["volume", "list", "--format", "json"])
        return try ContainerOutputParser.volumes(result.stdout)
    }

    /// `network list` only. `attachedContainers` stays empty. For counts and polling.
    func listNetworkSummaries() async throws -> [NetworkSummary] {
        if let router { return try await router.listNetworkSummaries() }
        let result = try await run(["network", "list", "--format", "json"])
        return try ContainerOutputParser.networks(result.stdout)
    }

    func countVolumes() async throws -> Int {
        try await listVolumeSummaries().count
    }

    func countNetworks() async throws -> Int {
        try await listNetworkSummaries().count
    }

    // MARK: Commit

    /// `container commit <id> <reference>` (container 1.6.0 and later).
    func commitArguments(_ id: String, reference: String) -> [String] {
        ["commit", id, reference.trimmingCharacters(in: .whitespaces)]
    }

    /// Saves the container's file system as a new image.
    func commitContainer(_ id: String, reference: String) async throws {
        if let problem = ImageReferenceCheck.problem(reference) {
            throw DeckError.commandFailed(problem)
        }
        try await run(commitArguments(id, reference: reference))
    }

    // MARK: Streamed stats

    /// `container stats <ids>` in its streaming table mode. One process for as long as it runs.
    func statsStreamArguments(_ ids: [String]) -> [String] {
        ["stats"] + ids
    }

    /// Raw lines of the streaming stats table. Cancel the task to stop the process.
    func statsStream(_ ids: [String]) -> AsyncThrowingStream<String, Error> {
        stream(statsStreamArguments(ids))
    }
}

/// Checks an image name typed by a person ("name", "name:tag", "registry/name:tag").
public enum ImageReferenceCheck {
    /// The commit command needs this version or newer.
    public static let commitMinimumVersion = SemanticVersion(1, 6, 0)

    /// A short reason the reference cannot work, or nil when it looks fine.
    public static func problem(_ reference: String) -> String? {
        let text = reference.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "Enter an image name." }
        if text.contains(where: { $0.isWhitespace }) { return "Image names cannot have spaces." }
        var name = text
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        var tag: String?
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            tag = String(name[name.index(after: colon)...])
            name = String(name[..<colon])
        }
        if name.isEmpty { return "Enter an image name before the tag." }
        if let tag {
            if tag.isEmpty { return "Enter a tag after the colon, or leave the colon out." }
            if tag.count > 128 { return "Tags can be at most 128 characters." }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
            if tag.unicodeScalars.contains(where: { !allowed.contains($0) }) || tag.hasPrefix(".") || tag.hasPrefix("-") {
                return "Tags use letters, numbers, dots, dashes and underscores."
            }
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        // The first part may be a registry host (has a dot, a colon port or is localhost). It may use capitals.
        let pathParts = parts.count > 1 && (parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost") ? parts.dropFirst() : parts[...]
        let allowedPath = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        for part in pathParts {
            if part.isEmpty { return "Image names cannot have empty parts between slashes." }
            if part.unicodeScalars.contains(where: { !allowedPath.contains($0) }) {
                return "Image names use lowercase letters, numbers, dots, dashes and underscores."
            }
        }
        return nil
    }

    /// "name:latest" when no tag was typed. Leaves digests alone.
    public static func withDefaultTag(_ reference: String) -> String {
        let text = reference.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("@") else { return text }
        let last = text.split(separator: "/").last.map(String.init) ?? text
        return last.contains(":") ? text : text + ":latest"
    }
}

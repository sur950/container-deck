import Foundation

/// Which images are in use, counting every kind of container that holds one: plain
/// containers, cluster nodes and machines.
///
/// Container 1.7 hides cluster nodes from `container list` (`ContainerPlatformFeatures.listHidesClusterNodes`),
/// and both releases hide machines. A screen or prune that only looks at the container list
/// would then think `kindest/node` is unused and delete it under a live cluster, which a new
/// worker, a Recreate or a repair needs again. And Apple's `container image prune` (without
/// `--all`) removes every untagged image, in use or not, and the node image is untagged
/// (`kindest/node@sha256:...`). So the app prunes images itself with these rules.
public struct ImageUser: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case container, clusterNode, machine }
    public var name: String
    public var image: String
    public var kind: Kind

    public init(name: String, image: String, kind: Kind) {
        self.name = name
        self.image = image
        self.kind = kind
    }
}

public enum ImageUsage {
    /// "nginx" becomes "docker.io/library/nginx:latest". A digest stays.
    public static func normalize(_ raw: String) -> String {
        var ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return "" }
        var digest = ""
        if let at = ref.firstIndex(of: "@") {
            digest = String(ref[at...])
            ref = String(ref[..<at])
        }
        var parts = ref.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return (ref + digest).lowercased() }
        let hasDomain = parts.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
        if !hasDomain { parts.insert("docker.io", at: 0) }
        if parts[0] == "index.docker.io" || parts[0] == "registry-1.docker.io" { parts[0] = "docker.io" }
        if parts[0] == "docker.io" && parts.count == 2 { parts.insert("library", at: 1) }
        var name = parts.joined(separator: "/")
        if digest.isEmpty && !parts[parts.count - 1].contains(":") { name += ":latest" }
        return (name + digest).lowercased()
    }

    /// The `sha256:<hex>` part of a reference, if it has one.
    static func digest(of reference: String) -> String? {
        guard let at = reference.firstIndex(of: "@") else {
            return reference.hasPrefix("sha256:") ? reference.lowercased() : nil
        }
        return String(reference[reference.index(after: at)...]).lowercased()
    }

    /// True when `user` (a container's image reference) is this image: same reference in
    /// short or full form, or the same digest (cluster nodes reference `kindest/node@sha256:...`).
    public static func uses(_ user: String, image: ImageSummary) -> Bool {
        let left = normalize(user)
        if !left.isEmpty && left == normalize(image.reference) { return true }
        if let digest = digest(of: user), digest == image.digest.lowercased() || digest == self.digest(of: image.reference) {
            return true
        }
        return false
    }

    /// Names of the users of `image`.
    public static func users(of image: ImageSummary, in users: [ImageUser]) -> [String] {
        users.filter { uses($0.image, image: image) }.map(\.name)
    }

    /// No tag, like Apple's prune (`kindest/node@sha256:...`, `sha256:...`, `<none>`).
    public static func isUntagged(_ reference: String) -> Bool {
        var ref = reference.trimmingCharacters(in: .whitespaces)
        if ref.isEmpty || ref.hasPrefix("sha256:") || ref.contains("<none>") { return true }
        if let at = ref.firstIndex(of: "@") { ref = String(ref[..<at]) }
        let last = ref.split(separator: "/").last.map(String.init) ?? ref
        return !last.contains(":")
    }

    /// What a prune removes: untagged images (or every image with `all`) that nothing uses.
    public static func prunable(_ images: [ImageSummary], users: [ImageUser], all: Bool) -> [ImageSummary] {
        images.filter { image in
            (all || isUntagged(image.reference)) && !users.contains { uses($0.image, image: image) }
        }
    }
}

public extension ContainerClient {
    /// Every container that holds an image: the container list, plus cluster nodes where
    /// the list hides them (1.7), plus machines. Throws when cluster nodes cannot be read
    /// on a release that hides them, so a prune never runs blind.
    func imageUsers() async throws -> [ImageUser] {
        var users = try await listContainers(all: true).map {
            ImageUser(name: $0.id, image: $0.image, kind: KubeClusterParser.isClusterNode($0) ? .clusterNode : .container)
        }
        if await platformFeatures().listHidesClusterNodes {
            let nodes: [ContainerSummary]
            do {
                nodes = try await listClusterNodes()
            } catch {
                throw DeckError.commandFailed("Could not check which images the Kubernetes nodes use, so no image was removed.\n\nDetails: \(error.localizedDescription)")
            }
            let known = Set(users.map(\.name))
            users += nodes.filter { !known.contains($0.id) }.map { ImageUser(name: $0.id, image: $0.image, kind: .clusterNode) }
        }
        // Releases without machines fail here, which is fine.
        if let machines = try? await listMachines() {
            users += machines.filter { !$0.image.isEmpty }.map { ImageUser(name: $0.name, image: $0.image, kind: .machine) }
        }
        return users
    }

    /// Removes untagged images, or with `all` every image, that no container, cluster node or
    /// machine uses. Done here rather than with `container image prune`, which removes the
    /// untagged `kindest/node` image under a live cluster. Returns the removed references.
    @discardableResult
    func pruneImages(all: Bool = false) async throws -> [String] {
        let images = try await listImages()
        let users = try await imageUsers()
        var removed: [String] = []
        var firstError: Error?
        for image in ImageUsage.prunable(images, users: users, all: all) {
            do {
                try await deleteImage(image.reference)
                removed.append(image.reference)
            } catch {
                firstError = firstError ?? error
            }
        }
        if removed.isEmpty, let firstError { throw firstError }
        return removed
    }
}

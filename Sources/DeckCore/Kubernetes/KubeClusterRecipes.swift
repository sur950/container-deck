import Foundation

/// Remembers how each cluster was made, so Recreate can make it the same way
/// (the CNI choice and node image are not visible on the nodes).
public struct KubeClusterRecipes: Sendable {
    public let file: URL

    public init(file: URL = KubernetesConfig.recipesFile) {
        self.file = file
    }

    public func all() -> [String: KubeClusterOptions] {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: KubeClusterOptions].self, from: data) else { return [:] }
        return decoded
    }

    public func recipe(for name: String) -> KubeClusterOptions? {
        all()[name]
    }

    public func save(_ options: KubeClusterOptions) {
        var list = all()
        list[options.name] = options
        write(list)
    }

    public func remove(_ name: String) {
        var list = all()
        guard list.removeValue(forKey: name) != nil else { return }
        write(list)
    }

    private func write(_ list: [String: KubeClusterOptions]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(list) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

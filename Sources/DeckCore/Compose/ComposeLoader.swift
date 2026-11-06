import Foundation

// Loads a project made of one or more compose files: `-f` files and the
// override file merge in order, `include` adds other projects, `extends` builds
// a service on top of another one. The result is one YAML tree for the reader.

/// The files of one project. Every line in the merged tree also says which file
/// it came from: line `n` of source `i` is stored as `i * stride + n`. Source 0 is
/// the main file, so a project of one file keeps its plain line numbers.
struct ComposeSources {
    static let stride = 1_000_000

    struct Source: Equatable {
        var file: URL
        /// Folder relative paths in this file resolve against.
        var baseDirectory: URL
    }

    private(set) var list: [Source] = []

    /// Index of the source, added when new.
    mutating func add(_ file: URL, baseDirectory: URL) -> Int {
        let source = Source(file: file.standardizedFileURL, baseDirectory: baseDirectory.standardizedFileURL)
        if let index = list.firstIndex(of: source) { return index }
        list.append(source)
        return list.count - 1
    }

    func offset(_ index: Int) -> Int { index * Self.stride }

    /// File and plain line of a stored line. No file for line 0.
    func decode(_ line: Int) -> (file: URL?, line: Int) {
        guard line > 0 else { return (nil, 0) }
        let index = line / Self.stride
        let plain = line % Self.stride
        guard index < list.count else { return (nil, plain) }
        return (list[index].file, plain)
    }

    func source(forLine line: Int) -> Source? {
        let index = line > 0 ? line / Self.stride : 0
        return index < list.count ? list[index] : list.first
    }
}

/// A YAML error in a file other than the main one, so the app can point at it.
public struct ComposeFileYAMLError: LocalizedError, Equatable {
    public var file: URL
    public var message: String

    public init(file: URL, message: String) {
        self.file = file
        self.message = message
    }

    public var errorDescription: String? { "\(file.lastPathComponent) is not valid YAML. \(message)" }
}

struct ComposeLoader {
    let readFile: (URL) -> String?
    let processEnvironment: [String: String]

    private(set) var sources = ComposeSources()
    /// Problems found while loading. Lines are stored lines (see ComposeSources).
    private(set) var problems: [ComposeProblem] = []
    /// Files read through `include` and `extends`, in the order they were read.
    private(set) var includedFiles: [URL] = []

    private var includeStack: [String] = []
    private var extendsTrees: [String: (root: ComposeNode, source: Int)?] = [:]

    init(readFile: @escaping (URL) -> String?, processEnvironment: [String: String]) {
        self.readFile = readFile
        self.processEnvironment = processEnvironment
    }

    private mutating func problem(_ kind: ComposeProblem.Kind, _ service: String?, _ key: String, _ line: Int, _ message: String) {
        problems.append(ComposeProblem(kind: kind, service: service, key: key, line: line, message: message))
    }

    // MARK: Files

    /// Reads `files` in order and merges them into one tree, with includes and
    /// extends applied and `!reset` values removed. The first file must be a map.
    mutating func load(_ files: [URL], projectDirectory: URL, environment: [String: String]) throws -> ComposeNode {
        var merged: ComposeNode?
        for (position, file) in files.enumerated() {
            let isMain = sources.list.isEmpty
            let index = sources.add(file, baseDirectory: projectDirectory)
            guard let text = readFile(file) else {
                throw ComposeError.failed("Could not read \(file.lastPathComponent).")
            }
            guard var tree = try parseTree(text, file: file, source: index, environment: environment, isMain: isMain) else {
                if position == 0 { throw ComposeError.invalidYAML("The file is empty or is not a map of keys.") }
                continue
            }
            tree = applyIncludes(tree)
            merged = merged.map { ComposeMerge.merge($0, tree) } ?? tree
        }
        guard let merged else { throw ComposeError.invalidYAML("The file is empty or is not a map of keys.") }
        return applyExtends(merged, environment: environment).cleaned()
    }

    /// One file as a tree. nil for an empty file.
    private mutating func parseTree(_ text: String, file: URL, source: Int, environment: [String: String], isMain: Bool) throws -> ComposeNode? {
        let parsed: (node: ComposeNode?, errors: [(line: Int, message: String)])
        do {
            parsed = try ComposeNodeBuilder.parse(text, interpolator: ComposeInterpolator(values: environment), lineOffset: sources.offset(source))
        } catch ComposeError.invalidYAML(let message) where !isMain {
            throw ComposeFileYAMLError(file: file, message: message)
        }
        for error in parsed.errors {
            problem(.invalid, nil, "variables", error.line, error.message)
        }
        guard let root = parsed.node, !root.isNull else { return nil }
        guard root.entries != nil else {
            if isMain { throw ComposeError.invalidYAML("The file is empty or is not a map of keys.") }
            throw ComposeFileYAMLError(file: file, message: "The file is not a map of keys.")
        }
        return root
    }

    private func resolve(_ raw: String, base: URL) -> URL {
        if raw.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath).standardizedFileURL
        }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        return base.appendingPathComponent(raw).standardizedFileURL
    }

    private func baseDirectory(forLine line: Int) -> URL {
        sources.source(forLine: line)?.baseDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // MARK: include

    /// Loads each `include` entry as its own project (own folder, own `.env`) and
    /// adds its services, networks, volumes, secrets and configs. A name that is
    /// already defined differently here is a problem, and this file's one is kept.
    private mutating func applyIncludes(_ tree: ComposeNode) -> ComposeNode {
        guard let includeEntry = tree.entry("include"), var entries = tree.entries else { return tree }
        entries.removeAll { $0.key == "include" }
        var result = ComposeNode(value: .map(entries), line: tree.line)

        let items: [ComposeNode]
        if let list = includeEntry.node.items {
            items = list
        } else if includeEntry.node.isNull {
            items = []
        } else {
            problem(.invalid, nil, "include", includeEntry.line, "include must be a list of files.")
            return result
        }
        for item in items {
            let base = baseDirectory(forLine: item.line == 0 ? includeEntry.line : item.line)
            let line = item.line == 0 ? includeEntry.line : item.line
            let rawPaths: [String] = item.text.map { [$0] } ?? item["path"]?.stringList ?? []
            guard !rawPaths.isEmpty else {
                problem(.invalid, nil, "include", line, "Each include entry needs a path.")
                continue
            }
            for field in item.entries ?? [] where !["path", "project_directory", "env_file"].contains(field.key) && !field.key.hasPrefix("x-") {
                problem(.notBuilt, nil, "include.\(field.key)", field.line, "include option \(field.key) is not built yet.")
            }
            let files = rawPaths.map { resolve($0, base: base) }
            if let missing = files.first(where: { readFile($0) == nil }) {
                problem(.invalid, nil, "include", line, "The included file \(missing.path) was not found.")
                continue
            }
            let key = files.map(\.path).joined(separator: ",")
            if includeStack.contains(key) {
                problem(.invalid, nil, "include", line, "\(files[0].lastPathComponent) includes itself through a loop.")
                continue
            }
            let projectDirectory = item["project_directory"]?.text.map { resolve($0, base: base) } ?? files[0].deletingLastPathComponent()
            let envFiles = item["env_file"]?.stringList?.map { resolve($0, base: base) }
                ?? [projectDirectory.appendingPathComponent(".env")]
            var dotEnv: [String: String] = [:]
            for envFile in envFiles {
                if let text = readFile(envFile) {
                    dotEnv.merge(DotEnvParser.dictionary(text, lookup: processEnvironment)) { _, new in new }
                } else if item["env_file"] != nil {
                    problem(.invalid, nil, "include.env_file", line, "The env file \(envFile.path) was not found.")
                }
            }
            let environment = ComposeInterpolator.environment(dotEnv: dotEnv, process: processEnvironment)

            includeStack.append(key)
            defer { includeStack.removeLast() }
            let imported: ComposeNode
            do {
                imported = try load(files, projectDirectory: projectDirectory, environment: environment)
            } catch {
                problem(.invalid, nil, "include", line, "Could not include \(files[0].lastPathComponent). \(error.localizedDescription)")
                continue
            }
            for file in files where !includedFiles.contains(file) { includedFiles.append(file) }
            result = importResources(imported, into: result, from: files[0], line: line)
        }
        return result
    }

    private mutating func importResources(_ imported: ComposeNode, into tree: ComposeNode, from file: URL, line: Int) -> ComposeNode {
        guard var entries = tree.entries else { return tree }
        let kinds = ["services": "Service", "networks": "Network", "volumes": "Volume", "secrets": "Secret", "configs": "Config"]
        for section in ["services", "networks", "volumes", "secrets", "configs"] {
            guard let incoming = imported[section]?.entries, !incoming.isEmpty else { continue }
            guard let index = entries.firstIndex(where: { $0.key == section }) else {
                entries.append(ComposeEntry(key: section, line: line, node: ComposeNode(value: .map(incoming), line: line)))
                continue
            }
            var existing = entries[index].node.entries ?? []
            for item in incoming {
                if let current = existing.first(where: { $0.key == item.key }) {
                    if !current.node.sameValue(as: item.node) {
                        problem(.invalid, section == "services" ? item.key : nil, "\(section).\(item.key)", current.line,
                                "\(kinds[section] ?? "Item") \(item.key) is also defined in the included file \(file.lastPathComponent). Remove one of them.")
                    }
                    continue
                }
                existing.append(item)
            }
            entries[index].node = ComposeNode(value: .map(existing), line: entries[index].node.line)
        }
        return ComposeNode(value: .map(entries), line: tree.line)
    }

    // MARK: extends

    private mutating func applyExtends(_ root: ComposeNode, environment: [String: String]) -> ComposeNode {
        guard var entries = root.entries, let servicesIndex = entries.firstIndex(where: { $0.key == "services" }),
              let services = entries[servicesIndex].node.entries,
              services.contains(where: { $0.node.entry("extends") != nil }) else { return root }
        var resolved: [ComposeEntry] = []
        for service in services {
            var entry = service
            entry.node = resolveExtends(service.key, in: services, fileKey: "", environment: environment, stack: [])
            resolved.append(entry)
        }
        entries[servicesIndex].node = ComposeNode(value: .map(resolved), line: entries[servicesIndex].node.line)
        return ComposeNode(value: .map(entries), line: root.line)
    }

    /// The service with its `extends` chain merged in. Problems keep the service as written.
    private mutating func resolveExtends(_ name: String, in services: [ComposeEntry], fileKey: String, environment: [String: String], stack: [String]) -> ComposeNode {
        guard let service = services.first(where: { $0.key == name }) else { return .null(line: 0) }
        guard let extendsEntry = service.node.entry("extends"), var fields = service.node.entries else { return service.node }
        fields.removeAll { $0.key == "extends" }
        let own = ComposeNode(value: .map(fields), line: service.node.line)
        let path = "services.\(name).extends"
        let line = extendsEntry.line

        let target: String?
        let otherFile: String?
        if let text = extendsEntry.node.text {
            target = text
            otherFile = nil
        } else {
            target = extendsEntry.node["service"]?.text
            otherFile = extendsEntry.node["file"]?.text
        }
        guard let target, !target.isEmpty else {
            problem(.invalid, name, path, line, "extends needs the name of a service.")
            return own
        }

        var baseServices = services
        var baseFileKey = fileKey
        var where_ = "this file"
        if let otherFile {
            let url = resolve(otherFile, base: baseDirectory(forLine: line))
            guard let loaded = extendsTree(url, environment: environment), let list = loaded.root["services"]?.entries else {
                problem(.invalid, name, path, line, "The file \(otherFile) for extends was not found or has no services.")
                return own
            }
            baseServices = list
            baseFileKey = url.path
            where_ = url.lastPathComponent
        }
        let key = "\(baseFileKey)#\(target)"
        if stack.contains(key) || (baseFileKey == fileKey && target == name) {
            problem(.invalid, name, path, line, "\(name) extends itself through a loop.")
            return own
        }
        guard baseServices.contains(where: { $0.key == target }) else {
            problem(.invalid, name, path, line, "extends: service \(target) was not found in \(where_).")
            return own
        }
        let base = resolveExtends(target, in: baseServices, fileKey: baseFileKey, environment: environment, stack: stack + ["\(fileKey)#\(name)"])
        return ComposeMerge.merge(base.cleaned(), own, path: ["services", name])
    }

    /// Another compose file read for `extends`, once. Paths in it resolve against its own folder.
    private mutating func extendsTree(_ url: URL, environment: [String: String]) -> (root: ComposeNode, source: Int)? {
        if let cached = extendsTrees[url.path] { return cached }
        var result: (root: ComposeNode, source: Int)?
        if let text = readFile(url) {
            let index = sources.add(url, baseDirectory: url.deletingLastPathComponent())
            if let tree = try? parseTree(text, file: url, source: index, environment: environment, isMain: false) {
                result = (tree, index)
                if !includedFiles.contains(url.standardizedFileURL) { includedFiles.append(url.standardizedFileURL) }
            }
        }
        extendsTrees[url.path] = result
        return result
    }
}

import Foundation

// Merges compose YAML trees the way Docker Compose does when it reads several
// files (`-f a.yaml -f b.yaml`, `compose.override.yaml`, `extends`). Follows the
// Compose Specification merge rules and the special cases of compose-go:
// https://github.com/compose-spec/compose-spec/blob/main/13-merge.md

enum ComposeMerge {

    /// How one path merges.
    private enum Rule {
        /// Mappings merge by key, sequences append without exact duplicates, scalars are replaced.
        case standard
        /// The later value wins (`command`, `entrypoint`, `healthcheck.test`).
        case replace
        /// `KEY=value` lists and `KEY: value` maps merge by key.
        case keyValue
        /// Sequences append, then keep one entry per key. The last entry wins at the
        /// place of the first.
        case unique(Index)
        /// Lists of names and maps by name both merge as maps.
        case asMapping(defaults: [(String, String)])
        /// `build: ./dir` reads as `build: {context: ./dir}`.
        case build
        /// `extra_hosts`, by host name.
        case hosts
        /// `ulimits.<name>`: two maps merge, otherwise the later value wins.
        case ulimit
        /// `networks.<name>.ipam.config`, by subnet.
        case ipamConfig
    }

    private enum Index {
        /// The text before `=`, or the whole text.
        case keyValue
        case text
        case port
        case volumeTarget
        case deviceTarget
        case envFilePath
        case mount(defaultPath: String)
    }

    /// Merges `override` on top of `base`. `path` is the key path of both nodes.
    static func merge(_ base: ComposeNode, _ override: ComposeNode, path: [String] = []) -> ComposeNode {
        if override.tag == .reset { return override }
        if override.tag == .override {
            var replaced = override
            replaced.tag = nil
            return replaced
        }
        switch rule(for: path) {
        case .replace:
            return override
        case .keyValue:
            return mergeKeyValues(base, override)
        case .unique(let index):
            guard let left = sequence(base), let right = sequence(override) else { return override }
            return ComposeNode(value: .list(unique(left + right, index: index)), line: base.line)
        case .asMapping(let defaults):
            guard let left = mapping(base, defaults: defaults), let right = mapping(override, defaults: defaults) else { return override }
            return mergeMaps(left, right, path: path)
        case .build:
            return mergeMaps(buildMap(base), buildMap(override), path: path)
        case .hosts:
            return mergeHosts(base, override)
        case .ulimit:
            if base.entries != nil, override.entries != nil { return mergeMaps(base, override, path: path) }
            return override
        case .ipamConfig:
            guard let left = base.items, let right = override.items else { return override }
            return ComposeNode(value: .list(mergeBySubnet(left, right)), line: base.line)
        case .standard:
            break
        }
        switch (base.value, override.value) {
        case (.map, .map):
            return mergeMaps(base, override, path: path)
        case let (.list(left), .list(right)):
            return ComposeNode(value: .list(appendWithoutDuplicates(left, right)), line: base.line)
        default:
            // A bare key (null) keeps the earlier value, like compose-go. Use !reset to clear it.
            return override.isNull ? base : override
        }
    }

    // MARK: Rules by path

    private static let keyValuePaths: Set<String> = [
        "services.*.annotations", "services.*.build.args", "services.*.build.additional_contexts",
        "services.*.build.labels", "services.*.environment", "services.*.labels", "services.*.deploy.labels",
        "services.*.sysctls", "services.*.volumes.*.volume.labels",
        "networks.*.labels", "volumes.*.labels", "secrets.*.labels", "configs.*.labels"
    ]

    private static func rule(for path: [String]) -> Rule {
        let pattern = Self.pattern(path)
        if keyValuePaths.contains(pattern) { return .keyValue }
        switch pattern {
        case "services.*.command", "services.*.entrypoint", "services.*.healthcheck.test":
            return .replace
        case "services.*.depends_on":
            return .asMapping(defaults: [("condition", "service_started"), ("required", "true")])
        case "services.*.networks":
            return .asMapping(defaults: [])
        case "services.*.build":
            return .build
        case "services.*.extra_hosts":
            return .hosts
        case "services.*.ulimits.*":
            return .ulimit
        case "networks.*.ipam.config":
            return .ipamConfig
        case "services.*.ports":
            return .unique(.port)
        case "services.*.volumes":
            return .unique(.volumeTarget)
        case "services.*.devices":
            return .unique(.deviceTarget)
        case "services.*.env_file", "services.*.label_file":
            return .unique(.envFilePath)
        case "services.*.secrets":
            return .unique(.mount(defaultPath: "/run/secrets"))
        case "services.*.configs":
            return .unique(.mount(defaultPath: ""))
        case "services.*.expose", "services.*.external_links":
            return .unique(.text)
        case "services.*.dns", "services.*.dns_opt", "services.*.dns_search", "services.*.tmpfs",
             "services.*.cap_add", "services.*.cap_drop", "services.*.profiles", "services.*.links",
             "services.*.networks.*.aliases", "services.*.networks.*.link_local_ips", "services.*.build.extra_hosts":
            return .unique(.keyValue)
        default:
            return .standard
        }
    }

    /// "services.web.build.args" as "services.*.build.args". Names under the top
    /// level maps and under a few named maps become `*`.
    private static func pattern(_ path: [String]) -> String {
        var parts = path
        if parts.count >= 2, ["services", "networks", "volumes", "secrets", "configs"].contains(parts[0]) {
            parts[1] = "*"
        }
        if parts.count >= 4, parts[0] == "services", ["ulimits", "networks", "volumes"].contains(parts[2]) {
            parts[3] = "*"
        }
        return parts.joined(separator: ".")
    }

    // MARK: Mappings

    private static func mergeMaps(_ base: ComposeNode, _ override: ComposeNode, path: [String]) -> ComposeNode {
        guard var entries = base.entries, let others = override.entries else { return override }
        for other in others {
            if let index = entries.firstIndex(where: { $0.key == other.key }) {
                if other.node.tag == .reset {
                    entries.remove(at: index)
                    continue
                }
                let merged = merge(entries[index].node, other.node, path: path + [other.key])
                let replaced = other.node.tag == .override || merged.line == other.node.line
                entries[index].node = merged
                if replaced { entries[index].line = other.line }
            } else if other.node.tag != .reset {
                var added = other
                added.node = other.node.cleaned()
                entries.append(added)
            }
        }
        return ComposeNode(value: .map(entries), line: base.line)
    }

    /// Lists of names become maps with `defaults` (or null) as values.
    private static func mapping(_ node: ComposeNode, defaults: [(String, String)]) -> ComposeNode? {
        if node.isNull { return ComposeNode(value: .map([]), line: node.line) }
        if node.entries != nil { return node }
        guard let items = node.items else {
            guard let text = node.text else { return nil }
            return mapping(ComposeNode(value: .list([.scalar(text, line: node.line)]), line: node.line), defaults: defaults)
        }
        var entries: [ComposeEntry] = []
        for item in items {
            guard let name = item.text else { return nil }
            let value: ComposeNode
            if defaults.isEmpty {
                value = .null(line: item.line)
            } else {
                value = ComposeNode(value: .map(defaults.map { ComposeEntry(key: $0.0, line: item.line, node: .scalar($0.1, line: item.line)) }), line: item.line)
            }
            entries.removeAll { $0.key == name }
            entries.append(ComposeEntry(key: name, line: item.line, node: value))
        }
        return ComposeNode(value: .map(entries), line: node.line)
    }

    private static func buildMap(_ node: ComposeNode) -> ComposeNode {
        if node.text != nil {
            return ComposeNode(value: .map([ComposeEntry(key: "context", line: node.line, node: node)]), line: node.line)
        }
        return node
    }

    // MARK: Key value lists

    /// `KEY=value` lists and `KEY: value` maps as ordered map entries.
    static func keyValueEntries(_ node: ComposeNode) -> [ComposeEntry]? {
        if node.isNull { return [] }
        if let entries = node.entries { return entries }
        let items = node.items ?? (node.text != nil ? [node] : nil)
        guard let items else { return nil }
        var result: [ComposeEntry] = []
        for item in items {
            guard let text = item.text else { continue }
            let entry: ComposeEntry
            if let eq = text.firstIndex(of: "=") {
                var value = ComposeNode.scalar(String(text[text.index(after: eq)...]), line: item.line)
                value.tag = item.tag
                entry = ComposeEntry(key: String(text[..<eq]), line: item.line, node: value)
            } else {
                var value = ComposeNode.null(line: item.line)
                value.tag = item.tag
                entry = ComposeEntry(key: text, line: item.line, node: value)
            }
            if let index = result.firstIndex(where: { $0.key == entry.key }) {
                result[index] = entry
            } else {
                result.append(entry)
            }
        }
        return result
    }

    private static func mergeKeyValues(_ base: ComposeNode, _ override: ComposeNode) -> ComposeNode {
        guard var entries = keyValueEntries(base), let others = keyValueEntries(override) else { return override }
        for other in others {
            if let index = entries.firstIndex(where: { $0.key == other.key }) {
                if other.node.tag == .reset {
                    entries.remove(at: index)
                } else {
                    entries[index] = other
                }
            } else if other.node.tag != .reset {
                entries.append(other)
            }
        }
        return ComposeNode(value: .map(entries), line: base.line)
    }

    // MARK: extra_hosts

    /// `host:ip`, `host=ip` and `host: ip` as map entries by host.
    static func hostEntries(_ node: ComposeNode) -> [ComposeEntry]? {
        if node.isNull { return [] }
        if let entries = node.entries { return entries }
        let items = node.items ?? (node.text != nil ? [node] : nil)
        guard let items else { return nil }
        var result: [ComposeEntry] = []
        for item in items {
            guard let text = item.text else { continue }
            let separator = text.firstIndex(of: "=") ?? text.firstIndex(of: ":")
            let host = separator.map { String(text[..<$0]) } ?? text
            let ip = separator.map { String(text[text.index(after: $0)...]) }
            var value = ip.map { ComposeNode.scalar($0, line: item.line) } ?? .null(line: item.line)
            value.tag = item.tag
            result.removeAll { $0.key == host }
            result.append(ComposeEntry(key: host, line: item.line, node: value))
        }
        return result
    }

    private static func mergeHosts(_ base: ComposeNode, _ override: ComposeNode) -> ComposeNode {
        guard var entries = hostEntries(base), let others = hostEntries(override) else { return override }
        for other in others {
            if let index = entries.firstIndex(where: { $0.key == other.key }) {
                if other.node.tag == .reset { entries.remove(at: index) } else { entries[index] = other }
            } else if other.node.tag != .reset {
                entries.append(other)
            }
        }
        return ComposeNode(value: .map(entries), line: base.line)
    }

    // MARK: Sequences

    private static func sequence(_ node: ComposeNode) -> [ComposeNode]? {
        if node.isNull { return [] }
        if let items = node.items { return items }
        if node.text != nil { return [node] }
        return nil
    }

    private static func appendWithoutDuplicates(_ base: [ComposeNode], _ other: [ComposeNode]) -> [ComposeNode] {
        var result = base
        for item in other where !result.contains(where: { $0.sameValue(as: item) }) {
            result.append(item.cleaned())
        }
        return result
    }

    private static func unique(_ items: [ComposeNode], index: Index) -> [ComposeNode] {
        var result: [ComposeNode] = []
        var positions: [String: Int] = [:]
        for item in items where item.tag != .reset {
            let key = Self.key(item, index: index)
            if let position = positions[key] {
                result[position] = item
            } else {
                positions[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    private static func key(_ node: ComposeNode, index: Index) -> String {
        switch index {
        case .text:
            return node.text ?? description(node)
        case .keyValue:
            guard let text = node.text else { return description(node) }
            return text.firstIndex(of: "=").map { String(text[..<$0]) } ?? text
        case .port:
            if let text = node.text { return text }
            let host = node["host_ip"]?.text ?? "0.0.0.0"
            let published = node["published"]?.text ?? ""
            let target = node["target"]?.text ?? ""
            let proto = node["protocol"]?.text ?? "tcp"
            return "\(host):\(published):\(target)/\(proto)"
        case .volumeTarget:
            if let text = node.text { return volumeTarget(text) }
            return node["target"]?.text ?? description(node)
        case .deviceTarget:
            if let text = node.text {
                let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                return parts.count == 1 ? parts[0] : parts[1]
            }
            return node["target"]?.text ?? description(node)
        case .envFilePath:
            return node.text ?? node["path"]?.text ?? description(node)
        case .mount(let defaultPath):
            if let text = node.text { return "\(defaultPath)/\(text)" }
            if let target = node["target"]?.text { return target }
            return "\(defaultPath)/\(node["source"]?.text ?? "")"
        }
    }

    /// Target of a short volume like "./data:/data:ro" or "/data".
    static func volumeTarget(_ text: String) -> String {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 1 ? parts[0] : parts[1]
    }

    private static func mergeBySubnet(_ base: [ComposeNode], _ other: [ComposeNode]) -> [ComposeNode] {
        var result = base
        for item in other {
            let subnet = item["subnet"]?.text
            if let index = result.firstIndex(where: { $0["subnet"]?.text == subnet }) {
                result[index] = mergeMaps(result[index], item, path: ["networks", "*", "ipam", "config", "*"])
            } else {
                result.append(item.cleaned())
            }
        }
        return result
    }

    /// A stable text for nodes without a natural key, so they never collide by accident.
    private static func description(_ node: ComposeNode) -> String {
        switch node.value {
        case .scalar(let text, let isNull): return isNull ? "~" : text
        case .list(let items): return "[" + items.map(description).joined(separator: ",") + "]"
        case .map(let entries): return "{" + entries.map { "\($0.key):\(description($0.node))" }.joined(separator: ",") + "}"
        }
    }
}

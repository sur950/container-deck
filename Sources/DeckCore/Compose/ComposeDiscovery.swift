import Foundation
import Yams

// Compose helpers: stacks found by other tools' labels, which services an Up
// would recreate (config hash label), and YAML syntax errors with line numbers.

/// Who started a stack, read from its labels.
public enum ComposeOrigin: String, Sendable, Hashable {
    /// Container Deck (our own labels, with config hash and file).
    case deck
    /// Docker Compose labels (`com.docker.compose.*`). Also set by podman-compose
    /// and other compose tools for Apple's runtime that follow Docker's labels.
    case docker

    public var title: String {
        switch self {
        case .deck: return AppConfig.appName
        case .docker: return "Compose labels"
        }
    }
}

public extension ComposeLabel {
    static let dockerProject = "com.docker.compose.project"
    static let dockerService = "com.docker.compose.service"
    static let dockerConfigFiles = "com.docker.compose.project.config_files"
    static let dockerWorkingDir = "com.docker.compose.project.working_dir"
    static let dockerConfigHash = "com.docker.compose.config-hash"

    /// Project name from our label first, then Docker's.
    public static func projectName(_ labels: [String: String]) -> String? {
        for key in [project, dockerProject] {
            if let value = labels[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return nil
    }

    static func serviceName(_ labels: [String: String]) -> String? {
        for key in [service, dockerService] {
            if let value = labels[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return nil
    }

    /// The compose file the stack came from, when a label says so.
    static func filePath(_ labels: [String: String]) -> String? {
        if let value = labels[file], !value.isEmpty { return value }
        // Docker writes a comma separated list, relative to the working dir or absolute.
        if let list = labels[dockerConfigFiles], let first = list.split(separator: ",").first {
            let path = first.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { return path }
            if let dir = labels[dockerWorkingDir], !dir.isEmpty {
                return URL(fileURLWithPath: dir).appendingPathComponent(path).path
            }
        }
        return nil
    }

    /// Every compose file the stack came from, main file first. Empty when unknown.
    static func filePaths(_ labels: [String: String]) -> [String] {
        if let list = labels[files], !list.isEmpty {
            let paths = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !paths.isEmpty { return paths }
        }
        if let value = labels[file], !value.isEmpty { return [value] }
        if let list = labels[dockerConfigFiles] {
            return list.split(separator: ",").compactMap { part -> String? in
                let path = part.trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { return path }
                guard let dir = labels[dockerWorkingDir], !dir.isEmpty else { return nil }
                return URL(fileURLWithPath: dir).appendingPathComponent(path).path
            }
        }
        return []
    }

    static func origin(_ labels: [String: String]) -> ComposeOrigin? {
        if let value = labels[project], !value.isEmpty { return .deck }
        if let value = labels[dockerProject], !value.isEmpty { return .docker }
        return nil
    }

    /// True when the container belongs to `name` by any known label.
    static func belongs(_ labels: [String: String], to name: String) -> Bool {
        projectName(labels) == name
    }
}

/// What Up would do to one service.
public enum ComposeServiceChange: String, Sendable, Hashable {
    /// No container yet. Up creates it.
    case new
    /// Same config hash and running. Up leaves it.
    case upToDate
    /// Same config hash but stopped. Up starts it.
    case willStart
    /// Different (or missing) config hash. Up recreates it.
    case changed

    public var title: String {
        switch self {
        case .new: return "New"
        case .upToDate: return "Up to date"
        case .willStart: return "Will start"
        case .changed: return "Changed"
        }
    }

    public var help: String {
        switch self {
        case .new: return "Up creates this service."
        case .upToDate: return "Nothing changed. Up leaves it running."
        case .willStart: return "Nothing changed. Up starts the stopped container."
        case .changed: return "The settings changed since it was created. Up recreates only this service."
        }
    }
}

public enum ComposeReup {
    /// Compares each planned service with the container that runs it, by the
    /// config hash label. Only `changed` services are recreated by Up.
    public static func changes(_ plan: ComposePlan, containers: [ContainerSummary], forceRecreate: Bool = false) -> [String: ComposeServiceChange] {
        var existing: [String: ContainerSummary] = [:]
        for container in containers where ComposeLabel.belongs(container.labels, to: plan.projectName) {
            if let service = ComposeLabel.serviceName(container.labels) { existing[service] = container }
        }
        var result: [String: ComposeServiceChange] = [:]
        for service in plan.services {
            guard let current = existing[service.name] else {
                result[service.name] = .new
                continue
            }
            let same = current.labels[ComposeLabel.configHash] == service.configHash
            if !same || forceRecreate {
                result[service.name] = .changed
            } else {
                result[service.name] = current.isRunning ? .upToDate : .willStart
            }
        }
        return result
    }

    /// "2 changed, 1 new, 3 up to date".
    public static func summary(_ changes: [String: ComposeServiceChange]) -> String {
        let order: [ComposeServiceChange] = [.changed, .new, .willStart, .upToDate]
        let parts = order.compactMap { kind -> String? in
            let count = changes.values.filter { $0 == kind }.count
            return count > 0 ? "\(count) \(kind.title.lowercased())" : nil
        }
        return parts.isEmpty ? "No services" : parts.joined(separator: ", ")
    }
}

/// A YAML syntax error with its place in the file.
public struct ComposeYAMLIssue: Sendable, Hashable {
    public var line: Int
    public var column: Int
    public var problem: String

    public init(line: Int, column: Int, problem: String) {
        self.line = line
        self.column = column
        self.problem = problem
    }

    /// "Line 4, column 3: did not find expected key."
    public var message: String {
        var text = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first { text = first.uppercased() + text.dropFirst() }
        if !text.hasSuffix(".") { text += "." }
        return "Line \(line), column \(column): \(text)"
    }

    public static func from(_ error: Error) -> ComposeYAMLIssue? {
        guard let yaml = error as? YamlError else { return nil }
        switch yaml {
        case let .scanner(context, problem, mark, _),
             let .parser(context, problem, mark, _),
             let .composer(context, problem, mark, _):
            var text = problem
            if let context = context?.text, !context.isEmpty { text += " (\(context))" }
            return ComposeYAMLIssue(line: mark.line, column: mark.column, problem: text)
        default:
            return nil
        }
    }

    /// Line number in a message made by `message`. nil when there is none.
    public static func line(in message: String) -> Int? {
        guard let range = message.range(of: #"Line (\d+), column"#, options: .regularExpression) else { return nil }
        let digits = message[range].filter(\.isNumber)
        return Int(digits)
    }
}

/// Lines around a line of the compose file, for the Problems tab.
public struct ComposeSourceExcerpt: Sendable, Hashable {
    public struct Line: Sendable, Hashable, Identifiable {
        public var number: Int
        public var text: String
        public var isTarget: Bool
        public var id: Int { number }
    }

    public var lines: [Line]

    /// `context` lines before and after. Empty when the line is outside the text.
    public static func make(_ text: String, line: Int, context: Int = 1) -> ComposeSourceExcerpt {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard line >= 1, line <= all.count else { return ComposeSourceExcerpt(lines: []) }
        let start = max(1, line - context)
        let end = min(all.count, line + context)
        let lines = (start...end).map { number in
            Line(number: number, text: all[number - 1].replacingOccurrences(of: "\t", with: "    "), isTarget: number == line)
        }
        return ComposeSourceExcerpt(lines: lines)
    }
}

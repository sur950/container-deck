import Foundation

/// Runs commands as admin. macOS shows its own password prompt.
public struct PrivilegedRunner: Sendable {
    let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    /// Runs every command in order inside one password prompt.
    public func run(_ commands: [[String]]) async throws -> CommandResult {
        let shell = commands
            .map { $0.map(Self.shellQuote).joined(separator: " ") }
            .joined(separator: " && ")
        let script = "do shell script \"\(Self.appleScriptEscape(shell))\" with administrator privileges"
        return try await runner.run("/usr/bin/osascript", ["-e", script])
    }

    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run([[executable] + arguments])
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

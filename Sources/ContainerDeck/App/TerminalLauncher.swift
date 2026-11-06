import Foundation
import AppKit

/// Opens a shell command in the terminal app chosen in Settings.
///
/// Every app gets the same small executable script, so quoting never breaks:
/// Terminal, iTerm2 and Warp open it as a `.command` file. Ghostty, kitty,
/// Alacritty and WezTerm run it with their own command line flags.
@MainActor
enum TerminalLauncher {
    enum LaunchError: LocalizedError {
        case notInstalled(String)
        case scriptFailed(String)
        case launchFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let app):
                return "\(app) is not installed. Pick another terminal in Settings."
            case .scriptFailed(let reason):
                return "Could not prepare the terminal command. \(reason)"
            case .launchFailed(let app, let reason):
                return "Could not open \(app). \(reason)"
            }
        }
    }

    /// `onFailure` hears about errors that only show up after the app was asked
    /// to open (Terminal refused the script, the app could not start).
    static func open(command: String, onFailure: (@MainActor (Error) -> Void)? = nil) throws {
        let app = Prefs.terminalApp
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
            throw LaunchError.notInstalled(app.title)
        }
        let script = try makeScript(command: command)

        switch app {
        case .terminal, .iterm, .warp:
            openFile(script, with: appURL, app: app, onFailure: onFailure)
        case .ghostty:
            // Same as `open -na Ghostty.app --args -e <script>`.
            openNewInstance(appURL, arguments: ["-e", script.path], app: app, onFailure: onFailure)
        case .kitty:
            try runBundled(appURL, binary: "kitty", arguments: [script.path], app: app, onFailure: onFailure)
        case .alacritty:
            try runBundled(appURL, binary: "alacritty", arguments: ["-e", script.path], app: app, onFailure: onFailure)
        case .wezterm:
            try runBundled(appURL, binary: "wezterm-gui", arguments: ["start", "--", script.path], app: app, onFailure: onFailure)
        }
    }

    // MARK: - Helpers

    /// Writes a temporary executable script that runs the command, then removes itself.
    private static func makeScript(command: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerDeck", isDirectory: true)
        let file = folder.appendingPathComponent("shell-\(UUID().uuidString.prefix(8)).command")
        let body = """
        #!/bin/sh
        rm -f "$0"
        \(command)

        """
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
        } catch {
            throw LaunchError.scriptFailed(error.localizedDescription)
        }
        return file
    }

    /// Opens the script with the app, like `open -a <app> <script>`.
    private static func openFile(_ file: URL, with appURL: URL, app: TerminalApp, onFailure: (@MainActor (Error) -> Void)?) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: config) { _, error in
            report(error, file: file, app: app, onFailure: onFailure)
        }
    }

    /// Hands a late launch error back on the main actor and removes the unused script.
    private nonisolated static func report(_ error: Error?, file: URL?, app: TerminalApp, onFailure: (@MainActor (Error) -> Void)?) {
        guard let error else { return }
        if let file { try? FileManager.default.removeItem(at: file) }
        let message = error.localizedDescription
        Task { @MainActor in
            onFailure?(LaunchError.launchFailed(app.title, message))
        }
    }

    /// Starts a new copy of the app with arguments, like `open -na <app> --args ...`.
    private static func openNewInstance(_ appURL: URL, arguments: [String], app: TerminalApp, onFailure: (@MainActor (Error) -> Void)?) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        config.arguments = arguments
        let script = arguments.last.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            report(error, file: script, app: app, onFailure: onFailure)
        }
    }

    /// Runs the app's own command line binary. Falls back to a new app instance.
    private static func runBundled(
        _ appURL: URL, binary: String, arguments: [String], app: TerminalApp, onFailure: (@MainActor (Error) -> Void)?
    ) throws {
        let executable = appURL.appendingPathComponent("Contents/MacOS/\(binary)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            openNewInstance(appURL, arguments: arguments, app: app, onFailure: onFailure)
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LaunchError.launchFailed(app.title, error.localizedDescription)
        }
    }
}

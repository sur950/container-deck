import Foundation

// Images like ubuntu, debian or alpine start a shell by default. With no
// terminal and no input, that shell has nothing to read, so it exits at once
// and the container stops with no logs. `container run -d -i -t` needs a real
// terminal, which the app does not have. The fix is to keep the container
// alive with `sleep infinity` and open a shell in it with `container exec -it`.

/// Spots a run whose process is a bare interactive shell, which stops at once
/// without a terminal.
public enum BareShell {
    /// Shell programs that read commands from input when given nothing to run.
    public static let shellNames: Set<String> = ["bash", "sh", "zsh", "ash", "dash", "fish"]
    /// Folders a shell may be named with. An empty string is the bare name.
    static let folders: Set<String> = ["", "/bin", "/usr/bin", "/usr/local/bin"]
    /// Options that still leave the shell reading input: login and interactive.
    static let passiveFlags: Set<String> = ["-l", "--login", "-i", "-il", "-li", "--interactive"]

    /// The command that keeps a container alive.
    public static let keepRunningCommand = ["sleep", "infinity"]
    /// Label that remembers the image's shell, so Terminal opens that shell.
    public static let shellLabel = "deck.shell"
    /// Shell for Terminal when nothing better is known.
    public static let defaultShell = "/bin/sh"
    /// A stopped bare shell that ran this long or less stopped "right away".
    public static let quickExit: TimeInterval = 5

    /// The shell when `words` is just a shell, like `bash`, `/bin/sh` or
    /// `/bin/bash -l`. nil when there is a script, a `-c`, or another program.
    public static func shell(in words: [String]) -> String? {
        guard let first = words.first, isShellPath(first) else { return nil }
        for word in words.dropFirst() where !passiveFlags.contains(word) {
            return nil
        }
        return first
    }

    /// True for `bash`, `/bin/bash`, `/usr/bin/zsh` and the like.
    public static func isShellPath(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return false }
        let name: String
        let folder: String
        if let slash = word.lastIndex(of: "/") {
            name = String(word[word.index(after: slash)...])
            folder = String(word[..<slash])
        } else {
            name = word
            folder = ""
        }
        return shellNames.contains(name) && folders.contains(folder)
    }

    /// The process the run starts, the way `container run` puts it together:
    /// a set entrypoint replaces the image entrypoint and command, a set
    /// command replaces the image command only. nil when the image is unknown
    /// and the run does not say.
    public static func effectiveCommand(_ options: RunOptions, image: ImageConfigInfo?) -> [String]? {
        if let entrypoint = clean(options.entrypoint) {
            return [entrypoint] + options.command
        }
        guard let image else {
            return options.command.isEmpty ? nil : options.command
        }
        return image.entrypoint + (options.command.isEmpty ? image.cmd : options.command)
    }

    /// The shell when this run stops right away because it starts a bare
    /// shell with no terminal. nil when it runs something else or has a terminal.
    public static func exitingShell(_ options: RunOptions, image: ImageConfigInfo?) -> String? {
        guard !options.tty, let words = effectiveCommand(options, image: image) else { return nil }
        return shell(in: words)
    }

    /// The shell of a stopped container that stopped right away because it
    /// ran a bare shell with no terminal. `stoppedAt` is when it stopped, when
    /// known. The container service does not record it yet, and a bare shell
    /// with no terminal always stops at once, so nil counts as quick.
    public static func quickExitShell(_ detail: ContainerDetail, stoppedAt: Date? = nil) -> String? {
        let summary = detail.summary
        guard summary.state == .stopped, !detail.terminal else { return nil }
        if let started = summary.startedAt, let stoppedAt, stoppedAt.timeIntervalSince(started) > quickExit {
            return nil
        }
        let process = summary.command.isEmpty ? detail.entrypoint + detail.arguments : summary.command
        return shell(in: process)
    }

    /// The shell Terminal opens in a container: the one the app saved when it
    /// kept the container running, the container's own shell, or `/bin/sh`.
    public static func terminalShell(for summary: ContainerSummary) -> String {
        if let saved = summary.labels[shellLabel], isShellPath(saved) {
            return saved.trimmingCharacters(in: .whitespaces)
        }
        return shell(in: summary.command) ?? defaultShell
    }

    private static func clean(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

public extension RunOptions {
    /// Runs `sleep infinity` in place of the shell, and saves the shell in a
    /// label for Terminal. When the image has its own entrypoint, `sleep`
    /// replaces it, since a command alone would go after that entrypoint.
    func keptRunning(shell: String, image: ImageConfigInfo?) -> RunOptions {
        var result = self
        let words = BareShell.keepRunningCommand
        if let image, !image.entrypoint.isEmpty {
            result.entrypoint = words[0]
            result.command = Array(words.dropFirst())
        } else {
            result.entrypoint = nil
            result.command = words
        }
        result.labels[BareShell.shellLabel] = shell
        return result
    }

    /// The Run sheet's "Keep it running" choice. Only changes the run when
    /// `on`, the person set no command and no entrypoint, and the image would
    /// start a bare shell that stops right away.
    func applyingKeepRunning(_ on: Bool, image: ImageConfigInfo?) -> RunOptions {
        guard on, let shell = keepRunningShell(image: image) else { return self }
        return keptRunning(shell: shell, image: image)
    }

    /// The shell when the Run sheet should offer "Keep it running": no command
    /// or entrypoint set and the image starts a bare shell.
    func keepRunningShell(image: ImageConfigInfo?) -> String? {
        let entry = entrypoint?.trimmingCharacters(in: .whitespaces) ?? ""
        guard command.isEmpty, entry.isEmpty, let image else { return nil }
        return BareShell.exitingShell(self, image: image)
    }
}

public extension ContainerClient {
    /// The run preparation step every app path takes before `container run`
    /// (Run sheet, Images, palette, Explore, Builds). When no command or
    /// entrypoint is set and the image starts a bare shell, the run gets
    /// `sleep infinity` so it keeps running. An image that is not on this
    /// Mac yet is pulled first, since `container run` would pull it anyway.
    /// Any failure leaves the options as they are and the run goes on.
    func prepareRun(
        _ options: RunOptions, keepShellRunning: Bool = true,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> RunOptions {
        let entry = options.entrypoint?.trimmingCharacters(in: .whitespaces) ?? ""
        let image = options.image.trimmingCharacters(in: .whitespaces)
        guard keepShellRunning, options.command.isEmpty, entry.isEmpty, !options.tty, !image.isEmpty else { return options }
        var config = try? await inspectImage(image).config
        if config == nil {
            progress("Getting \(image)…")
            do {
                for try await _ in pullImage(image, platform: options.platform) {}
            } catch {
                return options
            }
            config = try? await inspectImage(image).config
        }
        return options.applyingKeepRunning(true, image: config)
    }

    /// The safe recreate plan for a container that stopped because it ran a
    /// bare shell: the same settings, now running `sleep infinity`. The old
    /// container's capture stays as it was, so a failed run puts it back.
    func keepRunningPlan(_ id: String, shell: String) async throws -> RecreatePlan {
        let capture = try await captureForRecreate(id)
        let config = try? await inspectImage(capture.options.image).config
        return RecreatePlan(old: capture, new: capture.options.keptRunning(shell: shell, image: config))
    }
}

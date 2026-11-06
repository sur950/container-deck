import Foundation

/// Output of one finished command.
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }

    /// Best message to show a person when the command failed.
    public var failureMessage: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "The command exited with code \(exitCode)." : out
    }
}

/// Runs a program and returns its output. Swapped for a mock in tests.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, stdin: nil)
    }
}

/// Real runner built on Foundation's Process.
public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // Never let a command wait on a prompt we cannot answer.
                let inPipe = Pipe()
                if stdin != nil {
                    process.standardInput = inPipe
                } else {
                    process.standardInput = FileHandle.nullDevice
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: DeckError.launchFailed(executable, error.localizedDescription))
                    return
                }

                if let stdin {
                    inPipe.fileHandleForWriting.write(stdin)
                    try? inPipe.fileHandleForWriting.close()
                }

                // Read both pipes at the same time so a full buffer never blocks the process.
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)
                ))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

import Foundation

/// Like ProcessRunner, but stops the process when the calling task is cancelled.
/// Engine Import uses it for long exports so Cancel really stops the copy.
public struct CancellableRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        let box = RunningProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    let inPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
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
                    box.attach(process)

                    if let stdin {
                        inPipe.fileHandleForWriting.write(stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }

                    let errBox = OutputBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()

                    if box.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: CommandResult(
                        exitCode: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errBox.data, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class RunningProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let stopNow = cancelled
        lock.unlock()
        if stopNow, process.isRunning { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        if let current, current.isRunning { current.terminate() }
    }
}

private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

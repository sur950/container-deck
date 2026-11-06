import Foundation

/// Runs a long command and hands back its output line by line
/// (logs, build output, pull progress). Cancelling the stream stops the process.
public protocol CommandStreaming: Sendable {
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error>
}

extension ProcessRunner: CommandStreaming {
    public func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            // stdout and stderr go to the same place, like a terminal.
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let buffer = LineBuffer()
            let reader = pipe.fileHandleForReading

            reader.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for line in buffer.append(data) {
                    continuation.yield(line)
                }
            }

            process.terminationHandler = { finished in
                reader.readabilityHandler = nil
                let rest = (try? reader.readToEnd()) ?? Data()
                for line in buffer.append(rest) + buffer.flush() {
                    continuation.yield(line)
                }
                if finished.terminationStatus == 0 || buffer.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: DeckError.commandFailed(
                        buffer.lastLine ?? "The command exited with code \(finished.terminationStatus)."
                    ))
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    buffer.isCancelled = true
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: DeckError.launchFailed(executable, error.localizedDescription))
            }
        }
    }
}

/// Splits incoming bytes into lines on \n and \r (progress bars use \r).
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var _lastLine: String?
    private var _cancelled = false

    var isCancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }

    var lastLine: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastLine
    }

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<index]
            pending.removeSubrange(pending.startIndex...index)
            let line = String(decoding: lineData, as: UTF8.self)
            if !line.isEmpty {
                lines.append(line)
                _lastLine = line
            }
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        if line.isEmpty { return [] }
        _lastLine = line
        return [line]
    }
}

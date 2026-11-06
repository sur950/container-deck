import Foundation

/// Reads a container log file the daemon handed over, like `container logs`:
/// the last N lines (or the whole file), then new lines as they are written.
enum APILogReader {
    static let chunkSize = 64 * 1024
    /// How often a followed file is checked for new bytes.
    static let pollInterval: Duration = .milliseconds(250)

    /// `tail` nil prints the whole file (blank lines kept, trailing newlines dropped).
    /// A tail of N gives the last N non empty lines, as the CLI does.
    static func read(
        _ file: OwnedFileDescriptor,
        tail: Int?,
        follow: Bool,
        emit: (String) -> Void
    ) async throws {
        let fd = file.rawValue
        var offset = try size(fd)
        if let tail, tail >= 0 {
            for line in try lastLines(fd, count: tail, end: offset) { emit(line) }
        } else {
            let data = try readRange(fd, from: 0, to: offset)
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                for line in text.components(separatedBy: "\n") {
                    emit(line.hasSuffix("\r") ? String(line.dropLast()) : line)
                }
            }
        }
        guard follow else { return }

        var partial = Data()
        while true {
            try Task.checkCancellation()
            let current = try size(fd)
            if current < offset {
                // The file was cut (container restarted). Carry on from its new end.
                offset = current
                partial.removeAll()
            } else if current > offset {
                partial.append(try readRange(fd, from: offset, to: current))
                offset = current
                for line in completeLines(&partial) where !line.isEmpty { emit(line) }
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Takes the finished lines out of `buffer` and leaves an unfinished one in it.
    static func completeLines(_ buffer: inout Data) -> [String] {
        guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let done = buffer[buffer.startIndex...lastNewline]
        buffer = Data(buffer[buffer.index(after: lastNewline)...])
        return String(decoding: done, as: UTF8.self)
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// The last `count` non empty lines before `end`, reading backwards in chunks.
    static func lastLines(_ fd: Int32, count: Int, end: UInt64) throws -> [String] {
        guard count > 0, end > 0 else { return [] }
        var start = end
        var buffer = Data()
        var lines: [String] = []
        while start > 0 {
            let step = min(UInt64(chunkSize), start)
            start -= step
            buffer.insert(contentsOf: try readRange(fd, from: start, to: start + step), at: 0)
            var pieces = String(decoding: buffer, as: UTF8.self).components(separatedBy: .newlines)
            // Stopped in the middle of the file: the first piece may be cut, so it waits.
            if start > 0, !pieces.isEmpty { pieces.removeFirst() }
            lines = pieces.filter { !$0.isEmpty }
            if lines.count >= count { break }
        }
        return Array(lines.suffix(count))
    }

    static func size(_ fd: Int32) throws -> UInt64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw APIError.malformedReply("log file") }
        return UInt64(max(info.st_size, 0))
    }

    static func readRange(_ fd: Int32, from start: UInt64, to end: UInt64) throws -> Data {
        guard end > start else { return Data() }
        var data = Data(count: Int(end - start))
        var done = 0
        while done < data.count {
            let got = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return pread(fd, base + done, buffer.count - done, off_t(start) + off_t(done))
            }
            if got < 0 { throw APIError.malformedReply("log file read") }
            if got == 0 { break }
            done += got
        }
        data.count = done
        return data
    }
}

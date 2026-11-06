import Foundation

/// Progress of one model download.
public struct ModelDownloadProgress: Sendable, Equatable {
    public var completedBytes: UInt64
    public var totalBytes: UInt64
    /// File being fetched now.
    public var currentFile: String
    public var filesDone: Int
    public var fileCount: Int

    public init(completedBytes: UInt64, totalBytes: UInt64, currentFile: String, filesDone: Int, fileCount: Int) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentFile = currentFile
        self.filesDone = filesDone
        self.fileCount = fileCount
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

/// Downloads a Hugging Face model into the library, one file at a time.
/// Partial files are kept as `<name>.part`, so a cancelled or failed download picks up
/// where it stopped (HTTP Range). Files already there with the right size are skipped.
public struct ModelDownloader: Sendable {
    public let paths: AIPaths

    public init(paths: AIPaths = AIPaths()) {
        self.paths = paths
    }

    /// Bytes still to download for these files in this folder (resumable parts count as done).
    public static func remainingBytes(_ files: [HFFile], in folder: URL) -> UInt64 {
        files.reduce(0) { total, file in
            let done = existingBytes(file, in: folder)
            return total + (file.size > done ? file.size - done : 0)
        }
    }

    static func existingBytes(_ file: HFFile, in folder: URL) -> UInt64 {
        let dest = folder.appendingPathComponent(file.path)
        if let size = fileSize(dest), size == file.size { return size }
        return fileSize(dest.appendingPathExtension("part")).map { min($0, file.size) } ?? 0
    }

    static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    /// Downloads every file. Returns the model folder. Throws `CancellationError` when cancelled.
    @discardableResult
    public func download(repo: String, files: [HFFile], progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> URL {
        guard HuggingFaceClient.isRepoID(repo) else { throw DeckError.network("\(repo) is not a model name.") }
        let folder = paths.modelFolder(repo)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = ModelManifest(repo: repo, files: files, complete: false)
        try manifest.save(folder)

        let total = files.reduce(0) { $0 + $1.size }
        let remaining = Self.remainingBytes(files, in: folder)
        if let free = LocalModelStore.freeSpace(at: folder), remaining + 512 * 1024 * 1024 > free {
            throw DeckError.commandFailed("Not enough free disk space. The model needs \(ByteCountFormatter.string(fromByteCount: Int64(remaining), countStyle: .file)) more.")
        }

        var doneBefore: UInt64 = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let dest = folder.appendingPathComponent(file.path)
            let base = doneBefore
            progress(ModelDownloadProgress(completedBytes: base, totalBytes: total, currentFile: file.path, filesDone: index, fileCount: files.count))
            if Self.fileSize(dest) != file.size {
                guard let url = HuggingFaceClient.resolveURL(repo, path: file.path) else { throw DeckError.network("Bad file name \(file.path).") }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await fetch(url, to: dest, expectedSize: file.size) { bytes in
                    progress(ModelDownloadProgress(completedBytes: base + bytes, totalBytes: total, currentFile: file.path, filesDone: index, fileCount: files.count))
                }
            }
            doneBefore += file.size
        }
        manifest.complete = true
        try manifest.save(folder)
        progress(ModelDownloadProgress(completedBytes: total, totalBytes: total, currentFile: "", filesDone: files.count, fileCount: files.count))
        return folder
    }

    /// Fetches one file into `<dest>.part`, resuming it, then moves it into place.
    func fetch(_ url: URL, to dest: URL, expectedSize: UInt64, onBytes: @escaping @Sendable (UInt64) -> Void) async throws {
        let part = dest.appendingPathExtension("part")
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        var have = Self.fileSize(part) ?? 0
        if expectedSize > 0, have > expectedSize {
            try FileManager.default.removeItem(at: part)
            FileManager.default.createFile(atPath: part.path, contents: nil)
            have = 0
        }
        if expectedSize == 0 || have < expectedSize {
            let fetcher = try FileFetcher(file: part, resumeFrom: have, onBytes: onBytes)
            try await fetcher.run(url)
        }
        let got = Self.fileSize(part) ?? 0
        if expectedSize > 0, got != expectedSize {
            throw DeckError.network("\(dest.lastPathComponent) is \(got) bytes, expected \(expectedSize). Try again to resume.")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
    }
}

/// One HTTP download into a file, with Range resume and byte progress.
private final class FileFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let onBytes: @Sendable (UInt64) -> Void
    private let lock = NSLock()
    private var written: UInt64
    private let resumeFrom: UInt64
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var task: URLSessionDataTask?
    private var lastReport = Date.distantPast

    init(file: URL, resumeFrom: UInt64, onBytes: @escaping @Sendable (UInt64) -> Void) throws {
        handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: resumeFrom)
        self.resumeFrom = resumeFrom
        self.written = resumeFrom
        self.onBytes = onBytes
    }

    func run(_ url: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        if resumeFrom > 0 { request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        defer {
            session.finishTasksAndInvalidate()
            try? handle.close()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            lock.lock(); let task = self.task; lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            completionHandler(.allow)
        case 200:
            // The server ignored Range: start the file again.
            if resumeFrom > 0 {
                try? handle.truncate(atOffset: 0)
                lock.lock(); written = 0; lock.unlock()
            }
            completionHandler(.allow)
        default:
            lock.lock()
            failure = DeckError.network(status == 401 || status == 403
                ? "This model needs a Hugging Face account. Only public models can be downloaded."
                : "The download answered with status \(status).")
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            lock.lock(); failure = error; lock.unlock()
            dataTask.cancel()
            return
        }
        lock.lock()
        written += UInt64(data.count)
        let value = written
        let now = Date()
        let report = now.timeIntervalSince(lastReport) > 0.15
        if report { lastReport = now }
        lock.unlock()
        if report { onBytes(value) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        let value = written
        lock.unlock()
        try? handle.synchronize()
        onBytes(value)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error = error as? URLError, error.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            continuation?.resume(throwing: DeckError.network(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }
}

import Foundation
import CryptoKit

/// Retry and timeout settings for the kernel download.
public struct KernelDownloadPolicy: Sendable {
    /// Retries in a row that may fail without bringing new data. A try that brought
    /// at least `progressCredit` bytes does not use up a retry.
    public var retries: Int
    /// Wait before retry n is `baseDelay * 2^(n-1)` seconds (2, 4, 8 by default).
    public var baseDelay: TimeInterval
    /// Seconds without any data before a connection counts as stalled.
    public var idleTimeout: TimeInterval
    /// Longest a single connection may run. The archive is large and networks can be slow.
    public var resourceTimeout: TimeInterval
    public var progressCredit: Int64
    /// Seconds between progress updates.
    public var progressInterval: TimeInterval

    public init(retries: Int = 3, baseDelay: TimeInterval = 2, idleTimeout: TimeInterval = 90,
                resourceTimeout: TimeInterval = 4 * 60 * 60, progressCredit: Int64 = 1_000_000,
                progressInterval: TimeInterval = 0.25) {
        self.retries = retries
        self.baseDelay = baseDelay
        self.idleTimeout = idleTimeout
        self.resourceTimeout = resourceTimeout
        self.progressCredit = progressCredit
        self.progressInterval = progressInterval
    }

    public static let standard = KernelDownloadPolicy()

    func delay(beforeRetry n: Int) -> TimeInterval {
        baseDelay * pow(2, Double(max(0, n - 1)))
    }
}

/// Downloads the kernel archive into one folder with HTTP Range resume, retries with
/// backoff and a SHA-256 check. A damaged archive is deleted and fetched once more from scratch.
public struct KernelDownloader: @unchecked Sendable {
    public let directory: URL
    let configuration: URLSessionConfiguration
    let policy: KernelDownloadPolicy
    /// Extra room kept free next to the archive (Apple unpacks the kernel from it).
    static let spareBytes: Int64 = 300_000_000

    public init(directory: URL, configuration: URLSessionConfiguration = .default, policy: KernelDownloadPolicy = .standard) {
        self.directory = directory
        self.configuration = configuration
        self.policy = policy
    }

    public func archiveURL(for source: KernelSource) -> URL {
        directory.appendingPathComponent(source.fileName)
    }

    public func partURL(for source: KernelSource) -> URL {
        directory.appendingPathComponent(source.fileName + ".part")
    }

    /// Deletes everything in the download folder.
    public func removeDownloads() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Returns the checked archive. Throws `KernelInstallError` or `CancellationError`.
    public func fetch(_ source: KernelSource, progress: @escaping @Sendable (KernelInstallStage) -> Void) async throws -> URL {
        guard let expected = source.sha256Hex else {
            throw KernelInstallError.other(message: "The kernel checksum from the container tool is not valid.", details: source.digest)
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw KernelInstallError.other(message: "Could not create the download folder.", details: "\(directory.path)\n\(error.localizedDescription)")
        }
        removeOtherFiles(keeping: [source.fileName, source.fileName + ".part"])

        var mismatches: [String] = []
        for round in 0..<2 {
            let archive = try await download(source, freshRetry: round > 0, progress: progress)
            progress(.verifying)
            let actual = try await Self.sha256Hex(of: archive)
            if actual == expected { return archive }
            try? fm.removeItem(at: archive)
            try? fm.removeItem(at: partURL(for: source))
            mismatches.append("Download \(round + 1): kernel archive digest mismatch: expected sha256:\(expected), got sha256:\(actual)")
        }
        throw KernelInstallError.damaged(details: "\(source.url.absoluteString)\n" + mismatches.joined(separator: "\n"))
    }

    // MARK: - Download with retries

    private func download(_ source: KernelSource, freshRetry: Bool, progress: @escaping @Sendable (KernelInstallStage) -> Void) async throws -> URL {
        let fm = FileManager.default
        let archive = archiveURL(for: source)
        let part = partURL(for: source)
        // A finished archive from an earlier try (for example the install step failed) is checked again, not fetched.
        if fm.fileExists(atPath: archive.path) {
            if let size = source.expectedSize, Self.fileSize(archive) != size {
                try? fm.removeItem(at: archive)
            } else {
                return archive
            }
        }
        if let size = source.expectedSize, let have = Self.fileSize(part), have > size {
            try? fm.removeItem(at: part)
        }
        if !fm.fileExists(atPath: part.path) {
            fm.createFile(atPath: part.path, contents: nil)
        }
        try checkFreeSpace(source, have: Self.fileSize(part) ?? 0)

        var attempt = 1
        var failuresInARow = 0
        var knownTotal = source.expectedSize ?? 0
        while true {
            try Task.checkCancellation()
            let offset = Self.fileSize(part) ?? 0
            if let size = source.expectedSize, offset == size {
                try Self.move(part, to: archive)
                return archive
            }
            let meter = SpeedMeter()
            let attemptNumber = attempt
            let report: @Sendable (Int64, Int64) -> Void = { received, total in
                progress(.downloading(KernelDownloadProgress(
                    receivedBytes: received, totalBytes: total, bytesPerSecond: meter.add(received),
                    attempt: attemptNumber, isFreshRetry: freshRetry
                )))
            }
            report(offset, knownTotal)
            let fetch = KernelHTTPFetch(file: part, offset: offset, expectedTotal: source.expectedSize,
                                        interval: policy.progressInterval, onBytes: report)
            do {
                try await fetch.run(source.url, configuration: sessionConfiguration())
                try Self.move(part, to: archive)
                return archive
            } catch let failure as KernelFetchFailure {
                if fetch.total > 0 { knownTotal = fetch.total }
                let gained = (Self.fileSize(part) ?? 0) - offset
                failuresInARow = gained >= policy.progressCredit ? 0 : failuresInARow + 1
                guard failure.isTransient, failuresInARow <= policy.retries else {
                    throw failure.installError(url: source.url, attempts: attempt)
                }
                attempt += 1
                let wait = policy.delay(beforeRetry: max(1, failuresInARow))
                report(Self.fileSize(part) ?? 0, knownTotal)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
        }
    }

    private func sessionConfiguration() -> URLSessionConfiguration {
        // swiftlint:disable:next force_cast
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = policy.idleTimeout
        config.timeoutIntervalForResource = policy.resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        return config
    }

    private func checkFreeSpace(_ source: KernelSource, have: Int64) throws {
        let size = source.expectedSize ?? 700_000_000
        let needed = max(0, size - have) + Self.spareBytes
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free > 0, free < needed {
            throw KernelInstallError.diskFull(neededBytes: needed)
        }
    }

    private func removeOtherFiles(keeping names: Set<String>) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !names.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Files

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private static func move(_ part: URL, to archive: URL) throws {
        try? FileManager.default.removeItem(at: archive)
        do {
            try FileManager.default.moveItem(at: part, to: archive)
        } catch {
            throw KernelInstallError.other(message: "Could not save the kernel download.", details: error.localizedDescription)
        }
    }

    /// SHA-256 of a file, read in 4 MB pieces off the main thread. Stops when cancelled.
    public static func sha256Hex(of file: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: file)
            } catch {
                throw KernelInstallError.other(message: "Could not read the kernel download.", details: error.localizedDescription)
            }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

// MARK: - One HTTP request

/// Why one request stopped.
enum KernelFetchFailure: Error, Equatable {
    case transport(URLError.Code, String)
    case http(Int)
    /// The server sent fewer bytes than it said.
    case incomplete(received: Int64, expected: Int64)
    /// A 206 for another range, or a 416. The part file was emptied.
    case badRange
    case write(String)

    var isTransient: Bool {
        switch self {
        case .transport(let code, _):
            return ![.badURL, .unsupportedURL, .fileDoesNotExist, .noPermissionsToReadFile, .appTransportSecurityRequiresSecureConnection].contains(code)
        case .http(let status):
            return status >= 500 || status == 408 || status == 429
        case .incomplete, .badRange:
            return true
        case .write:
            return false
        }
    }

    func installError(url: URL, attempts: Int) -> KernelInstallError {
        let tries = attempts == 1 ? "1 try" : "\(attempts) tries"
        switch self {
        case .transport(let code, let text):
            let details = "\(url.absoluteString)\nURLError \(code.rawValue): \(text)\nStopped after \(tries)."
            if code == .timedOut { return .timedOut(details: details) }
            let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                                               .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
                                               .secureConnectionFailed, .cannotLoadFromNetwork]
            if offline.contains(code) { return .offline(details: details) }
            return .other(message: "The kernel download failed. Check your connection and try again.", details: details)
        case .http(let status):
            return .server(status: status, details: "\(url.absoluteString)\nHTTP \(status). Stopped after \(tries).")
        case .incomplete(let received, let expected):
            return .offline(details: "\(url.absoluteString)\nThe connection ended at \(received) of \(expected) bytes. Stopped after \(tries).")
        case .badRange:
            return .other(message: "The kernel download failed. Try again.", details: "\(url.absoluteString)\nThe server did not resume the download.")
        case .write(let text):
            return .other(message: "Could not save the kernel download. Check the free disk space.", details: text)
        }
    }
}

/// One GET into the part file, from `offset`, with Range resume and byte progress.
final class KernelHTTPFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle?
    private let offset: Int64
    private let expectedTotal: Int64?
    private let interval: TimeInterval
    private let onBytes: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var written: Int64
    private var totalBytes: Int64
    private var failure: KernelFetchFailure?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var lastReport = Date.distantPast

    /// Size of the whole archive once the server told us (0 before).
    var total: Int64 {
        lock.lock(); defer { lock.unlock() }
        return totalBytes
    }

    init(file: URL, offset: Int64, expectedTotal: Int64?, interval: TimeInterval, onBytes: @escaping @Sendable (Int64, Int64) -> Void) {
        handle = try? FileHandle(forWritingTo: file)
        try? handle?.truncate(atOffset: UInt64(offset))
        self.offset = offset
        self.expectedTotal = expectedTotal
        self.interval = interval
        self.onBytes = onBytes
        self.written = offset
        self.totalBytes = expectedTotal ?? 0
    }

    func run(_ url: URL, configuration: URLSessionConfiguration) async throws {
        guard handle != nil else { throw KernelFetchFailure.write("Could not open the download file.") }
        var request = URLRequest(url: url)
        request.setValue("ContainerDeck", forHTTPHeaderField: "User-Agent")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer {
            session.invalidateAndCancel()
            try? handle?.synchronize()
            try? handle?.close()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            lock.lock(); let task = self.task; lock.unlock()
            task?.cancel()
        }
    }

    // Keep the Range header when GitHub redirects to its file host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if offset > 0 { next.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        switch status {
        case 206:
            let range = Self.contentRange(http?.value(forHTTPHeaderField: "Content-Range"))
            guard let range, range.start == offset else {
                fail(.badRange, truncate: true)
                completionHandler(.cancel)
                return
            }
            if let total = range.total { setTotal(total) }
            completionHandler(.allow)
        case 200:
            // The server ignored Range: start the file again.
            if offset > 0 {
                try? handle?.truncate(atOffset: 0)
                lock.lock(); written = 0; lock.unlock()
            }
            if response.expectedContentLength > 0 { setTotal(response.expectedContentLength) }
            completionHandler(.allow)
        case 416:
            fail(.badRange, truncate: true)
            completionHandler(.cancel)
        default:
            fail(.http(status), truncate: false)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            fail(.write(error.localizedDescription), truncate: false)
            dataTask.cancel()
            return
        }
        lock.lock()
        written += Int64(data.count)
        let value = written
        let total = totalBytes
        let now = Date()
        let report = now.timeIntervalSince(lastReport) >= interval
        if report { lastReport = now }
        lock.unlock()
        if report { onBytes(value, total) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        let value = written
        let total = totalBytes
        lock.unlock()
        onBytes(value, total)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error = error as? URLError, error.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error = error as? URLError {
            continuation?.resume(throwing: KernelFetchFailure.transport(error.code, error.localizedDescription))
        } else if let error {
            continuation?.resume(throwing: KernelFetchFailure.transport(.unknown, error.localizedDescription))
        } else if total > 0, value != total {
            continuation?.resume(throwing: KernelFetchFailure.incomplete(received: value, expected: total))
        } else {
            continuation?.resume()
        }
    }

    private func fail(_ failure: KernelFetchFailure, truncate: Bool) {
        if truncate { try? handle?.truncate(atOffset: 0) }
        lock.lock()
        if self.failure == nil { self.failure = failure }
        if truncate { written = 0 }
        lock.unlock()
    }

    private func setTotal(_ total: Int64) {
        lock.lock(); totalBytes = total; lock.unlock()
    }

    /// "bytes 100-199/1000" -> (100, 1000). Total is nil for "*".
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = header.dropFirst(6)
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard let span = parts.first, let startText = span.split(separator: "-").first,
              let start = Int64(startText.trimmingCharacters(in: .whitespaces)) else { return nil }
        let total = parts.count > 1 ? Int64(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (start, total)
    }
}

/// Download speed over the last few seconds.
final class SpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private let window: TimeInterval = 4

    /// Adds a sample and returns bytes per second (0 until there are two samples).
    func add(_ bytes: Int64, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        lock.lock(); defer { lock.unlock() }
        samples.append((time, bytes))
        samples.removeAll { time - $0.time > window }
        guard let first = samples.first, samples.count > 1, time > first.time else { return 0 }
        return max(0, Double(bytes - first.bytes) / (time - first.time))
    }
}

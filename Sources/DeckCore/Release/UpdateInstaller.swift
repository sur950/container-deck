import Foundation

/// Downloads, checks and unpacks a release, then hands the swap to a detached script.
/// No UI here. The app layer shows progress and quits after `handOff`.
public struct UpdateInstaller: Sendable {
    public enum Step: Sendable, Equatable {
        /// Fraction 0...1, nil while the size is unknown.
        case downloading(Double?)
        case verifyingChecksum
        /// Checking the Ed25519 signature of the disk image.
        case verifyingUpdateSignature
        case mounting
        case verifyingSignature
        case ready
    }

    /// A verified new app, ready for `handOff`.
    public struct Prepared: Sendable, Equatable {
        public let app: URL
        public let diskImage: URL
        public let workDir: URL
        public let version: String
        public let trust: UpdateTrustDecision
        public let checksumVerified: Bool
        public let signatureVerified: Bool
    }

    public let runner: CommandRunning
    public let session: URLSession
    public let workRoot: URL
    /// Ed25519 public key (base64) that release disk images must be signed with.
    public let publicKey: String
    /// Reads the leaf certificate hash of signed code. Swappable for tests.
    public let certificateHash: @Sendable (URL) -> String?

    public init(runner: CommandRunning = ProcessRunner(), session: URLSession = .shared,
                workRoot: URL = FileManager.default.temporaryDirectory,
                publicKey: String = AppConfig.updatePublicKey,
                certificateHash: @escaping @Sendable (URL) -> String? = { SigningCertificate.leafHash(of: $0) }) {
        self.runner = runner
        self.session = session
        self.workRoot = workRoot
        self.publicKey = publicKey
        self.certificateHash = certificateHash
    }

    /// False when this build has no update key: never install by itself, open the download page.
    public var canInstallAutomatically: Bool { UpdateSignature.isConfigured(publicKey: publicKey) }

    /// A fresh temporary folder for one update.
    public func makeWorkDir() throws -> URL {
        let dir = workRoot.appendingPathComponent("\(AppConfig.bundleID).update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Whole flow

    /// Download, checksum, update signature, mount, find the app, verify its code signature, copy it out.
    /// Refuses to start when this build has no update public key.
    /// - Parameters:
    ///   - runningApp: the bundle that will be replaced (for the certificate check). nil for dev builds.
    public func prepare(
        release: AppRelease,
        expectedBundleID: String,
        currentVersion: String?,
        runningApp: URL?,
        progress: @escaping @Sendable (Step) -> Void
    ) async throws -> Prepared {
        guard canInstallAutomatically else { throw UpdateInstallError.updatesNotSigned }
        guard let asset = UpdateAssets.pickInstallAsset(release.assets) else { throw UpdateInstallError.noDiskImage }
        guard UpdateAssets.signatureAsset(for: asset, in: release.assets) != nil else { throw UpdateInstallError.updateSignatureMissing }
        guard UpdateAssets.checksumAsset(for: asset, in: release.assets) != nil else { throw UpdateInstallError.checksumMissing }
        let work = try makeWorkDir()
        do {
            let (dmg, verified) = try await downloadVerified(asset: asset, release: release, into: work, progress: progress)

            progress(.mounting)
            let app = try await extractApp(from: dmg, into: work)

            progress(.verifyingSignature)
            let trust = try await verify(app: app, expectedBundleID: expectedBundleID,
                                         currentVersion: currentVersion, runningApp: runningApp)
            progress(.ready)
            let version = Self.bundleValue(app, "CFBundleShortVersionString") ?? release.version.description
            return Prepared(app: app, diskImage: dmg, workDir: work, version: version, trust: trust,
                            checksumVerified: verified, signatureVerified: true)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Download the asset, check it against "<asset>.sha256" when the release has one, and,
    /// when this build has an update key, require a valid Ed25519 signature in "<asset>.sig".
    /// Returns the file and whether a checksum was checked.
    public func downloadVerified(asset: ReleaseAsset, release: AppRelease, into dir: URL,
                                 progress: @escaping @Sendable (Step) -> Void) async throws -> (URL, Bool) {
        let sigAsset = UpdateAssets.signatureAsset(for: asset, in: release.assets)
        if canInstallAutomatically && sigAsset == nil { throw UpdateInstallError.updateSignatureMissing }

        progress(.downloading(0))
        let file = try await download(asset.url, to: dir.appendingPathComponent(asset.name)) { fraction in
            progress(.downloading(fraction))
        }
        var checked = false
        if let sumAsset = UpdateAssets.checksumAsset(for: asset, in: release.assets) {
            progress(.verifyingChecksum)
            let text = try await fetchText(sumAsset.url)
            guard let expected = UpdateChecksum.parse(text, fileName: asset.name) else {
                throw UpdateInstallError.checksumUnreadable
            }
            try UpdateChecksum.verify(file: file, expected: expected)
            checked = true
        }
        if canInstallAutomatically, let sigAsset {
            progress(.verifyingUpdateSignature)
            let text = try await fetchText(sigAsset.url)
            try UpdateSignature.verify(file: file, signatureText: text, publicKey: publicKey)
        }
        return (file, checked)
    }

    // MARK: Download

    /// Downloads `url` to `destination` with progress. Works for https and file URLs.
    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("ContainerDeck", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("ContainerDeck", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateInstallError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateInstallError.downloadFailed("The server answered \(http.statusCode).")
        }
        guard data.count < 1 << 20, let text = String(data: data, encoding: .utf8) else { throw UpdateInstallError.checksumUnreadable }
        return text
    }

    // MARK: Disk image

    /// Mounts the image read only, copies the app out with `ditto`, then detaches.
    public func extractApp(from dmg: URL, into dir: URL) async throws -> URL {
        let mount = dir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        var attach = try await runner.run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path
        ])
        if !attach.succeeded {
            // hdiutil attach is deprecated on newer macOS. diskutil image is the replacement.
            let modern = try? await runner.run("/usr/sbin/diskutil", [
                "image", "attach", "--mountOptions", "nobrowse", "--readOnly", "--mountPoint", mount.path, dmg.path
            ])
            if let modern, modern.succeeded { attach = modern }
        }
        guard attach.succeeded else { throw UpdateInstallError.mountFailed(attach.failureMessage) }

        let result: Result<URL, Error>
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: mount.path)
            guard let name = UpdateLocation.pickAppBundle(names) else { throw UpdateInstallError.appNotFound }
            let out = dir.appendingPathComponent("new", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let copy = out.appendingPathComponent(name)
            let ditto = try await runner.run("/usr/bin/ditto", [mount.appendingPathComponent(name).path, copy.path])
            guard ditto.succeeded else { throw UpdateInstallError.mountFailed(ditto.failureMessage) }
            result = .success(copy)
        } catch {
            result = .failure(error)
        }

        let detach = try? await runner.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        if detach?.succeeded != true {
            let forced = try? await runner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            if forced?.succeeded != true {
                _ = try? await runner.run("/usr/sbin/diskutil", ["unmount", "force", mount.path])
            }
        }
        try? FileManager.default.removeItem(at: mount)
        return try result.get()
    }

    // MARK: Signature

    public func codeSignInfo(of url: URL) async -> CodeSignInfo {
        guard let result = try? await runner.run("/usr/bin/codesign", ["-dv", "--verbose=2", url.path]) else {
            return .unsigned
        }
        var info = CodeSignInfo.parse(result.stderr + "\n" + result.stdout)
        if info.isSigned && !info.isAdHoc {
            info.leafCertificateHash = certificateHash(url)
        }
        return info
    }

    /// Strict signature check, bundle id, signing certificate and version. Throws when the app must not be installed.
    @discardableResult
    public func verify(app: URL, expectedBundleID: String, currentVersion: String?, runningApp: URL?) async throws -> UpdateTrustDecision {
        let check = try await runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.succeeded else { throw UpdateInstallError.signatureInvalid(check.failureMessage) }

        let candidate = await codeSignInfo(of: app)
        let running: CodeSignInfo? = runningApp == nil ? nil : await codeSignInfo(of: runningApp!)
        let decision = UpdateTrust.evaluate(running: running, candidate: candidate,
                                            candidateBundleID: Self.bundleValue(app, "CFBundleIdentifier"),
                                            expectedBundleID: expectedBundleID)
        if case .rejected(let reason) = decision { throw UpdateInstallError.rejected(reason) }

        let version = Self.bundleValue(app, "CFBundleShortVersionString")
        guard UpdateTrust.isAcceptableVersion(candidate: version, current: currentVersion) else {
            throw UpdateInstallError.versionNotNewer(version ?? "unknown")
        }
        return decision
    }

    /// Reads Info.plist directly (Bundle caches by path, which is wrong for a fresh copy).
    public static func bundleValue(_ app: URL, _ key: String) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return dict[key] as? String
    }

    // MARK: Hand off

    /// Writes the install script and starts it detached with nohup. The caller must quit right after.
    @discardableResult
    public func handOff(_ prepared: Prepared, replacing target: URL, pid: Int32, logFile: URL) throws -> UpdateInstallScript {
        let script = UpdateInstallScript(pid: pid, newApp: prepared.app.path, target: target.path,
                                         workDir: prepared.workDir.path, logFile: logFile.path)
        let scriptURL = prepared.workDir.appendingPathComponent("install.sh")
        do {
            try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = ["/bin/sh", scriptURL.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            try process.run()
        } catch {
            throw UpdateInstallError.handOffFailed(error.localizedDescription)
        }
        return script
    }
}

/// URLSession download delegate that reports progress and moves the file into place.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double?) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private let lock = NSLock()

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so move it now.
        let outcome: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            outcome = .failure(UpdateInstallError.downloadFailed("The server answered \(http.statusCode)."))
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                outcome = .success(destination)
            } catch {
                outcome = .failure(UpdateInstallError.downloadFailed(error.localizedDescription))
            }
        }
        lock.lock(); result = outcome; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let outcome = result
        lock.unlock()
        guard let pending else { return }
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            pending.resume(throwing: cancelled ? CancellationError() : UpdateInstallError.downloadFailed(error.localizedDescription))
        } else if let outcome {
            if case .success = outcome { progress(1) }
            pending.resume(with: outcome)
        } else {
            pending.resume(throwing: UpdateInstallError.downloadFailed("No file was received."))
        }
    }
}

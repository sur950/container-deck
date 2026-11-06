import Foundation
import Security
import CryptoKit

/// The proxy's own certificate authority, made with /usr/bin/openssl.
/// The CA key never leaves `directory` (Application Support, owner only).
/// Leaf certificates are made per name on first use and kept for reuse.
/// Trust is a separate step the person starts with a button (`trust`), never automatic.
public actor LocalCertificateAuthority {
    public let directory: URL
    let runner: any CommandRunning
    private var identities: [String: SecIdentity] = [:]
    /// Password of the PKCS#12 files on disk. They only live in the owner only folder.
    private let bundlePassword = "container-deck"

    public init(directory: URL = DomainsConfig.certificatesDirectory(), runner: any CommandRunning = ProcessRunner()) {
        self.directory = directory
        self.runner = runner
    }

    public nonisolated var caCertificateURL: URL { directory.appendingPathComponent("ca.pem") }
    nonisolated var caKeyURL: URL { directory.appendingPathComponent("ca.key") }
    nonisolated var leavesDirectory: URL { directory.appendingPathComponent("leaves", isDirectory: true) }

    public nonisolated var exists: Bool {
        FileManager.default.fileExists(atPath: caCertificateURL.path)
            && FileManager.default.fileExists(atPath: caKeyURL.path)
    }

    // MARK: - CA

    /// Makes the CA when it does not exist yet. Returns true when it made a new one.
    @discardableResult
    public func createIfNeeded() async throws -> Bool {
        if exists { return false }
        try prepareDirectory(directory)
        try? FileManager.default.removeItem(at: leavesDirectory)
        identities = [:]
        try await openssl(Self.caArguments(key: caKeyURL.path, certificate: caCertificateURL.path))
        try restrict(caKeyURL)
        return true
    }

    /// Deletes the CA and every leaf. Remove trust first (`untrustArguments`).
    public func reset() throws {
        identities = [:]
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func caArguments(key: String, certificate: String) -> [String] {
        [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-keyout", key, "-out", certificate,
            "-days", String(DomainsConfig.caValidityDays),
            "-subj", "/CN=\(DomainsConfig.caCommonName)/O=\(AppConfig.appName)",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-addext", "subjectKeyIdentifier=hash",
        ]
    }

    // MARK: - Leaf certificates

    /// TLS identity for one name. Made and signed on first use.
    public func identity(for name: String) async throws -> SecIdentity {
        let name = HostName.normalize(name)
        guard HostName.isValidName(name) || HostName.isValidLabel(name) else {
            throw DeckError.commandFailed("\(name) is not a valid name for a certificate.")
        }
        if let cached = identities[name] { return cached }
        guard exists else { throw DeckError.commandFailed("Create the local certificate authority first.") }
        let bundle = leavesDirectory.appendingPathComponent("\(name).p12")
        let pem = leavesDirectory.appendingPathComponent("\(name).pem")
        if !(await isFresh(pem)) || !FileManager.default.fileExists(atPath: bundle.path) {
            try await makeLeaf(name: name, bundle: bundle, pem: pem)
        }
        let identity = try Self.importIdentity(Data(contentsOf: bundle), password: bundlePassword)
        identities[name] = identity
        return identity
    }

    /// Path of the leaf certificate for a name, once made.
    public nonisolated func leafCertificateURL(for name: String) -> URL {
        leavesDirectory.appendingPathComponent("\(HostName.normalize(name)).pem")
    }

    private func isFresh(_ pem: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: pem.path) else { return false }
        // Still valid for at least a day.
        let result = try? await runner.run(DomainsConfig.opensslPath, ["x509", "-checkend", "86400", "-noout", "-in", pem.path])
        return result?.succeeded == true
    }

    private func makeLeaf(name: String, bundle: URL, pem: URL) async throws {
        try prepareDirectory(leavesDirectory)
        let base = leavesDirectory.appendingPathComponent(name)
        let key = base.appendingPathExtension("key")
        let csr = base.appendingPathExtension("csr")
        let ext = base.appendingPathExtension("ext")
        defer {
            try? FileManager.default.removeItem(at: csr)
            try? FileManager.default.removeItem(at: ext)
        }
        try Self.leafExtensions(name: name).write(to: ext, atomically: true, encoding: .utf8)
        try await openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", csr.path, "-subj", "/CN=\(name)"])
        try restrict(key)
        try await openssl([
            "x509", "-req", "-sha256", "-in", csr.path,
            "-CA", caCertificateURL.path, "-CAkey", caKeyURL.path,
            "-set_serial", Self.randomSerial(),
            "-days", String(DomainsConfig.leafValidityDays),
            "-extfile", ext.path, "-out", pem.path,
        ])
        try await openssl([
            "pkcs12", "-export", "-inkey", key.path, "-in", pem.path, "-certfile", caCertificateURL.path,
            "-name", name, "-out", bundle.path, "-passout", "pass:\(bundlePassword)",
        ])
        try restrict(bundle)
    }

    static func leafExtensions(name: String) -> String {
        """
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=DNS:\(name)
        authorityKeyIdentifier=keyid
        subjectKeyIdentifier=hash

        """
    }

    static func randomSerial() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        bytes[0] &= 0x7F // positive
        bytes[0] |= 0x01
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads a PKCS#12 bundle into memory only. Nothing is added to a keychain.
    static func importIdentity(_ data: Data, password: String) throws -> SecIdentity {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let list = items as? [[String: Any]],
              let first = list.first,
              let value = first[kSecImportItemIdentity as String] else {
            throw DeckError.commandFailed("Could not read the certificate for the proxy (error \(status)).")
        }
        return value as! SecIdentity // CFType bridge, the key is always a SecIdentity
    }

    // MARK: - Trust

    /// True when macOS trusts the CA for this user (the person approved it once).
    public nonisolated func isTrusted() -> Bool {
        guard let certificate = Self.loadCertificate(caCertificateURL) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// SHA-1 of the CA certificate, used to find and delete it in a keychain.
    public nonisolated func caFingerprint() -> String? {
        guard let certificate = Self.loadCertificate(caCertificateURL) else { return nil }
        return Self.sha1Hex(SecCertificateCopyData(certificate) as Data)
    }

    /// `security add-trusted-cert` for the login keychain. macOS asks the person to approve.
    public nonisolated func trustArguments(keychain: String = LocalCertificateAuthority.loginKeychainPath()) -> [String] {
        ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, caCertificateURL.path]
    }

    /// Removes the trust setting and the CA from the keychain.
    public nonisolated func untrustArguments(keychain: String = LocalCertificateAuthority.loginKeychainPath()) -> [[String]] {
        var commands = [["remove-trusted-cert", caCertificateURL.path]]
        if let fingerprint = caFingerprint() {
            commands.append(["delete-certificate", "-Z", fingerprint, keychain])
        }
        return commands
    }

    /// Asks macOS to trust the CA. Only call from a button the person pressed.
    public func trust() async throws {
        try await runner.run(DomainsConfig.securityPath, trustArguments()).orThrow()
    }

    public func untrust() async throws {
        for args in untrustArguments() {
            let result = try await runner.run(DomainsConfig.securityPath, args)
            // Already gone is fine.
            if !result.succeeded && !result.stderr.lowercased().contains("could not be found")
                && !result.stderr.lowercased().contains("no matching") && !result.stderr.lowercased().contains("not found") {
                try result.orThrow()
            }
        }
    }

    public static func loginKeychainPath() -> String {
        NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
    }

    // MARK: - Helpers

    static func loadCertificate(_ url: URL) -> SecCertificate? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let body = text
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    static func sha1Hex(_ data: Data) -> String {
        // Insecure.SHA1 is fine here: it is only an index into the keychain, like `security -Z`.
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private func openssl(_ arguments: [String]) async throws {
        try await runner.run(DomainsConfig.opensslPath, arguments).orThrow()
    }

    private func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func restrict(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

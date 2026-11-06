import Foundation
import Security

/// TLS material for one cluster: the CA to trust and the client identity to present.
/// The identity is built in memory only. Nothing is added to the keychain.
public final class KubeTLS: @unchecked Sendable {
    public let anchor: SecCertificate?
    public let identity: SecIdentity?
    public let insecure: Bool

    init(anchor: SecCertificate?, identity: SecIdentity?, insecure: Bool) {
        self.anchor = anchor
        self.identity = identity
        self.insecure = insecure
    }

    /// Reads the CA and, when the kubeconfig has a client certificate, makes a
    /// PKCS#12 bundle with /usr/bin/openssl and imports it in memory.
    public static func make(
        _ credentials: KubeConfigFile.Credentials,
        runner: any CommandRunning = ProcessRunner(),
        openssl: String = "/usr/bin/openssl"
    ) async throws -> KubeTLS {
        let anchor = credentials.certificateAuthority.flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var identity: SecIdentity?
        if let cert = credentials.clientCertificatePEM, let key = credentials.clientKeyPEM {
            let p12 = try await pkcs12(certificatePEM: cert, keyPEM: key, runner: runner, openssl: openssl)
            identity = try importIdentity(p12.data, passphrase: p12.passphrase)
        }
        return KubeTLS(anchor: anchor, identity: identity, insecure: credentials.insecureSkipTLSVerify)
    }

    /// Arguments for `openssl pkcs12 -export`. 3DES and SHA1 are what Security reads on every macOS.
    static func pkcs12Arguments(certificate: String, key: String, passFile: String, output: String) -> [String] {
        [
            "pkcs12", "-export",
            "-in", certificate, "-inkey", key,
            "-passout", "file:\(passFile)",
            "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            "-out", output,
        ]
    }

    static func pkcs12(certificatePEM: Data, keyPEM: Data, runner: any CommandRunning, openssl: String) async throws -> (data: Data, passphrase: String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-k8s-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? FileManager.default.removeItem(at: folder) }

        let passphrase = UUID().uuidString
        let certFile = folder.appendingPathComponent("client.crt")
        let keyFile = folder.appendingPathComponent("client.key")
        let passFile = folder.appendingPathComponent("pass")
        let outFile = folder.appendingPathComponent("client.p12")
        for (file, data) in [(certFile, certificatePEM), (keyFile, keyPEM), (passFile, Data(passphrase.utf8))] {
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
                throw DeckError.commandFailed("Could not prepare the cluster certificate.")
            }
        }
        let result = try await runner.run(openssl, pkcs12Arguments(
            certificate: certFile.path, key: keyFile.path, passFile: passFile.path, output: outFile.path
        ))
        guard result.succeeded, let data = try? Data(contentsOf: outFile), !data.isEmpty else {
            throw DeckError.commandFailed("Could not read the cluster's client certificate. \(result.failureMessage)")
        }
        return (data, passphrase)
    }

    static func importIdentity(_ data: Data, passphrase: String) throws -> SecIdentity {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let list = items as? [[String: Any]],
              let first = list.first,
              let value = first[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw DeckError.commandFailed("Could not load the cluster's client certificate (error \(status)).")
        }
        // The type ID was checked above.
        return value as! SecIdentity
    }

    // MARK: - Trust

    /// Checks the server against the cluster CA only (not the system roots).
    func evaluate(_ trust: SecTrust, host: String) -> Bool {
        if insecure { return true }
        guard let anchor else {
            return SecTrustEvaluateWithError(trust, nil)
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }
}

import Foundation
import CryptoKit
import Security

// Update signing without Apple's Developer Program.
//
// 1. Ed25519: the Release workflow signs the raw 32 byte SHA-256 digest of the disk image
//    with the private key (UPDATE_SIGNING_KEY secret) and publishes "<dmg>.sig" (base64).
//    The app checks it against AppConfig.updatePublicKey before it installs anything.
// 2. Code signing certificate: every release is signed with the same free self signed
//    certificate. The new app's leaf certificate must be the running app's leaf certificate.

// MARK: - Ed25519

public enum UpdateSignature {
    /// True when this build has a public key, so it may install updates by itself.
    public static func isConfigured(publicKey: String = AppConfig.updatePublicKey) -> Bool {
        !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reads a base64 public key (32 raw bytes).
    public static func publicKey(base64: String) throws -> Curve25519.Signing.PublicKey {
        let text = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw UpdateInstallError.updatesNotSigned }
        guard let data = Data(base64Encoded: text),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
            throw UpdateInstallError.updateSignatureInvalid("The update key in this build is not valid.")
        }
        return key
    }

    /// Reads a "<dmg>.sig" file: base64 of the 64 byte signature. Blank lines and "#" comments are ignored.
    public static func parseSignature(_ text: String) -> Data? {
        let body = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined()
        guard let data = Data(base64Encoded: body), data.count == 64 else { return nil }
        return data
    }

    /// Signs a SHA-256 digest. Used by tests and scripts/update_signer.swift does the same.
    public static func sign(digest: Data, with key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: digest).base64EncodedString()
    }

    /// Throws unless `signatureText` is a valid signature of `digest` by `publicKey`.
    public static func verify(digest: Data, signatureText: String?, publicKey: String) throws {
        let key = try self.publicKey(base64: publicKey)
        guard let signatureText else { throw UpdateInstallError.updateSignatureMissing }
        guard let signature = parseSignature(signatureText) else {
            throw UpdateInstallError.updateSignatureInvalid("The signature file could not be read.")
        }
        guard key.isValidSignature(signature, for: digest) else {
            throw UpdateInstallError.updateSignatureInvalid("It was not signed with this app's update key.")
        }
    }

    /// Hashes `file` and checks its signature.
    public static func verify(file: URL, signatureText: String?, publicKey: String) throws {
        try verify(digest: UpdateChecksum.sha256Digest(of: file), signatureText: signatureText, publicKey: publicKey)
    }
}

// MARK: - Signing certificate

public enum SigningCertificate {
    /// SHA-256 (lowercase hex) of the leaf certificate the code at `url` is signed with.
    /// nil for ad hoc and unsigned code, or when the signature cannot be read.
    public static func leafHash(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

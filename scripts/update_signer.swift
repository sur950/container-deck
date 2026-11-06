// Ed25519 update signing with CryptoKit. No Apple Developer Program needed.
// Run with the Swift that ships with Xcode:
//
//   swift scripts/update_signer.swift keygen DIR          new key pair: DIR/update_private_key.txt, DIR/update_public_key.txt
//   swift scripts/update_signer.swift public-key          public key (base64) of the private key
//   swift scripts/update_signer.swift sign FILE           base64 signature of the SHA-256 digest of FILE
//   swift scripts/update_signer.swift verify FILE SIG PUB checks SIG (a .sig file) against base64 key PUB
//
// The private key (base64 of 32 raw bytes) is read from UPDATE_SIGNING_KEY, or from the file
// named by UPDATE_SIGNING_KEY_FILE. The app checks signatures the same way in
// Sources/DeckCore/Release/UpdateSignature.swift: the message is the raw 32 byte SHA-256 digest.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func digest(of path: String) -> Data {
    guard let handle = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    let env = ProcessInfo.processInfo.environment
    var text = env["UPDATE_SIGNING_KEY"] ?? ""
    if text.isEmpty, let file = env["UPDATE_SIGNING_KEY_FILE"], !file.isEmpty {
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { fail("cannot read \(file)") }
        text = contents
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { fail("set UPDATE_SIGNING_KEY or UPDATE_SIGNING_KEY_FILE") }
    guard let data = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("the private key is not base64 of 32 bytes")
    }
    return key
}

func write(_ text: String, to path: String, mode: Int) {
    guard FileManager.default.createFile(atPath: path, contents: Data((text + "\n").utf8),
                                         attributes: [.posixPermissions: mode]) else { fail("cannot write \(path)") }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    guard args.count == 2 else { fail("usage: keygen DIR") }
    let dir = args[1]
    let privatePath = (dir as NSString).appendingPathComponent("update_private_key.txt")
    let publicPath = (dir as NSString).appendingPathComponent("update_public_key.txt")
    if FileManager.default.fileExists(atPath: privatePath) { fail("\(privatePath) exists. Move it away first.") }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    write(key.rawRepresentation.base64EncodedString(), to: privatePath, mode: 0o600)
    write(key.publicKey.rawRepresentation.base64EncodedString(), to: publicPath, mode: 0o644)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public-key":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2 else { fail("usage: sign FILE") }
    let key = privateKey()
    let message = digest(of: args[1])
    guard let signature = try? key.signature(for: message) else { fail("signing failed") }
    guard key.publicKey.isValidSignature(signature, for: message) else { fail("the new signature does not verify") }
    print(signature.base64EncodedString())
case "verify":
    guard args.count == 4 else { fail("usage: verify FILE SIGFILE PUBLIC_KEY_BASE64") }
    guard let sigText = try? String(contentsOfFile: args[2], encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("cannot read the signature in \(args[2])")
    }
    guard let keyData = Data(base64Encoded: args[3].trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("the public key is not valid") }
    guard key.isValidSignature(signature, for: digest(of: args[1])) else { fail("signature does NOT match") }
    print("signature OK")
default:
    fail("usage: update_signer.swift keygen DIR | public-key | sign FILE | verify FILE SIGFILE PUBLIC_KEY")
}

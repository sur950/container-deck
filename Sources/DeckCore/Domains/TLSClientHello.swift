import Foundation

/// Reads the server name (SNI) from the first bytes a TLS client sends.
/// The proxy peeks at it to pick the certificate for that name. Pure, unit tested.
public enum TLSClientHello {
    public enum Result: Equatable, Sendable {
        case needMoreData
        case serverName(String)
        case noServerName
        case notTLS
    }

    /// Largest first record we wait for (one TLS record plus its header).
    public static let maximumLength = 16_384 + 5

    public static func parse(_ data: Data) -> Result {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { return .needMoreData }
        guard first == 0x16 else { return .notTLS }            // handshake record
        guard bytes.count >= 5 else { return .needMoreData }
        guard bytes[1] == 0x03 else { return .notTLS }          // TLS 1.x record version
        let recordLength = Int(bytes[3]) << 8 | Int(bytes[4])
        guard recordLength > 0, recordLength <= 16_384 else { return .notTLS }
        guard bytes.count >= 5 + recordLength else { return .needMoreData }
        return parseHandshake(Array(bytes[5..<(5 + recordLength)]))
    }

    private static func parseHandshake(_ b: [UInt8]) -> Result {
        var reader = Reader(bytes: b)
        guard let type = reader.u8(), type == 0x01 else { return .notTLS } // ClientHello
        guard reader.u24() != nil else { return .notTLS }
        guard reader.skip(2 + 32) else { return .notTLS }                   // version, random
        guard let sessionLength = reader.u8(), reader.skip(Int(sessionLength)) else { return .notTLS }
        guard let suitesLength = reader.u16(), reader.skip(suitesLength) else { return .notTLS }
        guard let compressionLength = reader.u8(), reader.skip(Int(compressionLength)) else { return .notTLS }
        guard let extensionsLength = reader.u16() else { return .noServerName }
        let end = min(reader.offset + extensionsLength, b.count)
        while reader.offset + 4 <= end {
            guard let extType = reader.u16(), let extLength = reader.u16() else { break }
            guard reader.offset + extLength <= end else { return .notTLS }
            if extType == 0x0000 {
                var ext = Reader(bytes: Array(b[reader.offset..<(reader.offset + extLength)]))
                guard let listLength = ext.u16() else { return .notTLS }
                let listEnd = min(ext.offset + listLength, ext.bytes.count)
                while ext.offset + 3 <= listEnd {
                    guard let nameType = ext.u8(), let nameLength = ext.u16() else { break }
                    guard ext.offset + nameLength <= listEnd else { return .notTLS }
                    if nameType == 0 {
                        let raw = Array(ext.bytes[ext.offset..<(ext.offset + nameLength)])
                        guard let name = String(bytes: raw, encoding: .ascii), !name.isEmpty else { return .notTLS }
                        return .serverName(name.lowercased())
                    }
                    _ = ext.skip(nameLength)
                }
                return .noServerName
            }
            _ = reader.skip(extLength)
        }
        return .noServerName
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func u8() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() -> Int? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }

        mutating func u24() -> Int? {
            guard offset + 3 <= bytes.count else { return nil }
            defer { offset += 3 }
            return Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, offset + count <= bytes.count else { return false }
            offset += count
            return true
        }
    }
}

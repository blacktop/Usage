import CryptoKit
import Foundation

/// Domain-separated SHA-256 over a field list.
///
/// Every field is length-prefixed, so no combination of separators in the field values can produce
/// the same byte stream as a different field list. That keeps derived identifiers injective.
enum DomainDigest {
    static func hex(domain: String, fields: [String]) -> String {
        var bytes = Data()
        append(domain, to: &bytes)
        for field in fields {
            append(field, to: &bytes)
        }
        return Hex.lowercased(SHA256.hash(data: bytes))
    }

    private static func append(_ field: String, to bytes: inout Data) {
        let utf8 = Data(field.utf8)
        bytes.append(contentsOf: Array("\(utf8.count):".utf8))
        bytes.append(utf8)
    }
}

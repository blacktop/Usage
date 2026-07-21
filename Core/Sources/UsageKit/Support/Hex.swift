/// Allocation-light hexadecimal encoding used by identifier derivation and token escaping.
enum Hex {
    private static let lowercase = Array("0123456789abcdef")
    private static let uppercase = Array("0123456789ABCDEF")

    static func lowercased(_ bytes: some Sequence<UInt8>) -> String {
        var out = ""
        for byte in bytes {
            out.append(lowercase[Int(byte >> 4)])
            out.append(lowercase[Int(byte & 0x0F)])
        }
        return out
    }

    static func uppercasedPair(_ byte: UInt8) -> String {
        var out = ""
        out.append(uppercase[Int(byte >> 4)])
        out.append(uppercase[Int(byte & 0x0F)])
        return out
    }

    static func isLowercaseDigest(_ string: String, byteCount: Int) -> Bool {
        guard string.utf8.count == byteCount * 2 else { return false }
        return string.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }
}

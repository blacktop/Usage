import Foundation

/// On-disk shape of the identity alias map.
///
/// Contains only derived identifiers and timestamps: no display label, no email, no credential
/// slot, and no credential material. Written by the app under the writer lock; read by anyone.
public struct IdentityAliasMapV1: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    /// One retired fallback identity and the canonical identity that replaced it.
    public struct Alias: Sendable, Hashable, Codable {
        public let providerID: String
        public let retiredAccountID: String
        public let canonicalAccountID: String
        public let recordedAt: Int64

        public init(
            providerID: String,
            retiredAccountID: String,
            canonicalAccountID: String,
            recordedAt: Int64
        ) {
            self.providerID = providerID
            self.retiredAccountID = retiredAccountID
            self.canonicalAccountID = canonicalAccountID
            self.recordedAt = recordedAt
        }
    }

    public let schemaVersion: Int
    /// Sorted by provider then retired identifier, so the encoded file is byte-stable.
    public let aliases: [Alias]

    public init(aliases: [Alias]) {
        schemaVersion = Self.currentSchemaVersion
        self.aliases = aliases.sorted {
            ($0.providerID, $0.retiredAccountID) < ($1.providerID, $1.retiredAccountID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, aliases
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        try SchemaVersion.check(version, upTo: Self.currentSchemaVersion, in: container)
        self.init(aliases: try container.decode([Alias].self, forKey: .aliases))
    }
}

enum SchemaVersion {
    static func check<Key>(
        _ version: Int,
        upTo current: Int,
        in container: KeyedDecodingContainer<Key>
    ) throws {
        guard version >= 1, version <= current else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription:
                        "Unsupported schema version \(version); this build reads 1…\(current)."
                )
            )
        }
    }
}

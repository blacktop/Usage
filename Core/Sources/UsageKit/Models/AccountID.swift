/// Opaque, SHA-256-derived account identity.
///
/// Never an email address, username, or display label: those are display metadata and change
/// independently of the account they describe. The `derivation` tag stays in the raw value because
/// identity reconciliation has to distinguish a canonical identity from the credential-slot
/// fallback that precedes it, and that distinction has to survive a round trip through history.
public struct AccountID: Sendable, Hashable, Codable, CustomStringConvertible {
    /// How the identifier was derived, which decides whether it can be retired by an alias.
    public enum Derivation: String, Sendable, Hashable, Codable, CaseIterable {
        /// Derived from a provider-supplied canonical account identifier.
        case canonical = "c1"
        /// Derived from a `CredentialSlotID`, used until a canonical identifier is observed.
        case credentialSlot = "s1"
    }

    private static let domain = "dev.blacktop.Usage/AccountID/v1"
    private static let digestByteCount = 32

    public let derivation: Derivation
    public let digest: String

    public var rawValue: String { "\(derivation.rawValue):\(digest)" }
    public var description: String { rawValue }

    private init(derivation: Derivation, digest: String) {
        self.derivation = derivation
        self.digest = digest
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let derivation = Derivation(rawValue: String(parts[0])) else {
            return nil
        }
        let digest = String(parts[1])
        guard Hex.isLowercaseDigest(digest, byteCount: Self.digestByteCount) else { return nil }
        self.init(derivation: derivation, digest: digest)
    }

    /// Derives the durable identity of an account the provider can name canonically.
    public static func canonical(provider: ProviderID, canonicalID: String) -> AccountID {
        AccountID(
            derivation: .canonical,
            digest: DomainDigest.hex(
                domain: domain,
                fields: [Derivation.canonical.rawValue, provider.rawValue, canonicalID]
            )
        )
    }

    /// Derives the fallback identity used until the provider supplies a canonical identifier.
    public static func credentialSlot(provider: ProviderID, slot: CredentialSlotID) -> AccountID {
        AccountID(
            derivation: .credentialSlot,
            digest: DomainDigest.hex(
                domain: domain,
                fields: [
                    Derivation.credentialSlot.rawValue, provider.rawValue, slot.source,
                    slot.opaqueID,
                ]
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let decoded = AccountID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Account identifier is not a tagged SHA-256 digest."
            )
        }
        self = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

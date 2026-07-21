/// Non-secret identity of one credential slot, as issued by the slot's own source.
///
/// A slot is "the Codex `auth.json` in this home directory" or "the Keychain item named
/// `Claude Code-credentials-1a2b3c4d`" — never the credential it holds.
///
/// Deliberately not `Codable`: slot identities are inputs to `AccountID` derivation only, and must
/// not reach history records, the alias map, or CLI output.
public struct CredentialSlotID: Sendable, Hashable {
    /// Namespace of the issuing source, e.g. `"file"` or `"keychain"`.
    public let source: String
    /// Source-scoped identity that contains no secret material.
    public let opaqueID: String

    public init(source: String, opaqueID: String) {
        self.source = source
        self.opaqueID = opaqueID
    }
}

import Foundation
import Testing

@testable import UsageKit

@Suite("Account identity derivation")
struct AccountIdentityTests {
    @Test("A canonical identifier never appears in the derived account identity")
    func canonicalIdentityIsOpaque() {
        let email = "person@example.com"
        let id = AccountID.canonical(provider: Fixtures.provider, canonicalID: email)
        #expect(!id.rawValue.contains("person"))
        #expect(!id.rawValue.contains("example"))
        #expect(!id.rawValue.contains("@"))
        #expect(id.derivation == .canonical)
        #expect(id.digest.count == 64)
    }

    @Test("Derivation is deterministic and provider-scoped")
    func derivationIsDeterministicPerProvider() {
        let a = AccountID.canonical(provider: ProviderID("codex"), canonicalID: "acct-1")
        let b = AccountID.canonical(provider: ProviderID("codex"), canonicalID: "acct-1")
        let other = AccountID.canonical(provider: ProviderID("claude"), canonicalID: "acct-1")
        #expect(a == b)
        #expect(a != other)
    }

    @Test("Canonical and credential-slot derivations never collide")
    func derivationsAreTagged() {
        let canonical = AccountID.canonical(provider: Fixtures.provider, canonicalID: "acct-1")
        let fallback = AccountID.credentialSlot(
            provider: Fixtures.provider,
            slot: Fixtures.slot("acct-1")
        )
        #expect(canonical != fallback)
        #expect(canonical.derivation == .canonical)
        #expect(fallback.derivation == .credentialSlot)
    }

    @Test("Field framing keeps derivation injective across separator-shaped inputs")
    func fieldFramingIsInjective() {
        let left = AccountID.credentialSlot(
            provider: Fixtures.provider,
            slot: CredentialSlotID(source: "a", opaqueID: "b:c")
        )
        let right = AccountID.credentialSlot(
            provider: Fixtures.provider,
            slot: CredentialSlotID(source: "a:b", opaqueID: "c")
        )
        #expect(left != right)
    }

    @Test("Identity round-trips through JSON and rejects a malformed digest")
    func identityRoundTripsAndValidates() throws {
        let id = AccountID.canonical(provider: Fixtures.provider, canonicalID: "acct-1")
        let encoded = try Fixtures.encodedString(id)
        #expect(encoded == "\"\(id.rawValue)\"")
        let decoded = try UsageJSON.decoder().decode(AccountID.self, from: Data(encoded.utf8))
        #expect(decoded == id)

        #expect(AccountID(rawValue: "c1:nothex") == nil)
        #expect(AccountID(rawValue: "zz:\(id.digest)") == nil)
        #expect(AccountID(rawValue: id.digest) == nil)
        #expect(throws: DecodingError.self) {
            try UsageJSON.decoder().decode(AccountID.self, from: Data("\"c1:short\"".utf8))
        }
    }

    /// A field-name diagnostic only. The boundary itself is asserted in `CredentialBoundaryTests`.
    @Test("A provider account carries exactly the six non-secret fields it declares")
    func providerAccountFieldsAreSecretFree() {
        let account = Fixtures.account(
            key: Fixtures.canonicalKey("alpha"),
            slot: Fixtures.slot("alpha"),
            displayName: "alpha@example.com"
        )
        let mirrored = Mirror(reflecting: account).children.compactMap(\.label)
        #expect(
            mirrored
                == [
                    "key", "slot", "locator", "profileRootID", "displayName", "availability",
                ]
        )
        #expect(String(describing: Credential(secret: "sk-live-abc")) == "Credential(redacted)")
    }
}

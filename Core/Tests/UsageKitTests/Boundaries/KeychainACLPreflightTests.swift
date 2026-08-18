import Foundation
import Security
import Testing

@testable import UsageKit

@Suite("Keychain ACL preflight")
struct KeychainACLPreflightTests {
    @Test("an entry that may prompt regardless of the caller never counts as allowed")
    func promptSelectorFailsClosed() {
        #expect(
            !KeychainACLPreflight.entryAllows(
                promptSelector: 1,
                trustedApplicationValidations: nil
            )
        )
        #expect(
            !KeychainACLPreflight.entryAllows(
                promptSelector: 0x0002,
                trustedApplicationValidations: [true]
            )
        )
    }

    @Test("an entry with no application list restricts nobody")
    func unrestrictedEntryAllows() {
        #expect(
            KeychainACLPreflight.entryAllows(
                promptSelector: 0,
                trustedApplicationValidations: nil
            )
        )
    }

    @Test("an explicit list requires at least one stored requirement to validate")
    func explicitListRequiresOneValidation() {
        #expect(
            KeychainACLPreflight.entryAllows(
                promptSelector: 0,
                trustedApplicationValidations: [false, true]
            )
        )
        #expect(
            !KeychainACLPreflight.entryAllows(
                promptSelector: 0,
                trustedApplicationValidations: [false, false]
            )
        )
        #expect(
            !KeychainACLPreflight.entryAllows(
                promptSelector: 0,
                trustedApplicationValidations: []
            ),
            "an empty list names nobody, and nobody includes this process"
        )
    }

    @Test("the preflight query asks for attributes and the reference, never the secret")
    func preflightQueryCannotPrompt() throws {
        let reference = try #require(KeychainItemReference(identifier: "cmVmZXJlbmNl"))
        let query = KeychainCredentialSource.preflightQuery(reference: reference)

        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecReturnRef as String] as? Bool == true)
        #expect(query[kSecValuePersistentRef as String] as? Data == reference.data)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }
}

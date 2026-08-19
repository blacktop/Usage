/// A credential store whose contents belong to Usage rather than to another application.
///
/// Providers still receive secrets only through `CredentialSource.withCredential`, with one
/// reviewed exception: `readCredential(at:)` hands back the payload of a Usage-owned row so the
/// Claude token refresher can exchange the mirrored refresh token and store its replacement —
/// bytes that never leave that one flow. This narrower surface exists for explicit Settings
/// actions and the refresher, and deliberately accepts only `.appKeychain` locators in the
/// production implementation.
public protocol ManagedCredentialStore: Sendable {
    func containsCredential(at locator: CredentialLocator) -> Bool

    /// The stored payload, or `nil` when the row is absent or unreadable without UI.
    func readCredential(at locator: CredentialLocator) -> String?

    func storeCredential(
        _ secret: String,
        at locator: CredentialLocator
    ) throws(ManagedCredentialStoreError)

    func removeCredential(at locator: CredentialLocator) throws(ManagedCredentialStoreError)
}

/// A redacted failure from an explicit Usage-owned credential mutation.
public enum ManagedCredentialStoreError: Error, Sendable, Equatable {
    case invalidCredential
    case storageUnavailable
}

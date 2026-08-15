/// A credential store whose contents belong to Usage rather than to another application.
///
/// Providers still receive secrets only through `CredentialSource.withCredential`. This narrower
/// mutation surface exists for explicit Settings actions and deliberately accepts only
/// `.appKeychain` locators in the production implementation.
public protocol ManagedCredentialStore: Sendable {
    func containsCredential(at locator: CredentialLocator) -> Bool

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

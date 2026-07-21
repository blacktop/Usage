/// Asynchronous persistence for the complete non-secret profile-root collection.
public protocol ProfileRootStore: Sendable {
    func load() async throws(ProfileRootStoreError) -> ProfileRootCollection
    func save(_ profiles: ProfileRootCollection) async throws(ProfileRootStoreError)
}

/// Recoverable failures from profile-root persistence.
public enum ProfileRootStoreError: Error, Sendable, Equatable {
    case corruptPayload
    case unsupportedSchemaVersion(Int)
    case storageUnavailable
    case invalidDefaultRoots(ProfileRootValidationError)
}

import Foundation

@testable import UsageKit

/// Builds the explicit root collections the multi-root and disabled-root proofs need.
///
/// A context that takes the default store gets the seeded roots under its own fake home, which is
/// what keeps the single-root suites readable. Anything that needs a second root, a relocated root,
/// or a disabled one names the whole collection here instead, so the assertion is about the roots
/// the test wrote rather than about the defaults.
enum SealedProfileRoots {
    static func root(
        _ providerID: ProviderID,
        label: String,
        at directory: URL,
        isEnabled: Bool = true
    ) throws -> ProfileRoot {
        try ProfileRoot(
            providerID: providerID,
            label: label,
            configurationDirectoryPath: directory.path(percentEncoded: false),
            isEnabled: isEnabled
        )
    }

    static func store(_ roots: ProfileRoot...) throws -> InMemoryProfileRootStore {
        InMemoryProfileRootStore(
            homeDirectory: ProviderFixtures.home,
            profiles: try ProfileRootCollection(profiles: roots)
        )
    }
}

/// A root store that cannot answer.
///
/// Stands in for a preferences payload that no longer decodes. Discovery has to surface this as a
/// failure: falling back to the seeded defaults would report accounts the user never configured
/// while their real collection sat unread.
struct UnreadableProfileRootStore: ProfileRootStore {
    let error: ProfileRootStoreError

    init(_ error: ProfileRootStoreError = .corruptPayload) {
        self.error = error
    }

    func load() async throws(ProfileRootStoreError) -> ProfileRootCollection {
        throw error
    }

    func save(_ profiles: ProfileRootCollection) async throws(ProfileRootStoreError) {
        throw error
    }
}

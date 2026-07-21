import Foundation

/// An isolated profile-root store that never reads process or production preferences.
public actor InMemoryProfileRootStore: ProfileRootStore {
    private let homeDirectory: URL
    private var storedProfiles: ProfileRootCollection?

    public init(
        homeDirectory: URL,
        profiles: ProfileRootCollection? = nil
    ) {
        self.homeDirectory = homeDirectory
        storedProfiles = profiles
    }

    public func load() async throws(ProfileRootStoreError) -> ProfileRootCollection {
        if let storedProfiles {
            return storedProfiles
        }
        do {
            return try ProfileRootCollection.seeded(homeDirectory: homeDirectory)
        } catch let error {
            throw .invalidDefaultRoots(error)
        }
    }

    public func save(
        _ profiles: ProfileRootCollection
    ) async throws(ProfileRootStoreError) {
        storedProfiles = profiles
    }
}

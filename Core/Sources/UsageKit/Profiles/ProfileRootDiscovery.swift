import Foundation

/// One enabled configuration root, resolved for a single discovery pass.
///
/// A provider is handed these instead of a home directory, so the set of directories it may read is
/// decided by configuration rather than by the provider's own idea of where an agent lives.
public struct ProfileRootLocation: Sendable, Hashable {
    public let id: ProfileRootID
    /// The configured label. This is the account's display name: it is the only thing that tells
    /// two roots of the same provider apart in the UI, and unlike an email or a plan name it is
    /// present whether or not the credential document parses.
    public let label: String
    public let directory: URL

    init(_ profile: ProfileRoot) {
        id = profile.id
        label = profile.label
        directory = URL(filePath: profile.configurationDirectoryPath, directoryHint: .isDirectory)
    }

    /// A document at `name` directly below this root.
    ///
    /// The only way a provider addresses a file: every read it performs is this root joined with a
    /// name the provider states as a constant, which is what bounds discovery to the configured
    /// directories.
    func document(_ name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }
}

extension ProviderContext {
    /// The enabled roots configured for `providerID`, in configuration order.
    ///
    /// Configuration order is discovery order and there is no cap on how many roots a provider may
    /// have. A disabled root is dropped here, before any file name is composed, so nothing below it
    /// is opened at all.
    ///
    /// Unreadable storage is a discovery failure rather than a fall back to the seeded defaults:
    /// substituting defaults for a collection we could not decode would quietly report the wrong
    /// accounts as though they were the configured ones.
    func enabledProfileRoots(
        for providerID: ProviderID
    ) async throws(UsageError) -> [ProfileRootLocation] {
        let collection: ProfileRootCollection
        do {
            collection = try await profileRoots.load()
        } catch {
            throw UsageError.providerUnavailable()
        }
        return collection.profiles
            .filter { $0.providerID == providerID && $0.isEnabled }
            .map(ProfileRootLocation.init)
    }
}

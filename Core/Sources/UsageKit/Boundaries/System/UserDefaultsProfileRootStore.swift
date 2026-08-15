import Foundation

/// A versioned `UserDefaults` store containing only non-secret provider configuration roots.
public struct UserDefaultsProfileRootStore: ProfileRootStore {
    public static let suiteName = "io.blacktop.Usage.shared"
    /// The pre-`io.` suite. Read once, only when the current suite is empty and only by the
    /// production initializer, so an existing configuration survives the bundle-ID move.
    static let legacySuiteName = "dev.blacktop.Usage.shared"
    public static let storageKey = "profileRoots"

    private let backing: UserDefaultsBacking
    private let legacyBacking: UserDefaultsBacking
    private let homeDirectory: URL

    /// Creates a crash-free production store backed by the app's preferences suite when available.
    public init(homeDirectory: URL) {
        self.init(
            homeDirectory: homeDirectory,
            suiteDefaults: UserDefaults(suiteName: Self.suiteName),
            legacyDefaults: UserDefaults(suiteName: Self.legacySuiteName)
        )
    }

    init(homeDirectory: URL, suiteName: String) {
        self.init(homeDirectory: homeDirectory, suiteDefaults: UserDefaults(suiteName: suiteName))
    }

    /// Creates a store with isolated preferences supplied by a test or embedding application.
    public init(homeDirectory: URL, defaults: UserDefaults) {
        self.init(homeDirectory: homeDirectory, suiteDefaults: defaults)
    }

    init(
        homeDirectory: URL,
        suiteDefaults: UserDefaults?,
        legacyDefaults: UserDefaults? = nil
    ) {
        backing = UserDefaultsBacking(defaults: suiteDefaults)
        legacyBacking = UserDefaultsBacking(defaults: legacyDefaults)
        self.homeDirectory = homeDirectory
    }

    public func load() async throws(ProfileRootStoreError) -> ProfileRootCollection {
        guard let defaults = backing.defaults else { throw .storageUnavailable }
        let stored = defaults.object(forKey: Self.storageKey) ?? migratedValue(into: defaults)
        guard let storedValue = stored else {
            do {
                return try ProfileRootCollection.seeded(homeDirectory: homeDirectory)
            } catch let error {
                throw .invalidDefaultRoots(error)
            }
        }
        guard let data = storedValue as? Data else {
            throw .corruptPayload
        }
        do {
            return try JSONDecoder().decode(ProfileRootCollection.self, from: data)
        } catch let error as ProfileRootCodingError {
            switch error {
            case .unsupportedSchemaVersion(let version):
                throw .unsupportedSchemaVersion(version)
            }
        } catch {
            throw .corruptPayload
        }
    }

    /// The legacy suite's payload, copied forward into `defaults` when one exists.
    ///
    /// The legacy suite itself is never written or cleared: the copy is idempotent and a
    /// downgrade to a pre-`io.` build keeps working from its own suite.
    private func migratedValue(into defaults: UserDefaults) -> Any? {
        guard let payload = legacyBacking.defaults?.object(forKey: Self.storageKey) as? Data else {
            return nil
        }
        defaults.set(payload, forKey: Self.storageKey)
        return payload
    }

    public func save(
        _ profiles: ProfileRootCollection
    ) async throws(ProfileRootStoreError) {
        guard let defaults = backing.defaults else { throw .storageUnavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            defaults.set(try encoder.encode(profiles), forKey: Self.storageKey)
        } catch {
            throw .corruptPayload
        }
    }
}

/// `UserDefaults` synchronizes access to its shared preferences domain, but is not annotated
/// `Sendable` by Foundation. This confines the unchecked conformance to the backing object.
private final class UserDefaultsBacking: @unchecked Sendable {
    let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }
}

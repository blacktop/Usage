import Foundation

/// A versioned `UserDefaults` store containing only non-secret provider configuration roots.
public struct UserDefaultsProfileRootStore: ProfileRootStore {
    public static let suiteName = "dev.blacktop.Usage.shared"
    public static let storageKey = "profileRoots"

    private let backing: UserDefaultsBacking
    private let homeDirectory: URL

    /// Creates a crash-free production store backed by the app's preferences suite when available.
    public init(homeDirectory: URL) {
        self.init(homeDirectory: homeDirectory, suiteName: Self.suiteName)
    }

    init(homeDirectory: URL, suiteName: String) {
        self.init(homeDirectory: homeDirectory, suiteDefaults: UserDefaults(suiteName: suiteName))
    }

    /// Creates a store with isolated preferences supplied by a test or embedding application.
    public init(homeDirectory: URL, defaults: UserDefaults) {
        self.init(homeDirectory: homeDirectory, suiteDefaults: defaults)
    }

    init(homeDirectory: URL, suiteDefaults: UserDefaults?) {
        backing = UserDefaultsBacking(defaults: suiteDefaults)
        self.homeDirectory = homeDirectory
    }

    public func load() async throws(ProfileRootStoreError) -> ProfileRootCollection {
        guard let defaults = backing.defaults else { throw .storageUnavailable }
        guard let storedValue = defaults.object(forKey: Self.storageKey) else {
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

import Foundation
import Testing

@testable import UsageKit

@Suite("UserDefaults profile-root store")
struct UserDefaultsProfileRootStoreTests {
    @Test("The production suite name is distinct and empty injected storage returns defaults")
    func emptyStorageSeedsDefaults() async throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let store = UserDefaultsProfileRootStore(
            homeDirectory: URL(filePath: "/Users/injected"),
            defaults: fixture.defaults
        )

        let profiles = try await store.load()

        #expect(UserDefaultsProfileRootStore.suiteName == "io.blacktop.Usage.shared")
        #expect(UserDefaultsProfileRootStore.suiteName != "io.blacktop.Usage")
        #expect(UserDefaultsProfileRootStore.legacySuiteName == "dev.blacktop.Usage.shared")
        #expect(
            profiles.profiles.map(\.configurationDirectoryPath) == [
                "/Users/injected/.claude",
                "/Users/injected/.codex",
                "/Users/injected/.copilot",
                "/Users/injected/.config/github-copilot",
            ])
        #expect(fixture.defaults.object(forKey: UserDefaultsProfileRootStore.storageKey) == nil)
    }

    @Test("A disposable named suite constructs, saves, and loads through the production path")
    func namedSuiteRoundTrips() async throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let homeDirectory = URL(filePath: "/Users/injected")
        let store = UserDefaultsProfileRootStore(
            homeDirectory: homeDirectory,
            suiteName: fixture.suiteName
        )
        var profiles = try ProfileRootCollection()
        try profiles.add(
            providerID: ProviderID("claude"),
            label: "Work",
            configurationDirectoryPath: "/Users/injected/.claude-work"
        )

        try await store.save(profiles)
        let reloadedStore = UserDefaultsProfileRootStore(
            homeDirectory: homeDirectory,
            suiteName: fixture.suiteName
        )

        #expect(try await reloadedStore.load() == profiles)
        #expect(
            fixture.defaults.data(forKey: UserDefaultsProfileRootStore.storageKey) != nil
        )
    }

    @Test("An empty suite migrates the legacy pre-io payload forward without clearing it")
    func migratesLegacySuiteForward() async throws {
        let fixture = try DefaultsFixture()
        let legacy = try DefaultsFixture()
        defer {
            fixture.remove()
            legacy.remove()
        }
        var profiles = try ProfileRootCollection()
        try profiles.add(
            providerID: ProviderID("claude"),
            label: "Migrated",
            configurationDirectoryPath: "/Users/injected/.claude"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        legacy.defaults.set(
            try encoder.encode(profiles),
            forKey: UserDefaultsProfileRootStore.storageKey
        )
        let store = UserDefaultsProfileRootStore(
            homeDirectory: URL(filePath: "/Users/injected"),
            suiteDefaults: fixture.defaults,
            legacyDefaults: legacy.defaults
        )

        let loaded = try await store.load()

        #expect(loaded == profiles, "the configured roots survive the bundle-ID move")
        #expect(
            fixture.defaults.data(forKey: UserDefaultsProfileRootStore.storageKey) != nil,
            "the payload is copied forward so later loads never depend on the legacy suite"
        )
        #expect(
            legacy.defaults.data(forKey: UserDefaultsProfileRootStore.storageKey) != nil,
            "the legacy suite is never cleared; a downgraded build keeps working"
        )
    }

    @Test("A populated suite never consults the legacy one")
    func populatedSuiteIgnoresLegacy() async throws {
        let fixture = try DefaultsFixture()
        let legacy = try DefaultsFixture()
        defer {
            fixture.remove()
            legacy.remove()
        }
        var current = try ProfileRootCollection()
        try current.add(
            providerID: ProviderID("codex"),
            label: "Current",
            configurationDirectoryPath: "/Users/injected/.codex"
        )
        var stale = try ProfileRootCollection()
        try stale.add(
            providerID: ProviderID("claude"),
            label: "Stale",
            configurationDirectoryPath: "/Users/injected/.claude"
        )
        let encoder = JSONEncoder()
        legacy.defaults.set(
            try encoder.encode(stale),
            forKey: UserDefaultsProfileRootStore.storageKey
        )
        let store = UserDefaultsProfileRootStore(
            homeDirectory: URL(filePath: "/Users/injected"),
            suiteDefaults: fixture.defaults,
            legacyDefaults: legacy.defaults
        )
        try await store.save(current)

        #expect(try await store.load() == current)
    }

    @Test("The store round-trips an unlimited ordered collection including disabled roots")
    func roundTripsEntireCollection() async throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let store = UserDefaultsProfileRootStore(
            homeDirectory: URL(filePath: "/Users/injected"),
            defaults: fixture.defaults
        )
        var profiles = try ProfileRootCollection()
        for index in 0..<73 {
            try profiles.add(
                providerID: ProviderID("codex"),
                label: "Profile \(index)",
                configurationDirectoryPath: "/roots/\(index)",
                isEnabled: index != 38
            )
        }
        let movedID = profiles.profiles[59].id
        try profiles.move(id: movedID, to: 4)

        try await store.save(profiles)
        let restored = try await store.load()

        #expect(restored == profiles)
        #expect(restored.profiles.count == 73)
        #expect(restored.profiles[4].id == movedID)
        let disabled = try #require(
            restored.profiles.first(where: { $0.label == "Profile 38" })
        )
        #expect(!disabled.isEnabled)
    }

    @Test("Corrupt and unsupported payload reads fail without changing stored bytes")
    func invalidPayloadIsNonDestructive() async throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let store = UserDefaultsProfileRootStore(
            homeDirectory: URL(filePath: "/Users/injected"),
            defaults: fixture.defaults
        )
        let key = UserDefaultsProfileRootStore.storageKey
        let corrupt = Data("not-json".utf8)
        fixture.defaults.set(corrupt, forKey: key)

        await #expect(throws: ProfileRootStoreError.corruptPayload) {
            try await store.load()
        }
        #expect(fixture.defaults.data(forKey: key) == corrupt)

        let unsupported = Data(#"{"schemaVersion":2,"profiles":[]}"#.utf8)
        fixture.defaults.set(unsupported, forKey: key)
        await #expect(throws: ProfileRootStoreError.unsupportedSchemaVersion(2)) {
            try await store.load()
        }
        #expect(fixture.defaults.data(forKey: key) == unsupported)
    }

    @Test("An unavailable production suite is reported by reads and writes")
    func unavailableSuiteIsRecoverable() async throws {
        let store = UserDefaultsProfileRootStore(
            homeDirectory: URL(filePath: "/Users/injected"),
            suiteDefaults: nil
        )
        let profiles = try ProfileRootCollection()

        await #expect(throws: ProfileRootStoreError.storageUnavailable) {
            try await store.load()
        }
        await #expect(throws: ProfileRootStoreError.storageUnavailable) {
            try await store.save(profiles)
        }
    }
}

private struct DefaultsFixture {
    let defaults: UserDefaults
    let suiteName: String

    init() throws {
        suiteName = "dev.blacktop.UsageTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

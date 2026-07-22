import Foundation
import Testing

@testable import UsageKit

@Suite("Provider profile roots")
struct ProfileRootTests {
    @Test("Injected-home defaults cover every shipped provider in stable order")
    func seedsEveryShippedProvider() throws {
        let home = URL(filePath: "/Users/fixture/../injected-home")
        let first = try ProfileRootCollection.seeded(homeDirectory: home)
        let second = try ProfileRootCollection.seeded(homeDirectory: home)

        #expect(first == second)
        #expect(
            first.profiles.map(\.providerID) == [
                ProviderID("claude"), ProviderID("codex"), ProviderID("copilot"),
                ProviderID("copilot"),
            ])
        #expect(
            first.profiles.map(\.label)
                == ["Claude", "Codex", "Copilot CLI", "Copilot Editor"]
        )
        #expect(
            first.profiles.map(\.configurationDirectoryPath) == [
                "/Users/injected-home/.claude",
                "/Users/injected-home/.codex",
                "/Users/injected-home/.copilot",
                "/Users/injected-home/.config/github-copilot",
            ])
        #expect(first.profiles.map(\.isEnabled) == [true, true, true, true])
        #expect(Set(first.profiles.map(\.id)).count == 4)
    }

    @Test("Paths normalize lexically and a blank label uses the directory name")
    func normalizesPathAndDefaultsBlankLabel() throws {
        let profile = try ProfileRoot(
            providerID: ProviderID("codex"),
            label: " \n ",
            configurationDirectoryPath: "/Users/fixture//profiles/../work/."
        )

        #expect(profile.label == "work")
        #expect(profile.configurationDirectoryPath == "/Users/fixture/work")
    }

    @Test("Relative configuration directories are rejected")
    func rejectsRelativePath() {
        #expect(throws: ProfileRootValidationError.configurationDirectoryMustBeAbsolute) {
            try ProfileRoot(
                providerID: ProviderID("claude"),
                label: "Relative",
                configurationDirectoryPath: ".config/claude"
            )
        }
    }

    @Test("Duplicates are provider-scoped and compared case-insensitively")
    func validatesProviderScopedDuplicates() throws {
        let claude = try ProfileRoot(
            providerID: ProviderID("claude"),
            label: "Claude",
            configurationDirectoryPath: "/Users/x/.claude"
        )
        let duplicate = try ProfileRoot(
            providerID: ProviderID("claude"),
            label: "Duplicate",
            configurationDirectoryPath: "/Users/x/profiles/../.Claude/"
        )
        let distinct = try ProfileRoot(
            providerID: ProviderID("claude"),
            label: "Claude Team",
            configurationDirectoryPath: "/Users/x/.claude-team"
        )
        let codex = try ProfileRoot(
            providerID: ProviderID("codex"),
            label: "Codex",
            configurationDirectoryPath: "/Users/x/.claude"
        )

        #expect(
            throws: ProfileRootValidationError.duplicateConfigurationDirectory(
                providerID: ProviderID("claude"),
                path: "/Users/x/.Claude"
            )
        ) {
            try ProfileRootCollection(profiles: [claude, duplicate])
        }
        let valid = try ProfileRootCollection(profiles: [claude, distinct, codex])
        #expect(valid.profiles.count == 3)
        #expect(valid.profiles[0].configurationDirectoryPath == "/Users/x/.claude")
        #expect(valid.profiles[1].configurationDirectoryPath == "/Users/x/.claude-team")
    }

    @Test("Canonical Unicode variants conflict without rewriting stored paths")
    func validatesUnicodeNormalizedDuplicates() throws {
        let composedPath = "/profiles/caf\u{00E9}"
        let decomposedPath = "/profiles/CAF\u{0065}\u{0301}"
        let composed = try ProfileRoot(
            providerID: ProviderID("claude"),
            label: "Composed",
            configurationDirectoryPath: composedPath
        )
        let decomposed = try ProfileRoot(
            providerID: ProviderID("claude"),
            label: "Decomposed",
            configurationDirectoryPath: decomposedPath
        )

        #expect(composed.configurationDirectoryPath == composedPath)
        #expect(decomposed.configurationDirectoryPath == decomposedPath)
        #expect(
            throws: ProfileRootValidationError.duplicateConfigurationDirectory(
                providerID: ProviderID("claude"),
                path: decomposedPath
            )
        ) {
            try ProfileRootCollection(profiles: [composed, decomposed])
        }
    }

    @Test("More than fifty roots remain editable, ordered, and stably identified")
    func supportsUnboundedEditingAndOrdering() throws {
        var collection = try ProfileRootCollection()
        for index in 0..<64 {
            try collection.add(
                providerID: ProviderID("codex"),
                label: "Root \(index)",
                configurationDirectoryPath: "/profiles/codex/\(index)"
            )
        }
        let originalIDs = collection.profiles.map(\.id)
        let editedID = originalIDs[37]

        try collection.edit(
            id: editedID,
            label: "  ",
            configurationDirectoryPath: "/profiles/codex/renamed/../thirty-seven",
            isEnabled: false
        )
        try collection.move(id: editedID, to: 0)

        #expect(collection.profiles.count == 64)
        #expect(collection.profiles[0].id == editedID)
        #expect(collection.profiles[0].label == "thirty-seven")
        #expect(collection.profiles[0].configurationDirectoryPath == "/profiles/codex/thirty-seven")
        #expect(!collection.profiles[0].isEnabled)
        #expect(Set(collection.profiles.map(\.id)) == Set(originalIDs))
    }

    @Test("Encoding restores order, IDs, labels, paths, and disabled roots")
    func codableRoundTripPreservesEntireCollection() throws {
        var collection = try ProfileRootCollection.seeded(
            homeDirectory: URL(filePath: "/Users/fixture")
        )
        let codexID = collection.profiles[1].id
        try collection.setEnabled(false, for: codexID)
        try collection.move(id: codexID, to: 0)

        let data = try JSONEncoder().encode(collection)
        let restored = try JSONDecoder().decode(ProfileRootCollection.self, from: data)

        #expect(restored == collection)
        #expect(restored.profiles[0].id == codexID)
        #expect(!restored.profiles[0].isEnabled)
    }

    @Test("The async in-memory abstraction seeds and round-trips without production defaults")
    func inMemoryStoreRoundTrips() async throws {
        let store = InMemoryProfileRootStore(homeDirectory: URL(filePath: "/Users/injected"))
        var profiles = try await store.load()
        try profiles.add(
            providerID: ProviderID("claude"),
            label: "Work",
            configurationDirectoryPath: "/profiles/claude/work",
            isEnabled: false
        )

        try await store.save(profiles)
        #expect(try await store.load() == profiles)
    }
}

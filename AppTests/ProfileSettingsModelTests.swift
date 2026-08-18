import Foundation
import Testing
import UsageKit

@testable import Usage

/// A latch that parks one store operation until a test lets it go.
///
/// An unarmed gate is not there at all, so the suites that do not care about ordering read and
/// write straight through. An armed one turns "a load overlapped a save" from something a test
/// would have to provoke with sleeps into a sequence it states outright.
private actor Gate {
    private var isArmed = false
    private var parked: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    /// Parks the next operation to reach this gate, and only that one.
    func arm() {
        isArmed = true
    }

    func park() async {
        guard isArmed else { return }
        isArmed = false
        await withCheckedContinuation { continuation in
            parked = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    /// Returns once an operation is parked here, whether it arrived before this call or after it.
    func waitForArrival() async {
        guard parked == nil else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        parked?.resume()
        parked = nil
    }
}

/// A profile-root store a test drives directly, including into failure and into a chosen order.
///
/// Not `UserDefaultsProfileRootStore`: these suites must neither read nor disturb the preferences
/// domain the running user's own roots live in.
private actor StubProfileRootStore: ProfileRootStore {
    enum Failure: Sendable, Equatable {
        case load(ProfileRootStoreError)
        case save(ProfileRootStoreError)
    }

    /// A load parks *after* reading, so a released one answers with the collection it saw on the
    /// way in — which is what a reload overtaken by a save is holding.
    let loadGate = Gate()
    let saveGate = Gate()

    private var collection: ProfileRootCollection
    private var failure: Failure?
    private(set) var saveCount = 0

    init(collection: ProfileRootCollection, failure: Failure? = nil) {
        self.collection = collection
        self.failure = failure
    }

    func setFailure(_ failure: Failure?) {
        self.failure = failure
    }

    var stored: ProfileRootCollection { collection }

    func load() async throws(ProfileRootStoreError) -> ProfileRootCollection {
        if case .load(let error) = failure { throw error }
        let read = collection
        await loadGate.park()
        return read
    }

    func save(_ profiles: ProfileRootCollection) async throws(ProfileRootStoreError) {
        await saveGate.park()
        if case .save(let error) = failure { throw error }
        saveCount += 1
        collection = profiles
    }
}

@MainActor
private final class RevealRecorder {
    private(set) var folders: [URL] = []

    func record(_ folder: URL) {
        folders.append(folder)
    }
}

@MainActor
private final class RediscoveryRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

/// Everything one test needs, wired to in-memory boundaries only.
@MainActor
private struct Harness {
    let store: StubProfileRootStore
    let files: InMemoryFileSystem
    let managedCredentials: InMemoryManagedCredentialStore
    let reveal: RevealRecorder
    let rediscovery: RediscoveryRecorder
    let settings: ProfileSettingsModel

    init(
        collection: ProfileRootCollection,
        files: InMemoryFileSystem = InMemoryFileSystem(),
        managedCredentials: InMemoryManagedCredentialStore = InMemoryManagedCredentialStore()
    ) {
        let store = StubProfileRootStore(collection: collection)
        let reveal = RevealRecorder()
        let rediscovery = RediscoveryRecorder()
        self.store = store
        self.files = files
        self.managedCredentials = managedCredentials
        self.reveal = reveal
        self.rediscovery = rediscovery
        settings = ProfileSettingsModel(
            store: store,
            registry: .agents,
            fileSystem: files,
            managedCredentials: managedCredentials,
            reveal: { reveal.record($0) },
            rediscover: { rediscovery.record() }
        )
    }

    func section(_ providerID: String) -> ProfileSettingsModel.ProviderSection? {
        settings.sections.first { $0.id == ProviderID(providerID) }
    }

    func rows(_ providerID: String) -> [ProfileSettingsModel.RootRow] {
        section(providerID)?.rows ?? []
    }
}

private let claude = ProviderID("claude")
private let home = URL(filePath: "/Users/fixture", directoryHint: .isDirectory)

private func collection(
    _ paths: [String],
    provider: ProviderID = claude
) throws -> ProfileRootCollection {
    var collection = try ProfileRootCollection()
    for path in paths {
        try collection.add(providerID: provider, label: "", configurationDirectoryPath: path)
    }
    return collection
}

@Suite("Provider folder settings")
@MainActor
struct ProfileSettingsModelTests {
    @Test("Every stored root is grouped under its provider, in registry then configuration order")
    func loadGroupsRootsByProvider() async throws {
        let harness = Harness(collection: try ProfileRootCollection.seeded(homeDirectory: home))

        await harness.settings.load()

        #expect(harness.settings.sections.map(\.id.rawValue) == ["codex", "claude", "copilot"])
        #expect(harness.settings.sections.map(\.rows.count) == [1, 1, 2])
        #expect(harness.rows("claude").map(\.profile.label) == ["Claude"])
        #expect(harness.rows("copilot").map(\.profile.label) == ["Copilot CLI", "Copilot Editor"])
        #expect(harness.settings.errorMessage == nil)
    }

    @Test("A root whose provider is not registered still gets a section of its own")
    func unregisteredProvidersAreStillVisible() async throws {
        let stored = try collection(["/Users/fixture/.gemini"], provider: ProviderID("gemini"))
        let harness = Harness(collection: stored)

        await harness.settings.load()

        #expect(
            harness.settings.sections.map(\.id.rawValue) == [
                "codex", "claude", "copilot", "gemini",
            ])
        #expect(harness.rows("gemini").map(\.profile.label) == [".gemini"])
    }

    @Test("Fifty-plus roots on one provider keep their order and their distinct identities")
    func manyRootsKeepIdentityAndOrder() async throws {
        let paths = (0..<60).map { "/Users/fixture/roots/\($0)" }
        let harness = Harness(collection: try collection(paths))

        await harness.settings.load()

        let rows = harness.rows("claude")
        #expect(rows.count == 60)
        #expect(rows.map(\.profile.configurationDirectoryPath) == paths)
        #expect(Set(rows.map(\.id)).count == 60)
        #expect(harness.rows("codex").isEmpty)
    }

    @Test("Adding a folder stores its normalized path and names it after the folder")
    func addingAFolderStoresOnlyItsPath() async throws {
        let harness = Harness(collection: try ProfileRootCollection())
        await harness.settings.load()

        await harness.settings.addRoot(
            providerID: claude,
            folder: URL(filePath: "/Users/fixture/profiles/./work/", directoryHint: .isDirectory)
        )
        await harness.settings.quiesce()

        let rows = harness.rows("claude")
        #expect(rows.map(\.profile.configurationDirectoryPath) == ["/Users/fixture/profiles/work"])
        #expect(rows.map(\.profile.label) == ["work"])
        #expect(rows.allSatisfy { $0.profile.isEnabled })
        #expect(await harness.store.saveCount == 1)
        #expect(harness.rediscovery.count == 1, "a successful edit rediscovers exactly once")
        #expect(harness.files.recordedReads.isEmpty, "Settings never opens a file below a root")
    }

    @Test("Relative components in a picked folder are resolved before the root is stored")
    func relativeComponentsAreResolvedBeforeStorage() async throws {
        let harness = Harness(collection: try ProfileRootCollection())
        await harness.settings.load()

        await harness.settings.addRoot(
            providerID: claude,
            folder: URL(filePath: "/Users/fixture/profiles/work/../archive/.")
        )
        await harness.settings.quiesce()

        let stored = await harness.store.stored
        #expect(
            stored.profiles.map(\.configurationDirectoryPath)
                == ["/Users/fixture/profiles/archive"]
        )
        #expect(harness.rows("claude").map(\.profile.label) == ["archive"])
    }

    @Test("A same-provider duplicate is refused and the persisted rows stay on screen")
    func duplicateRootsAreRefused() async throws {
        let harness = Harness(collection: try collection(["/Users/fixture/profiles/work"]))
        await harness.settings.load()

        await harness.settings.addRoot(
            providerID: claude,
            folder: URL(filePath: "/Users/fixture/PROFILES/Work")
        )
        await harness.settings.quiesce()

        #expect(harness.rows("claude").count == 1)
        #expect(
            harness.settings.errorMessage
                == "Claude already has a folder at /Users/fixture/PROFILES/Work."
        )
        #expect(await harness.store.saveCount == 0)
        #expect(harness.rediscovery.count == 0, "a refused edit rediscovers nothing")
    }

    @Test("The same folder under a different provider is not a duplicate")
    func sameFolderIsAllowedForADifferentProvider() async throws {
        let harness = Harness(collection: try collection(["/Users/fixture/profiles/work"]))
        await harness.settings.load()

        await harness.settings.addRoot(
            providerID: ProviderID("codex"),
            folder: URL(filePath: "/Users/fixture/profiles/work")
        )
        await harness.settings.quiesce()

        #expect(harness.rows("claude").count == 1)
        #expect(harness.rows("codex").count == 1)
        #expect(harness.settings.errorMessage == nil)
    }

    @Test("A failed save reports the failure and leaves the last persisted collection visible")
    func aFailedSaveKeepsTheLastPersistedCollection() async throws {
        let harness = Harness(collection: try collection(["/Users/fixture/profiles/work"]))
        await harness.settings.load()
        let before = harness.rows("claude")
        await harness.store.setFailure(.save(.storageUnavailable))

        await harness.settings.setEnabled(false, for: try #require(before.first).id)
        await harness.settings.quiesce()

        #expect(harness.rows("claude") == before)
        #expect(harness.rows("claude").allSatisfy { $0.profile.isEnabled })
        #expect(
            harness.settings.errorMessage == "Provider folders could not be saved to preferences."
        )
        #expect(harness.rediscovery.count == 0)
    }

    @Test("A failed load reports the failure without inventing rows")
    func aFailedLoadReportsRatherThanSeeds() async throws {
        let harness = Harness(collection: try ProfileRootCollection())
        await harness.store.setFailure(.load(.corruptPayload))

        await harness.settings.load()

        #expect(harness.settings.sections.allSatisfy { $0.rows.isEmpty })
        #expect(harness.settings.errorMessage == "Saved provider folders could not be read.")
    }

    @Test("Renaming, toggling, and removing each persist and rediscover once")
    func everyMutationPersistsAndRediscovers() async throws {
        let harness = Harness(collection: try collection(["/Users/fixture/profiles/work"]))
        await harness.settings.load()
        let id = try #require(harness.rows("claude").first).id

        await harness.settings.rename(id, to: "  Work  ")
        await harness.settings.setEnabled(false, for: id)
        await harness.settings.quiesce()

        #expect(harness.rows("claude").map(\.profile.label) == ["Work"])
        #expect(harness.rows("claude").allSatisfy { !$0.profile.isEnabled })
        #expect(harness.rediscovery.count == 2)

        await harness.settings.removeRoot(id)
        await harness.settings.quiesce()

        #expect(harness.rows("claude").isEmpty)
        #expect(await harness.store.stored.profiles.isEmpty)
        #expect(harness.rediscovery.count == 3)
    }

    @Test("Mutations queued together are serialized rather than racing over one collection")
    func concurrentMutationsAreSerialized() async throws {
        let harness = Harness(collection: try ProfileRootCollection())
        await harness.settings.load()

        async let first: Void = harness.settings.addRoot(
            providerID: claude,
            folder: URL(filePath: "/Users/fixture/profiles/a")
        )
        async let second: Void = harness.settings.addRoot(
            providerID: claude,
            folder: URL(filePath: "/Users/fixture/profiles/b")
        )
        _ = await (first, second)
        await harness.settings.quiesce()

        #expect(
            Set(harness.rows("claude").map(\.profile.configurationDirectoryPath))
                == ["/Users/fixture/profiles/a", "/Users/fixture/profiles/b"]
        )
        #expect(await harness.store.saveCount == 2)
    }

    @Test("A reload overtaken by a save keeps the edit instead of the collection it read first")
    func aReloadOvertakenByASaveKeepsTheEdit() async throws {
        let harness = Harness(collection: try collection(["/Users/fixture/profiles/work"]))
        await harness.settings.load()
        let id = try #require(harness.rows("claude").first).id

        // The order is stated rather than raced: the toggle's save parks in storage, the reload
        // reads the collection from before that toggle and parks behind it, the save is let go and
        // its edit settles, and only then does the reload come back holding the older collection.
        await harness.store.saveGate.arm()
        async let edit: Void = harness.settings.setEnabled(false, for: id)
        await harness.store.saveGate.waitForArrival()

        await harness.store.loadGate.arm()
        async let reload: Void = harness.settings.load()
        await harness.store.loadGate.waitForArrival()

        await harness.store.saveGate.release()
        await edit
        await harness.store.loadGate.release()
        await reload
        await harness.settings.quiesce()

        #expect(await harness.store.stored.profiles.map(\.isEnabled) == [false])
        #expect(
            harness.rows("claude").map(\.profile.isEnabled) == [false],
            "the rows stay at the edit rather than rolling back to the reload's older read"
        )
        #expect(harness.settings.errorMessage == nil)

        await harness.settings.rename(id, to: "Work")
        await harness.settings.quiesce()

        #expect(
            await harness.store.stored.profiles.map(\.isEnabled) == [false],
            "and the edit is not written back out by the mutation that follows the reload"
        )
    }

    @Test("A row reports the provider's sign-in file by existence alone")
    func credentialPresenceIsAnExistenceCheck() async throws {
        let files = InMemoryFileSystem(
            homeDirectory: home,
            files: [
                URL(filePath: "/Users/fixture/profiles/work/.credentials.json"): Data(),
                URL(filePath: "/Users/fixture/profiles/copilot/hosts.json"): Data(),
                URL(filePath: "/Users/fixture/profiles/copilot-config/config.json"): Data(),
            ]
        )
        var stored = try collection(
            ["/Users/fixture/profiles/work", "/Users/fixture/profiles/empty"]
        )
        try stored.add(
            providerID: ProviderID("copilot"),
            label: "",
            configurationDirectoryPath: "/Users/fixture/profiles/copilot"
        )
        try stored.add(
            providerID: ProviderID("copilot"),
            label: "",
            configurationDirectoryPath: "/Users/fixture/profiles/copilot-config"
        )
        let harness = Harness(collection: stored, files: files)

        await harness.settings.load()

        #expect(harness.rows("claude").map(\.hasCredentialDocument) == [true, false])
        #expect(harness.rows("copilot").map(\.hasCredentialDocument) == [true, false])
        #expect(harness.files.recordedReads.isEmpty, "presence is existence, never a read")
    }

    @Test("Every registered provider names the documents it reads below a root")
    func everyRegisteredProviderNamesItsDocuments() {
        #expect(ProviderCredentialDocuments.names(for: claude) == [".credentials.json"])
        #expect(ProviderCredentialDocuments.names(for: ProviderID("codex")) == ["auth.json"])
        #expect(
            ProviderCredentialDocuments.names(for: ProviderID("copilot"))
                == ["apps.json", "hosts.json", "oauth.json"]
        )
        #expect(ProviderCredentialDocuments.names(for: ProviderID("gemini")).isEmpty)
    }

    @Test("Claude explains its actual credential precedence")
    func claudeCredentialGuidanceIsAccurate() throws {
        #expect(
            ProviderCredentialDocuments.status(
                providerID: claude,
                hasCredentialDocument: true
            ) == "Credential JSON found"
        )
        #expect(
            ProviderCredentialDocuments.status(
                providerID: claude,
                hasCredentialDocument: false
            ) == "Claude Code Keychain checked during refresh"
        )
        #expect(
            ProviderCredentialDocuments.status(
                providerID: claude,
                hasCredentialDocument: false,
                hasSetupToken: true
            ) == "Setup token saved; Claude Code Keychain is preferred"
        )
        let guidance = try #require(ProviderCredentialDocuments.guidance(for: claude))
        #expect(guidance.contains(".credentials.json first"))
        #expect(guidance.contains("Claude Code’s root-specific Keychain"))
        #expect(guidance.contains("setup token remains unused"))
        #expect(guidance.contains("claude setup-token"))
        #expect(ProviderCredentialDocuments.guidance(for: ProviderID("codex")) == nil)
    }

    @Test("A Claude setup token is stored against only its profile root")
    func storesSetupTokenPerRoot() async throws {
        let harness = Harness(
            collection: try collection([
                "/Users/fixture/profiles/personal",
                "/Users/fixture/profiles/work",
            ])
        )
        await harness.settings.load()
        let rows = harness.rows("claude")
        let personal = try #require(rows.first)
        let work = try #require(rows.last)

        #expect(harness.settings.saveClaudeSetupToken("sk-ant-oat01-fixture", for: work.id))
        await harness.settings.quiesce()

        let updatedRows = harness.rows("claude")
        let updatedPersonal = try #require(updatedRows.first)
        let updatedWork = try #require(updatedRows.last)
        #expect(!updatedPersonal.hasSetupToken)
        #expect(updatedWork.hasSetupToken)
        #expect(
            harness.managedCredentials.containsCredential(
                at: ClaudeSetupTokenCredential.locator(for: work.id)
            )
        )
        #expect(
            !harness.managedCredentials.containsCredential(
                at: ClaudeSetupTokenCredential.locator(for: personal.id)
            )
        )
        #expect(harness.managedCredentials.storageCount == 1)
        #expect(harness.rediscovery.count == 1)
        #expect(await harness.store.saveCount == 0, "tokens never enter profile preferences")
    }

    @Test("Removing a Claude root also removes its Usage-owned setup token and mirror")
    func removingRootRemovesSetupToken() async throws {
        let stored = try collection(["/Users/fixture/profiles/work"])
        let id = try #require(stored.profiles.first).id
        let tokenStore = InMemoryManagedCredentialStore(
            locators: [
                ClaudeSetupTokenCredential.locator(for: id),
                ClaudeCredentialMirror.storageLocator(for: id),
            ]
        )
        let harness = Harness(collection: stored, managedCredentials: tokenStore)
        await harness.settings.load()
        #expect(try #require(harness.rows("claude").first).hasSetupToken)

        await harness.settings.removeRoot(id)
        await harness.settings.quiesce()

        #expect(harness.rows("claude").isEmpty)
        #expect(
            !tokenStore.containsCredential(
                at: ClaudeSetupTokenCredential.locator(for: id)
            )
        )
        #expect(
            !tokenStore.containsCredential(
                at: ClaudeCredentialMirror.storageLocator(for: id)
            )
        )
        #expect(tokenStore.removalCount == 2)
    }

    @Test("A failed Claude token cleanup leaves the same root available for retry")
    func failedTokenCleanupKeepsRootRetryable() async throws {
        let stored = try collection(["/Users/fixture/profiles/work"])
        let id = try #require(stored.profiles.first).id
        let locator = ClaudeSetupTokenCredential.locator(for: id)
        let tokenStore = InMemoryManagedCredentialStore(
            locators: [locator],
            removalFailure: .storageUnavailable
        )
        let harness = Harness(collection: stored, managedCredentials: tokenStore)
        await harness.settings.load()

        await harness.settings.removeRoot(id)
        await harness.settings.quiesce()

        #expect(harness.rows("claude").map(\.id) == [id])
        #expect(tokenStore.containsCredential(at: locator))
        #expect(await harness.store.saveCount == 0)
        #expect(harness.rediscovery.count == 0)
        #expect(harness.settings.errorMessage?.contains("Usage Keychain") == true)

        tokenStore.setRemovalFailure(nil)
        await harness.settings.removeRoot(id)
        await harness.settings.quiesce()

        #expect(harness.rows("claude").isEmpty)
        #expect(!tokenStore.containsCredential(at: locator))
        #expect(await harness.store.saveCount == 1)
        #expect(harness.rediscovery.count == 1)
    }

    @Test("Reveal hands the root's own directory to the injected action and opens nothing")
    func revealUsesTheInjectedAction() async throws {
        let harness = Harness(collection: try collection(["/Users/fixture/profiles/work"]))
        await harness.settings.load()
        let id = try #require(harness.rows("claude").first).id

        harness.settings.revealInFinder(id)
        harness.settings.revealInFinder(ProfileRootID())

        #expect(
            harness.reveal.folders
                == [URL(filePath: "/Users/fixture/profiles/work", directoryHint: .isDirectory)],
            "an unknown row reveals nothing rather than guessing a folder"
        )
    }

    @Test("A dismissed error stays dismissed until the next failure")
    func errorsAreDismissible() async throws {
        let harness = Harness(collection: try ProfileRootCollection())
        await harness.store.setFailure(.load(.unsupportedSchemaVersion(7)))

        await harness.settings.load()
        #expect(harness.settings.errorMessage != nil)

        harness.settings.dismissError()

        #expect(harness.settings.errorMessage == nil)
    }
}

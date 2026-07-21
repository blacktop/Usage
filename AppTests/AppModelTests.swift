import Foundation
import Testing
import UsageKit

@testable import Usage

@Suite("App model")
@MainActor
struct AppModelTests {
    private func model(
        _ provider: any Provider,
        clock: GatedClock,
        profileRoots: (any ProfileRootStore)? = nil
    ) -> AppModel {
        AppModel(
            registry: ProviderRegistry(providers: [provider]),
            context: ProviderContext(
                http: InMemoryHTTPTransport(),
                credentials: InMemoryCredentialSource(),
                fileSystem: InMemoryFileSystem(),
                clock: clock,
                interaction: BackgroundInteractionPolicy(),
                profileRoots: profileRoots
            ),
            // The stagger between one provider's fetches is proven in the coordinator's own
            // suite; here it would only park these tests on the gated clock.
            configuration: RefreshCoordinator.Configuration(stagger: .zero)
        )
    }

    @Test("A refresh fills the store with every discovered account")
    func refreshProjectsEveryAccount() async throws {
        let model = model(UsageKit.PreviewProvider(), clock: GatedClock())
        #expect(model.store.accounts.isEmpty)

        await model.refreshNow()

        #expect(model.store.accounts.count >= 2)
        #expect(model.store.accounts.allSatisfy { $0.report != nil })
        #expect(model.store.accounts.allSatisfy { $0.lastError == nil })
        #expect(Set(model.store.accounts.map(\.account.key)).count == model.store.accounts.count)
        #expect(model.store.discoveryFailures.isEmpty)
        #expect(!model.store.isRefreshing)
    }

    @Test("A second refresh keeps one row per account rather than duplicating them")
    func repeatedRefreshDoesNotDuplicateRows() async throws {
        let model = model(UsageKit.PreviewProvider(), clock: GatedClock())
        await model.refreshNow()
        let first = model.store.accounts.map(\.account.key)

        await model.refreshNow()

        #expect(model.store.accounts.map(\.account.key) == first)
    }

    @Test("The menu bar label reports the worst fraction across every account")
    func menuBarLabelUsesWorstFraction() async throws {
        let model = model(UsageKit.PreviewProvider(), clock: GatedClock())
        #expect(MenuBarLabel.worstFraction(in: model.store.accounts) == nil)

        await model.refreshNow()

        let worst = try #require(MenuBarLabel.worstFraction(in: model.store.accounts))
        let everyFraction = model.store.accounts.compactMap(\.report).flatMap(\.windows)
            .map(\.usedFraction)
        #expect(worst == everyFraction.max())
        #expect(worst > 1, "the preview data must include an over-quota window")
    }

    @Test("A failed refresh leaves the previously rendered report in place")
    func failureKeepsTheLastGoodReport() async throws {
        let provider = ScriptedProvider()
        let clock = GatedClock()
        let model = model(provider, clock: clock)

        await model.refreshNow()
        let cached = try #require(model.store.accounts.first?.report)

        clock.advance(by: .seconds(600))
        provider.failNextFetch(with: .transportFailure())
        await model.refreshNow()

        let state = try #require(model.store.accounts.first)
        #expect(state.report == cached)
        #expect(state.lastError == .transportFailure())
        #expect(state.refreshPhase == .scheduled, "a failed account is queued for its retry")
        #expect(AccountCard.RefreshIndicator.forState(state) == .failed)
    }

    @Test("A later success clears the error without disturbing the row")
    func successAfterFailureClearsTheError() async throws {
        let provider = ScriptedProvider()
        let clock = GatedClock()
        let model = model(provider, clock: clock)

        provider.failNextFetch(with: .transportFailure())
        await model.refreshNow()
        #expect(model.store.accounts.first?.lastError != nil)
        #expect(model.store.accounts.first?.report == nil)

        clock.advance(by: .seconds(1_800))
        await model.refreshNow()

        let state = try #require(model.store.accounts.first)
        #expect(state.lastError == nil)
        #expect(state.report?.capturedAt == clock.now)
        #expect(model.store.accounts.count == 1)
    }

    @Test("A discovery failure is reported per provider and cleared on recovery")
    func discoveryFailuresAreReportedPerProvider() async throws {
        let provider = ScriptedProvider()
        let model = model(provider, clock: GatedClock())

        provider.failDiscovery(with: .credentialUnavailable(kind: .file))
        await model.refreshNow()
        #expect(model.store.discoveryFailures[ScriptedProvider.id] != nil)
        #expect(model.store.accounts.isEmpty)

        provider.failDiscovery(with: nil)
        await model.refreshNow()

        #expect(model.store.discoveryFailures[ScriptedProvider.id] == nil)
        #expect(model.store.accounts.count == 1)
    }

    /// Settings edits roots through `model.profileRoots` and then asks for a rediscovery. That only
    /// works if the model kept the store its own context reads: a second store over the same suite
    /// would be a second boundary, and the edit and the refresh would race across it.
    @Test("An edit through the model's store is what the next discovery reads")
    func editingTheRetainedStoreIsVisibleToDiscovery() async throws {
        let home = URL(filePath: "/Users/fixture", directoryHint: .isDirectory)
        let roots = InMemoryProfileRootStore(homeDirectory: home)
        let model = model(ScriptedProvider(), clock: GatedClock(), profileRoots: roots)

        var edited = try await model.profileRoots.load()
        try edited.add(
            providerID: ProviderID("codex"),
            label: "Work",
            configurationDirectoryPath: "/Users/fixture/profiles/work"
        )
        try await model.profileRoots.save(edited)

        let observed = try await roots.load()
        #expect(observed.profiles.map(\.label).contains("Work"))
        #expect(observed == edited)
    }

    @Test("The shipped app runs the real providers through the shared profile-root store")
    func liveWiringUsesTheSharedStore() {
        let model = AppModel.live()
        #expect(model.profileRoots is UserDefaultsProfileRootStore)
        #expect(model.fileSystem is SystemFileSystem)
        #expect(model.registry.providerIDs == ProviderRegistry.agents.providerIDs)
        #expect(model.store.accounts.isEmpty)
        #expect(
            ProviderRegistry.agents.providerIDs.map(\.rawValue).sorted()
                == ["claude", "codex", "copilot"]
        )
        #expect(
            ProviderRegistry.agents.provider(for: UsageKit.PreviewProvider.id) == nil,
            "the synthetic preview accounts belong to the suites, not to a shipped menu bar"
        )
    }

    @Test("An unexpected error type reaches the store redacted")
    func foreignErrorsAreRedacted() async throws {
        let provider = ScriptedProvider()
        let model = model(provider, clock: GatedClock())
        provider.throwForeignErrorOnNextFetch()

        await model.refreshNow()

        let error = try #require(model.store.accounts.first?.lastError)
        #expect(error == .transportFailure())
        #expect(!error.message.contains("sk-proj"))
    }
}

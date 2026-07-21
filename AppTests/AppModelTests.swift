import Foundation
import Testing
import UsageKit

@testable import Usage

@Suite("App model")
@MainActor
struct AppModelTests {
    private func model(_ provider: any Provider, clock: GatedClock) -> AppModel {
        AppModel(
            registry: ProviderRegistry(providers: [provider]),
            context: ProviderContext(
                http: InMemoryHTTPTransport(),
                credentials: InMemoryCredentialSource(),
                fileSystem: InMemoryFileSystem(),
                clock: clock,
                interaction: BackgroundInteractionPolicy()
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

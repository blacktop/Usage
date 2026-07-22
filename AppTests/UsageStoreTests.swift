import Foundation
import Testing
import UsageKit

@testable import Usage

@Suite("Usage store")
@MainActor
struct UsageStoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func report(fraction: Double, at date: Date) throws -> UsageReport {
        try UsageReport(
            accountKey: ScriptedProvider.accountKey,
            plan: "scripted",
            windows: [
                UsageWindow(
                    id: WindowID(scope: .plan, slot: .primary, period: .weekly),
                    kind: .weekly,
                    label: "Weekly",
                    usedFraction: fraction
                )
            ],
            capturedAt: date
        )
    }

    private func discoveredStore() -> UsageStore {
        let store = UsageStore()
        store.apply(
            .discovered(
                accounts: [ScriptedProvider.account],
                provider: ScriptedProvider.id,
                at: start
            )
        )
        return store
    }

    @Test("Discovery projects one row per account and clears the provider's failure")
    func discoveryProjectsRows() throws {
        let store = UsageStore()
        store.apply(.discoveryFailed(error: .transportFailure(), provider: ScriptedProvider.id))
        #expect(store.discoveryFailures[ScriptedProvider.id] != nil)
        #expect(store.accounts.isEmpty)

        store.apply(
            .discovered(
                accounts: [ScriptedProvider.account],
                provider: ScriptedProvider.id,
                at: start
            )
        )

        #expect(store.discoveryFailures.isEmpty)
        #expect(store.accounts.count == 1)
        #expect(store.accounts.first?.report == nil)
        #expect(store.accounts.first?.refreshPhase == .idle)
    }

    @Test("cache → loading → failure keeps the cached report visible")
    func failureKeepsTheCachedReport() throws {
        let store = discoveredStore()
        let cached = try report(fraction: 0.4, at: start)
        store.apply(.succeeded(report: cached, at: start))

        store.apply(.began(key: ScriptedProvider.accountKey, at: start.addingTimeInterval(300)))
        #expect(store.isRefreshing)
        #expect(store.accounts.first?.report == cached, "loading must not blank the last report")

        store.apply(
            .failed(
                error: .transportFailure(),
                key: ScriptedProvider.accountKey,
                at: start.addingTimeInterval(310)
            )
        )

        let state = try #require(store.accounts.first)
        #expect(state.report == cached)
        #expect(state.lastError == .transportFailure())
        #expect(state.refreshPhase == .idle)
        #expect(!store.isRefreshing)
        #expect(AccountRefreshIndicator.forState(state) == .failed)
    }

    @Test("cache → loading → success replaces the report and clears the error")
    func successReplacesTheReportAndClearsTheError() throws {
        let store = discoveredStore()
        store.apply(.succeeded(report: try report(fraction: 0.4, at: start), at: start))
        store.apply(
            .failed(error: .transportFailure(), key: ScriptedProvider.accountKey, at: start)
        )
        #expect(store.accounts.first?.lastError != nil)

        let later = start.addingTimeInterval(600)
        store.apply(.began(key: ScriptedProvider.accountKey, at: later))
        store.apply(.succeeded(report: try report(fraction: 0.7, at: later), at: later))

        let state = try #require(store.accounts.first)
        #expect(state.lastError == nil)
        #expect(state.report?.capturedAt == later)
        #expect(state.report?.windows.first?.usedFraction == 0.7)
        #expect(store.accounts.count == 1)
    }

    @Test("A scheduled account does not add status noise to the account legend")
    func scheduledPhaseIsDistinctFromLoading() throws {
        let store = discoveredStore()
        store.apply(.succeeded(report: try report(fraction: 0.4, at: start), at: start))
        store.apply(.scheduled(key: ScriptedProvider.accountKey))

        let state = try #require(store.accounts.first)
        #expect(state.refreshPhase == .scheduled)
        #expect(!store.isRefreshing)
        #expect(AccountRefreshIndicator.forState(state) == nil)
        #expect(state.report != nil)
    }

    @Test("A failure for an account the store never discovered creates no row")
    func unknownAccountsAreIgnored() {
        let store = UsageStore()
        store.apply(
            .failed(error: .transportFailure(), key: ScriptedProvider.accountKey, at: start)
        )
        #expect(store.accounts.isEmpty)
    }

    @Test("Rediscovery keeps the cached report of an account that is still there")
    func rediscoveryKeepsCachedReports() throws {
        let store = discoveredStore()
        let cached = try report(fraction: 0.4, at: start)
        store.apply(.succeeded(report: cached, at: start))

        store.apply(
            .discovered(
                accounts: [ScriptedProvider.account],
                provider: ScriptedProvider.id,
                at: start
            )
        )

        #expect(store.accounts.count == 1)
        #expect(store.accounts.first?.report == cached)
    }

    @Test("A discovery failure never discards the accounts already on screen")
    func discoveryFailureKeepsRows() throws {
        let store = discoveredStore()
        let cached = try report(fraction: 0.4, at: start)
        store.apply(.succeeded(report: cached, at: start))

        store.apply(
            .discoveryFailed(
                error: .credentialUnavailable(kind: .file),
                provider: ScriptedProvider.id
            )
        )

        #expect(store.accounts.count == 1)
        #expect(store.accounts.first?.report == cached)
        #expect(store.discoveryFailures[ScriptedProvider.id] != nil)
    }

    @Test("A provider card says when its numbers are being shown despite a failed refresh")
    func freshnessTextDistinguishesStaleData() throws {
        let store = discoveredStore()
        store.apply(.succeeded(report: try report(fraction: 0.4, at: start), at: start))
        let loaded = try #require(store.accounts.first)
        let fresh = try #require(freshnessText(for: loaded))

        store.apply(
            .failed(error: .transportFailure(), key: ScriptedProvider.accountKey, at: start)
        )
        let failing = try #require(store.accounts.first)
        let stale = try #require(freshnessText(for: failing))

        #expect(fresh != stale)
        #expect(stale.contains("showing cached data from"))
    }

    private func freshnessText(for state: AccountState) -> String? {
        ProviderFreshnessText.text(
            for: ProviderUsagePresentation(
                section: PopoverAccountSection(
                    id: ScriptedProvider.id,
                    displayName: "Scripted",
                    accounts: [state],
                    unrepresentedProfiles: []
                )
            )
        )
    }
}

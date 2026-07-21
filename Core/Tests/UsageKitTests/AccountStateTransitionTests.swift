import Foundation
import Testing

@testable import UsageKit

@Suite("Account state transitions")
struct AccountStateTransitionTests {
    private let key = Fixtures.canonicalKey("alpha")
    private let now = Fixtures.capturedAt

    private func table() -> AccountStateTable {
        var table = AccountStateTable()
        table.replaceDiscovered(
            [Fixtures.account(key: key, slot: Fixtures.slot("alpha"), availability: .active)],
            forProvider: Fixtures.provider,
            at: now
        )
        return table
    }

    private func report(fraction: Double, at date: Date) throws -> UsageReport {
        try UsageReport(
            accountKey: key,
            plan: "pro",
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

    @Test("cache → loading → failure keeps the cached report and records the error")
    func cacheThenLoadingThenFailureKeepsReport() throws {
        var table = table()
        let cached = try report(fraction: 0.4, at: now)
        table.apply(cached, at: now)

        let loadingAt = now.addingTimeInterval(60)
        table.beginRefresh(key, at: loadingAt)
        #expect(table[key]?.refreshPhase == .loading)
        #expect(table[key]?.report == cached)

        let failedAt = now.addingTimeInterval(70)
        table.apply(.transportFailure(), for: key, at: failedAt)
        let state = try #require(table[key])
        #expect(state.report == cached)
        #expect(state.refreshPhase == .idle)
        #expect(state.lastError == .transportFailure())
        #expect(state.lastAttemptAt == failedAt)
    }

    @Test("cache → loading → success replaces the report and clears the error")
    func cacheThenLoadingThenSuccessClearsError() throws {
        var table = table()
        table.apply(try report(fraction: 0.4, at: now), at: now)
        table.apply(.transportFailure(), for: key, at: now)
        #expect(table[key]?.lastError != nil)

        let refreshedAt = now.addingTimeInterval(300)
        table.beginRefresh(key, at: refreshedAt)
        let fresh = try report(fraction: 0.6, at: refreshedAt)
        table.apply(fresh, at: refreshedAt)

        let state = try #require(table[key])
        #expect(state.report == fresh)
        #expect(state.lastError == nil)
        #expect(state.refreshPhase == .idle)
    }

    @Test("An out-of-order response older than the cached report is discarded")
    func staleResponseDoesNotMoveTheAccountBackwards() throws {
        var table = table()
        let newest = try report(fraction: 0.6, at: now.addingTimeInterval(300))
        table.apply(newest, at: now.addingTimeInterval(300))
        table.apply(try report(fraction: 0.1, at: now), at: now.addingTimeInterval(301))
        #expect(table[key]?.report == newest)
    }

    @Test("Only invalidation removes a cached report")
    func onlyInvalidationClearsTheReport() throws {
        var table = table()
        table.apply(try report(fraction: 0.4, at: now), at: now)
        table.markScheduled(key)
        #expect(table[key]?.report != nil)
        table.invalidate(key)
        #expect(table[key]?.report == nil)
        #expect(table[key]?.lastError == nil)
    }

    @Test("Re-discovery refreshes display metadata without discarding cached usage")
    func rediscoveryPreservesCachedUsage() throws {
        var table = table()
        let cached = try report(fraction: 0.4, at: now)
        table.apply(cached, at: now)
        table.replaceDiscovered(
            [
                Fixtures.account(
                    key: key,
                    slot: Fixtures.slot("alpha"),
                    displayName: "alpha@example.com",
                    availability: .inactive
                )
            ],
            forProvider: Fixtures.provider,
            at: now
        )
        let state = try #require(table[key])
        #expect(state.report == cached)
        #expect(state.account.displayName == "alpha@example.com")
        #expect(state.account.availability == .inactive)
    }

    @Test("An empty discovery result never blanks a card that is showing usage")
    func emptyDiscoveryKeepsTheRowAndItsReport() throws {
        var table = table()
        let cached = try report(fraction: 0.62, at: now)
        table.apply(cached, at: now)

        table.replaceDiscovered([], forProvider: Fixtures.provider, at: now)

        #expect(table.accounts.count == 1, "an unreadable credential store is not a removal")
        #expect(table[key]?.report == cached)
        #expect(table[key]?.lastError == nil)
    }

    @Test("Transitions for an unknown account are ignored rather than creating a row")
    func unknownAccountTransitionsAreIgnored() throws {
        var table = table()
        let stranger = Fixtures.canonicalKey("stranger")
        table.beginRefresh(stranger, at: now)
        table.apply(.transportFailure(), for: stranger, at: now)
        #expect(table.accounts.count == 1)
        #expect(table[stranger] == nil)
    }
}

import Foundation
import Testing

@testable import UsageKit

@Suite("Multi-account pipeline")
struct MultiAccountPipelineTests {
    @Test("Two accounts of one provider stay distinct through fetch, store, JSON, and history")
    func twoAccountsOfOneProviderStayDistinct() async throws {
        let clock = ManualClock()
        let context = Fixtures.context(clock: clock)
        let provider = PreviewProvider()

        let discovered = try await provider.discoverAccounts(using: context)
        #expect(discovered.count >= 2)
        let first = try #require(discovered.first)
        let second = try #require(discovered.dropFirst().first)
        #expect(first.key != second.key)

        var table = AccountStateTable()
        table.replaceDiscovered(
            discovered,
            forProvider: PreviewProvider.id,
            at: Fixtures.capturedAt
        )
        #expect(table.accounts.count == discovered.count)

        var reports: [UsageReport] = []
        for account in [first, second] {
            table.beginRefresh(account.key, at: clock.now)
            let report = try await provider.fetchUsage(for: account, using: context)
            table.apply(report, at: clock.now)
            reports.append(report)
        }

        #expect(table[first.key]?.report?.accountKey == first.key)
        #expect(table[second.key]?.report?.accountKey == second.key)
        #expect(table[first.key]?.report != table[second.key]?.report)

        let output = UsageOutputV1(
            generatedAt: clock.now,
            accounts: reports.enumerated().map { index, report in
                UsageOutputV1.Account(
                    label: index == 0 ? first.displayName : second.displayName,
                    report: UsageReportDTO(report)
                )
            },
            failures: []
        )
        let decoded = try UsageJSON.decoder().decode(
            UsageOutputV1.self,
            from: try UsageJSON.encoder().encode(output)
        )
        #expect(decoded.accounts.count == 2)
        #expect(decoded.accounts[0].report.accountID != decoded.accounts[1].report.accountID)
        #expect(decoded.accounts[0].label != decoded.accounts[1].label)

        let records = reports.map { HistoryRecordV1(report: $0, recordedAt: clock.now) }
        let rebuilt = try records.map { try $0.report.toModel() }
        #expect(rebuilt == reports)
        #expect(Set(rebuilt.map(\.accountKey)).count == 2)
    }

    @Test("Each account's failure is contained to its own row")
    func failuresDoNotCrossAccounts() async throws {
        let clock = ManualClock()
        let context = Fixtures.context(clock: clock)
        let provider = PreviewProvider()
        let discovered = try await provider.discoverAccounts(using: context)
        let first = try #require(discovered.first)
        let second = try #require(discovered.dropFirst().first)

        var table = AccountStateTable()
        table.replaceDiscovered(
            discovered,
            forProvider: PreviewProvider.id,
            at: Fixtures.capturedAt
        )
        table.apply(
            try await provider.fetchUsage(for: second, using: context),
            at: clock.now
        )
        table.apply(.transportFailure(), for: first.key, at: clock.now)

        #expect(table[first.key]?.lastError == .transportFailure())
        #expect(table[first.key]?.report == nil)
        #expect(table[second.key]?.lastError == nil)
        #expect(table[second.key]?.report != nil)
    }

    @Test("The registry finds registered providers and refuses unknown identifiers")
    func registryLookupIsTotal() {
        let registry = ProviderRegistry(providers: [PreviewProvider()])
        #expect(registry.providerIDs == [PreviewProvider.id])
        #expect(registry.provider(for: PreviewProvider.id) != nil)
        #expect(registry.provider(for: ProviderID("nope")) == nil)
    }
}

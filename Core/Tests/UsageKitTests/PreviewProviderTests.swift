import Foundation
import Testing

@testable import UsageKit

@Suite("Preview provider")
struct PreviewProviderTests {
    private let provider = PreviewProvider()

    @Test("Discovery returns several distinct accounts with exactly one active")
    func discoveryReturnsSeveralAccounts() async throws {
        let accounts = try await provider.discoverAccounts(using: Fixtures.context())
        #expect(accounts.count == 3)
        #expect(Set(accounts.map(\.key)).count == 3)
        #expect(Set(accounts.map(\.slot)).count == 3)
        #expect(accounts.filter { $0.availability == .active }.count == 1)
        #expect(accounts.allSatisfy { $0.key.accountID.derivation == .canonical })
    }

    @Test("The synthetic accounts cover the awkward window shapes")
    func syntheticAccountsCoverEdgeShapes() async throws {
        let clock = ManualClock()
        let context = Fixtures.context(clock: clock)
        let accounts = try await provider.discoverAccounts(using: context)
        var windows: [UsageWindow] = []
        for account in accounts {
            windows += try await provider.fetchUsage(for: account, using: context).windows
        }

        #expect(windows.contains { $0.usedFraction > 1 })
        #expect(windows.contains { $0.resetsAt == nil })
        #expect(
            windows.contains {
                guard case .count = $0.detail else { return false }
                return true
            }
        )
        #expect(
            windows.contains {
                guard case .money = $0.detail else { return false }
                return true
            }
        )
        #expect(Set(windows.map(\.id)).count == windows.count)
    }

    @Test("A credit balance is present on the metered account")
    func creditBalanceIsPresent() async throws {
        let context = Fixtures.context()
        let accounts = try await provider.discoverAccounts(using: context)
        var balances: [CreditBalance] = []
        for account in accounts {
            if let credits = try await provider.fetchUsage(for: account, using: context).credits {
                balances.append(credits)
            }
        }
        #expect(balances.count == 1)
        #expect(balances.first?.currency == "USD")
    }

    @Test("Reports are anchored to the injected clock, not the wall clock")
    func reportsUseTheInjectedClock() async throws {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 1_000_000))
        let context = Fixtures.context(clock: clock)
        let account = try #require(try await provider.discoverAccounts(using: context).first)
        let before = try await provider.fetchUsage(for: account, using: context)
        #expect(before.capturedAt == clock.now)

        clock.advance(by: .seconds(3_600))
        let after = try await provider.fetchUsage(for: account, using: context)
        #expect(after.capturedAt == clock.now)
        #expect(after.capturedAt > before.capturedAt)
    }

    @Test("Fetching for an account the provider does not own fails cleanly")
    func unknownAccountIsRejected() async throws {
        let stranger = Fixtures.account(
            key: Fixtures.canonicalKey("stranger"),
            slot: Fixtures.slot("stranger")
        )
        await #expect(throws: UsageError.providerUnavailable()) {
            try await provider.fetchUsage(for: stranger, using: Fixtures.context())
        }
    }

    @Test("The provider defaults to one concurrent fetch")
    func defaultConcurrencyBoundIsOne() {
        #expect(provider.maxConcurrentFetches == 1)
        #expect(provider.providerID == PreviewProvider.id)
    }
}

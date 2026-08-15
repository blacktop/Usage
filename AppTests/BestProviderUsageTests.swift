import Foundation
import Testing
import UsageKit

@testable import Usage

/// A provider that exists only to give the registry an ID and a display name.
///
/// Registry lookups dispatch through the instance-side `providerID`, so the static requirement
/// never participates in these tests.
private struct NamedProvider: Provider {
    static var id: ProviderID { ProviderID("named") }

    let providerID: ProviderID
    let displayName: String
    let dashboardURL = URL(filePath: "/dev/null")

    func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] { [] }

    func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        throw UsageError.providerUnavailable()
    }
}

@Suite("Best provider selection")
@MainActor
struct BestProviderUsageTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func key(_ provider: String, _ account: String) -> AccountKey {
        let id = ProviderID(provider)
        return AccountKey(providerID: id, accountID: .canonical(provider: id, canonicalID: account))
    }

    private func report(
        _ key: AccountKey,
        usedFractions: [Double],
        isPartial: Bool = false,
        creditsOnly: Bool = false
    ) throws -> UsageReport {
        try UsageReport(
            accountKey: key,
            plan: nil,
            windows: usedFractions.enumerated().map { index, used in
                try UsageWindow(
                    id: WindowID(
                        scope: .additional(feature: "window-\(index)"),
                        slot: .primary,
                        period: .weekly
                    ),
                    kind: .weekly,
                    label: "Window \(index)",
                    usedFraction: used
                )
            },
            credits: creditsOnly
                ? try CreditBalance(remaining: 5, granted: 10, currency: "USD") : nil,
            capturedAt: now,
            isPartial: isPartial
        )
    }

    private func state(
        _ provider: String,
        _ account: String,
        usedFractions: [Double]? = nil,
        isPartial: Bool = false,
        creditsOnly: Bool = false,
        error: UsageError? = nil
    ) throws -> AccountState {
        let key = key(provider, account)
        let projection = AccountProjection(
            key: key,
            slots: [],
            profileRootIDs: [],
            displayName: account,
            availability: .active
        )
        let report = try usedFractions.map {
            try report(key, usedFractions: $0, isPartial: isPartial, creditsOnly: creditsOnly)
        }
        return AccountState(account: projection, report: report, lastError: error)
    }

    private func registry(_ names: [(String, String)]) -> ProviderRegistry {
        ProviderRegistry(
            providers: names.map {
                NamedProvider(providerID: ProviderID($0.0), displayName: $0.1)
            }
        )
    }

    @Test("the provider whose bottleneck window has the most room wins")
    func selectsGreatestHeadroom() throws {
        let accounts = [
            try state("codex", "a", usedFractions: [0.11, 0.60]),
            try state("claude", "b", usedFractions: [0.45, 0.02]),
        ]
        let best = BestProviderUsage.select(
            accounts: accounts,
            registry: registry([("codex", "Codex"), ("claude", "Claude")])
        )
        #expect(best?.providerID == ProviderID("claude"))
        #expect(best?.displayName == "Claude")
        #expect(best?.remainingFraction == 0.55, "the bottleneck window ranks, not the best one")
    }

    @Test("the bottleneck spans every account of the provider")
    func bottleneckSpansAccounts() throws {
        let accounts = [
            try state("codex", "a", usedFractions: [0.10]),
            try state("codex", "b", usedFractions: [0.80]),
            try state("claude", "c", usedFractions: [0.50]),
        ]
        let best = BestProviderUsage.select(
            accounts: accounts,
            registry: registry([("codex", "Codex"), ("claude", "Claude")])
        )
        #expect(best?.providerID == ProviderID("claude"))
        #expect(best?.remainingFraction == 0.5)
    }

    @Test("an account with a current error disqualifies its whole provider")
    func errorDisqualifiesProvider() throws {
        let accounts = [
            try state("codex", "a", usedFractions: [0.05], error: .transportFailure()),
            try state("claude", "b", usedFractions: [0.90]),
        ]
        let best = BestProviderUsage.select(
            accounts: accounts,
            registry: registry([("codex", "Codex"), ("claude", "Claude")])
        )
        #expect(
            best?.providerID == ProviderID("claude"),
            "a cached report beside a failed refresh stays visible but does not compete"
        )
    }

    @Test("a partial report disqualifies its provider")
    func partialReportDisqualifies() throws {
        let accounts = [
            try state("codex", "a", usedFractions: [0.05], isPartial: true),
            try state("claude", "b", usedFractions: [0.90]),
        ]
        let best = BestProviderUsage.select(
            accounts: accounts,
            registry: registry([("codex", "Codex"), ("claude", "Claude")])
        )
        #expect(best?.providerID == ProviderID("claude"))
    }

    @Test("a credits-only report has no capacity value to rank")
    func creditsOnlyDisqualifies() throws {
        let accounts = [
            try state("codex", "a", usedFractions: [], creditsOnly: true),
            try state("claude", "b", usedFractions: [0.90]),
        ]
        let best = BestProviderUsage.select(
            accounts: accounts,
            registry: registry([("codex", "Codex"), ("claude", "Claude")])
        )
        #expect(best?.providerID == ProviderID("claude"))
    }

    @Test("an account still waiting for its first report disqualifies its provider")
    func missingReportDisqualifies() throws {
        let accounts = [
            try state("codex", "a", usedFractions: [0.05]),
            try state("codex", "b"),
            try state("claude", "c", usedFractions: [0.90]),
        ]
        let best = BestProviderUsage.select(
            accounts: accounts,
            registry: registry([("codex", "Codex"), ("claude", "Claude")])
        )
        #expect(best?.providerID == ProviderID("claude"))
    }

    @Test("no eligible provider selects nothing, which keeps the icon-only fallback")
    func nothingEligible() throws {
        let accounts = [
            try state("codex", "a"),
            try state("claude", "b", usedFractions: [0.10], error: .transportFailure()),
        ]
        let best = BestProviderUsage.select(
            accounts: accounts,
            registry: registry([("codex", "Codex"), ("claude", "Claude")])
        )
        #expect(best == nil)
        #expect(BestProviderUsage.select(accounts: [], registry: registry([])) == nil)
    }

    @Test("equal headroom breaks ties by registry order, then by raw provider ID")
    func deterministicTies() throws {
        let tied = [
            try state("claude", "a", usedFractions: [0.30]),
            try state("codex", "b", usedFractions: [0.30]),
        ]
        let registryOrder = BestProviderUsage.select(
            accounts: tied,
            registry: registry([("codex", "Codex"), ("claude", "Claude")])
        )
        #expect(
            registryOrder?.providerID == ProviderID("codex"),
            "registry order decides, not account order"
        )

        let unregistered = BestProviderUsage.select(accounts: tied, registry: registry([]))
        #expect(
            unregistered?.providerID == ProviderID("claude"),
            "providers absent from the registry fall back to raw-ID order"
        )
    }
}

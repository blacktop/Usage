import Foundation
import Testing

@testable import UsageKit

/// A provider whose whole behaviour is scripted, for exercising the collector's own contract
/// rather than any real provider's.
private struct ScriptedProvider: Provider {
    static let id = ProviderID("scripted")

    let providerID: ProviderID
    let accounts: [ProviderAccount]
    let discoveryError: UsageError?
    let reports: [AccountID: Result<UsageReport, UsageError>]

    var displayName: String { providerID.rawValue }
    var dashboardURL: URL { StaticURL.make("https://example.invalid") }

    func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        if let discoveryError { throw discoveryError }
        return accounts
    }

    func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        switch reports[account.key.accountID] {
        case .success(let report): return report
        case .failure(let error): throw error
        case nil: throw UsageError.providerUnavailable()
        }
    }
}

@Suite("Usage collection")
struct UsageCollectorTests {
    private static let alpha = ProviderID("alpha")
    private static let beta = ProviderID("beta")

    private static func account(_ provider: ProviderID, _ name: String) -> ProviderAccount {
        let slot = CredentialSlotID(source: "test", opaqueID: name)
        return ProviderAccount(
            key: AccountKey(
                providerID: provider,
                accountID: .credentialSlot(provider: provider, slot: slot)
            ),
            slot: slot,
            locator: CredentialLocator(kind: .file, identifier: "/dev/null"),
            displayName: name,
            availability: .active
        )
    }

    private static func report(for account: ProviderAccount) throws -> UsageReport {
        try UsageReport(
            accountKey: account.key,
            plan: "pro",
            windows: [],
            capturedAt: Fixtures.capturedAt
        )
    }

    private static func provider(
        _ id: ProviderID,
        accounts: [ProviderAccount],
        failing: [AccountID: UsageError] = [:],
        discoveryError: UsageError? = nil
    ) throws -> ScriptedProvider {
        var reports: [AccountID: Result<UsageReport, UsageError>] = [:]
        for account in accounts {
            if let error = failing[account.key.accountID] {
                reports[account.key.accountID] = .failure(error)
            } else {
                reports[account.key.accountID] = .success(try report(for: account))
            }
        }
        return ScriptedProvider(
            providerID: id,
            accounts: accounts,
            discoveryError: discoveryError,
            reports: reports
        )
    }

    private func collect(_ providers: [any Provider]) async -> UsageCollection {
        await UsageCollector(registry: ProviderRegistry(providers: providers))
            .collect(providers: providers.map(\.providerID), using: Fixtures.context())
    }

    @Test("every provider answering for every account is a complete run")
    func reportsComplete() async throws {
        let collection = await collect([
            try Self.provider(Self.alpha, accounts: [Self.account(Self.alpha, "one")]),
            try Self.provider(Self.beta, accounts: [Self.account(Self.beta, "two")]),
        ])
        #expect(collection.accounts.count == 2)
        #expect(collection.failures.isEmpty)
        #expect(collection.outcome == .complete)
        #expect(collection.outcome.rawValue == 0)
    }

    @Test("one provider failing leaves the other's answer intact")
    func containsFailuresToOneProvider() async throws {
        let alphaAccount = Self.account(Self.alpha, "one")
        let collection = await collect([
            try Self.provider(
                Self.alpha,
                accounts: [alphaAccount],
                failing: [alphaAccount.key.accountID: .transportFailure()]
            ),
            try Self.provider(Self.beta, accounts: [Self.account(Self.beta, "two")]),
        ])

        #expect(collection.accounts.map(\.report.accountKey.providerID) == [Self.beta])
        #expect(collection.failures.map(\.providerID) == [Self.alpha])
        #expect(collection.failures.first?.accountID == alphaAccount.key.accountID)
        #expect(collection.outcome == .partial)
        #expect(collection.outcome.rawValue == 2)
    }

    @Test("one account failing inside a healthy provider is still only a partial answer")
    func partialWithinOneProvider() async throws {
        let first = Self.account(Self.alpha, "one")
        let second = Self.account(Self.alpha, "two")
        let collection = await collect([
            try Self.provider(
                Self.alpha,
                accounts: [first, second],
                failing: [second.key.accountID: .transportFailure()]
            )
        ])
        #expect(collection.accounts.count == 1)
        #expect(collection.failures.count == 1)
        #expect(collection.outcome == .partial)
    }

    @Test("nothing answering at all is a total failure")
    func reportsTotalFailure() async throws {
        let account = Self.account(Self.alpha, "one")
        let collection = await collect([
            try Self.provider(
                Self.alpha,
                accounts: [account],
                failing: [account.key.accountID: .transportFailure()]
            )
        ])
        #expect(collection.accounts.isEmpty)
        #expect(collection.outcome == .none)
        #expect(collection.outcome.rawValue == 1)
    }

    @Test("a provider that discovers no account is unavailable rather than silently absent")
    func reportsUnavailableProvider() async throws {
        let collection = await collect([try Self.provider(Self.alpha, accounts: [])])
        let failure = try #require(collection.failures.first)
        #expect(failure.error.category == .providerUnavailable)
        #expect(failure.accountID == nil)
        #expect(collection.outcome == .none)
    }

    @Test("a discovery failure is attributed to the provider, not to an account")
    func reportsDiscoveryFailure() async throws {
        let collection = await collect([
            try Self.provider(
                Self.alpha,
                accounts: [],
                discoveryError: .interactionForbidden()
            )
        ])
        let failure = try #require(collection.failures.first)
        #expect(failure.error.category == .interactionRequired)
        #expect(failure.accountID == nil)
    }

    @Test("an unregistered provider is reported, not skipped")
    func reportsUnknownProvider() async {
        let collection = await UsageCollector(registry: ProviderRegistry(providers: []))
            .collect(providers: [Self.alpha], using: Fixtures.context())
        #expect(collection.failures.map(\.providerID) == [Self.alpha])
        #expect(collection.failures.first?.error.category == .providerUnavailable)
    }

    @Test("results follow the requested order, not the order the providers finished in")
    func ordersResultsDeterministically() async throws {
        let providers: [any Provider] = [
            try Self.provider(Self.beta, accounts: [Self.account(Self.beta, "two")]),
            try Self.provider(Self.alpha, accounts: [Self.account(Self.alpha, "one")]),
        ]
        let registry = ProviderRegistry(providers: providers)
        for _ in 0..<8 {
            let collection = await UsageCollector(registry: registry)
                .collect(providers: [Self.alpha, Self.beta], using: Fixtures.context())
            #expect(
                collection.accounts.map(\.report.accountKey.providerID) == [
                    Self.alpha, Self.beta,
                ])
        }
    }

    @Test("a provider's accounts keep their discovery order")
    func keepsAccountOrder() async throws {
        let accounts = [Self.account(Self.alpha, "one"), Self.account(Self.alpha, "two")]
        let collection = await collect([try Self.provider(Self.alpha, accounts: accounts)])
        #expect(collection.accounts.map(\.account.displayName) == ["one", "two"])
    }

    @Test("the envelope carries every account and every failure")
    func buildsTheEnvelope() async throws {
        let alphaAccount = Self.account(Self.alpha, "one")
        let collection = await collect([
            try Self.provider(Self.alpha, accounts: [alphaAccount]),
            try Self.provider(
                Self.beta,
                accounts: [],
                discoveryError: UsageError.transportFailure()
            ),
        ])
        let output = collection.output(generatedAt: Fixtures.recordedAt)

        #expect(output.schemaVersion == 1)
        #expect(output.generatedAt == 1_700_000_060)
        #expect(output.accounts.map(\.label) == ["one"])
        #expect(output.accounts.first?.report.providerID == "alpha")
        #expect(output.failures.map(\.providerID) == ["beta"])
    }
}

@Suite("Provider selection")
struct ProviderSelectionTests {
    @Test("no selection means every registered provider, in registration order")
    func defaultsToEveryProvider() throws {
        #expect(
            try ProviderRegistry.agents.resolve([]).map(\.rawValue) == [
                "codex", "claude", "copilot",
            ])
    }

    @Test("a selection is de-duplicated and case-insensitive, keeping the order given")
    func normalisesSelection() throws {
        #expect(
            try ProviderRegistry.agents.resolve(["Copilot", "codex", "copilot"]).map(\.rawValue)
                == ["copilot", "codex"]
        )
    }

    @Test("every unknown name is reported at once")
    func reportsUnknownNames() {
        #expect(throws: UnknownProviderIDs(names: ["gemini", "cursor"])) {
            try ProviderRegistry.agents.resolve(["codex", "gemini", "cursor"])
        }
    }
}

import Foundation
import Synchronization
import UsageKit

/// A provider whose discovery and fetch outcomes are scripted, so the store's failure paths can be
/// driven without a test-only hook in the store itself.
final class ScriptedProvider: Provider, Sendable {
    static let id = ProviderID("scripted")

    let displayName = "Scripted"
    let dashboardURL = URL(filePath: "/dev/null")

    static let accountKey = AccountKey(
        providerID: id,
        accountID: .canonical(provider: id, canonicalID: "scripted-1")
    )

    static let account = ProviderAccount(
        key: accountKey,
        slot: CredentialSlotID(source: "scripted", opaqueID: "scripted-1"),
        locator: CredentialLocator(kind: .file, identifier: "/dev/null"),
        displayName: "scripted@example.com",
        availability: .active
    )

    /// An error that is deliberately not a `UsageError` and carries a token-shaped description, so
    /// a test can prove nothing but a redacted error reaches the store.
    struct ForeignError: Error {
        let description = "Bearer sk-proj-LEAKED"
    }

    private struct Script {
        var discoveryFailure: UsageError?
        var fetchFailures: [UsageError] = []
        var foreignFailures = 0
    }

    private let script = Mutex(Script())

    init() {}

    func failDiscovery(with error: UsageError?) {
        script.withLock { $0.discoveryFailure = error }
    }

    /// Queues one failing fetch. Later fetches succeed again.
    func failNextFetch(with error: UsageError) {
        script.withLock { $0.fetchFailures.append(error) }
    }

    /// Queues one fetch that throws something the app has never seen before.
    func throwForeignErrorOnNextFetch() {
        script.withLock { $0.foreignFailures += 1 }
    }

    func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        if let failure = script.withLock({ $0.discoveryFailure }) { throw failure }
        return [Self.account]
    }

    func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        let outcome = script.withLock { script -> (failure: UsageError?, foreign: Bool) in
            guard script.foreignFailures == 0 else {
                script.foreignFailures -= 1
                return (nil, true)
            }
            guard !script.fetchFailures.isEmpty else { return (nil, false) }
            return (script.fetchFailures.removeFirst(), false)
        }
        if outcome.foreign { throw ForeignError() }
        if let failure = outcome.failure { throw failure }
        return try UsageReport(
            accountKey: account.key,
            plan: "scripted",
            windows: [
                UsageWindow(
                    id: WindowID(scope: .plan, slot: .primary, period: .weekly),
                    kind: .weekly,
                    label: "Weekly",
                    usedFraction: 0.5
                )
            ],
            capturedAt: context.clock.now
        )
    }
}

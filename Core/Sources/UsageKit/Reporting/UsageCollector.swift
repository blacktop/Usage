/// Runs discovery and fetch across a set of providers and collects both halves of the answer.
///
/// Different providers run concurrently in a non-throwing task group, so one provider's failure
/// neither cancels nor discards another's result. Accounts within one provider run in sequence,
/// which honours every `maxConcurrentFetches` bound a provider can declare and keeps a provider
/// with many accounts from opening a burst of connections to an undocumented endpoint.
public struct UsageCollector: Sendable {
    private let registry: ProviderRegistry

    public init(registry: ProviderRegistry) {
        self.registry = registry
    }

    public func collect(
        providers requested: [ProviderID],
        using context: ProviderContext
    ) async -> UsageCollection {
        var results: [ProviderID: Batch] = [:]
        await withTaskGroup(of: (ProviderID, Batch).self) { group in
            for id in requested {
                guard let provider = registry.provider(for: id) else {
                    results[id] = Batch.unavailable(id)
                    continue
                }
                group.addTask { (id, await Self.batch(from: provider, using: context)) }
            }
            for await (id, batch) in group {
                results[id] = batch
            }
        }
        return UsageCollection(
            requested: requested,
            accounts: requested.flatMap { results[$0]?.accounts ?? [] },
            failures: requested.flatMap { results[$0]?.failures ?? [] }
        )
    }

    /// One provider's accounts and failures.
    private struct Batch: Sendable {
        var accounts: [CollectedAccount] = []
        var failures: [CollectedFailure] = []

        static func unavailable(_ id: ProviderID) -> Batch {
            Batch(
                failures: [
                    CollectedFailure(
                        providerID: id,
                        accountID: nil,
                        error: .providerUnavailable()
                    )
                ]
            )
        }
    }

    private static func batch(
        from provider: any Provider,
        using context: ProviderContext
    ) async -> Batch {
        let id = provider.providerID
        let discovered: [ProviderAccount]
        do {
            discovered = try await provider.discoverAccounts(using: context)
        } catch {
            return Batch(
                failures: [
                    CollectedFailure(
                        providerID: id,
                        accountID: nil,
                        error: UsageError.normalized(error)
                    )
                ]
            )
        }
        guard !discovered.isEmpty else { return .unavailable(id) }
        return await fetchAll(discovered, from: provider, using: context)
    }

    private static func fetchAll(
        _ accounts: [ProviderAccount],
        from provider: any Provider,
        using context: ProviderContext
    ) async -> Batch {
        var batch = Batch()
        for account in accounts {
            do {
                batch.accounts.append(
                    CollectedAccount(
                        account: account,
                        report: try await provider.fetchUsage(for: account, using: context)
                    )
                )
            } catch {
                batch.failures.append(
                    CollectedFailure(
                        providerID: provider.providerID,
                        accountID: account.key.accountID,
                        error: UsageError.normalized(error)
                    )
                )
            }
        }
        return batch
    }
}

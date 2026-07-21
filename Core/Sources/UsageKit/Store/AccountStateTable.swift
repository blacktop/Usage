import Foundation

/// The store's projection: one row per logical account, keyed by resolved identity.
///
/// Every lookup resolves aliases first, so a report fetched under a retired credential-slot
/// identity lands on the same row as one fetched under the canonical identity.
public struct AccountStateTable: Sendable, Hashable {
    public private(set) var reconciler: IdentityReconciler
    private var states: [AccountKey: AccountState]
    private var order: [AccountKey]

    public init(reconciler: IdentityReconciler = IdentityReconciler()) {
        self.reconciler = reconciler
        states = [:]
        order = []
    }

    /// Rows in discovery order.
    public var accounts: [AccountState] {
        order.compactMap { states[$0] }
    }

    public subscript(key: AccountKey) -> AccountState? {
        states[reconciler.resolve(key)]
    }

    /// Replaces the discovered account set. Rows whose accounts are gone are removed; rows that
    /// survive keep their cached report, phase, and error.
    ///
    /// An empty result is not a removal. Discovery answers with an empty array both for "this
    /// account is gone" and for "the credential store could not be read this instant" — a locked
    /// Keychain, a credential file caught mid-rewrite — so treating it as authoritative would blank
    /// a card that is showing a perfectly good report, with no error to explain why.
    public mutating func replaceDiscovered(
        _ accounts: [ProviderAccount], forProvider id: ProviderID, at date: Date
    ) {
        guard !accounts.isEmpty else { return }
        promoteFallbacks(among: accounts, at: date)
        let projections = reconciler.project(accounts)
        let surviving = Set(projections.map(\.key))
        for key in order where key.providerID == id && !surviving.contains(key) {
            states[key] = nil
        }
        order.removeAll { $0.providerID == id && !surviving.contains($0) }
        for projection in projections {
            if let existing = states[projection.key] {
                states[projection.key] = existing.withAccount(projection)
            } else {
                states[projection.key] = AccountState(account: projection)
                order.append(projection.key)
            }
        }
    }

    public mutating func markScheduled(_ key: AccountKey) {
        mutate(key) { $0.scheduled() }
    }

    public mutating func beginRefresh(_ key: AccountKey, at date: Date) {
        mutate(key) { $0.beganRefresh(at: date) }
    }

    /// Applies a successful fetch. A report for a row that no longer exists — an account that
    /// disappeared while its fetch was in flight — is dropped rather than resurrecting the row.
    public mutating func apply(_ report: UsageReport, at date: Date) {
        mutate(report.accountKey) { $0.succeeded(with: report, at: date) }
    }

    public mutating func apply(_ error: UsageError, for key: AccountKey, at date: Date) {
        mutate(key) { $0.failed(with: error, at: date) }
    }

    public mutating func invalidate(_ key: AccountKey) {
        mutate(key) { $0.invalidated() }
    }

    /// Records a fallback-to-canonical promotion and folds the retired row into the canonical one.
    ///
    /// The newest report by `capturedAt` wins and the retired row is removed, so promotion can
    /// never leave two live rows for one account.
    @discardableResult
    public mutating func promote(
        fallback: AccountKey,
        canonical: AccountKey,
        at date: Date
    ) -> IdentityReconciler.Observation {
        let observation = reconciler.observe(fallback: fallback, canonical: canonical, at: date)
        guard observation == .recorded else { return observation }
        guard let retired = states[fallback] else { return observation }
        states[fallback] = nil
        order.removeAll { $0 == fallback }
        let rekeyed = retired.withAccount(retired.account.withKey(canonical))
        guard let existing = states[canonical] else {
            states[canonical] = rekeyed
            order.append(canonical)
            return observation
        }
        states[canonical] = Self.merge(existing: existing, retired: rekeyed)
        return observation
    }

    /// Records the promotion the provider has just proved by naming a canonical identity for a
    /// credential slot an account is already keyed by.
    ///
    /// Without this, a provider whose canonical identifier appears late — or disappears for one
    /// discovery because the credential file was caught mid-write — deletes the row it had and
    /// builds an empty one under the other identity, taking the cached report with it.
    private mutating func promoteFallbacks(among accounts: [ProviderAccount], at date: Date) {
        for account in accounts where account.key.accountID.derivation == .canonical {
            let fallback = AccountKey(
                providerID: account.key.providerID,
                accountID: .credentialSlot(provider: account.key.providerID, slot: account.slot)
            )
            guard states[fallback] != nil else { continue }
            promote(fallback: fallback, canonical: account.key, at: date)
        }
    }

    private static func merge(existing: AccountState, retired: AccountState) -> AccountState {
        let keepsExisting = Self.isNewer(existing.report, than: retired.report)
        let winner = keepsExisting ? existing : retired
        let loser = keepsExisting ? retired : existing
        return AccountState(
            account: existing.account.merging(retired.account),
            report: winner.report,
            refreshPhase: existing.refreshPhase,
            lastError: Self.survivingError(winner: winner, loser: loser),
            lastAttemptAt: [existing.lastAttemptAt, retired.lastAttemptAt].compactMap(\.self).max()
        )
    }

    /// The error that belongs beside the report that survived.
    ///
    /// The losing row's error is kept only while it still describes something the winning report
    /// has not superseded. Attaching a retired row's authentication failure to numbers fetched
    /// after it would tell the user to sign in to an account that is authenticating fine.
    private static func survivingError(winner: AccountState, loser: AccountState) -> UsageError? {
        if let error = winner.lastError { return error }
        guard let captured = winner.report?.capturedAt, let attempted = loser.lastAttemptAt,
            captured > attempted
        else { return loser.lastError }
        return nil
    }

    private static func isNewer(_ lhs: UsageReport?, than rhs: UsageReport?) -> Bool {
        guard let rhs else { return true }
        guard let lhs else { return false }
        return lhs.capturedAt >= rhs.capturedAt
    }

    private mutating func mutate(_ key: AccountKey, _ transform: (AccountState) -> AccountState) {
        let resolved = reconciler.resolve(key)
        guard let existing = states[resolved] else { return }
        states[resolved] = transform(existing)
    }
}

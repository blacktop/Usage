import Foundation

/// Resolves credential-slot-derived account identities onto the canonical identities that replaced
/// them, and decides when a new alias may be recorded.
///
/// Two rules do the work. Alias resolution runs before every store, history, latest-cache,
/// notification-dedupe, and account-selection lookup, so a promoted account keeps one row and one
/// history. And an alias is never overwritten: when a credential slot is reused by a *different*
/// canonical account, that account is simply keyed by its own canonical identity, and the previous
/// account's history stays attached to the previous identity.
public struct IdentityReconciler: Sendable, Hashable {
    private struct Entry: Sendable, Hashable {
        let canonical: AccountID
        let recordedAt: Date
    }

    /// What `observe` did, so a caller can tell a real promotion from a no-op or a conflict.
    public enum Observation: Sendable, Hashable {
        /// A new alias was recorded; the fallback identity is now retired.
        case recorded
        /// The same alias was already present.
        case unchanged
        /// The pair is not a fallback/canonical promotion at all.
        case notApplicable
        /// The fallback is already aliased elsewhere. Nothing is rewritten.
        case conflict(existing: AccountID)
    }

    private static let maximumChainDepth = 8

    private var entries: [AccountKey: Entry]

    public init() {
        entries = [:]
    }

    public init(_ map: IdentityAliasMapV1) throws {
        entries = [:]
        for alias in map.aliases {
            let providerID = ProviderID(alias.providerID)
            guard let retired = AccountID(rawValue: alias.retiredAccountID),
                let canonical = AccountID(rawValue: alias.canonicalAccountID)
            else {
                throw UsageError.decodingFailure(field: "identityAliases.accountID")
            }
            let key = AccountKey(providerID: providerID, accountID: retired)
            guard entries[key] == nil else {
                throw UsageError.invalidValue(
                    field: "identityAliases.retiredAccountID",
                    rule: .unique
                )
            }
            entries[key] = Entry(
                canonical: canonical,
                recordedAt: Date(timeIntervalSince1970: TimeInterval(alias.recordedAt))
            )
        }
    }

    /// Maps a possibly retired identity onto the identity everything is keyed by today.
    ///
    /// Bounded and cycle-safe: a corrupt persisted map cannot make a lookup hang.
    public func resolve(_ key: AccountKey) -> AccountKey {
        var current = key
        var seen: Set<AccountKey> = [key]
        for _ in 0..<Self.maximumChainDepth {
            guard let entry = entries[current] else { return current }
            let next = AccountKey(providerID: current.providerID, accountID: entry.canonical)
            guard seen.insert(next).inserted else { return current }
            current = next
        }
        return current
    }

    /// Records that `fallback` and `canonical` are the same account.
    @discardableResult
    public mutating func observe(
        fallback: AccountKey,
        canonical: AccountKey,
        at date: Date
    ) -> Observation {
        guard fallback.providerID == canonical.providerID,
            fallback.accountID.derivation == .credentialSlot,
            canonical.accountID.derivation == .canonical
        else {
            return .notApplicable
        }
        if let existing = entries[fallback] {
            return existing.canonical == canonical.accountID
                ? .unchanged : .conflict(existing: existing.canonical)
        }
        entries[fallback] = Entry(canonical: canonical.accountID, recordedAt: date)
        return .recorded
    }

    public var aliasMap: IdentityAliasMapV1 {
        IdentityAliasMapV1(
            aliases: entries.map { key, entry in
                IdentityAliasMapV1.Alias(
                    providerID: key.providerID.rawValue,
                    retiredAccountID: key.accountID.rawValue,
                    canonicalAccountID: entry.canonical.rawValue,
                    recordedAt: Int64(entry.recordedAt.timeIntervalSince1970.rounded())
                )
            }
        )
    }
}

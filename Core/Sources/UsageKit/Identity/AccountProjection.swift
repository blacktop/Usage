/// One logical account, after alias resolution has folded together every credential slot that
/// resolves to the same identity.
public struct AccountProjection: Sendable, Hashable, Identifiable {
    public let key: AccountKey
    /// Every credential slot that projects onto this account, in discovery order.
    public let slots: [CredentialSlotID]
    public let displayName: String?
    public let availability: ProviderAccount.Availability

    public var id: AccountKey { key }

    public init(
        key: AccountKey,
        slots: [CredentialSlotID],
        displayName: String?,
        availability: ProviderAccount.Availability
    ) {
        self.key = key
        self.slots = slots
        self.displayName = displayName
        self.availability = availability
    }

    /// Re-keys a projection onto the identity that superseded it.
    public func withKey(_ key: AccountKey) -> AccountProjection {
        AccountProjection(
            key: key,
            slots: slots,
            displayName: displayName,
            availability: availability
        )
    }
}

extension IdentityReconciler {
    /// Folds discovered accounts onto their resolved identities.
    ///
    /// Two slots that resolve to one identity become one projection with two slots. Accounts that
    /// merely share a display label stay separate, because the label is not identity.
    public func project(_ accounts: [ProviderAccount]) -> [AccountProjection] {
        var order: [AccountKey] = []
        var grouped: [AccountKey: [ProviderAccount]] = [:]
        for account in accounts {
            let key = resolve(account.key)
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(account)
        }
        return order.compactMap { key in
            guard let members = grouped[key] else { return nil }
            return AccountProjection(
                key: key,
                slots: Self.orderedSlots(of: members),
                displayName: members.compactMap(\.displayName).first,
                availability: Self.mostAvailable(of: members)
            )
        }
    }

    private static func orderedSlots(of accounts: [ProviderAccount]) -> [CredentialSlotID] {
        var seen: Set<CredentialSlotID> = []
        return accounts.map(\.slot).filter { seen.insert($0).inserted }
    }

    private static func mostAvailable(
        of accounts: [ProviderAccount]
    ) -> ProviderAccount.Availability {
        if accounts.contains(where: { $0.availability == .active }) { return .active }
        if accounts.contains(where: { $0.availability == .inactive }) { return .inactive }
        return .unavailable
    }
}

/// One logical account, after alias resolution has folded together every credential slot that
/// resolves to the same identity.
public struct AccountProjection: Sendable, Hashable, Identifiable {
    public let key: AccountKey
    /// Every credential slot that projects onto this account, in discovery order.
    public let slots: [CredentialSlotID]
    /// Every configured root represented by those slots, in discovery order.
    public let profileRootIDs: [ProfileRootID]
    public let displayName: String?
    public let availability: ProviderAccount.Availability

    public var id: AccountKey { key }

    public init(
        key: AccountKey,
        slots: [CredentialSlotID],
        profileRootIDs: [ProfileRootID] = [],
        displayName: String?,
        availability: ProviderAccount.Availability
    ) {
        self.key = key
        self.slots = slots
        self.profileRootIDs = profileRootIDs
        self.displayName = displayName
        self.availability = availability
    }

    /// Re-keys a projection onto the identity that superseded it.
    public func withKey(_ key: AccountKey) -> AccountProjection {
        AccountProjection(
            key: key,
            slots: slots,
            profileRootIDs: profileRootIDs,
            displayName: displayName,
            availability: availability
        )
    }

    /// Combines the discovery metadata of two rows already resolved onto this account.
    func merging(_ other: AccountProjection) -> AccountProjection {
        AccountProjection(
            key: key,
            slots: Self.uniqued(slots + other.slots),
            profileRootIDs: Self.uniqued(profileRootIDs + other.profileRootIDs),
            displayName: displayName ?? other.displayName,
            availability: Self.mostAvailable(availability, other.availability)
        )
    }

    /// `values` with later duplicates dropped, so discovery order survives every fold.
    fileprivate static func uniqued<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen: Set<Element> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// The best state either side can prove. Folding a set of rows starts from `.unavailable`, so
    /// no rows at all is the same answer as no usable row.
    fileprivate static func mostAvailable(
        _ first: ProviderAccount.Availability,
        _ second: ProviderAccount.Availability
    ) -> ProviderAccount.Availability {
        if first == .active || second == .active { return .active }
        if first == .inactive || second == .inactive { return .inactive }
        return .unavailable
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
                slots: AccountProjection.uniqued(members.map(\.slot)),
                profileRootIDs: AccountProjection.uniqued(members.compactMap(\.profileRootID)),
                displayName: members.compactMap(\.displayName).first,
                availability: members.map(\.availability)
                    .reduce(.unavailable, AccountProjection.mostAvailable)
            )
        }
    }
}

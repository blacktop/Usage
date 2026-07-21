/// The identity every store row, history record, notification, and selection is keyed by.
public struct AccountKey: Sendable, Hashable, Codable {
    public let providerID: ProviderID
    public let accountID: AccountID

    public init(providerID: ProviderID, accountID: AccountID) {
        self.providerID = providerID
        self.accountID = accountID
    }
}

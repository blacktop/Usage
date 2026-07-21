/// A discovered account, described without any secret material.
///
/// The coordinator and the store retain these safely: every field is non-secret by construction,
/// and a `Credential` is neither `Sendable` nor able to vend its secret as a value, so no field
/// here can be filled from one. A provider resolves `locator` through `CredentialSource` inside a
/// single operation instead.
public struct ProviderAccount: Sendable, Hashable, Identifiable {
    /// Discovery state, collapsing "is this the agent's selected account" and "can we read it".
    public enum Availability: String, Sendable, Hashable, Codable, CaseIterable {
        /// The account the owning agent is currently signed in as.
        case active
        /// Discovered and usable, but not the agent's current selection.
        case inactive
        /// Discovered, but its credential is missing, expired, or unreadable without UI.
        case unavailable
    }

    public let key: AccountKey
    public let slot: CredentialSlotID
    public let locator: CredentialLocator
    /// Human-facing label such as an email or workspace name. Never used as identity.
    public let displayName: String?
    public let availability: Availability

    public var id: AccountKey { key }

    public init(
        key: AccountKey,
        slot: CredentialSlotID,
        locator: CredentialLocator,
        displayName: String? = nil,
        availability: Availability = .inactive
    ) {
        self.key = key
        self.slot = slot
        self.locator = locator
        self.displayName = displayName
        self.availability = availability
    }
}

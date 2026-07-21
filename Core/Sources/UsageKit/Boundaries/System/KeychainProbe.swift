import Foundation
import Security

/// A Keychain `OSStatus` reduced to a redacted outcome category.
///
/// The numeric status travels alongside it everywhere, so an unmapped value is still recorded
/// exactly rather than flattened into a category and lost.
public enum KeychainProbeCategory: String, Sendable, Codable, CaseIterable {
    case success
    case itemNotFound
    case interactionNotAllowed
    case authFailed
    case userCanceled
    case other

    public init(status: OSStatus) {
        switch status {
        case errSecSuccess: self = .success
        case errSecItemNotFound: self = .itemNotFound
        case errSecInteractionNotAllowed: self = .interactionNotAllowed
        case errSecAuthFailed: self = .authFailed
        case errSecUserCanceled: self = .userCanceled
        default: self = .other
        }
    }
}

/// The enumeration leg's result: how the query ended, and how many rows matched.
///
/// Attributes, account names, and row references are read by the query and never leave it. A count
/// is the most this can say about what is stored.
public struct KeychainEnumerationOutcome: Sendable, Codable, Equatable {
    public let status: Int32
    public let itemCount: Int

    public init(status: Int32, itemCount: Int) {
        self.status = status
        self.itemCount = itemCount
    }

    public var category: KeychainProbeCategory { KeychainProbeCategory(status: status) }
}

/// The payload leg's result.
///
/// There is deliberately no byte count and no value here. A length is still information about a
/// secret, so the read is reduced to "non-empty or not" at the point of the read and the value is
/// dropped before this type is constructed.
public struct KeychainPayloadOutcome: Sendable, Codable, Equatable {
    public let status: Int32
    public let didReadPayload: Bool
    public let isPayloadPresent: Bool

    public init(status: Int32, didReadPayload: Bool, isPayloadPresent: Bool) {
        self.status = status
        self.didReadPayload = didReadPayload
        self.isPayloadPresent = isPayloadPresent
    }

    public var category: KeychainProbeCategory { KeychainProbeCategory(status: status) }
}

/// The Keychain feasibility gate's diagnostic probe.
///
/// **This type exists only for the gate. No refresh, discovery, or provider path uses it.**
/// `KeychainCredentialSource` remains the only production reader; it collapses every failure to
/// "nothing is visible", which is the right answer for a refresh whose optional secondary source is
/// locked, and useless as a measurement. The gate needs to tell "no items exist" from
/// `errSecInteractionNotAllowed` from `errSecAuthFailed`, so it needs the `OSStatus` the production
/// path throws away.
///
/// Every query it sends is built by `KeychainCredentialSource` and policed by the same
/// `KeychainNoUIPolicy`, so what the gate measures is what production sends. A gate that tested a
/// query of its own shape would prove nothing about the production one.
public struct KeychainProbe: Sendable {
    /// The one service the gate is scoped to.
    public static let claudeService = ClaudeCredentialFile.keychainService

    public init() {}

    /// One enumeration's result, and the row a payload read would address.
    ///
    /// The reference never leaves the probe. It addresses a row and so identifies an account, and
    /// nothing the gate reports carries either.
    struct Enumeration {
        let outcome: KeychainEnumerationOutcome
        let newest: KeychainItemReference?
    }

    /// Matches every row under `service`, returning only the status and how many there were.
    public func enumerate(service: String, allowsCredentialUI: Bool) -> KeychainEnumerationOutcome {
        enumeration(service: service, allowsCredentialUI: allowsCredentialUI).outcome
    }

    /// Reads the newest row's payload the way a provider would, then discards it.
    public func readPayload(service: String, allowsCredentialUI: Bool) -> KeychainPayloadOutcome {
        payloadOutcome(
            after: enumeration(service: service, allowsCredentialUI: allowsCredentialUI),
            allowsCredentialUI: allowsCredentialUI
        )
    }

    func enumeration(service: String, allowsCredentialUI: Bool) -> Enumeration {
        var matched: CFTypeRef?
        let status = SecItemCopyMatching(
            Self.enumerationQuery(service: service, allowsCredentialUI: allowsCredentialUI)
                as CFDictionary,
            &matched
        )
        let rows = (matched as? [[String: Any]]) ?? []
        return Enumeration(
            outcome: KeychainEnumerationOutcome(status: status, itemCount: rows.count),
            newest: rows.compactMap(KeychainItem.init)
                .min(by: KeychainItem.newestFirst)?.reference
        )
    }

    /// The payload read itself, so the value's whole lifetime is these few lines.
    ///
    /// The row is addressed by the persistent reference the enumeration returned, because that is
    /// how production addresses it. When enumeration produced no row the payload query is never
    /// issued, and the enumeration's own status is reported as the reason.
    func payloadOutcome(
        after enumerated: Enumeration,
        allowsCredentialUI: Bool
    ) -> KeychainPayloadOutcome {
        guard let reference = enumerated.newest else {
            return KeychainPayloadOutcome(
                status: enumerated.outcome.status,
                didReadPayload: false,
                isPayloadPresent: false
            )
        }
        var payload: CFTypeRef?
        let status = SecItemCopyMatching(
            Self.payloadQuery(reference: reference, allowsCredentialUI: allowsCredentialUI)
                as CFDictionary,
            &payload
        )
        let isPayloadPresent = (payload as? Data).map { !$0.isEmpty } ?? false
        payload = nil
        return KeychainPayloadOutcome(
            status: status,
            didReadPayload: true,
            isPayloadPresent: isPayloadPresent
        )
    }

    static func enumerationQuery(service: String, allowsCredentialUI: Bool) -> [String: Any] {
        source(allowsCredentialUI: allowsCredentialUI)
            .policed(KeychainCredentialSource.enumerationQuery(service: service))
    }

    static func payloadQuery(
        reference: KeychainItemReference,
        allowsCredentialUI: Bool
    ) -> [String: Any] {
        source(allowsCredentialUI: allowsCredentialUI)
            .policed(KeychainCredentialSource.payloadQuery(reference: reference))
    }

    /// The production source, configured by the caller's explicit choice.
    ///
    /// There is no default: a probe that silently permitted UI would raise a dialog the operator
    /// running the gate did not ask for.
    private static func source(allowsCredentialUI: Bool) -> KeychainCredentialSource {
        let interaction: any InteractionPolicy =
            allowsCredentialUI ? UserInitiatedInteractionPolicy() : BackgroundInteractionPolicy()
        return KeychainCredentialSource(interaction: interaction)
    }
}

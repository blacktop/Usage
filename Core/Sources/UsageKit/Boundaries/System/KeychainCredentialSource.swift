import Foundation
import Security

/// A Keychain row's persistent reference, carried through `CredentialLocator.identifier`.
///
/// Base64 of the reference rather than a `service/account` pair, because both of those attributes
/// are free-form strings that can contain whatever separator we might otherwise pick. The reference
/// addresses a row and carries no secret material.
struct KeychainItemReference: Hashable, Sendable {
    let data: Data

    var identifier: String { data.base64EncodedString() }

    init(data: Data) {
        self.data = data
    }

    init?(identifier: String) {
        guard let data = Data(base64Encoded: identifier), !data.isEmpty else { return nil }
        self.data = data
    }
}

/// The production `CredentialSource` for `.keychain` locators.
///
/// Under the background policy — which every scheduled refresh and the whole CLI run under — every
/// query carries `KeychainNoUIPolicy`, so a refresh can never raise an Allow/Deny or password
/// dialog: it fails with `errSecInteractionNotAllowed`, which becomes `.interactionRequired`. A
/// explicit account action retries the same locator under `UserInitiatedInteractionPolicy`, which
/// is the one construction that omits the no-UI markers and therefore the one that can prompt.
///
/// Enumeration is attributes-only — `kSecReturnData` is absent from that query by construction —
/// so discovering which accounts exist can never read one.
public struct KeychainCredentialSource: CredentialSource {
    private let noUI = KeychainNoUIPolicy()
    private let allowsCredentialUI: Bool
    private let suppressionAvailable: Bool

    public init(interaction: any InteractionPolicy = BackgroundInteractionPolicy()) {
        self.init(
            interaction: interaction,
            suppressionAvailable: KeychainUserInteraction.isAvailable
        )
    }

    /// Test seam for the process-wide suppression lever, which cannot be faked through dlsym.
    init(interaction: any InteractionPolicy, suppressionAvailable: Bool) {
        allowsCredentialUI = interaction.allowsCredentialUI
        self.suppressionAvailable = suppressionAvailable
    }

    /// Items visible under `namespace.identifier`, read as a Keychain service, newest first.
    ///
    /// A query that fails for any reason answers "nothing is visible without UI", which is the
    /// honest result for discovery: the alternative is failing a provider's whole account
    /// enumeration because one optional secondary source is locked.
    public func slots(in namespace: CredentialLocator) async throws -> [CredentialSlotDescriptor] {
        guard namespace.kind == .keychain else { return [] }
        let (status, result) = copyMatching(Self.enumerationQuery(service: namespace.identifier))
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return
            items
            .compactMap(KeychainItem.init)
            .sorted(by: KeychainItem.newestFirst)
            .map { $0.descriptor(service: namespace.identifier) }
    }

    public func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T {
        guard locator.kind == .keychain,
            let reference = KeychainItemReference(identifier: locator.identifier)
        else {
            throw UsageError.credentialUnavailable(kind: locator.kind)
        }
        let payload = try payload(for: reference)
        let secret = try CredentialDocument.secret(in: payload, at: locator.path, kind: .keychain)
        return try await operation(Credential(secret: secret, document: payload))
    }

    /// `query` with the no-UI markers applied, unless the caller's policy permits credential UI.
    ///
    /// This is the whole difference between a background read and an explicit approval action.
    /// Applying the markers unconditionally would make `UserInitiatedInteractionPolicy` inert and
    /// leave the `.interactionRequired` message telling the user to do something with no
    /// implementation.
    func policed(_ query: [String: Any]) -> [String: Any] {
        allowsCredentialUI ? query : noUI.applied(to: query)
    }

    /// One policed query, run with dialogs suppressed unless this source is the explicit approval
    /// path.
    ///
    /// The suppression is here rather than in `policed(_:)` because it is not a query attribute:
    /// `KeychainNoUIPolicy`'s markers travel with the dictionary, while the file-based keychain's
    /// dialog is governed by process state that has to be set and restored around the call.
    private func copyMatching(_ query: [String: Any]) -> (status: OSStatus, value: CFTypeRef?) {
        let policedQuery = policed(query)
        let run = {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(policedQuery as CFDictionary, &result)
            return (status: status, value: result)
        }
        guard !allowsCredentialUI else { return run() }
        // Without the process-wide lever, "suppressed" would run unsuppressed and a background
        // query could raise the file-based keychain's dialog anyway. Failing closed here keeps
        // the no-prompt guarantee structural: the caller sees the same interaction-required
        // outcome the no-UI markers would have produced, and the explicit approval path — which
        // permits UI — is unaffected.
        guard suppressionAvailable else { return (errSecInteractionNotAllowed, nil) }
        return KeychainUserInteraction.suppressed(run)
    }

    private func payload(for reference: KeychainItemReference) throws(UsageError) -> Data {
        if !allowsCredentialUI {
            try preflight(reference)
        }
        let (status, result) = copyMatching(Self.payloadQuery(reference: reference))
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                throw UsageError.credentialUnavailable(kind: .keychain)
            }
            return data
        default:
            throw Self.failure(for: status)
        }
    }

    /// Refuses the payload query up front when the row's own ACL says it would be denied.
    ///
    /// An attributes-and-reference query never raises the file-based keychain's dialog, and the
    /// row's decrypt ACL names exactly who may read the payload without one. Judging that before
    /// the data query means a background refresh whose build the ACL does not trust reports
    /// `.interactionRequired` without spending a denied read — and, on configurations where the
    /// suppression lever is imperfect, without ever constructing the query that could prompt.
    /// An undetermined judgement falls through to the suppressed read, which stays fail-closed.
    private func preflight(_ reference: KeychainItemReference) throws(UsageError) {
        let (status, result) = copyMatching(Self.preflightQuery(reference: reference))
        switch status {
        case errSecSuccess:
            guard let attributes = result as? [String: Any],
                let item = attributes[kSecValueRef as String]
            else { return }
            if KeychainACLPreflight.check(item: item as AnyObject) == .interactionRequired {
                throw UsageError.interactionForbidden()
            }
        case errSecItemNotFound:
            throw UsageError.credentialUnavailable(kind: .keychain)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw Self.failure(for: status)
        default:
            return
        }
    }

    /// The redacted application error for a failed payload query.
    ///
    /// `errSecUserCanceled` includes authorization dialogs dismissed by the user and denials the
    /// Security framework returns without displaying one. Neither means the credential is absent;
    /// both mean a deliberate approval attempt is required.
    static func failure(for status: OSStatus) -> UsageError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            .interactionForbidden()
        default:
            .credentialUnavailable(kind: .keychain)
        }
    }

    /// Attributes and row references for every item under one service.
    ///
    /// `kSecReturnData` is deliberately absent: enumeration answers what exists, and a query that
    /// cannot return a secret is a query that cannot be made to prompt for one.
    static func enumerationQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
    }

    /// Attributes and the item reference for one row — everything the ACL judgement needs, and
    /// deliberately not `kSecReturnData`, so this query cannot be made to prompt for a secret.
    static func preflightQuery(reference: KeychainItemReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: reference.data,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
    }

    static func payloadQuery(reference: KeychainItemReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: reference.data,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
    }
}

/// One enumerated row, reduced to the non-secret attributes a slot descriptor needs.
struct KeychainItem {
    let account: String
    let reference: KeychainItemReference
    let modifiedAt: Date

    init?(_ attributes: [String: Any]) {
        guard
            let account = (attributes[kSecAttrAccount as String] as? String)?.trimmedNonEmpty,
            let reference = attributes[kSecValuePersistentRef as String] as? Data,
            !reference.isEmpty
        else { return nil }
        self.account = account
        self.reference = KeychainItemReference(data: reference)
        modifiedAt =
            attributes[kSecAttrModificationDate as String] as? Date
            ?? attributes[kSecAttrCreationDate as String] as? Date
            ?? Date.distantPast
    }

    /// Newest first, then by account name so equal timestamps still order deterministically.
    static func newestFirst(_ lhs: KeychainItem, _ rhs: KeychainItem) -> Bool {
        lhs.modifiedAt == rhs.modifiedAt
            ? lhs.account < rhs.account
            : lhs.modifiedAt > rhs.modifiedAt
    }

    /// The slot identity is the service and account attributes, not the row reference: a
    /// credential rewritten in place is the same account, and identity has to survive that.
    func descriptor(service: String) -> CredentialSlotDescriptor {
        CredentialSlotDescriptor(
            slot: CredentialSlotID(source: "keychain:\(service)", opaqueID: account),
            locator: CredentialLocator(kind: .keychain, identifier: reference.identifier),
            displayName: account
        )
    }
}

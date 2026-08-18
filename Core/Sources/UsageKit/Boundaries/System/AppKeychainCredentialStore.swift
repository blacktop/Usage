import Foundation
import Security

/// Usage-owned generic passwords, addressed by an explicit service and account.
///
/// This store never opens another application's item. An item is created by Usage under Usage's
/// own signing requirement, so its ACL remains stable across Claude Code token rotations. Reads
/// still obey the injected interaction policy: scheduled refreshes fail closed rather than raise
/// UI, while the Settings writer is an explicit user action.
public struct AppKeychainCredentialStore: CredentialSource, ManagedCredentialStore {
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

    public static func namespace(service: String) -> CredentialLocator? {
        guard let service = singleLine(service) else { return nil }
        return CredentialLocator(kind: .appKeychain, identifier: service)
    }

    public static func locator(service: String, account: String) -> CredentialLocator? {
        guard let namespace = namespace(service: service), let account = singleLine(account) else {
            return nil
        }
        return CredentialLocator(
            kind: namespace.kind,
            identifier: namespace.identifier,
            path: [account]
        )
    }

    public func slots(in namespace: CredentialLocator) async throws -> [CredentialSlotDescriptor] {
        guard namespace.kind == .appKeychain, namespace.path.isEmpty,
            let service = Self.singleLine(namespace.identifier)
        else { return [] }
        let (status, result) = copyMatching(Self.enumerationQuery(service: service))
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { attributes in
            guard
                let account = (attributes[kSecAttrAccount as String] as? String)?
                    .trimmedNonEmpty,
                let locator = Self.locator(service: service, account: account)
            else { return nil }
            return CredentialSlotDescriptor(
                slot: CredentialSlotID(
                    source: "app-keychain:\(service)",
                    opaqueID: account
                ),
                locator: locator,
                displayName: account
            )
        }
        .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
    }

    public func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T {
        guard let address = Self.address(locator) else {
            throw UsageError.credentialUnavailable(kind: locator.kind)
        }
        let (status, result) = copyMatching(
            Self.payloadQuery(service: address.service, account: address.account)
        )
        switch status {
        case errSecSuccess:
            guard let payload = result as? Data else {
                throw UsageError.credentialUnavailable(kind: .appKeychain)
            }
            // A one-component path names a bare secret. Further components address the secret
            // inside a stored document, mirroring how `.keychain` locators are resolved, so a
            // Usage-owned copy of a document credential reads through the same machinery as the
            // original.
            let documentPath = Array(locator.path.dropFirst())
            guard !documentPath.isEmpty else {
                guard let secret = String(data: payload, encoding: .utf8)?.trimmedNonEmpty else {
                    throw UsageError.credentialUnavailable(kind: .appKeychain)
                }
                return try await operation(Credential(secret: secret))
            }
            let secret = try CredentialDocument.secret(
                in: payload, at: documentPath, kind: .appKeychain
            )
            return try await operation(Credential(secret: secret, document: payload))
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw UsageError.interactionForbidden()
        default:
            throw UsageError.credentialUnavailable(kind: .appKeychain)
        }
    }

    public func containsCredential(at locator: CredentialLocator) -> Bool {
        guard let address = Self.address(locator) else { return false }
        let (status, _) = copyMatchingNoUI(
            Self.attributesQuery(service: address.service, account: address.account)
        )
        return status == errSecSuccess
    }

    public func storeCredential(
        _ secret: String,
        at locator: CredentialLocator
    ) throws(ManagedCredentialStoreError) {
        guard let address = Self.address(locator),
            let normalized = Self.credential(secret),
            let payload = normalized.data(using: .utf8)
        else {
            throw .invalidCredential
        }
        let query = Self.itemQuery(service: address.service, account: address.account)
        let updated = runSecItem {
            SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: payload] as CFDictionary
            )
        }
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = payload
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = runSecItem { SecItemAdd(item as CFDictionary, nil) }
            guard added == errSecSuccess else { throw .storageUnavailable }
        default:
            throw .storageUnavailable
        }
    }

    public func removeCredential(
        at locator: CredentialLocator
    ) throws(ManagedCredentialStoreError) {
        guard let address = Self.address(locator) else { throw .invalidCredential }
        let status = runSecItem {
            SecItemDelete(
                Self.itemQuery(service: address.service, account: address.account) as CFDictionary
            )
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .storageUnavailable
        }
    }

    static func enumerationQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
    }

    static func attributesQuery(service: String, account: String) -> [String: Any] {
        var query = itemQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        return query
    }

    static func payloadQuery(service: String, account: String) -> [String: Any] {
        var query = itemQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        return query
    }

    static func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        guard allowsCredentialUI else { return copyMatchingNoUI(query) }
        var result: CFTypeRef?
        return (SecItemCopyMatching(query as CFDictionary, &result), result)
    }

    /// Presence is passive UI state, even when the store also serves explicit Settings writes.
    ///
    /// Loading Settings must never turn an attributes-only status check into an approval dialog.
    private func copyMatchingNoUI(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        // Without the process-wide lever, "suppressed" would run unsuppressed and could raise the
        // file-based keychain's dialog from a passive read; failing closed preserves the
        // no-prompt guarantee at the cost of reporting the credential as approval-gated.
        guard suppressionAvailable else { return (errSecInteractionNotAllowed, nil) }
        let policed = noUI.applied(to: query)
        return KeychainUserInteraction.suppressed {
            var result: CFTypeRef?
            return (SecItemCopyMatching(policed as CFDictionary, &result), result)
        }
    }

    private func runSecItem(_ operation: () -> OSStatus) -> OSStatus {
        guard !allowsCredentialUI else { return operation() }
        guard suppressionAvailable else { return errSecInteractionNotAllowed }
        return KeychainUserInteraction.suppressed(operation)
    }

    /// The Keychain row a locator names: its service, and its account from the path's first
    /// component. Later components address inside the payload and are not part of the row.
    private static func address(
        _ locator: CredentialLocator
    ) -> (
        service: String, account: String
    )? {
        guard locator.kind == .appKeychain,
            let service = singleLine(locator.identifier),
            let account = locator.path.first.flatMap(singleLine)
        else { return nil }
        return (service, account)
    }

    private static func credential(_ value: String) -> String? {
        guard value.utf8.count <= 16_384, let value = value.trimmedNonEmpty,
            !value.unicodeScalars.contains(where: CharacterSet.newlines.contains)
        else { return nil }
        return value
    }

    private static func singleLine(_ value: String) -> String? {
        guard value.utf8.count <= 1_024, let value = value.trimmedNonEmpty,
            !value.unicodeScalars.contains(where: CharacterSet.newlines.contains)
        else { return nil }
        return value
    }
}

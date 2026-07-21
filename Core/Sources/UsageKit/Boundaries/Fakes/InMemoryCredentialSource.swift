import Foundation
import Synchronization

/// In-memory `CredentialSource` that never touches the Keychain or the disk.
///
/// It also models the two failure modes real sources have: a locator with no credential behind it,
/// and a locator whose credential can only be read by raising UI.
public final class InMemoryCredentialSource: CredentialSource, Sendable {
    private struct State {
        var secrets: [CredentialLocator: String]
        var documents: [CredentialLocator: Data]
        var interactiveOnly: Set<CredentialLocator>
        var slots: [CredentialLocator: [CredentialSlotDescriptor]]
        var resolvedLocators: [CredentialLocator] = []
        var enumeratedNamespaces: [CredentialLocator] = []
    }

    private let state: Mutex<State>
    private let interaction: any InteractionPolicy

    public init(
        secrets: [CredentialLocator: String] = [:],
        documents: [CredentialLocator: Data] = [:],
        interactiveOnly: Set<CredentialLocator> = [],
        slots: [CredentialLocator: [CredentialSlotDescriptor]] = [:],
        interaction: any InteractionPolicy = BackgroundInteractionPolicy()
    ) {
        state = Mutex(
            State(
                secrets: secrets,
                documents: documents,
                interactiveOnly: interactiveOnly,
                slots: slots
            )
        )
        self.interaction = interaction
    }

    /// Locators the source was asked to resolve, in call order.
    public var resolvedLocators: [CredentialLocator] {
        state.withLock { $0.resolvedLocators }
    }

    /// Namespaces the source was asked to enumerate, in call order.
    public var enumeratedNamespaces: [CredentialLocator] {
        state.withLock { $0.enumeratedNamespaces }
    }

    public func slots(in namespace: CredentialLocator) async throws -> [CredentialSlotDescriptor] {
        state.withLock { state in
            state.enumeratedNamespaces.append(namespace)
            return state.slots[namespace] ?? []
        }
    }

    public func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T {
        let resolved = try state.withLock { state throws(UsageError) -> (String, Data?) in
            state.resolvedLocators.append(locator)
            if state.interactiveOnly.contains(locator), !interaction.allowsCredentialUI {
                throw UsageError.interactionForbidden()
            }
            guard let secret = state.secrets[locator] else {
                throw UsageError.credentialUnavailable(kind: locator.kind)
            }
            return (secret, state.documents[locator])
        }
        let credential =
            resolved.1.map { Credential(secret: resolved.0, document: $0) }
            ?? Credential(secret: resolved.0)
        return try await operation(credential)
    }
}

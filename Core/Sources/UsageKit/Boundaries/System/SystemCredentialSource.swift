/// The production `CredentialSource`, routing each locator to the store that owns it.
///
/// `CredentialLocator.Kind` is the whole routing table, so a provider never chooses between a file
/// and the Keychain: it hands over a locator and the source knows where that lives.
public struct SystemCredentialSource: CredentialSource {
    private let files: FileCredentialSource
    private let keychain: KeychainCredentialSource

    public init(
        fileSystem: any ProviderFileSystem,
        interaction: any InteractionPolicy = BackgroundInteractionPolicy()
    ) {
        files = FileCredentialSource(fileSystem: fileSystem)
        keychain = KeychainCredentialSource(interaction: interaction)
    }

    public func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T {
        switch locator.kind {
        case .file: try await files.withCredential(at: locator, perform: operation)
        case .keychain: try await keychain.withCredential(at: locator, perform: operation)
        }
    }

    public func slots(in namespace: CredentialLocator) async throws -> [CredentialSlotDescriptor] {
        switch namespace.kind {
        case .file: []
        case .keychain: try await keychain.slots(in: namespace)
        }
    }
}

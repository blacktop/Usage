/// The production `CredentialSource`, routing each locator to the store that owns it.
///
/// `CredentialLocator.Kind` is the whole routing table. A provider hands over a locator and this
/// source resolves it through the file system, Keychain, or an explicitly named GitHub CLI account.
public struct SystemCredentialSource: CredentialSource {
    private let files: FileCredentialSource
    private let keychain: KeychainCredentialSource
    private let appKeychain: AppKeychainCredentialStore
    private let githubCLI: GitHubCLICredentialSource

    public init(
        fileSystem: any ProviderFileSystem,
        interaction: any InteractionPolicy = BackgroundInteractionPolicy()
    ) {
        files = FileCredentialSource(fileSystem: fileSystem)
        keychain = KeychainCredentialSource(interaction: interaction)
        appKeychain = AppKeychainCredentialStore(interaction: interaction)
        githubCLI = GitHubCLICredentialSource()
    }

    public func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T {
        switch locator.kind {
        case .file: try await files.withCredential(at: locator, perform: operation)
        case .keychain: try await keychain.withCredential(at: locator, perform: operation)
        case .appKeychain:
            try await appKeychain.withCredential(at: locator, perform: operation)
        case .githubCLI: try await githubCLI.withCredential(at: locator, perform: operation)
        }
    }

    public func slots(in namespace: CredentialLocator) async throws -> [CredentialSlotDescriptor] {
        switch namespace.kind {
        case .file: []
        case .keychain: try await keychain.slots(in: namespace)
        case .appKeychain: try await appKeychain.slots(in: namespace)
        case .githubCLI: []
        }
    }
}

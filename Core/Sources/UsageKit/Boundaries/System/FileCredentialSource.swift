import Foundation

/// Resolves `.file` locators through the injected `ProviderFileSystem`.
///
/// It reads through the same boundary the providers use rather than reaching for `FileManager`
/// directly, so a test can seal the whole credential path behind one in-memory double, and so there
/// is exactly one place in the package that opens an agent's credential file.
///
/// There is no enumeration: a file source has no namespace to list, and inventing one would mean
/// scanning directories for credential-shaped files.
public struct FileCredentialSource: CredentialSource {
    private let fileSystem: any ProviderFileSystem

    public init(fileSystem: any ProviderFileSystem) {
        self.fileSystem = fileSystem
    }

    public func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T {
        guard locator.kind == .file else {
            throw UsageError.credentialUnavailable(kind: locator.kind)
        }
        let url = URL(filePath: locator.identifier)
        guard let payload = try? fileSystem.read(contentsOf: url) else {
            throw UsageError.credentialUnavailable(kind: .file)
        }
        let secret = try CredentialDocument.secret(in: payload, at: locator.path, kind: .file)
        return try await operation(Credential(secret: secret, document: payload))
    }
}

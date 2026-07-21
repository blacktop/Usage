import Foundation

/// The production `ProviderFileSystem`: a read-only view of the real disk.
///
/// `homeDirectory` is injected rather than read at each call site so a provider never spells a
/// credential path itself, and every underlying failure is collapsed into a redacted `UsageError` —
/// `Foundation`'s own file errors carry the full path in their description, which must not reach a
/// log or a rendered message.
public struct SystemFileSystem: ProviderFileSystem {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: Self.path(of: url))
    }

    public func read(contentsOf url: URL) throws(UsageError) -> Data {
        guard let data = FileManager.default.contents(atPath: Self.path(of: url)) else {
            throw UsageError.credentialUnavailable(kind: .file)
        }
        return data
    }

    public func contentsOfDirectory(at url: URL) throws(UsageError) -> [URL] {
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: Self.path(of: url))
        else {
            throw UsageError.credentialUnavailable(kind: .file)
        }
        return names.sorted().map { url.appending(path: $0, directoryHint: .notDirectory) }
    }

    private static func path(of url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}

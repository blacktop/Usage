import Foundation

/// Claude Code's own Keychain address, derived the way the CLI derives it.
///
/// The default `~/.claude` root uses the plain `Claude Code-credentials` service. Custom roots use
/// that service plus the first eight hex characters of the SHA-256 of the canonical configuration
/// path. The injected home directory makes the plain service unambiguous: it is addressable only
/// for that host's exact default root and can never be guessed for another configured directory.
public enum ClaudeCodeKeychain {
    static let defaultService = "Claude Code-credentials"
    static let servicePrefix = defaultService + "-"
    static let pathHashLength = 8

    /// The plain default service for `HOME/.claude`, otherwise the root's hashed service.
    public static func service(for root: URL, homeDirectory: URL) -> String {
        let defaultRoot = homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
        if ProfileKeychainName.canonicalPath(root: root)
            == ProfileKeychainName.canonicalPath(root: defaultRoot)
        {
            return defaultService
        }
        return servicePrefix + ProfileKeychainName.pathHash(root: root, length: pathHashLength)
    }

    /// The enumeration namespace for one configuration root.
    public static func namespace(for root: URL, homeDirectory: URL) -> CredentialLocator {
        CredentialLocator(
            kind: .keychain,
            identifier: service(for: root, homeDirectory: homeDirectory)
        )
    }
}

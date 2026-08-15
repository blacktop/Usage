/// The Usage-owned Keychain address for a Claude `setup-token`.
///
/// One token belongs to one configured profile root. The root ID is non-secret and stable across
/// relabels and path edits, while the service name is deliberately unrelated to Claude Code's own
/// mutable `Claude Code-credentials` item.
public enum ClaudeSetupTokenCredential {
    public static let service = "io.blacktop.Usage.claude-setup-token"

    public static var namespace: CredentialLocator {
        CredentialLocator(kind: .appKeychain, identifier: service)
    }

    public static func locator(for profileRootID: ProfileRootID) -> CredentialLocator {
        CredentialLocator(
            kind: .appKeychain,
            identifier: service,
            path: [profileRootID.description]
        )
    }
}

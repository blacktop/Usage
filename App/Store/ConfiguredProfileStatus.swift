import Foundation
import UsageKit

/// One configured provider folder and the non-secret fact needed to explain why it has no account.
struct ConfiguredProfileStatus: Identifiable, Equatable {
    let profile: ProfileRoot
    let hasCredentialDocument: Bool

    var id: ProfileRootID { profile.id }
}

/// The credential-document names shared by Settings and the popover's configured-profile model.
///
/// Checking these names is deliberately weaker than discovery: it says only that a known document
/// exists, never that it parses or contains a usable credential.
enum ProviderCredentialDocuments {
    static func names(for providerID: ProviderID) -> [String] {
        switch providerID.rawValue {
        case "claude": [".credentials.json"]
        case "codex": ["auth.json"]
        case "copilot": ["apps.json", "hosts.json", "oauth.json"]
        default: []
        }
    }

    static func status(
        providerID: ProviderID,
        hasCredentialDocument: Bool,
        hasSetupToken: Bool = false
    ) -> String {
        guard providerID == ClaudeProvider.id else {
            return hasCredentialDocument
                ? "Sign-in file found"
                : "No sign-in file in this folder"
        }
        if hasSetupToken {
            return "Setup token saved; Claude Code Keychain is preferred"
        }
        return hasCredentialDocument
            ? "Credential JSON found"
            : "Claude Code Keychain checked during refresh"
    }

    static func guidance(for providerID: ProviderID) -> String? {
        guard providerID == ClaudeProvider.id else { return nil }
        return
            "Usage tries .credentials.json first, then Claude Code’s root-specific Keychain "
            + "item, then a setup token saved with the key button. A setup token remains unused "
            + "while either earlier source is usable; create one with claude setup-token only as "
            + "a fallback."
    }

    static func exists(
        below profile: ProfileRoot,
        using fileSystem: any ProviderFileSystem
    ) -> Bool {
        let directory = URL(
            filePath: profile.configurationDirectoryPath,
            directoryHint: .isDirectory
        )
        return names(for: profile.providerID).contains { name in
            fileSystem.fileExists(
                at: directory.appending(path: name, directoryHint: .notDirectory)
            )
        }
    }
}

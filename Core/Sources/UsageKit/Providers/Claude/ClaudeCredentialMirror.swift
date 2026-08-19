import Foundation

/// Usage's own copy of one root's Claude Code credential, kept fresh by `ClaudeTokenRefresh`.
///
/// The mirror is an item Usage creates under its own signing requirement, holding both tokens,
/// the expiry, and the plan fields; scopes and every field Usage does not use are dropped. One
/// approval captures the credential, after which Usage is independent of Claude Code's item —
/// necessary because no read approval on that item can be durable, as documented with the
/// extracted evidence in docs/keychain-gate.md (2026-08-19).
public enum ClaudeCredentialMirror {
    /// Deliberately unrelated to Claude Code's own service, like the setup-token service.
    public static let service = "io.blacktop.Usage.claude-mirror"

    /// One mirror row per configured root, readable through the same document machinery as the
    /// original: the first path component is the row's account, the rest address the bearer token.
    static func locator(for rootID: ProfileRootID) -> CredentialLocator {
        CredentialLocator(
            kind: .appKeychain,
            identifier: service,
            path: [rootID.description] + ClaudeCredentialFile.secretPath
        )
    }

    /// The row itself, for storage and removal, where the secret path has no meaning.
    public static func storageLocator(for rootID: ProfileRootID) -> CredentialLocator {
        CredentialLocator(kind: .appKeychain, identifier: service, path: [rootID.description])
    }

    /// The trimmed single-line document to store, or `nil` when the source holds no usable
    /// subscription token.
    ///
    /// Keeping the stored shape identical to Claude Code's own document — minus the fields Usage
    /// does not use — means `ClaudeCredentialFile.secretPath`, the plan-label parser, and the
    /// refresher read the mirror exactly as they read the original.
    static func payload(from document: Data) -> String? {
        ClaudeCredentialFile.oauthFields(from: document).flatMap(payload(fields:))
    }

    /// The stored form of one set of OAuth fields — also how the refresher writes rotated tokens.
    static func payload(fields: ClaudeCredentialFile.OAuthFields) -> String? {
        guard let accessToken = fields.accessToken else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let document = StoredDocument(
            claudeAiOauth: StoredDocument.OAuth(
                accessToken: accessToken,
                refreshToken: fields.refreshToken,
                expiresAt: fields.expiresAtMilliseconds,
                rateLimitTier: fields.rateLimitTier,
                subscriptionType: fields.subscriptionType
            )
        )
        guard let data = try? encoder.encode(document) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct StoredDocument: Encodable {
        struct OAuth: Encodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Int?
            let rateLimitTier: String?
            let subscriptionType: String?
        }

        let claudeAiOauth: OAuth
    }
}

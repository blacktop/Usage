import Foundation

/// Usage's own last-good copy of one root's Claude Code keychain credential.
///
/// Claude Code deletes and recreates its keychain item on some credential rewrites, and every
/// recreation voids the read approval the user last granted — the ACL grant lives on the item.
/// The mirror is an item Usage creates under its own signing requirement, so it survives those
/// rotations and lets a background refresh keep reporting full-resolution usage until the copied
/// token expires, instead of going dark the moment the grant dies.
///
/// The copy is redacted before it is stored: only the access token and the two plan-label fields
/// survive. The refresh token never leaves the source document — Usage cannot refresh a token and
/// must not hold the credential that could.
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

    /// The redacted single-line document to store, or `nil` when the source holds no usable
    /// subscription token.
    ///
    /// Keeping the stored shape identical to Claude Code's own document — minus everything Usage
    /// does not use — means `ClaudeCredentialFile.secretPath` and the plan-label parser read the
    /// mirror exactly as they read the original.
    static func payload(from document: Data) -> String? {
        guard let source = try? JSONDecoder().decode(Source.self, from: document),
            let accessToken = source.accessToken
        else { return nil }
        var oauth: [String: String] = ["accessToken": accessToken]
        oauth["subscriptionType"] = source.subscriptionType
        oauth["rateLimitTier"] = source.rateLimitTier
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(["claudeAiOauth": oauth]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct Source: Decodable {
        let accessToken: String?
        let subscriptionType: String?
        let rateLimitTier: String?

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            let oauth = root.nested("claudeAiOauth")
            accessToken = oauth?.trimmedString("accessToken")
            subscriptionType = oauth?.trimmedString("subscriptionType")
            rateLimitTier = oauth?.trimmedString("rateLimitTier")
        }
    }
}

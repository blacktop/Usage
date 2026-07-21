import Foundation

/// Everything Usage keeps from `~/.codex/auth.json` — which is everything in it that is *not* a
/// secret.
///
/// The access and refresh tokens are read during parsing and deliberately not stored: the only
/// thing this type records about them is that a usable pair was present.
struct CodexAuthMetadata: Sendable, Hashable {
    /// `tokens.account_id`, or the matching `id_token` claim. Non-secret: it is sent in cleartext
    /// as the `ChatGPT-Account-Id` request header.
    let accountID: String?
    /// Display metadata only. Never part of `AccountID`.
    let email: String?
    /// Plan label used when the usage response omits `plan_type`.
    let planType: String?
    let lastRefresh: Date?
}

/// Reader for the Codex CLI's credential file. Read-only by construction: there is no writer here
/// and no token-refresh path, because Usage and the Codex CLI would race on the same file.
enum CodexAuthFile {
    /// Where the bearer token sits inside the document, for `CredentialSource` to resolve.
    static let secretPath = ["tokens", "access_token"]
    /// How long an untouched `last_refresh` is tolerated before the credential looks stale.
    ///
    /// Advisory only: the CLI can refresh a token without updating this field, so a stale-looking
    /// credential is still fetched. It never gates a request.
    static let stalenessThreshold: TimeInterval = 8 * 86_400
    /// The one document Codex discovery reads, directly below a configured root.
    static let documentName = "auth.json"

    static func url(root: URL) -> URL {
        root.appending(path: documentName, directoryHint: .notDirectory)
    }

    /// Parses the document, requiring an OAuth token pair.
    ///
    /// A bare `OPENAI_API_KEY` is explicitly *not* accepted. The Codex CLI's own default parser
    /// returns the API key before it ever looks at `tokens`, but an API key is not a valid bearer
    /// for the usage endpoint, so honouring it would turn "logged in with an API key" into a 401
    /// that reads as an expired login.
    static func parse(_ data: Data) throws(UsageError) -> CodexAuthMetadata {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            throw UsageError.decodingFailure(field: "auth.json")
        }
        guard document.hasOAuthTokens else {
            throw UsageError.credentialUnavailable(kind: .file)
        }
        let claims = document.idToken.flatMap(CodexIDToken.claims(in:))
        return CodexAuthMetadata(
            accountID: document.accountID ?? claims?.accountID,
            email: claims?.email,
            planType: claims?.planType,
            lastRefresh: document.lastRefresh
        )
    }

    private struct Document: Decodable {
        let hasOAuthTokens: Bool
        let accountID: String?
        let idToken: String?
        let lastRefresh: Date?

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            let tokens = root.nested("tokens")
            let hasAccess = tokens?.trimmedString("access_token", "accessToken") != nil
            let hasRefresh = tokens?.trimmedString("refresh_token", "refreshToken") != nil
            hasOAuthTokens = hasAccess && hasRefresh
            accountID = tokens?.trimmedString("account_id", "accountId")
            idToken = tokens?.trimmedString("id_token", "idToken")
            lastRefresh = ProviderDates.iso8601(root.trimmedString("last_refresh", "lastRefresh"))
        }
    }
}

/// Claim reader for the `id_token` sitting beside the Codex OAuth tokens.
///
/// The signature is never verified and must not be: this is a local read of a file the user already
/// owns, used to label an account, not an authorization decision.
enum CodexIDToken {
    struct Claims: Sendable, Hashable {
        let accountID: String?
        let planType: String?
        let email: String?
    }

    static func claims(in token: String) -> Claims? {
        guard let payload = base64URLPayload(of: token),
            let document = try? JSONDecoder().decode(Document.self, from: payload)
        else { return nil }
        return Claims(
            accountID: document.auth?.accountID ?? document.flatAccountID,
            planType: document.auth?.planType,
            email: document.email ?? document.profile?.email
        )
    }

    private static func base64URLPayload(of token: String) -> Data? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 =
            String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    private struct Document: Decodable {
        let email: String?
        let flatAccountID: String?
        let auth: Scoped?
        let profile: Profile?

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            email = root.trimmedString("email")
            flatAccountID = root.trimmedString("chatgpt_account_id")
            auth = root.nested("https://api.openai.com/auth").map(Scoped.init)
            profile = root.nested("https://api.openai.com/profile").map(Profile.init)
        }
    }

    private struct Scoped {
        let accountID: String?
        let planType: String?

        init(_ container: KeyedDecodingContainer<AnyCodingKey>) {
            accountID = container.trimmedString("chatgpt_account_id")
            planType = container.trimmedString("chatgpt_plan_type")
        }
    }

    private struct Profile {
        let email: String?

        init(_ container: KeyedDecodingContainer<AnyCodingKey>) {
            email = container.trimmedString("email")
        }
    }
}

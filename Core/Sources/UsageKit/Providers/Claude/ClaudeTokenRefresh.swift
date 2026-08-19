import Foundation

/// One refresh-token exchange against Anthropic's OAuth endpoint, on the mirror's behalf.
///
/// Why the mirror refreshes itself instead of re-reading Claude Code's item is recorded in
/// docs/keychain-gate.md (2026-08-19). The exchange presents Claude Code's own public client
/// identifier, because the mirrored tokens belong to that client. Secrets are handled entirely
/// inside this file: the refresh token travels from the stored payload into one outbound
/// request, the response's tokens go straight back into the Usage-owned row, and callers receive
/// only an `Outcome`.
enum ClaudeTokenRefresh {
    static let endpoint = StaticURL.make("https://platform.claude.com/v1/oauth/token")
    /// Claude Code's public OAuth client identifier — the client the mirrored tokens belong to.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Exchange this long before nominal expiry, absorbing clock skew and in-flight time.
    static let expiryMargin: Duration = .seconds(60)

    enum Outcome: Sendable, Equatable {
        /// The stored access token has life left; nothing was exchanged.
        case fresh
        /// The exchange succeeded and the row now holds the rotated tokens.
        case refreshed
        /// No row, no refresh token, or an unparseable payload — nothing to exchange.
        case unavailable
        /// The provider terminally rejected the refresh token; the row was deleted because its
        /// tokens can never work again. Only a fresh approval can re-seed it.
        case invalidGrant
        /// A transient failure (network, 5xx, unparseable grant); the row is untouched and a
        /// later attempt may succeed.
        case failed
    }

    /// Ensures the row's access token is usable, exchanging the refresh token when it is not.
    ///
    /// `force` skips the expiry check for the retry after a fetch the provider rejected with 401:
    /// the stored expiry was evidently wrong, and the exchange is the only way to find out
    /// whether the refresh token still stands.
    static func refresh(
        rowAt storage: CredentialLocator,
        in store: any ManagedCredentialStore,
        using http: any HTTPTransport,
        now: Date,
        force: Bool = false
    ) async -> Outcome {
        guard let payload = store.readCredential(at: storage),
            let fields = ClaudeCredentialFile.oauthFields(from: Data(payload.utf8)),
            fields.accessToken != nil
        else { return .unavailable }
        if !force, !isExpired(fields.expiresAtMilliseconds, now: now) {
            return .fresh
        }
        guard let refreshToken = fields.refreshToken else { return .unavailable }
        guard let response = try? await http.send(request(refreshToken: refreshToken)) else {
            return .failed
        }
        guard response.isSuccess else {
            if isInvalidGrant(response) {
                try? store.removeCredential(at: storage)
                return .invalidGrant
            }
            return .failed
        }
        guard let granted = try? JSONDecoder().decode(GrantResponse.self, from: response.body),
            let accessToken = granted.accessToken,
            let rotated = ClaudeCredentialMirror.payload(
                fields: ClaudeCredentialFile.OAuthFields(
                    accessToken: accessToken,
                    // A response without a rotated refresh token keeps the proven one.
                    refreshToken: granted.refreshToken ?? refreshToken,
                    // `expires_in` is optional in OAuth 2; without it the row stores no expiry
                    // and the provider's own 401 drives the next exchange.
                    expiresAtMilliseconds: granted.expiresIn.map {
                        Int((now.timeIntervalSince1970 + Double($0)) * 1000)
                    },
                    subscriptionType: fields.subscriptionType,
                    rateLimitTier: fields.rateLimitTier
                )
            )
        else { return .failed }
        do {
            try store.storeCredential(rotated, at: storage)
        } catch {
            return .failed
        }
        return .refreshed
    }

    /// Whether the stored expiry says the access token is not worth sending.
    ///
    /// A row without a usable expiry claims nothing, so the provider's own 401 decides — the
    /// same posture the credential-file path takes. `ProviderDates` supplies that judgement:
    /// a zero or negative stored value means "not stated", never "expired in 1970".
    static func isExpired(_ expiresAtMilliseconds: Int?, now: Date) -> Bool {
        guard
            let expiresAt = ProviderDates.epochMilliseconds(expiresAtMilliseconds.map(Double.init))
        else { return false }
        return expiresAt <= now.adding(expiryMargin)
    }

    static func request(refreshToken: String) -> HTTPRequest {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        return HTTPRequest(
            method: .post,
            url: endpoint,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: Data((components.percentEncodedQuery ?? "").utf8)
        )
    }

    /// Whether the grant rejection is terminal for this refresh token.
    ///
    /// Only `invalid_grant` on a 4xx auth status is: the token was revoked or superseded, and
    /// retrying can never repair it. Every other rejection stays retryable.
    static func isInvalidGrant(_ response: HTTPResponse) -> Bool {
        guard response.status == 400 || response.status == 401 else { return false }
        let rejection = try? JSONDecoder().decode(GrantRejection.self, from: response.body)
        return rejection?.error == "invalid_grant"
    }

    /// Decoded leniently, like every other provider payload: a string-typed `expires_in` or an
    /// unexpected sibling field must not discard a validly minted token.
    private struct GrantResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            accessToken = root.trimmedString("access_token")
            refreshToken = root.trimmedString("refresh_token")
            expiresIn = root.lenientInt("expires_in")
        }
    }

    private struct GrantRejection: Decodable {
        let error: String?

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            error = root.trimmedString("error")
        }
    }
}

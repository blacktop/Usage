import Foundation
import Testing

@testable import UsageKit

@Suite("Claude token refresh")
struct ClaudeTokenRefreshTests {
    private static let now = Date(timeIntervalSince1970: 1_784_000_000)
    private static let accessToken = "sk-ant-oat01-FAKE-ACCESS-TOKEN-DO-NOT-USE-0000000000"
    private static let refreshToken = "sk-ant-ort01-FAKE-REFRESH-TOKEN-DO-NOT-USE-000000000"

    private let storage = ClaudeCredentialMirror.storageLocator(for: ProfileRootID())

    private func payload(expiresAtMilliseconds: Int?) throws -> String {
        try #require(
            ClaudeCredentialMirror.payload(
                fields: ClaudeCredentialFile.OAuthFields(
                    accessToken: Self.accessToken,
                    refreshToken: Self.refreshToken,
                    expiresAtMilliseconds: expiresAtMilliseconds,
                    subscriptionType: "max",
                    rateLimitTier: "default_claude_max_20x"
                )
            )
        )
    }

    private func expiredMilliseconds() -> Int {
        Int((Self.now.timeIntervalSince1970 - 60) * 1000)
    }

    @Test("the exchange request carries the grant, the token, and Claude Code's client id")
    func buildsGrantRequest() {
        let request = ClaudeTokenRefresh.request(refreshToken: Self.refreshToken)

        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=\(Self.refreshToken)"))
        #expect(body.contains("client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"))
    }

    @Test("an unexpired token is left alone and costs no request")
    func unexpiredTokenIsFresh() async throws {
        let farFuture = Int((Self.now.timeIntervalSince1970 + 3_600) * 1000)
        let store = InMemoryManagedCredentialStore(
            payloads: [storage: try payload(expiresAtMilliseconds: farFuture)]
        )
        let http = InMemoryHTTPTransport()

        let outcome = await ClaudeTokenRefresh.refresh(
            rowAt: storage, in: store, using: http, now: Self.now
        )

        #expect(outcome == .fresh)
        #expect(http.recordedRequests.isEmpty)
    }

    @Test("an expired token is exchanged and the row holds the rotated pair afterwards")
    func expiredTokenIsExchanged() async throws {
        let store = InMemoryManagedCredentialStore(
            payloads: [storage: try payload(expiresAtMilliseconds: expiredMilliseconds())]
        )
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeTokenRefresh.endpoint,
            with: ProviderFixtures.claudeGrantResponse(
                rotatedRefreshToken: "sk-ant-ort01-ROTATED-000")
        )

        let outcome = await ClaudeTokenRefresh.refresh(
            rowAt: storage, in: store, using: http, now: Self.now
        )

        #expect(outcome == .refreshed)
        let rotated = try #require(store.readCredential(at: storage))
        #expect(rotated.contains(ProviderFixtures.mintedClaudeAccessToken))
        #expect(rotated.contains("sk-ant-ort01-ROTATED-000"))
        #expect(!rotated.contains(Self.refreshToken), "the superseded refresh token is replaced")
        let expected = Int((Self.now.timeIntervalSince1970 + 28_800) * 1000)
        #expect(rotated.contains("\"expiresAt\":\(expected)"))
        #expect(rotated.contains("default_claude_max_20x"), "plan fields survive the rotation")
    }

    @Test("a grant response without a rotated refresh token keeps the proven one")
    func keepsRefreshTokenWhenNotRotated() async throws {
        let store = InMemoryManagedCredentialStore(
            payloads: [storage: try payload(expiresAtMilliseconds: expiredMilliseconds())]
        )
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeTokenRefresh.endpoint,
            with: ProviderFixtures.claudeGrantResponse(rotatedRefreshToken: nil))

        let outcome = await ClaudeTokenRefresh.refresh(
            rowAt: storage, in: store, using: http, now: Self.now
        )

        #expect(outcome == .refreshed)
        let rotated = try #require(store.readCredential(at: storage))
        #expect(rotated.contains(Self.refreshToken))
    }

    @Test("an invalid_grant deletes the row; other rejections leave it for a later attempt")
    func invalidGrantIsTerminal() async throws {
        let store = InMemoryManagedCredentialStore(
            payloads: [storage: try payload(expiresAtMilliseconds: expiredMilliseconds())]
        )
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeTokenRefresh.endpoint,
            with: HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        )

        let outcome = await ClaudeTokenRefresh.refresh(
            rowAt: storage, in: store, using: http, now: Self.now
        )

        #expect(outcome == .invalidGrant)
        #expect(!store.containsCredential(at: storage))

        let transientStore = InMemoryManagedCredentialStore(
            payloads: [storage: try payload(expiresAtMilliseconds: expiredMilliseconds())]
        )
        let transientHTTP = InMemoryHTTPTransport()
        transientHTTP.stub(ClaudeTokenRefresh.endpoint, with: HTTPResponse(status: 503))

        let transient = await ClaudeTokenRefresh.refresh(
            rowAt: storage, in: transientStore, using: transientHTTP, now: Self.now
        )

        #expect(transient == .failed)
        #expect(transientStore.containsCredential(at: storage))
    }

    @Test("a row without a refresh token, or no row at all, has nothing to exchange")
    func missingMaterialIsUnavailable() async throws {
        let tokenOnly = try #require(
            ClaudeCredentialMirror.payload(
                fields: ClaudeCredentialFile.OAuthFields(
                    accessToken: Self.accessToken,
                    refreshToken: nil,
                    expiresAtMilliseconds: expiredMilliseconds(),
                    subscriptionType: nil,
                    rateLimitTier: nil
                )
            )
        )
        let store = InMemoryManagedCredentialStore(payloads: [storage: tokenOnly])
        let http = InMemoryHTTPTransport()

        #expect(
            await ClaudeTokenRefresh.refresh(
                rowAt: storage, in: store, using: http, now: Self.now
            ) == .unavailable
        )
        #expect(
            await ClaudeTokenRefresh.refresh(
                rowAt: storage,
                in: InMemoryManagedCredentialStore(),
                using: http,
                now: Self.now
            ) == .unavailable
        )
        #expect(http.recordedRequests.isEmpty)
    }

    @Test("a row without an expiry claims nothing; force is what retries a 401")
    func absentExpiryDefersToTheProvider() async throws {
        let undated = try payload(expiresAtMilliseconds: nil)
        let store = InMemoryManagedCredentialStore(payloads: [storage: undated])
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeTokenRefresh.endpoint,
            with: ProviderFixtures.claudeGrantResponse(rotatedRefreshToken: nil))

        #expect(
            await ClaudeTokenRefresh.refresh(
                rowAt: storage, in: store, using: http, now: Self.now
            ) == .fresh
        )
        #expect(
            await ClaudeTokenRefresh.refresh(
                rowAt: storage, in: store, using: http, now: Self.now, force: true
            ) == .refreshed
        )
    }
}

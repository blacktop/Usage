import Foundation
import Testing

@testable import UsageKit

@Suite("Error redaction")
struct RedactionTests {
    private static let tokens = [
        "sk-proj-LIVE0000TOKEN0000SECRET",
        "gho_0123456789abcdefghijklmnopqrstuvwxyz",
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.PAYLOAD.SIGNATURE",
        "/Users/tester/.codex/auth.json",
    ]

    private func failingResponse(status: Int) -> HTTPResponse {
        let body = """
            {"error":{"message":"invalid token \(Self.tokens[0])",\
            "id_token":"\(Self.tokens[2])","source":"\(Self.tokens[3])"}}
            """
        return HTTPResponse(
            status: status,
            headers: [
                "Authorization": "Bearer \(Self.tokens[0])",
                "Set-Cookie": "session=\(Self.tokens[1])",
                "Retry-After": "42",
            ],
            body: Data(body.utf8)
        )
    }

    private func assertRedacted(_ error: UsageError) throws {
        let surfaces = [
            try Fixtures.encodedString(error),
            error.message,
            error.description,
            String(describing: error),
            String(reflecting: error),
        ]
        for surface in surfaces {
            for token in Self.tokens {
                #expect(!surface.contains(token))
            }
            #expect(!surface.contains("Bearer"))
            #expect(!surface.contains("Set-Cookie"))
            #expect(!surface.contains("auth.json"))
        }
    }

    @Test(
        "A failing response never leaks its body, headers, or credential path",
        arguments: [401, 403, 429, 500, 418]
    )
    func failedResponsesAreRedacted(status: Int) throws {
        let error = UsageError.from(failingResponse(status: status))
        try assertRedacted(error)
        #expect(error.message == "The provider returned HTTP \(status).")
    }

    @Test("Retry metadata survives redaction")
    func retryMetadataIsPreserved() {
        let error = UsageError.from(failingResponse(status: 429))
        #expect(error.category == .rateLimited)
        #expect(error.retry == UsageError.RetryAdvice(delay: .seconds(42), scope: .account))
    }

    @Test("Status codes map onto categories")
    func statusCategoriesAreMapped() {
        #expect(UsageError.from(HTTPResponse(status: 401)).category == .authenticationExpired)
        #expect(UsageError.from(HTTPResponse(status: 403)).category == .authenticationExpired)
        #expect(UsageError.from(HTTPResponse(status: 429)).category == .rateLimited)
        #expect(UsageError.from(HTTPResponse(status: 503)).category == .serverError)
        #expect(UsageError.from(HTTPResponse(status: 400)).category == .invalidRequest)
        #expect(UsageError.from(HTTPResponse(status: 200)).retry == nil)
    }

    @Test("A whole fetch — resolve credential, send it, fail — leaks nothing")
    func endToEndFailureIsRedacted() async throws {
        let url = try #require(URL(string: "https://example.invalid/usage"))
        let locator = CredentialLocator(kind: .file, identifier: Self.tokens[3])
        let source = InMemoryCredentialSource(secrets: [locator: Self.tokens[0]])
        let transport = InMemoryHTTPTransport()
        transport.stub(url, with: failingResponse(status: 401))

        let response = try await source.withCredential(at: locator) { credential in
            try await transport.send(
                credential.authorizing(HTTPRequest(url: url), with: .bearer)
            )
        }
        let error = UsageError.from(response)

        #expect(error.category == .authenticationExpired)
        try assertRedacted(error)
        let sent = try #require(transport.recordedRequests.first)
        #expect(sent.headerValue("authorization")?.contains(Self.tokens[0]) == true)
    }

    @Test("Every error factory produces a token-free surface")
    func allErrorFactoriesAreRedacted() throws {
        let errors: [UsageError] = [
            .transportFailure(),
            .decodingFailure(field: "rate_limit.primary_window"),
            .invalidValue(field: "usedFraction", rule: .finite),
            .credentialUnavailable(kind: .keychain),
            .interactionForbidden(),
            .cancelled(),
            .providerUnavailable(),
        ]
        for error in errors {
            try assertRedacted(error)
            #expect(!error.message.isEmpty)
        }
    }

    @Test("A missing credential reports only the locator kind, never its path")
    func credentialUnavailableHidesThePath() async throws {
        let locator = CredentialLocator(kind: .keychain, identifier: Self.tokens[3])
        let source = InMemoryCredentialSource()
        let error = await #expect(throws: UsageError.self) {
            try await source.withCredential(at: locator) { _ in HTTPResponse(status: 200) }
        }
        let unwrapped = try #require(error)
        #expect(unwrapped.category == .credentialUnavailable)
        try assertRedacted(unwrapped)
    }

    @Test("A background policy refuses an interactive credential without raising UI")
    func backgroundPolicyFailsClosed() async throws {
        let locator = CredentialLocator(kind: .keychain, identifier: "Claude Code-credentials")
        let source = InMemoryCredentialSource(
            secrets: [locator: Self.tokens[0]],
            interactiveOnly: [locator],
            interaction: BackgroundInteractionPolicy()
        )
        let error = await #expect(throws: UsageError.self) {
            try await source.withCredential(at: locator) { _ in HTTPResponse(status: 200) }
        }
        #expect(try #require(error).category == .interactionRequired)

        let allowed = InMemoryCredentialSource(
            secrets: [locator: Self.tokens[0]],
            interactiveOnly: [locator],
            interaction: UserInitiatedInteractionPolicy()
        )
        let url = try #require(URL(string: "https://example.invalid/usage"))
        let transport = InMemoryHTTPTransport()
        transport.stub(url, with: HTTPResponse(status: 200))
        let response = try await allowed.withCredential(at: locator) { credential in
            try await transport.send(credential.authorizing(HTTPRequest(url: url), with: .bearer))
        }
        #expect(response.status == 200)
    }

    @Test("Field names are stripped of separators and length-capped as defence in depth")
    func fieldNamesAreSanitised() {
        #expect(FieldName("rate_limit.primary[0]").rawValue == "rate_limit.primary[0]")
        let hostile = FieldName("Bearer sk-proj-abc/def").rawValue
        #expect(!hostile.contains(" "))
        #expect(!hostile.contains("/"))
        #expect(!hostile.contains("-"))
        #expect(FieldName(String(repeating: "a", count: 500)).rawValue.count == 64)
        #expect(FieldName("///").rawValue == "unknown")
    }
}

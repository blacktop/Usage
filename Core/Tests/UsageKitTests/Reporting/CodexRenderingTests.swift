import Foundation
import Testing

@testable import UsageKit

/// The Codex vertical slice end to end: fixture credential file, fixture HTTP response, and both
/// CLI surfaces rendered from the result. Every boundary is injected; nothing here reaches a real
/// credential, the Keychain, or the network.
@Suite("Codex CLI rendering")
struct CodexRenderingTests {
    private static let now = Date(timeIntervalSince1970: 1_766_930_000)
    private let authURL = CodexAuthFile.url(root: ProviderFixtures.codexRoot)

    private func collection(
        usage fixture: String,
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) async throws -> UsageCollection {
        let http = InMemoryHTTPTransport()
        http.stub(
            CodexProvider.usageURL,
            with: try ProviderFixtures.response("Codex", fixture, status: status, headers: headers)
        )
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(files: [
                authURL: try ProviderFixtures.data("Codex", "codex-auth")
            ]),
            credentials: SealedCredentialSource(secrets: [
                CodexProvider.locator(at: authURL): "FAKE-access-token-0000"
            ]),
            http: http,
            clock: ManualClock(now: Self.now)
        )
        return await UsageCollector(registry: ProviderRegistry(providers: [CodexProvider()]))
            .collect(providers: [CodexProvider.id], using: context)
    }

    // MARK: - usage list

    @Test("usage list renders every window, the credit balance, and no credential path")
    func rendersTheTable() async throws {
        let collection = try await collection(usage: "codex-usage-happy")
        let rendered = UsageTable.render(collection, now: Self.now)

        #expect(
            rendered == """
                PROVIDER  ACCOUNT  PLAN  WINDOW               LEFT  RESETS
                codex     Codex    pro   Session               78%  5h 1m
                codex     Codex    pro   Weekly                57%  5d 12h
                codex     Codex    pro   GPT-5.3-Codex-Spark   70%  5h 1m
                codex     Codex    pro   GPT-5.3-Codex-Spark    0%  5d 12h

                PROVIDER  ACCOUNT  CREDITS
                codex     Codex    14.5
                """
        )
        #expect(!rendered.contains("auth.json"))
        for secret in ProviderFixtures.secretShapedValues {
            #expect(!rendered.contains(secret))
        }
    }

    @Test("an expired sign-in renders the failure and the command that clears it")
    func rendersTheReauthenticationAction() async throws {
        let collection = try await collection(usage: "codex-usage-auth-expired", status: 401)
        let rendered = UsageTable.render(collection, now: Self.now)

        #expect(
            rendered == """
                No accounts reported usage.

                FAILURES
                  codex  authenticationExpired: The provider returned HTTP 401.
                    Sign in to Codex again, then refresh. Run: codex login
                """
        )
    }

    @Test("a rate limit renders its retry advice and scope, with no sign-in instruction")
    func rendersRetryAdvice() async throws {
        let collection = try await collection(
            usage: "codex-usage-auth-expired",
            status: 429,
            headers: ["Retry-After": "120"]
        )
        let rendered = UsageTable.render(collection, now: Self.now)

        #expect(rendered.contains("rateLimited: The provider returned HTTP 429."))
        #expect(rendered.contains("(retry in 120s, account scope)"))
        #expect(!rendered.contains("codex login"))
    }

    @Test("a malformed sibling costs its own row and nothing else")
    func rendersPartialResponses() async throws {
        let collection = try await collection(usage: "codex-usage-malformed-element")
        let rendered = UsageTable.render(collection, now: Self.now)

        #expect(rendered.contains("Session"))
        #expect(rendered.contains("Weekly"))
        #expect(!rendered.contains("Broken Limit"))
        #expect(collection.outcome == .complete)
    }

    @Test("a partly readable response says so rather than passing as the whole picture")
    func marksAPartialReport() async throws {
        let partial = try await collection(usage: "codex-usage-malformed-element")
        let account = try #require(partial.accounts.first)
        #expect(account.report.isPartial)
        #expect(
            UsageTable.render(partial, now: Self.now)
                .contains("PARTIAL (some limits could not be read)")
        )
        #expect(
            try Fixtures.encodedString(partial.output(generatedAt: Self.now))
                .contains(#""partial":true"#)
        )

        let complete = try await collection(usage: "codex-usage-happy")
        #expect(try #require(complete.accounts.first).report.isPartial == false)
        #expect(!UsageTable.render(complete, now: Self.now).contains("PARTIAL"))
        #expect(
            !(try Fixtures.encodedString(complete.output(generatedAt: Self.now)))
                .contains("partial")
        )
    }

    @Test("an account with no display label falls back to a short identity digest")
    func rendersWithoutADisplayLabel() throws {
        let account = ProviderAccount(
            key: Fixtures.canonicalKey("golden"),
            slot: Fixtures.slot("slot"),
            locator: CredentialLocator(kind: .file, identifier: "/Users/secret/.codex/auth.json")
        )
        let collection = UsageCollection(
            requested: [Fixtures.provider],
            accounts: [CollectedAccount(account: account, report: try Fixtures.goldenReport())],
            failures: []
        )
        let rendered = UsageTable.render(collection, now: Fixtures.capturedAt)

        #expect(rendered.contains("5c5cd4db0261"))
        #expect(!rendered.contains("/Users/secret"))
        #expect(rendered.contains("0%"))
    }

    @Test("a run with nothing at all to say still says so")
    func rendersAnEmptyRun() {
        let rendered = UsageTable.render(
            UsageCollection(requested: [], accounts: [], failures: []),
            now: Self.now
        )
        #expect(rendered == "No accounts reported usage.")
    }

    @Test(
        "reset countdowns are short and never negative",
        arguments: [
            (-90.0, "due"), (0.0, "due"), (30.0, "<1m"), (90.0, "1m"), (3_600.0, "1h"),
            (5_400.0, "1h 30m"), (86_400.0, "1d"), (180_000.0, "2d 2h"),
        ]
    )
    func formatsResetCountdowns(offset: Double, expected: String) {
        #expect(RelativeTime.short(from: Self.now, to: Self.now + offset) == expected)
    }

    // MARK: - usage json

    @Test("usage json emits the versioned envelope, with no token and no credential path")
    func rendersTheEnvelope() async throws {
        let collection = try await collection(usage: "codex-usage-happy")
        let encoded = try Fixtures.encodedString(collection.output(generatedAt: Self.now))

        #expect(encoded.contains(#""schemaVersion":1"#))
        #expect(encoded.contains(#""generatedAt":1766930000"#))
        #expect(encoded.contains(#""label":"Codex""#))
        #expect(encoded.contains(#""providerID":"codex""#))
        #expect(encoded.contains(#""id":"plan:primary:session""#))
        #expect(encoded.contains(#""remaining":"14.5""#))
        #expect(encoded.contains(#""failures":[]"#))
        #expect(!encoded.contains("auth.json"))
        for secret in ProviderFixtures.secretShapedValues {
            #expect(!encoded.contains(secret))
        }
    }

    @Test("a failed run encodes its category, its message, and the command that clears it")
    func encodesFailures() async throws {
        let collection = try await collection(usage: "codex-usage-auth-expired", status: 401)
        let output = collection.output(generatedAt: Self.now)
        let encoded = try Fixtures.encodedString(output)

        let failure = try #require(output.failures.first)
        #expect(failure.providerID == "codex")
        #expect(failure.category == "authenticationExpired")
        #expect(failure.reauth?.command == "codex login")
        #expect(failure.reauth?.summary == "Sign in to Codex again, then refresh.")
        #expect(encoded.contains(#""reauth":{"command":"codex login""#))
        #expect(output.accounts.isEmpty)
    }

    @Test("the envelope round-trips through its own decoder")
    func envelopeRoundTrips() async throws {
        let output = try await collection(usage: "codex-usage-happy")
            .output(generatedAt: Self.now)
        let data = try UsageJSON.encoder().encode(output)
        #expect(try UsageJSON.decoder().decode(UsageOutputV1.self, from: data) == output)
    }

    // MARK: - Exit status

    @Test("the exit status distinguishes a complete run from a partial and a total failure")
    func reportsExitStatus() async throws {
        #expect(try await collection(usage: "codex-usage-happy").outcome.rawValue == 0)
        #expect(
            try await collection(usage: "codex-usage-auth-expired", status: 401).outcome.rawValue
                == 1
        )
    }
}

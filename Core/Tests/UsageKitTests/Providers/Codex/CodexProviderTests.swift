import Foundation
import Testing

@testable import UsageKit

@Suite("Codex provider")
struct CodexProviderTests {
    private let authURL = CodexAuthFile.url(root: ProviderFixtures.codexRoot)

    private func fileSystem(auth fixture: String?) throws -> SealedFileSystem {
        guard let fixture else { return SealedFileSystem() }
        return SealedFileSystem(files: [authURL: try ProviderFixtures.data("Codex", fixture)])
    }

    private func context(
        auth fixture: String?,
        http: InMemoryHTTPTransport = InMemoryHTTPTransport(),
        clock: ManualClock = ManualClock()
    ) throws -> (ProviderContext, SealedFileSystem, SealedCredentialSource) {
        let files = try fileSystem(auth: fixture)
        let credentials = SealedCredentialSource(
            secrets: [CodexProvider.locator(at: authURL): "FAKE-access-token-0000"]
        )
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: credentials,
            http: http,
            clock: clock
        )
        return (context, files, credentials)
    }

    // MARK: - Credential discovery

    @Test("discovers the account named by the id token, keyed by the canonical account id")
    func discoversAccount() async throws {
        let (context, files, credentials) = try context(auth: "codex-auth")
        let accounts = try await CodexProvider().discoverAccounts(using: context)

        let account = try #require(accounts.first)
        #expect(accounts.count == 1)
        #expect(account.key.accountID.derivation == .canonical)
        #expect(
            account.key.accountID
                == .canonical(provider: CodexProvider.id, canonicalID: "acct_FAKE0000000000000001")
        )
        #expect(account.displayName == "Codex", "the configured label names the account")
        #expect(account.availability == .active)
        #expect(account.locator.path == ["tokens", "access_token"])
        #expect(files.readsOutsideHome.isEmpty)
        #expect(credentials.resolvedLocators.isEmpty)
    }

    @Test("reports no account when the credential file is absent")
    func discoversNothingWithoutFile() async throws {
        let (context, _, _) = try context(auth: nil)
        #expect(try await CodexProvider().discoverAccounts(using: context).isEmpty)
    }

    @Test("an API key alone is not an OAuth account")
    func apiKeyIsNotAnAccount() async throws {
        let (context, _, _) = try context(auth: "codex-auth-apikey-only")
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )
        #expect(account.availability == .unavailable)
        #expect(account.key.accountID.derivation == .credentialSlot)
    }

    @Test("a token-less credential file is a discoverable but unusable slot")
    func tokenlessFileIsUnavailable() async throws {
        let (context, _, _) = try context(auth: "codex-auth-no-tokens")
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )
        #expect(account.availability == .unavailable)
        #expect(
            account.displayName == "Codex",
            "an unusable slot is still labelled, because the label comes from configuration"
        )
    }

    // MARK: - The Keychain is not a Codex credential source

    /// A `Codex Auth` Keychain item exists on some machines, but its payload format is
    /// undocumented and the Codex CLI reference never reads it. Reading it meant guessing it holds
    /// another `auth.json`. Reinstating that guess turns these red.
    @Test(
        "the Keychain is never enumerated, whatever the credential file says",
        arguments: [nil, "codex-auth", "codex-auth-apikey-only"] as [String?]
    )
    func neverEnumeratesTheKeychain(fixture: String?) async throws {
        let (context, _, credentials) = try context(auth: fixture)

        let accounts = try await CodexProvider().discoverAccounts(using: context)

        #expect(credentials.enumeratedNamespaces.isEmpty)
        #expect(accounts.allSatisfy { $0.locator.kind == .file })
    }

    @Test("an unusable credential file yields an unavailable account, not a Keychain fallback")
    func unusableFileDoesNotFallBack() async throws {
        let (context, _, credentials) = try context(auth: "codex-auth-apikey-only")

        let accounts = try await CodexProvider().discoverAccounts(using: context)

        #expect(accounts.count == 1)
        #expect(accounts.first?.locator.kind == .file)
        #expect(accounts.first?.availability == .unavailable)
        #expect(credentials.enumeratedNamespaces.isEmpty)
    }

    // MARK: - Request construction

    @Test("sends the exact usage request")
    func buildsUsageRequest() throws {
        let request = CodexProvider.usageRequest(chatGPTAccountID: "acct_FAKE0000000000000001")
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["User-Agent"] == "Usage/0.1.0")
        #expect(request.headers["ChatGPT-Account-Id"] == "acct_FAKE0000000000000001")
        #expect(request.body == nil)
        #expect(request.headers["Authorization"] == nil)
    }

    @Test("omits the account header entirely when no account id is known")
    func omitsAccountHeader() throws {
        let request = CodexProvider.usageRequest(chatGPTAccountID: nil)
        #expect(request.headers["ChatGPT-Account-Id"] == nil)
        #expect(CodexProvider.usageRequest(chatGPTAccountID: "").headers.count == 2)
    }

    @Test("stamps the bearer token onto the sent request and nothing else")
    func sendsAuthorizedRequest() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            CodexProvider.usageURL,
            with: try ProviderFixtures.response("Codex", "codex-usage-happy"))
        let (context, _, credentials) = try context(auth: "codex-auth", http: http)
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )

        _ = try await CodexProvider().fetchUsage(for: account, using: context)

        let sent = try #require(http.recordedRequests.first)
        #expect(sent.headerValue("Authorization") == "Bearer FAKE-access-token-0000")
        #expect(sent.headerValue("ChatGPT-Account-Id") == "acct_FAKE0000000000000001")
        #expect(credentials.resolvedLocators == [CodexProvider.locator(at: authURL)])
    }

    // MARK: - Response parsing

    @Test("maps the happy path onto four windows and a credit balance")
    func mapsHappyPath() async throws {
        let report = try await fetch(usage: "codex-usage-happy")

        #expect(report.plan == "pro")
        #expect(report.windows.count == 4)

        let session = try #require(report.windows.first { $0.kind == .session })
        #expect(session.usedFraction == 0.22)
        #expect(session.duration == .seconds(18_000))
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_766_948_068))

        let weekly = try #require(report.windows.first { $0.kind == .weekly })
        #expect(weekly.usedFraction == 0.43)
        #expect(weekly.duration == .seconds(604_800))

        let spark = report.windows.filter { $0.kind == .named("GPT-5.3-Codex-Spark") }
        #expect(spark.count == 2)
        #expect(
            Set(spark.map(\.id.rawValue)) == [
                "additional:gpt-5-3-codex-spark:primary:session",
                "additional:gpt-5-3-codex-spark:secondary:weekly",
            ]
        )
        #expect(report.credits?.remaining == Decimal(string: "14.5"))
        #expect(report.credits?.currency == nil)
    }

    @Test("a malformed array element never discards its valid siblings")
    func keepsSiblingsAcrossMalformedElements() async throws {
        let response = try CodexUsageResponse.decode(
            try ProviderFixtures.data("Codex", "codex-usage-malformed-element")
        )
        #expect(response.hadDecodeFailure)

        let report = try await fetch(usage: "codex-usage-malformed-element")
        #expect(report.windows.count == 3)
        #expect(report.windows.first { $0.kind == .session }?.usedFraction == 0.22)
        #expect(report.windows.first { $0.kind == .weekly }?.usedFraction == 0.43)

        let extras = report.windows.filter { $0.kind == .named("GPT-5.3-Codex-Spark") }
        #expect(extras.count == 1)
        #expect(extras.first?.usedFraction == 0.30)
        #expect(!report.windows.contains { $0.kind == .named("Broken Limit") })
    }

    @Test("an entirely malformed additional array leaves the plan windows intact")
    func keepsPlanWindowsWhenEveryElementIsMalformed() async throws {
        let report = try await fetch(usage: "codex-usage-all-elements-malformed")
        #expect(report.windows.count == 1)
        let weekly = try #require(report.windows.first)
        #expect(weekly.kind == .weekly)
        #expect(weekly.usedFraction == 0.61)
    }

    @Test("a response that yields no limit at all is a failure, not an empty report")
    func rejectsAResponseWithNothingToMap() async throws {
        await #expect(throws: UsageError.decodingFailure(field: "wham.usage")) {
            _ = try await fetch(usage: "codex-usage-renamed-shape")
        }
    }

    @Test("two limits over one metered feature keep separate identities")
    func separatesLimitsSharingAMeteredFeature() async throws {
        let report = try await fetch(usage: "codex-usage-shared-metered-feature")

        #expect(report.windows.count == 2)
        #expect(
            Set(report.windows.map(\.id.rawValue)) == [
                "additional:code-review-requests:primary:weekly",
                "additional:code-review-tokens:primary:weekly",
            ]
        )
        #expect(report.windows.first { $0.label == "Tokens" }?.usedFraction == 0.95)
        #expect(report.windows.first { $0.label == "Requests" }?.usedFraction == 0.10)
    }

    @Test("a weekly-only free plan lands in the weekly window, not the session one")
    func normalisesWeeklyOnlyPlan() async throws {
        let report = try await fetch(usage: "codex-usage-all-elements-malformed")
        #expect(!report.windows.contains { $0.kind == .session })
    }

    @Test("a zero reset is no reset, and a zero window length is no length")
    func treatsZeroesAsAbsent() async throws {
        let report = try await fetch(usage: "codex-usage-zero-reset")
        let window = try #require(report.windows.first)
        #expect(window.resetsAt == nil)
        #expect(window.duration == nil)
    }

    @Test(
        "window role follows the window length",
        arguments: [
            (300, CodexWindowPeriod.session),
            (18_000, CodexWindowPeriod.session),
            (86_400, CodexWindowPeriod.session),
            (604_800, CodexWindowPeriod.weekly),
            (2_592_000, CodexWindowPeriod.weekly),
        ]
    )
    func classifiesWindows(seconds: Int, expected: CodexWindowPeriod) {
        #expect(CodexWindowPeriod.classify(seconds: seconds) == expected)
    }

    @Test("an unrecognised window length is not forced into a role")
    func doesNotGuessUnknownWindowLengths() {
        #expect(CodexWindowPeriod.classify(seconds: 3 * 86_400) == nil)
        #expect(CodexWindowPeriod.classify(seconds: 0) == nil)
        #expect(CodexWindowPeriod.classify(seconds: nil) == nil)
    }

    // MARK: - Authentication expiry

    @Test("401 and 403 both mean the sign-in has to be renewed", arguments: [401, 403])
    func mapsUnauthorizedStatuses(status: Int) async throws {
        let error = try await fetchError(usage: "codex-usage-auth-expired", status: status)
        #expect(error.category == .authenticationExpired)
        #expect(error.reason == .httpStatus(code: status))
        #expect(error.retry == nil)
    }

    @Test("the 401 body never reaches the rendered error or its encoding")
    func redactsAuthExpiredBody() async throws {
        let error = try await fetchError(usage: "codex-usage-auth-expired", status: 401)
        let encoded = try Fixtures.encodedString(error)
        for secret in ProviderFixtures.secretShapedValues {
            #expect(!error.message.contains(secret))
            #expect(!error.description.contains(secret))
            #expect(!encoded.contains(secret))
        }
    }

    @Test("an expired sign-in carries `codex login`, the only thing that clears it")
    func offersReauthentication() async throws {
        let error = try await fetchError(usage: "codex-usage-auth-expired", status: 401)
        let action = try #require(error.reauthentication)
        #expect(action.command == "codex login")
        #expect(action.summary == "Sign in to Codex again, then refresh.")
    }

    @Test("a credential the source cannot resolve carries the same instruction")
    func offersReauthenticationWhenTheCredentialIsGone() async throws {
        let files = try fileSystem(auth: "codex-auth")
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: SealedCredentialSource()
        )
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )

        let thrown = await #expect(throws: UsageError.self) {
            _ = try await CodexProvider().fetchUsage(for: account, using: context)
        }
        let error = try #require(thrown)
        #expect(error.category == .credentialUnavailable)
        #expect(error.reauthentication?.command == "codex login")
    }

    @Test("a 429 carries its Retry-After as account-scoped advice")
    func honoursRetryAfter() async throws {
        let error = try await fetchError(
            usage: "codex-usage-auth-expired",
            status: 429,
            headers: ["Retry-After": "120"]
        )
        #expect(error.category == .rateLimited)
        #expect(error.retry?.delay == .seconds(120))
        #expect(error.retry?.scope == .account)
    }

    @Test("a Retry-After given as an HTTP date is honoured too")
    func honoursHTTPDateRetryAfter() async throws {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let http = InMemoryHTTPTransport()
        http.stub(
            CodexProvider.usageURL,
            with: try ProviderFixtures.response(
                "Codex",
                "codex-usage-auth-expired",
                status: 429,
                headers: ["Retry-After": "Tue, 14 Nov 2023 22:16:40 GMT"]
            )
        )
        let (context, _, _) = try context(auth: "codex-auth", http: http, clock: clock)
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )

        let thrown = await #expect(throws: UsageError.self) {
            _ = try await CodexProvider().fetchUsage(for: account, using: context)
        }
        let error = try #require(thrown)
        #expect(error.category == .rateLimited)
        #expect(error.retry == UsageError.RetryAdvice(delay: .seconds(200), scope: .account))
        #expect(error.reauthentication == nil)
    }

    // MARK: - Offline

    @Test("an unreachable endpoint is a network failure, not an expired sign-in")
    func reportsTransportFailure() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(CodexProvider.usageURL, failingWith: .transportFailure())
        let (context, _, _) = try context(auth: "codex-auth", http: http)
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )

        let thrown = await #expect(throws: UsageError.self) {
            _ = try await CodexProvider().fetchUsage(for: account, using: context)
        }
        let error = try #require(thrown)
        #expect(error.category == .network)
        #expect(error.reason == .transportFailure)
        #expect(error.retry == nil)
        #expect(error.reauthentication == nil)
    }

    @Test("discovery still lists the account while the network is down")
    func discoversWhileOffline() async throws {
        let (context, _, _) = try context(auth: "codex-auth")
        let accounts = try await CodexProvider().discoverAccounts(using: context)
        #expect(accounts.count == 1)
    }

    // MARK: - No mutation, no UI

    @Test("every credential writer is untouched after a full discovery and fetch")
    func neverMutatesOrPrompts() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            CodexProvider.usageURL,
            with: try ProviderFixtures.response("Codex", "codex-usage-happy")
        )
        let files = try fileSystem(auth: "codex-auth")
        let credentials = SealedCredentialSource(
            secrets: [CodexProvider.locator(at: authURL): "FAKE-access-token-0000"],
            interactiveOnly: [],
            allowsInteraction: false
        )
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: credentials,
            http: http
        )

        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )
        _ = try await CodexProvider().fetchUsage(for: account, using: context)

        #expect(files.mutationAttempts.isEmpty)
        #expect(files.isUnmodified)
        #expect(files.readsOutsideHome.isEmpty)
        #expect(credentials.mutationAttempts.isEmpty)
        #expect(credentials.isUnmodified)
        #expect(credentials.refusedInteractiveRequests.isEmpty)
        #expect(credentials.enumeratedNamespaces.isEmpty)
        #expect(http.recordedRequests.allSatisfy { $0.method == .get })
    }

    @Test("the writer fakes do fail when something writes, so the proof is not vacuous")
    func writerFakesDetectMutation() throws {
        let files = try fileSystem(auth: "codex-auth")
        files.write(Data("{}".utf8), to: authURL)
        #expect(!files.mutationAttempts.isEmpty)
        #expect(!files.isUnmodified)

        let credentials = SealedCredentialSource()
        credentials.store("FAKE-access-token-0000", at: CodexProvider.locator(at: authURL))
        #expect(!credentials.mutationAttempts.isEmpty)
        #expect(!credentials.isUnmodified)
    }

    @Test("discovery makes no network request")
    func discoveryIsLocal() async throws {
        let (context, _, _) = try context(auth: "codex-auth", http: InMemoryHTTPTransport())
        _ = try await CodexProvider().discoverAccounts(using: context)
        let http = try #require(context.http as? InMemoryHTTPTransport)
        #expect(http.recordedRequests.isEmpty)
    }

    @Test("a credential that can only be read interactively fails closed in the background")
    func failsClosedWithoutInteraction() async throws {
        let locator = CodexProvider.locator(at: authURL)
        let credentials = SealedCredentialSource(
            secrets: [locator: "FAKE-access-token-0000"],
            interactiveOnly: [locator],
            allowsInteraction: false
        )
        let context = ProviderContext.sealed(
            fileSystem: try fileSystem(auth: "codex-auth"),
            credentials: credentials
        )
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )

        await #expect(throws: UsageError.interactionForbidden()) {
            _ = try await CodexProvider().fetchUsage(for: account, using: context)
        }
        #expect(credentials.refusedInteractiveRequests == [locator])
    }

    // MARK: - Helpers

    private func fetch(usage fixture: String) async throws -> UsageReport {
        let http = InMemoryHTTPTransport()
        http.stub(CodexProvider.usageURL, with: try ProviderFixtures.response("Codex", fixture))
        let (context, _, _) = try context(auth: "codex-auth", http: http)
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )
        return try await CodexProvider().fetchUsage(for: account, using: context)
    }

    private func fetchError(
        usage fixture: String,
        status: Int,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) async throws -> UsageError {
        let http = InMemoryHTTPTransport()
        http.stub(
            CodexProvider.usageURL,
            with: try ProviderFixtures.response(
                "Codex",
                fixture,
                status: status,
                headers: headers
            )
        )
        let (context, _, _) = try context(auth: "codex-auth", http: http)
        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )
        var captured: UsageError?
        do {
            _ = try await CodexProvider().fetchUsage(for: account, using: context)
        } catch let error as UsageError {
            captured = error
        }
        return try #require(captured)
    }
}

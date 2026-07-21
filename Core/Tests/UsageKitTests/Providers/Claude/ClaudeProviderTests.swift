import Foundation
import Testing

@testable import UsageKit

@Suite("Claude provider")
struct ClaudeProviderTests {
    private static let credentialURL = ClaudeCredentialFile.url(home: ProviderFixtures.home)
    private static let accessToken = "sk-ant-oat01-FAKE-ACCESS-TOKEN-DO-NOT-USE-0000000000"
    /// A clock set before the happy fixture's expiry and after the expired fixture's.
    private static let now = Date(timeIntervalSince1970: 1_784_000_000)

    private static func keychainDescriptor(
        _ opaqueID: String,
        displayName: String?
    ) -> CredentialSlotDescriptor {
        CredentialSlotDescriptor(
            slot: CredentialSlotID(source: ClaudeProvider.keychainSlotSource, opaqueID: opaqueID),
            locator: CredentialLocator(
                kind: .keychain,
                identifier: ClaudeCredentialFile.keychainService
            ),
            displayName: displayName
        )
    }

    private static func keychainLocator() -> CredentialLocator {
        CredentialLocator(
            kind: .keychain,
            identifier: ClaudeCredentialFile.keychainService,
            path: ClaudeCredentialFile.secretPath
        )
    }

    private static func fileLocator() -> CredentialLocator {
        CredentialLocator(
            kind: .file,
            identifier: credentialURL.standardizedFileURL.path(percentEncoded: false),
            path: ClaudeCredentialFile.secretPath
        )
    }

    // MARK: - Credential discovery

    @Test("enumerates every Keychain slot, newest first, without reading any item's data")
    func enumeratesKeychainSlots() async throws {
        let credentials = SealedCredentialSource(
            slots: [
                ClaudeProvider.keychainNamespace: [
                    Self.keychainDescriptor("aa11bb22cc33", displayName: "primary@example.invalid"),
                    Self.keychainDescriptor("dd44ee55ff66", displayName: "second@example.invalid"),
                ]
            ]
        )
        let context = ProviderContext.sealed(credentials: credentials)

        let accounts = try await ClaudeProvider().discoverAccounts(using: context)

        #expect(accounts.count == 2)
        #expect(accounts[0].availability == .active)
        #expect(accounts[1].availability == .inactive)
        #expect(accounts[0].displayName == "primary@example.invalid")
        #expect(accounts.allSatisfy { $0.key.accountID.derivation == .credentialSlot })
        #expect(Set(accounts.map(\.key)).count == 2)
        #expect(accounts.allSatisfy { $0.locator.path == ["claudeAiOauth", "accessToken"] })
        #expect(credentials.enumeratedNamespaces == [ClaudeProvider.keychainNamespace])
        #expect(credentials.resolvedLocators.isEmpty)
    }

    @Test("falls back to the credentials file only when the Keychain has no slot")
    func fallsBackToFile() async throws {
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    Self.credentialURL: try ProviderFixtures.data(
                        "Claude",
                        "claude-credential-happy"
                    )
                ]
            ),
            clock: ManualClock(now: Self.now)
        )

        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        #expect(account.locator.kind == .file)
        #expect(account.availability == .active)
        #expect(account.displayName == "Claude Max 20x")
    }

    @Test("an expired file credential is discovered but marked unusable")
    func expiredFileCredential() async throws {
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    Self.credentialURL: try ProviderFixtures.data(
                        "Claude",
                        "claude-credential-expired"
                    )
                ]
            ),
            clock: ManualClock(now: Self.now)
        )
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        #expect(account.availability == .unavailable)
    }

    @Test("an MCP-only credential document is a missing sign-in, not a malformed file")
    func mcpOnlyCredential() throws {
        let data = try ProviderFixtures.data("Claude", "claude-credential-mcp-only")
        #expect(throws: UsageError.credentialUnavailable(kind: .keychain)) {
            _ = try ClaudeCredentialFile.parse(data, kind: .keychain)
        }
    }

    @Test(
        "plan label is composed from the credential, which is the only place it appears",
        arguments: [
            ("max", "default_claude_max_20x", "Claude Max 20x"),
            ("pro", "default_claude_pro", "Claude Pro"),
            ("team", nil, "Claude Team"),
            (nil, "default_claude_max", "Claude Max"),
            (nil, nil, nil),
        ] as [(String?, String?, String?)]
    )
    func composesPlanLabel(subscription: String?, tier: String?, expected: String?) {
        #expect(
            ClaudePlanLabel.make(subscriptionType: subscription, rateLimitTier: tier) == expected)
    }

    // MARK: - Request construction

    @Test("sends the exact usage request")
    func buildsUsageRequest() {
        let request = ClaudeProvider.usageRequest()
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(request.headers["User-Agent"] == "claude-code/2.1.0")
        #expect(request.headers["anthropic-version"] == nil)
        #expect(request.headers["Authorization"] == nil)
        #expect(request.body == nil)
    }

    @Test("stamps the bearer token onto the sent request")
    func sendsAuthorizedRequest() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let (account, context) = try await keychainAccount(http: http)
        _ = try await ClaudeProvider().fetchUsage(for: account, using: context)

        let sent = try #require(http.recordedRequests.first)
        #expect(sent.headerValue("Authorization") == "Bearer \(Self.accessToken)")
    }

    // MARK: - Response parsing

    @Test("maps the happy path onto four windows and a credit balance")
    func mapsHappyPath() async throws {
        let report = try await fetch(usage: "claude-usage-happy")

        #expect(report.windows.count == 4)
        let session = try #require(report.windows.first { $0.kind == .session })
        #expect(session.usedFraction == 0.125)
        #expect(session.duration == .seconds(18_000))
        // Literal instants, not another call to the formatter under test: the `.000Z` and the
        // `.282694+00:00` spellings are the two shapes `ProviderDates` exists to absorb, and
        // comparing the parser to itself passes just as happily when both sides are nil.
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_784_572_200))

        let weekly = try #require(report.windows.first { $0.kind == .weekly })
        #expect(weekly.usedFraction == 0.41)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_784_883_600.282))

        let scoped = try #require(
            report.windows.first { $0.id.rawValue == "additional:fable:primary:weekly" }
        )
        #expect(scoped.label == "Fable only")
        #expect(scoped.usedFraction == 0.05)

        #expect(report.windows.contains { $0.id.rawValue == "additional:routines:primary:weekly" })
        #expect(report.credits?.remaining == Decimal(string: "17.25"))
        #expect(report.credits?.granted == Decimal(string: "20.5"))
        #expect(report.credits?.currency == "USD")
    }

    @Test("the session and weekly-all rows of the limits array do not duplicate the plan windows")
    func doesNotDuplicatePlanWindows() async throws {
        let report = try await fetch(usage: "claude-usage-happy")
        #expect(report.windows.filter { $0.kind == .session }.count == 1)
        #expect(report.windows.filter { $0.kind == .weekly }.count == 1)
    }

    @Test("a malformed limits element never discards its valid siblings")
    func keepsSiblingsAcrossMalformedElements() async throws {
        let response = try ClaudeUsageResponse.decode(
            try ProviderFixtures.data("Claude", "claude-usage-malformed-element")
        )
        #expect(response.hadDecodeFailure)
        #expect(response.limits.count == 4)

        let report = try await fetch(usage: "claude-usage-malformed-element")
        #expect(report.isPartial, "the dropped subtree is visible in the report itself")
        #expect(report.windows.first { $0.kind == .session }?.usedFraction == 0.11)
        #expect(report.windows.first { $0.kind == .weekly }?.usedFraction == 0.09)
        #expect(
            report.windows.first { $0.id.rawValue == "additional:fake-model-a:primary:weekly" }?
                .usedFraction == 0.05
        )
        #expect(
            report.windows.first { $0.id.rawValue == "additional:fake-model-b:primary:weekly" }?
                .usedFraction == 0.225
        )
    }

    @Test("an all-models scope is dropped rather than double-counting the weekly window")
    func dropsAllModelsScope() async throws {
        let report = try await fetch(usage: "claude-usage-malformed-element")
        #expect(!report.windows.contains { $0.label.contains("All models") })
        #expect(report.windows.count == 4)
    }

    @Test("a corrupt sibling window does not fail the whole document")
    func dropsCorruptSiblingWindow() async throws {
        let report = try await fetch(usage: "claude-usage-malformed-element")
        #expect(!report.windows.contains { $0.label == "Sonnet only" })
    }

    @Test("a spend-limit-only account still produces a report, expressed as credits")
    func mapsSpendLimitOnly() async throws {
        let report = try await fetch(usage: "claude-usage-spend-limit-only")
        #expect(report.windows.isEmpty)
        #expect(report.credits?.remaining == Decimal(1))
        #expect(report.credits?.granted == Decimal(50))
        #expect(report.credits?.currency == "EUR")
    }

    @Test("a response with nothing usable is a typed error, not an empty report")
    func rejectsEmptyResponse() async throws {
        await #expect(throws: UsageError.decodingFailure(field: "oauth.usage")) {
            _ = try await fetch(usage: "claude-usage-empty")
        }
    }

    // MARK: - Authentication expiry

    @Test("401 means the sign-in has to be renewed")
    func mapsUnauthorized() async throws {
        let error = try await fetchError(usage: "claude-usage-auth-expired", status: 401)
        #expect(error.category == .authenticationExpired)
        #expect(error.reason == .httpStatus(code: 401))
    }

    @Test("the 401 body never reaches the rendered error or its encoding")
    func redactsAuthExpiredBody() async throws {
        let error = try await fetchError(usage: "claude-usage-auth-expired", status: 401)
        let encoded = try Fixtures.encodedString(error)
        for secret in ProviderFixtures.secretShapedValues {
            #expect(!error.message.contains(secret))
            #expect(!error.description.contains(secret))
            #expect(!encoded.contains(secret))
        }
    }

    @Test("a 429 honours an HTTP-date Retry-After as well as delta-seconds")
    func honoursRetryAfterDate() async throws {
        let error = try await fetchError(
            usage: "claude-usage-429",
            status: 429,
            headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]
        )
        #expect(error.category == .rateLimited)
        let target = try #require(ProviderDates.iso8601("2026-10-21T07:28:00Z"))
        #expect(
            error.retry?.delay == .seconds(Int(target.timeIntervalSince(Self.now).rounded(.up))))
        #expect(error.retry?.scope == .account)
    }

    @Test("an expired file credential is not sent to the network at all")
    func skipsNetworkForExpiredCredential() async throws {
        let http = InMemoryHTTPTransport()
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    Self.credentialURL: try ProviderFixtures.data(
                        "Claude",
                        "claude-credential-expired"
                    )
                ]
            ),
            credentials: SealedCredentialSource(secrets: [Self.fileLocator(): Self.accessToken]),
            http: http,
            clock: ManualClock(now: Self.now)
        )
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )

        await #expect(
            throws: UsageError(
                category: .authenticationExpired,
                reason: .credentialUnavailable(kind: .file)
            )
        ) {
            _ = try await ClaudeProvider().fetchUsage(for: account, using: context)
        }
        #expect(http.recordedRequests.isEmpty)
    }

    // MARK: - No mutation, no UI

    @Test("discovery and fetch mutate nothing and never ask for credential UI")
    func neverMutatesOrPrompts() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let files = SealedFileSystem(
            files: [
                Self.credentialURL: try ProviderFixtures.data("Claude", "claude-credential-happy")
            ]
        )
        let credentials = SealedCredentialSource(
            secrets: [Self.fileLocator(): Self.accessToken],
            allowsInteraction: false
        )
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: credentials,
            http: http,
            clock: ManualClock(now: Self.now)
        )

        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        _ = try await ClaudeProvider().fetchUsage(for: account, using: context)

        #expect(files.mutationAttempts.isEmpty)
        #expect(files.isUnmodified)
        #expect(files.readsOutsideHome.isEmpty)
        #expect(credentials.refusedInteractiveRequests.isEmpty)
    }

    @Test("a Keychain slot that would need UI fails closed during a background refresh")
    func failsClosedWithoutInteraction() async throws {
        let credentials = SealedCredentialSource(
            secrets: [Self.keychainLocator(): Self.accessToken],
            slots: [
                ClaudeProvider.keychainNamespace: [
                    Self.keychainDescriptor("aa11bb22cc33", displayName: nil)
                ]
            ],
            interactiveOnly: [Self.keychainLocator()],
            allowsInteraction: false
        )
        let context = ProviderContext.sealed(credentials: credentials)
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )

        await #expect(throws: UsageError.interactionForbidden()) {
            _ = try await ClaudeProvider().fetchUsage(for: account, using: context)
        }
        #expect(credentials.refusedInteractiveRequests == [Self.keychainLocator()])
    }

    @Test("discovery makes no network request")
    func discoveryIsLocal() async throws {
        let http = InMemoryHTTPTransport()
        let context = ProviderContext.sealed(
            credentials: SealedCredentialSource(
                slots: [
                    ClaudeProvider.keychainNamespace: [
                        Self.keychainDescriptor("aa11bb22cc33", displayName: nil)
                    ]
                ]
            ),
            http: http
        )
        _ = try await ClaudeProvider().discoverAccounts(using: context)
        #expect(http.recordedRequests.isEmpty)
    }

    // MARK: - Helpers

    private func keychainAccount(
        http: InMemoryHTTPTransport
    ) async throws -> (ProviderAccount, ProviderContext) {
        let credentials = SealedCredentialSource(
            secrets: [Self.keychainLocator(): Self.accessToken],
            slots: [
                ClaudeProvider.keychainNamespace: [
                    Self.keychainDescriptor("aa11bb22cc33", displayName: "primary@example.invalid")
                ]
            ]
        )
        let context = ProviderContext.sealed(
            credentials: credentials,
            http: http,
            clock: ManualClock(now: Self.now)
        )
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        return (account, context)
    }

    private func fetch(usage fixture: String) async throws -> UsageReport {
        let http = InMemoryHTTPTransport()
        http.stub(ClaudeProvider.usageURL, with: try ProviderFixtures.response("Claude", fixture))
        let (account, context) = try await keychainAccount(http: http)
        return try await ClaudeProvider().fetchUsage(for: account, using: context)
    }

    private func fetchError(
        usage fixture: String,
        status: Int,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) async throws -> UsageError {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response(
                "Claude",
                fixture,
                status: status,
                headers: headers
            )
        )
        let (account, context) = try await keychainAccount(http: http)
        var captured: UsageError?
        do {
            _ = try await ClaudeProvider().fetchUsage(for: account, using: context)
        } catch let error as UsageError {
            captured = error
        }
        return try #require(captured)
    }
}

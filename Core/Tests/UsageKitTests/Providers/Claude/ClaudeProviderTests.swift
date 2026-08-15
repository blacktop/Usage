import Foundation
import Testing

@testable import UsageKit

@Suite("Claude provider")
struct ClaudeProviderTests {
    private static let credentialURL = ClaudeCredentialFile.url(root: ProviderFixtures.claudeRoot)
    private static let accessToken = "sk-ant-oat01-FAKE-ACCESS-TOKEN-DO-NOT-USE-0000000000"
    /// A clock set before the happy fixture's expiry and after the expired fixture's.
    private static let now = Date(timeIntervalSince1970: 1_784_000_000)

    private static func fileLocator() -> CredentialLocator {
        CredentialLocator(
            kind: .file,
            identifier: credentialURL.standardizedFileURL.path(percentEncoded: false),
            path: ClaudeCredentialFile.secretPath
        )
    }

    private static func keychainNamespace(for root: URL) -> CredentialLocator {
        ClaudeCodeKeychain.namespace(for: root, homeDirectory: ProviderFixtures.home)
    }

    private func fileSystem(credential fixture: String?) throws -> SealedFileSystem {
        guard let fixture else { return SealedFileSystem() }
        return SealedFileSystem(
            files: [Self.credentialURL: try ProviderFixtures.data("Claude", fixture)]
        )
    }

    private func context(
        credential fixture: String?,
        http: any HTTPTransport = RefusingHTTPTransport(),
        credentials: SealedCredentialSource = SealedCredentialSource()
    ) throws -> ProviderContext {
        ProviderContext.sealed(
            fileSystem: try fileSystem(credential: fixture),
            credentials: credentials,
            http: http,
            clock: ManualClock(now: Self.now)
        )
    }

    // MARK: - Credential discovery

    @Test("discovers the credential document below the configured root")
    func discoversFileCredential() async throws {
        let files = try fileSystem(credential: "claude-credential-happy")
        let credentials = SealedCredentialSource()
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: credentials,
            clock: ManualClock(now: Self.now)
        )

        let accounts = try await ClaudeProvider().discoverAccounts(using: context)

        let account = try #require(accounts.first)
        #expect(accounts.count == 1)
        #expect(account.locator.kind == .file)
        #expect(account.locator.identifier == Self.fileLocator().identifier)
        #expect(account.locator.path == ["claudeAiOauth", "accessToken"])
        #expect(account.availability == .active)
        #expect(account.displayName == "Claude", "the configured label names the account")
        #expect(account.key.accountID.derivation == .credentialSlot)
        #expect(files.readsOutsideHome.isEmpty)
        #expect(credentials.resolvedLocators.isEmpty)
    }

    @Test("reports no account when the root holds no credential document")
    func discoversNothingWithoutFile() async throws {
        let context = try context(credential: nil)
        #expect(try await ClaudeProvider().discoverAccounts(using: context).isEmpty)
    }

    @Test("a locally expired credential remains usable until the provider rejects it")
    func expiredFileCredential() async throws {
        let context = try context(credential: "claude-credential-expired")
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        #expect(account.availability == .active)
    }

    @Test("an MCP-only credential document is a missing sign-in, not a malformed file")
    func mcpOnlyCredential() throws {
        let data = try ProviderFixtures.data("Claude", "claude-credential-mcp-only")
        #expect(throws: UsageError.credentialUnavailable(kind: .file)) {
            _ = try ClaudeCredentialFile.parse(data, kind: .file)
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

    // MARK: - Usage-owned setup tokens

    @Test("the setup-token service is Usage-owned and unrelated to Claude Code's item")
    func setupTokenServiceName() {
        #expect(ClaudeSetupTokenCredential.service == "io.blacktop.Usage.claude-setup-token")
        #expect(ClaudeSetupTokenCredential.service != KeychainProbe.claudeService)
        #expect(ClaudeSetupTokenCredential.namespace.kind == .appKeychain)
    }

    @Test("the default root uses Claude Code's plain service, never its stale hashed service")
    func defaultRootUsesPlainClaudeKeychain() async throws {
        let defaultNamespace = CredentialLocator(
            kind: .keychain,
            identifier: KeychainProbe.claudeService
        )
        let staleHashedNamespace = CredentialLocator(
            kind: .keychain,
            identifier: "Claude Code-credentials-45fdef0d"
        )
        let currentDescriptor = CredentialSlotDescriptor(
            slot: CredentialSlotID(source: "keychain", opaqueID: "fixture"),
            locator: CredentialLocator(kind: .keychain, identifier: "current-reference"),
            displayName: "fixture"
        )
        let staleDescriptor = CredentialSlotDescriptor(
            slot: CredentialSlotID(source: "keychain", opaqueID: "stale"),
            locator: CredentialLocator(kind: .keychain, identifier: "stale-reference"),
            displayName: "stale"
        )
        let credentials = SealedCredentialSource(
            slots: [
                defaultNamespace: [currentDescriptor],
                staleHashedNamespace: [staleDescriptor],
            ]
        )

        let accounts = try await ClaudeProvider().discoverAccounts(
            using: ProviderContext.sealed(credentials: credentials)
        )

        let account = try #require(accounts.first)
        #expect(accounts.count == 1)
        #expect(account.locator.identifier == "current-reference")
        #expect(
            credentials.enumeratedNamespaces == [
                ClaudeSetupTokenCredential.namespace,
                defaultNamespace,
            ],
            "the obsolete default-root hash is never consulted"
        )
        #expect(credentials.resolvedLocators.isEmpty)
    }

    @Test("a Claude Code Keychain row beats a setup token and keeps the root's logical slot")
    func keychainRowTakesPrecedenceOverSetupToken() async throws {
        let setup = try setupTokenDiscovery()
        let namespace = Self.keychainNamespace(for: ProviderFixtures.claudeRoot)
        let rowDescriptor = CredentialSlotDescriptor(
            slot: CredentialSlotID(source: "keychain:\(namespace.identifier)", opaqueID: "user"),
            locator: CredentialLocator(kind: .keychain, identifier: "cmVmZXJlbmNl")
        )
        let credentials = SealedCredentialSource(
            slots: [
                namespace: [rowDescriptor],
                ClaudeSetupTokenCredential.namespace: [
                    setupTokenDescriptor(locator: setup.locator)
                ],
            ]
        )
        let context = ProviderContext.sealed(
            credentials: credentials,
            clock: ManualClock(now: Self.now),
            profileRoots: setup.profileRoots
        )

        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        let setupAccount = try #require(
            try await ClaudeProvider().discoverAccounts(using: setup.context).first
        )

        #expect(account.locator.kind == .keychain)
        #expect(account.locator.identifier == "cmVmZXJlbmNl")
        #expect(account.locator.path == ClaudeCredentialFile.secretPath)
        #expect(account.availability == .active)
        #expect(account.slot == setupAccount.slot, "identity survives the backend change")
        #expect(credentials.resolvedLocators.isEmpty, "discovery never reads payloads")
    }

    @Test("a keychain-backed fetch stamps the bearer and reads the plan from the document")
    func fetchesWithKeychainCredential() async throws {
        let root = try SealedProfileRoots.root(
            ClaudeProvider.id,
            label: "Claude",
            at: ProviderFixtures.claudeRoot
        )
        let namespace = Self.keychainNamespace(for: ProviderFixtures.claudeRoot)
        let locator = CredentialLocator(
            kind: .keychain,
            identifier: "cmVmZXJlbmNl",
            path: ClaudeCredentialFile.secretPath
        )
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let credentials = SealedCredentialSource(
            secrets: [locator: Self.accessToken],
            documents: [locator: try ProviderFixtures.data("Claude", "claude-credential-happy")],
            slots: [
                namespace: [
                    CredentialSlotDescriptor(
                        slot: CredentialSlotID(
                            source: "keychain:\(namespace.identifier)", opaqueID: "user"),
                        locator: CredentialLocator(kind: .keychain, identifier: "cmVmZXJlbmNl")
                    )
                ]
            ]
        )
        let context = ProviderContext.sealed(
            credentials: credentials,
            http: http,
            clock: ManualClock(now: Self.now),
            profileRoots: try SealedProfileRoots.store(root)
        )
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )

        let report = try await ClaudeProvider().fetchUsage(for: account, using: context)

        #expect(report.plan == "Claude Max 20x", "the plan label comes from the keychain payload")
        #expect(!report.windows.isEmpty)
        let request = try #require(http.recordedRequests.first)
        #expect(request.url == ClaudeProvider.usageURL)
        #expect(request.headerValue("Authorization") == "Bearer \(Self.accessToken)")
        #expect(credentials.resolvedLocators == [locator])
    }

    @Test("a 401 on a keychain credential recommends running claude, and only there")
    func keychainFailureRecommendsClaudeLogin() {
        let expired = UsageError.from(HTTPResponse(status: 401))

        let keychain = ClaudeProvider.annotated(
            expired,
            for: CredentialLocator(kind: .keychain, identifier: "ref")
        )
        #expect(keychain.reauthentication?.command == "claude")

        let file = ClaudeProvider.annotated(
            expired,
            for: CredentialLocator(kind: .file, identifier: "/fixture/.credentials.json")
        )
        #expect(file.reauthentication?.command == nil)
        #expect(file.reauthentication?.summary.contains(".credentials.json") == true)

        let setupToken = ClaudeProvider.annotated(
            expired,
            for: ClaudeSetupTokenCredential.locator(for: ProfileRootID())
        )
        #expect(setupToken.reauthentication?.command == nil)
        #expect(setupToken.reauthentication?.summary.contains("Settings") == true)

        let unrelated = ClaudeProvider.annotated(
            UsageError.from(HTTPResponse(status: 500)),
            for: CredentialLocator(kind: .keychain, identifier: "ref")
        )
        #expect(unrelated.reauthentication == nil, "only credential failures carry recovery")
    }

    @Test("discovers every configured Claude root through one Usage-owned service")
    func discoversMultipleSetupTokenAccounts() async throws {
        let work = ProviderFixtures.root("profiles/work")
        let personal = ProviderFixtures.root("profiles/personal")
        let workRoot = try SealedProfileRoots.root(ClaudeProvider.id, label: "Work", at: work)
        let personalRoot = try SealedProfileRoots.root(
            ClaudeProvider.id,
            label: "Personal",
            at: personal
        )
        let workLocator = ClaudeSetupTokenCredential.locator(for: workRoot.id)
        let personalLocator = ClaudeSetupTokenCredential.locator(for: personalRoot.id)
        let credentials = SealedCredentialSource(
            slots: [
                ClaudeSetupTokenCredential.namespace: [
                    setupTokenDescriptor(locator: workLocator),
                    setupTokenDescriptor(locator: personalLocator),
                ]
            ]
        )
        let context = ProviderContext.sealed(
            credentials: credentials,
            profileRoots: try SealedProfileRoots.store(workRoot, personalRoot)
        )

        let accounts = try await ClaudeProvider().discoverAccounts(using: context)

        #expect(accounts.map(\.displayName) == ["Work", "Personal"])
        #expect(accounts.map(\.locator) == [workLocator, personalLocator])
        #expect(
            credentials.enumeratedNamespaces == [
                ClaudeSetupTokenCredential.namespace,
                Self.keychainNamespace(for: work),
                Self.keychainNamespace(for: personal),
            ],
            "each custom root's hashed service is consulted before its setup token"
        )
        #expect(credentials.resolvedLocators.isEmpty, "discovery never reads token payloads")
    }

    @Test("a credential file takes precedence without changing the root's logical slot")
    func fileTakesPrecedenceOverSetupToken() async throws {
        let setup = try setupTokenDiscovery()
        let setupAccount = try #require(
            try await ClaudeProvider().discoverAccounts(using: setup.context).first
        )
        let files = try fileSystem(credential: "claude-credential-happy")
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: setup.credentials,
            clock: ManualClock(now: Self.now),
            profileRoots: setup.profileRoots
        )

        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )

        #expect(account.locator.kind == .file)
        #expect(account.slot == setupAccount.slot)
        #expect(setup.credentials.resolvedLocators.isEmpty)
    }

    @Test("an unusable credential file falls back to the root's setup token")
    func unusableFileFallsBackToSetupToken() async throws {
        let setup = try setupTokenDiscovery()
        let files = try fileSystem(credential: "claude-credential-mcp-only")
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: setup.credentials,
            clock: ManualClock(now: Self.now),
            profileRoots: setup.profileRoots
        )

        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )

        #expect(account.locator == setup.locator)
        #expect(account.availability == .active)
        #expect(setup.credentials.resolvedLocators.isEmpty)
    }

    @Test("an unusable credential file remains visible when no setup token exists")
    func unusableFileWithoutSetupTokenStaysUnavailable() async throws {
        let context = try context(credential: "claude-credential-mcp-only")

        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )

        #expect(account.locator.kind == .file)
        #expect(account.availability == .unavailable)
    }

    @Test("a setup token fetch maps unified headers without calling the profile endpoint")
    func fetchesWithSetupToken() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.messagesURL,
            with: HTTPResponse(
                status: 200,
                headers: [
                    "anthropic-ratelimit-unified-5h-utilization": "0.11",
                    "anthropic-ratelimit-unified-5h-reset": "1784572200",
                    "anthropic-ratelimit-unified-7d-utilization": "0.6",
                    "anthropic-ratelimit-unified-7d-reset": "1784883600",
                ]
            )
        )
        let setup = try await setupTokenAccount(http: http)

        let report = try await ClaudeProvider().fetchUsage(
            for: setup.account,
            using: setup.context
        )

        #expect(
            http.recordedRequests.first?.headerValue("Authorization")
                == "Bearer \(Self.accessToken)")
        #expect(http.recordedRequests.first?.url == ClaudeProvider.messagesURL)
        #expect(report.plan == "Claude setup token")
        #expect(report.windows.map(\.usedFraction) == [0.11, 0.6])
        #expect(report.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_784_572_200))
        #expect(!report.isPartial, "both setup-token windows were read")
        #expect(setup.credentials.resolvedLocators == [setup.locator])
    }

    @Test("a quota rejection still reports the unified headers it carries")
    func mapsHeadersOnQuotaRejection() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.messagesURL,
            with: HTTPResponse(
                status: 429,
                headers: [
                    "anthropic-ratelimit-unified-5h-utilization": "1.01",
                    "anthropic-ratelimit-unified-5h-reset": "1784572200",
                ]
            )
        )
        let setup = try await setupTokenAccount(http: http)

        let report = try await ClaudeProvider().fetchUsage(
            for: setup.account,
            using: setup.context
        )

        #expect(report.windows.map(\.usedFraction) == [1.01])
        #expect(report.isPartial, "the weekly setup-token window was absent")
    }

    @Test("authentication remains authoritative when stale rate headers are present")
    func rejectsAuthenticationFailureWithHeaders() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.messagesURL,
            with: HTTPResponse(
                status: 401,
                headers: [
                    "anthropic-ratelimit-unified-5h-utilization": "0.11",
                    "anthropic-ratelimit-unified-5h-reset": "1784572200",
                ]
            )
        )
        let setup = try await setupTokenAccount(http: http)

        do {
            _ = try await ClaudeProvider().fetchUsage(
                for: setup.account,
                using: setup.context
            )
            Issue.record("expected authentication failure")
        } catch let error as UsageError {
            #expect(error.category == .authenticationExpired)
            #expect(error.reason == .httpStatus(code: 401))
        }
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

    @Test("the setup-token probe is a bounded one-output-token inference request")
    func buildsSetupTokenProbeRequest() throws {
        let request = ClaudeProvider.setupTokenProbeRequest()
        #expect(request.method == .post)
        #expect(request.url == ClaudeProvider.messagesURL)
        #expect(request.headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        #expect(request.headers["Authorization"] == nil)
        let body = try #require(request.body)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["model"] as? String == "claude-haiku-4-5-20251001")
        #expect(object["max_tokens"] as? Int == 1)
        #expect((object["messages"] as? [[String: String]])?.count == 1)
    }

    @Test("stamps the bearer token onto the sent request")
    func sendsAuthorizedRequest() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let (account, context) = try await signedInAccount(http: http)
        _ = try await ClaudeProvider().fetchUsage(for: account, using: context)

        let sent = try #require(http.recordedRequests.first)
        #expect(sent.headerValue("Authorization") == "Bearer \(Self.accessToken)")
    }

    @Test("the plan label still comes from the credential, not from the configured label")
    func reportsPlanFromCredential() async throws {
        let report = try await fetch(usage: "claude-usage-happy")
        #expect(report.plan == "Claude Max 20x")
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
        let session = try #require(report.windows.first { $0.kind == .session })
        #expect(session.usedFraction == 0.125, "the flat member wins over its limits twin")
    }

    @Test("null flat members are absorbed by the limits array instead of failing the report")
    func mapsLimitsOnlyPayload() async throws {
        let report = try await fetch(usage: "claude-usage-limits-only")

        #expect(report.windows.count == 3)
        let session = try #require(report.windows.first { $0.kind == .session })
        #expect(session.usedFraction == 0.22)
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_784_572_200))
        let weekly = try #require(report.windows.first { $0.kind == .weekly })
        #expect(weekly.usedFraction == 0.63)
        let scoped = try #require(
            report.windows.first { $0.id.rawValue == "additional:fake-model-a:primary:weekly" }
        )
        #expect(scoped.label == "fake-model-a only", "the model id stands in for a null label")
        #expect(report.credits == nil)
    }

    @Test(
        "utilization is a percentage and is only ever divided by 100 — never unit-guessed",
        arguments: [0.0, 0.5, 1.0, 100.0, 150.0]
    )
    func percentIsAlwaysDividedBy100(percent: Double) async throws {
        let http = InMemoryHTTPTransport()
        let body = #"{"five_hour": {"utilization": \#(percent)}}"#
        http.stub(ClaudeProvider.usageURL, with: HTTPResponse(status: 200, body: Data(body.utf8)))
        let (account, context) = try await signedInAccount(http: http)

        let report = try await ClaudeProvider().fetchUsage(for: account, using: context)

        let session = try #require(report.windows.first)
        #expect(
            session.usedFraction == percent / 100,
            "a real 0.5% stays 0.005; a fractional-looking payload is not reinterpreted"
        )
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
        #expect(
            error.reauthentication?.command == nil,
            "running claude does not rewrite a credential file on macOS"
        )
        #expect(error.reauthentication?.summary.contains(".credentials.json") == true)
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

    @Test("a local expiry timestamp does not override a successful provider response")
    func providerDecidesWhetherCredentialIsExpired() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let context = try context(
            credential: "claude-credential-expired",
            http: http,
            credentials: SealedCredentialSource(secrets: [Self.fileLocator(): Self.accessToken])
        )
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )

        let report = try await ClaudeProvider().fetchUsage(for: account, using: context)

        #expect(!report.windows.isEmpty)
        #expect(http.recordedRequests.count == 1)
    }

    // MARK: - No mutation, no UI

    @Test("discovery and fetch mutate nothing and never ask for credential UI")
    func neverMutatesOrPrompts() async throws {
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let files = try fileSystem(credential: "claude-credential-happy")
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
        #expect(credentials.mutationAttempts.isEmpty)
        #expect(credentials.isUnmodified)
        #expect(credentials.refusedInteractiveRequests.isEmpty)
        #expect(
            credentials.enumeratedNamespaces == [ClaudeSetupTokenCredential.namespace],
            "only Usage's own token service is enumerated"
        )
    }

    @Test("a credential that would need UI fails closed during a background refresh")
    func failsClosedWithoutInteraction() async throws {
        let credentials = SealedCredentialSource(
            secrets: [Self.fileLocator(): Self.accessToken],
            interactiveOnly: [Self.fileLocator()],
            allowsInteraction: false
        )
        let context = try context(credential: "claude-credential-happy", credentials: credentials)
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )

        await #expect(throws: UsageError.interactionForbidden()) {
            _ = try await ClaudeProvider().fetchUsage(for: account, using: context)
        }
        #expect(credentials.refusedInteractiveRequests == [Self.fileLocator()])
    }

    @Test("discovery makes no network request")
    func discoveryIsLocal() async throws {
        let http = InMemoryHTTPTransport()
        let context = try context(credential: "claude-credential-happy", http: http)
        _ = try await ClaudeProvider().discoverAccounts(using: context)
        #expect(http.recordedRequests.isEmpty)
    }

    // MARK: - Helpers

    private func signedInAccount(
        http: InMemoryHTTPTransport
    ) async throws -> (ProviderAccount, ProviderContext) {
        let context = try context(
            credential: "claude-credential-happy",
            http: http,
            credentials: SealedCredentialSource(secrets: [Self.fileLocator(): Self.accessToken])
        )
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        return (account, context)
    }

    private func setupTokenDescriptor(
        locator: CredentialLocator
    ) -> CredentialSlotDescriptor {
        let account = locator.path.first ?? "invalid"
        return CredentialSlotDescriptor(
            slot: CredentialSlotID(
                source: "app-keychain:\(ClaudeSetupTokenCredential.service)",
                opaqueID: account
            ),
            locator: locator,
            displayName: account
        )
    }

    private func setupTokenDiscovery() throws -> (
        context: ProviderContext,
        credentials: SealedCredentialSource,
        profileRoots: InMemoryProfileRootStore,
        locator: CredentialLocator
    ) {
        let root = try SealedProfileRoots.root(
            ClaudeProvider.id,
            label: "Claude",
            at: ProviderFixtures.claudeRoot
        )
        let locator = ClaudeSetupTokenCredential.locator(for: root.id)
        let credentials = SealedCredentialSource(
            secrets: [locator: Self.accessToken],
            slots: [
                ClaudeSetupTokenCredential.namespace: [
                    setupTokenDescriptor(locator: locator)
                ]
            ]
        )
        let profileRoots = try SealedProfileRoots.store(root)
        return (
            ProviderContext.sealed(
                credentials: credentials,
                clock: ManualClock(now: Self.now),
                profileRoots: profileRoots
            ),
            credentials,
            profileRoots,
            locator
        )
    }

    private func setupTokenAccount(
        http: InMemoryHTTPTransport
    ) async throws -> (
        account: ProviderAccount,
        context: ProviderContext,
        credentials: SealedCredentialSource,
        locator: CredentialLocator
    ) {
        let setup = try setupTokenDiscovery()
        let context = ProviderContext.sealed(
            credentials: setup.credentials,
            http: http,
            clock: ManualClock(now: Self.now),
            profileRoots: setup.profileRoots
        )
        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        return (account, context, setup.credentials, setup.locator)
    }

    private func fetch(usage fixture: String) async throws -> UsageReport {
        let http = InMemoryHTTPTransport()
        http.stub(ClaudeProvider.usageURL, with: try ProviderFixtures.response("Claude", fixture))
        let (account, context) = try await signedInAccount(http: http)
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
        let (account, context) = try await signedInAccount(http: http)
        var captured: UsageError?
        do {
            _ = try await ClaudeProvider().fetchUsage(for: account, using: context)
        } catch let error as UsageError {
            captured = error
        }
        return try #require(captured)
    }
}

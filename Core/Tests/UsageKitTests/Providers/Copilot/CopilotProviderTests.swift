import Foundation
import Testing

@testable import UsageKit

@Suite("GitHub Copilot provider")
struct CopilotProviderTests {
    private static let token = "gho_FIXTURE0000000000000000000000000001"
    private static let githubKey = "Iv1.b507a08c87ecfe98:github.com"

    private static func url(_ fileName: String) -> URL {
        CopilotCredentialFiles.url(root: ProviderFixtures.copilotRoot, fileName: fileName)
    }

    private static func locator(
        _ fileName: String, key: String, field: String = "oauth_token"
    )
        -> CredentialLocator
    {
        CredentialLocator(
            kind: .file,
            identifier: url(fileName).standardizedFileURL.path(percentEncoded: false),
            path: [key, field]
        )
    }

    private static func keychainDescriptor(
        service: String,
        account: String = "github.com",
        identifier: String
    ) -> (CredentialLocator, CredentialSlotDescriptor) {
        let namespace = CredentialLocator(kind: .keychain, identifier: service)
        return (
            namespace,
            CredentialSlotDescriptor(
                slot: CredentialSlotID(source: "keychain:\(service)", opaqueID: account),
                locator: CredentialLocator(kind: .keychain, identifier: identifier),
                displayName: account
            )
        )
    }

    private static func githubCLIDescriptor(
        account: String = "fixture"
    )
        -> (CredentialLocator, CredentialSlotDescriptor)
    {
        let namespace = CredentialLocator(
            kind: .keychain,
            identifier: CopilotProvider.githubCLIKeychainService
        )
        return (
            namespace,
            CredentialSlotDescriptor(
                slot: CredentialSlotID(
                    source: "keychain:\(CopilotProvider.githubCLIKeychainService)",
                    opaqueID: account
                ),
                locator: CredentialLocator(
                    kind: .keychain,
                    identifier: "persistent-gh-\(account)"
                ),
                displayName: account
            )
        )
    }

    private func fileSystem(_ fixtures: [String: String]) throws -> SealedFileSystem {
        var files: [URL: Data] = [:]
        for (fileName, fixture) in fixtures {
            files[Self.url(fileName)] = try ProviderFixtures.data("Copilot", fixture)
        }
        return SealedFileSystem(files: files)
    }

    // MARK: - Credential discovery

    @Test("discovers one account per usable apps.json entry and skips the token-less one")
    func discoversAppsAccounts() async throws {
        let files = try fileSystem(["apps.json": "copilot-apps"])
        let context = ProviderContext.sealed(fileSystem: files)

        let accounts = try await CopilotProvider().discoverAccounts(using: context)

        #expect(accounts.count == 2)
        #expect(
            accounts.allSatisfy { $0.displayName == "Copilot CLI" },
            "the configured label names every account the root yields"
        )
        #expect(
            accounts.map(CopilotProvider.host(of:)) == ["github.com", "octofixture.ghe.com"]
        )
        #expect(Set(accounts.map(\.key)).count == 2)
        #expect(accounts.allSatisfy { $0.key.accountID.derivation == .credentialSlot })
        #expect(accounts.allSatisfy { $0.locator.path.last == "oauth_token" })
        #expect(files.readsOutsideHome.isEmpty)
    }

    @Test("apps.json wins over hosts.json for the same host, and both survive alongside oauth.json")
    func appliesFilePrecedence() async throws {
        let context = ProviderContext.sealed(
            fileSystem: try fileSystem([
                "apps.json": "copilot-apps",
                "hosts.json": "copilot-hosts",
                "oauth.json": "copilot-oauth",
            ])
        )

        let accounts = try await CopilotProvider().discoverAccounts(using: context)
        let sources = accounts.map(\.slot.source)

        #expect(accounts.count == 4)
        #expect(sources.filter { $0 == "copilot.apps.json" }.count == 2)
        #expect(sources.filter { $0 == "copilot.hosts.json" }.count == 1)
        #expect(sources.filter { $0 == "copilot.oauth.json" }.count == 1)
        let hostsAccount = try #require(
            accounts.first { $0.slot.source == "copilot.hosts.json" }
        )
        #expect(CopilotProvider.host(of: hostsAccount) == "legacy.ghe.example")
        let cliAccount = try #require(accounts.first { $0.slot.source == "copilot.oauth.json" })
        #expect(cliAccount.locator.path == ["cli.github.example", "access_token"])
    }

    @Test("reports no accounts when the credential directory is absent")
    func discoversNothingWithoutFiles() async throws {
        let context = ProviderContext.sealed()
        #expect(try await CopilotProvider().discoverAccounts(using: context).isEmpty)
    }

    @Test("Copilot CLI Keychain authentication supersedes a legacy file for github.com")
    func cliKeychainSupersedesLegacyFile() async throws {
        let cli = Self.keychainDescriptor(
            service: CopilotProvider.cliKeychainService,
            identifier: "persistent-copilot-cli"
        )
        let githubCLI = Self.githubCLIDescriptor(account: "fallback-user")
        let credentials = SealedCredentialSource(
            slots: [cli.0: [cli.1], githubCLI.0: [githubCLI.1]]
        )
        let context = ProviderContext.sealed(
            fileSystem: try fileSystem(["apps.json": "copilot-apps"]),
            credentials: credentials
        )

        let accounts = try await CopilotProvider().discoverAccounts(using: context)

        #expect(accounts.map(CopilotProvider.host(of:)) == ["github.com", "octofixture.ghe.com"])
        #expect(accounts.first?.locator.identifier == "persistent-copilot-cli")
        #expect(accounts.first?.locator.path.isEmpty == true)
        #expect(accounts.first?.displayName == "github.com")
        #expect(credentials.enumeratedNamespaces == [cli.0])
        #expect(credentials.resolvedLocators.isEmpty, "discovery must not read token payloads")
    }

    @Test("every GitHub CLI Keychain account becomes an account-bound gh locator")
    func githubCLIFallback() async throws {
        let cli = CredentialLocator(
            kind: .keychain,
            identifier: CopilotProvider.cliKeychainService
        )
        let first = Self.githubCLIDescriptor(account: "first-user")
        let second = Self.githubCLIDescriptor(account: "second-user")
        let credentials = SealedCredentialSource(slots: [first.0: [first.1, second.1]])

        let accounts = try await CopilotProvider().discoverAccounts(
            using: ProviderContext.sealed(credentials: credentials)
        )

        #expect(accounts.map(\.displayName) == ["first-user", "second-user"])
        #expect(accounts.map(\.locator.kind) == [.githubCLI, .githubCLI])
        #expect(accounts.map(\.locator.path) == [["first-user"], ["second-user"]])
        #expect(accounts.allSatisfy { CopilotProvider.host(of: $0) == "github.com" })
        #expect(credentials.enumeratedNamespaces == [cli, first.0])
    }

    @Test("Copilot CLI Keychain rows preserve enterprise hosts and reject non-host accounts")
    func keychainHostsArePreservedOrRejected() async throws {
        let namespace = CredentialLocator(
            kind: .keychain,
            identifier: CopilotProvider.cliKeychainService
        )
        let enterprise = Self.keychainDescriptor(
            service: CopilotProvider.cliKeychainService,
            account: "team.ghe.example",
            identifier: "persistent-enterprise"
        )
        let hostile = Self.keychainDescriptor(
            service: CopilotProvider.cliKeychainService,
            account: "team.ghe.example@evil.example",
            identifier: "persistent-hostile"
        )
        let credentials = SealedCredentialSource(
            slots: [namespace: [enterprise.1, hostile.1]]
        )

        let account = try #require(
            try await CopilotProvider().discoverAccounts(
                using: ProviderContext.sealed(credentials: credentials)
            ).first
        )

        #expect(CopilotProvider.host(of: account) == "team.ghe.example")
        #expect(account.displayName == "team.ghe.example")
        #expect(account.locator.identifier == "persistent-enterprise")
        #expect(credentials.enumeratedNamespaces == [namespace])
    }

    @Test(
        "REST host derivation",
        arguments: [
            ("github.com", "api.github.com"),
            ("octofixture.ghe.com", "api.octofixture.ghe.com"),
            ("api.already.example", "api.already.example"),
            ("HTTPS://Mixed.Case.Example/path", "api.mixed.case.example"),
            ("", "api.github.com"),
        ]
    )
    func derivesAPIHost(host: String, expected: String) {
        #expect(CopilotCredentialFiles.apiHost(for: host) == expected)
    }

    @Test(
        "a host key that would move the request's authority is refused, not repaired",
        arguments: [
            "ghe.corp@evil.example", "evil.example?x=1", "evil.example#f",
            "evil.example:notaport", "evil.example:1:2", "evil example", "[::1]",
        ]
    )
    func refusesHostileHostKeys(host: String) {
        #expect(CopilotProvider.usageURL(host: host) == nil)
        #expect(CopilotProvider.usageRequest(host: host) == nil)
    }

    @Test("a hostile host key yields no account and no request carrying the token")
    func hostileHostKeysAreNeverContacted() async throws {
        let http = InMemoryHTTPTransport()
        let context = ProviderContext.sealed(
            fileSystem: try fileSystem(["hosts.json": "copilot-hosts-hostile"]),
            http: http
        )

        let accounts = try await CopilotProvider().discoverAccounts(using: context)

        #expect(accounts.map(CopilotProvider.host(of:)) == ["github.com"])
        #expect(http.recordedRequests.isEmpty)
    }

    @Test("an enterprise host on a non-default port is still addressed on that port")
    func acceptsAnExplicitPort() throws {
        let url = try #require(CopilotProvider.usageURL(host: "ghe.example:8443"))
        #expect(url.absoluteString == "https://api.ghe.example:8443/copilot_internal/user")
    }

    // MARK: - Request construction

    @Test("sends the exact usage request")
    func buildsUsageRequest() throws {
        let request = try #require(CopilotProvider.usageRequest(host: "github.com"))
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://api.github.com/copilot_internal/user")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Editor-Version"] == "vscode/1.96.2")
        #expect(request.headers["Editor-Plugin-Version"] == "copilot-chat/0.26.7")
        #expect(request.headers["User-Agent"] == "GitHubCopilotChat/0.26.7")
        #expect(request.headers["X-GitHub-Api-Version"] == "2025-04-01")
        #expect(request.headers["Authorization"] == nil)
        #expect(request.body == nil)
    }

    @Test("an enterprise host is addressed on its own API server")
    func buildsEnterpriseRequest() throws {
        let request = try #require(CopilotProvider.usageRequest(host: "octofixture.ghe.com"))
        #expect(
            request.url.absoluteString
                == "https://api.octofixture.ghe.com/copilot_internal/user"
        )
    }

    @Test("authorization uses the Bearer scheme expected by the Copilot CLI endpoint")
    func usesBearerScheme() async throws {
        let http = InMemoryHTTPTransport()
        let (account, context) = try await githubAccount(http: http, usage: "copilot-user-happy")
        _ = try await CopilotProvider().fetchUsage(for: account, using: context)

        let sent = try #require(http.recordedRequests.first)
        #expect(sent.headerValue("Authorization") == "Bearer \(Self.token)")
    }

    @Test("the discovered GitHub CLI account's token is used as the whole bearer credential")
    func fetchesWithGitHubCLICredential() async throws {
        let item = Self.githubCLIDescriptor(account: "bound-user")
        let locator = try #require(GitHubCLICredentialSource.locator(login: "bound-user"))
        let credentials = SealedCredentialSource(
            secrets: [locator: Self.token],
            slots: [item.0: [item.1]]
        )
        let http = InMemoryHTTPTransport()
        http.stub(
            try #require(CopilotProvider.usageURL(host: "github.com")),
            with: try ProviderFixtures.response("Copilot", "copilot-user-happy")
        )
        let context = ProviderContext.sealed(credentials: credentials, http: http)
        let account = try #require(
            try await CopilotProvider().discoverAccounts(using: context).first
        )

        _ = try await CopilotProvider().fetchUsage(for: account, using: context)

        #expect(account.locator == locator)
        #expect(account.displayName == "bound-user")
        #expect(credentials.resolvedLocators == [locator])
        #expect(http.recordedRequests.first?.headerValue("Authorization") == "Bearer \(Self.token)")
    }

    // MARK: - Response parsing

    @Test("maps the happy path onto one window per metered quota")
    func mapsHappyPath() async throws {
        let report = try await fetch(usage: "copilot-user-happy")

        #expect(report.plan == "Individual")
        #expect(report.windows.count == 3)

        let premium = try #require(
            report.windows.first { $0.id.rawValue.contains("premium-interactions") }
        )
        #expect(premium.label == "Premium interactions")
        #expect(premium.usedFraction == 0.76)
        #expect(premium.detail == .count(used: 228, limit: 300))
        // A literal instant, not another call to the parser under test.
        #expect(premium.resetsAt == Date(timeIntervalSince1970: 1_785_542_400))

        let chat = try #require(report.windows.first { $0.id.rawValue.contains("chat") })
        #expect(chat.usedFraction == 0.1)
        #expect(chat.detail == .count(used: 50, limit: 500))
    }

    @Test("an unlimited quota is superseded by its monthly count rather than hiding it")
    func derivesWindowFromMonthlyCounts() async throws {
        let report = try await fetch(usage: "copilot-user-happy")
        let completions = try #require(
            report.windows.first { $0.id.rawValue.contains("completions") }
        )
        #expect(completions.usedFraction == 0.75)
        #expect(completions.detail == .count(used: 750, limit: 1_000))
    }

    @Test("a malformed quota entry never discards its valid siblings")
    func keepsSiblingsAcrossMalformedEntries() async throws {
        let response = try CopilotUsageResponse.decode(
            try ProviderFixtures.data("Copilot", "copilot-user-malformed-element")
        )
        #expect(response.hadDecodeFailure)
        #expect(
            response.quotaSnapshots.keys.sorted() == [
                "code_review", "premium_interactions", "spark_premium_interactions",
            ])

        let report = try await fetch(usage: "copilot-user-malformed-element")
        #expect(report.plan == "Business")
        #expect(report.isPartial, "the dropped quota entries are visible in the report itself")
        let premium = try #require(
            report.windows.first { $0.id.rawValue.contains("premium-interactions") }
        )
        #expect(premium.usedFraction == 0.75)
        let review = try #require(report.windows.first { $0.id.rawValue.contains("code-review") })
        #expect(review.usedFraction == 0.75)
        #expect(review.detail == .count(used: 30, limit: 40))
    }

    @Test("a bare calendar day resets at UTC midnight, not at the reader's local midnight")
    func readsABareResetDayAsUTC() async throws {
        let report = try await fetch(usage: "copilot-user-malformed-element")
        let premium = try #require(
            report.windows.first { $0.id.rawValue.contains("premium-interactions") }
        )
        #expect(premium.resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
    }

    @Test("an unusable monthly count fabricates no window")
    func skipsUnusableMonthlyCounts() async throws {
        let report = try await fetch(usage: "copilot-user-malformed-element")
        #expect(!report.windows.contains { $0.id.rawValue.contains("additional:chat") })
        #expect(report.windows.count == 2)
    }

    @Test("a token-based-billing seat is a healthy report with no metered window")
    func acceptsTokenBasedBilling() async throws {
        let report = try await fetch(usage: "copilot-user-token-based-billing")
        #expect(report.windows.isEmpty)
        #expect(report.plan == "Enterprise")
    }

    @Test("a placeholder quota does not render as an untouched allowance")
    func rejectsPlaceholderQuota() throws {
        let snapshot = CopilotQuotaSnapshot(
            entitlement: 0,
            remaining: 0,
            percentRemaining: 100,
            unlimited: false
        )
        #expect(snapshot.isPlaceholder)
    }

    @Test(
        "a placeholder that omits a field is still a placeholder, not a 0%-used window",
        arguments: [
            CopilotQuotaSnapshot(
                entitlement: 0,
                remaining: nil,
                percentRemaining: 100,
                unlimited: false
            ),
            CopilotQuotaSnapshot(
                entitlement: nil,
                remaining: nil,
                percentRemaining: 100,
                unlimited: false
            ),
        ]
    )
    func rejectsIncompletePlaceholderQuota(snapshot: CopilotQuotaSnapshot) {
        #expect(snapshot.isPlaceholder)
        #expect(snapshot.usedPercent == nil)
    }

    @Test("a seat whose only quota is an incomplete placeholder shows no window at all")
    func doesNotFabricateAWindowFromAPlaceholder() async throws {
        let report = try await fetch(usage: "copilot-user-placeholder-partial")
        #expect(report.windows.isEmpty, "0% used would claim an allowance the seat does not have")
        #expect(report.plan == "Business")
    }

    @Test("over-quota percentages survive as fractions above one")
    func preservesOverQuota() throws {
        let snapshot = CopilotQuotaSnapshot(
            entitlement: 100,
            remaining: -20,
            percentRemaining: -20,
            unlimited: false
        )
        #expect(snapshot.usedPercent == 120)
    }

    // MARK: - Authentication expiry and throttling

    @Test("401 means the sign-in has to be renewed")
    func mapsUnauthorized() async throws {
        let error = try await fetchError(usage: "copilot-user-auth-expired", status: 401)
        #expect(error.category == .authenticationExpired)
    }

    @Test("the 401 body never reaches the rendered error or its encoding")
    func redactsAuthExpiredBody() async throws {
        let error = try await fetchError(usage: "copilot-user-auth-expired", status: 401)
        let encoded = try Fixtures.encodedString(error)
        for secret in ProviderFixtures.secretShapedValues {
            #expect(!error.message.contains(secret))
            #expect(!error.description.contains(secret))
            #expect(!encoded.contains(secret))
        }
    }

    @Test("a 403 carrying a rate-limit signal is throttling, not an expired sign-in")
    func disambiguatesForbidden() async throws {
        let throttled = try await fetchError(
            usage: "copilot-user-forbidden-rate-limited",
            status: 403,
            headers: ["Retry-After": "60"]
        )
        #expect(throttled.category == .rateLimited)
        #expect(throttled.retry?.delay == .seconds(60))

        let exhausted = try await fetchError(
            usage: "copilot-user-forbidden-rate-limited",
            status: 403,
            headers: ["x-ratelimit-remaining": "0"]
        )
        #expect(exhausted.category == .rateLimited)
    }

    @Test("a bare 403 still means the sign-in has to be renewed")
    func plainForbiddenIsAuthFailure() async throws {
        let error = try await fetchError(usage: "copilot-user-auth-expired", status: 403)
        #expect(error.category == .authenticationExpired)
    }

    // MARK: - No mutation, no UI

    @Test("discovery and fetch mutate nothing and never ask for credential UI")
    func neverMutatesOrPrompts() async throws {
        let http = InMemoryHTTPTransport()
        let files = try fileSystem(["apps.json": "copilot-apps"])
        let credentials = SealedCredentialSource(
            secrets: [Self.locator("apps.json", key: Self.githubKey): Self.token],
            allowsInteraction: false
        )
        http.stub(
            try #require(CopilotProvider.usageURL(host: "github.com")),
            with: try ProviderFixtures.response("Copilot", "copilot-user-happy")
        )
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: credentials,
            http: http
        )

        let account = try #require(
            try await CopilotProvider().discoverAccounts(using: context)
                .first { $0.locator.path.first == Self.githubKey }
        )
        _ = try await CopilotProvider().fetchUsage(for: account, using: context)

        #expect(files.mutationAttempts.isEmpty)
        #expect(files.isUnmodified)
        #expect(files.readsOutsideHome.isEmpty)
        #expect(credentials.refusedInteractiveRequests.isEmpty)
        #expect(
            credentials.enumeratedNamespaces.map(\.identifier)
                == [
                    CopilotProvider.cliKeychainService,
                    CopilotProvider.githubCLIKeychainService,
                ]
        )
        #expect(
            credentials.resolvedLocators == [Self.locator("apps.json", key: Self.githubKey)],
            "global credential discovery enumerates accounts but never resolves a token"
        )
    }

    @Test("discovery makes no network request")
    func discoveryIsLocal() async throws {
        let http = InMemoryHTTPTransport()
        let context = ProviderContext.sealed(
            fileSystem: try fileSystem(["apps.json": "copilot-apps"]),
            http: http
        )
        _ = try await CopilotProvider().discoverAccounts(using: context)
        #expect(http.recordedRequests.isEmpty)
    }

    @Test("a credential that can only be read interactively fails closed in the background")
    func failsClosedWithoutInteraction() async throws {
        let locator = Self.locator("apps.json", key: Self.githubKey)
        let credentials = SealedCredentialSource(
            secrets: [locator: Self.token],
            interactiveOnly: [locator],
            allowsInteraction: false
        )
        let context = ProviderContext.sealed(
            fileSystem: try fileSystem(["apps.json": "copilot-apps"]),
            credentials: credentials
        )
        let account = try #require(
            try await CopilotProvider().discoverAccounts(using: context)
                .first { $0.locator.path.first == Self.githubKey }
        )

        await #expect(throws: UsageError.interactionForbidden()) {
            _ = try await CopilotProvider().fetchUsage(for: account, using: context)
        }
        #expect(credentials.refusedInteractiveRequests == [locator])
    }

    // MARK: - Helpers

    private func githubAccount(
        http: InMemoryHTTPTransport,
        usage fixture: String,
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) async throws -> (ProviderAccount, ProviderContext) {
        http.stub(
            try #require(CopilotProvider.usageURL(host: "github.com")),
            with: try ProviderFixtures.response(
                "Copilot",
                fixture,
                status: status,
                headers: headers
            )
        )
        let context = ProviderContext.sealed(
            fileSystem: try fileSystem(["apps.json": "copilot-apps"]),
            credentials: SealedCredentialSource(
                secrets: [Self.locator("apps.json", key: Self.githubKey): Self.token]
            ),
            http: http
        )
        let account = try #require(
            try await CopilotProvider().discoverAccounts(using: context)
                .first { $0.locator.path.first == Self.githubKey }
        )
        return (account, context)
    }

    private func fetch(usage fixture: String) async throws -> UsageReport {
        let http = InMemoryHTTPTransport()
        let (account, context) = try await githubAccount(http: http, usage: fixture)
        return try await CopilotProvider().fetchUsage(for: account, using: context)
    }

    private func fetchError(
        usage fixture: String,
        status: Int,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) async throws -> UsageError {
        let http = InMemoryHTTPTransport()
        let (account, context) = try await githubAccount(
            http: http,
            usage: fixture,
            status: status,
            headers: headers
        )
        var captured: UsageError?
        do {
            _ = try await CopilotProvider().fetchUsage(for: account, using: context)
        } catch let error as UsageError {
            captured = error
        }
        return try #require(captured)
    }
}

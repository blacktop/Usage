import Foundation
import Synchronization
import Testing

@testable import UsageKit

@Suite("Claude gate diagnostics")
struct ClaudeGateDiagnosticsTests {
    private static let accessToken = "sk-ant-oat01-FAKE-ACCESS-TOKEN-DO-NOT-USE-0000000000"
    private static let claudeDdbRoot = ProviderFixtures.root(".claude-ddb")

    /// Two enabled Claude roots in Settings order, one disabled Claude root, one Codex root.
    private static func roots() throws -> ProfileRootCollection {
        var collection = try ProfileRootCollection()
        try collection.add(
            providerID: ProviderID("claude"),
            label: "Claude",
            configurationDirectoryPath: ProviderFixtures.claudeRoot.path(percentEncoded: false)
        )
        try collection.add(
            providerID: ProviderID("claude"),
            label: "Claude DDB",
            configurationDirectoryPath: Self.claudeDdbRoot.path(percentEncoded: false)
        )
        try collection.add(
            providerID: ProviderID("claude"),
            label: "Disabled",
            configurationDirectoryPath: ProviderFixtures.root(".claude-off")
                .path(percentEncoded: false),
            isEnabled: false
        )
        try collection.add(
            providerID: ProviderID("codex"),
            label: "Codex",
            configurationDirectoryPath: ProviderFixtures.codexRoot.path(percentEncoded: false)
        )
        return collection
    }

    private static func context(
        credentials: SealedCredentialSource = SealedCredentialSource(),
        http: any HTTPTransport = RefusingHTTPTransport()
    ) throws -> ProviderContext {
        ProviderContext.sealed(
            credentials: credentials,
            http: http,
            profileRoots: InMemoryProfileRootStore(
                homeDirectory: ProviderFixtures.home,
                profiles: try roots()
            )
        )
    }

    private static func firstRootNamespace() -> CredentialLocator {
        ClaudeCodeKeychain.namespace(
            for: ProviderFixtures.claudeRoot,
            homeDirectory: ProviderFixtures.home
        )
    }

    private static func service(for root: URL) -> String {
        ClaudeCodeKeychain.service(for: root, homeDirectory: ProviderFixtures.home)
    }

    // MARK: - Service naming

    @Test("the default root uses the plain service and a custom root keeps its pinned hash")
    func serviceNamesMatchClaudeCode() {
        #expect(
            Self.service(for: ProviderFixtures.claudeRoot)
                == KeychainProbe.claudeService
        )
        #expect(
            Self.service(for: Self.claudeDdbRoot)
                == "Claude Code-credentials-b85be13e"
        )
    }

    @Test("only the exact home Claude root can use the plain service")
    func plainServiceIsDefaultRootOnly() {
        #expect(
            Self.service(for: ProviderFixtures.claudeRoot.appending(path: "nested"))
                != KeychainProbe.claudeService
        )
        #expect(
            Self.service(for: Self.claudeDdbRoot)
                .hasPrefix(KeychainProbe.claudeService + "-")
        )
    }

    // MARK: - Gate A

    @Test("Gate A queries the default plain service then custom hashed services")
    func gateAQueriesClaudeCodeServicesInOrder() async throws {
        let credentials = SealedCredentialSource()
        let context = try Self.context(credentials: credentials)
        let queried = Mutex<[String]>([])

        let outcomes = try await ClaudeGateDiagnostics.keychainAddressOutcomes(context: context) {
            service in
            queried.withLock { $0.append(service) }
            let matches = service == KeychainProbe.claudeService
            return KeychainEnumerationOutcome(status: 0, itemCount: matches ? 1 : 0)
        }

        #expect(
            queried.withLock { $0 } == [
                "Claude Code-credentials",
                "Claude Code-credentials-b85be13e",
            ],
            "enabled Claude roots only, in Settings order"
        )
        #expect(
            outcomes == [
                ClaudeKeychainAddressOutcome(profileIndex: 1, matched: true, status: 0),
                ClaudeKeychainAddressOutcome(profileIndex: 2, matched: false, status: 0),
            ]
        )
        #expect(credentials.resolvedLocators.isEmpty, "Gate A must never read a payload")
        #expect(credentials.enumeratedNamespaces.isEmpty, "Gate A bypasses credential sources")
    }

    @Test("a failed enumeration is no-match with its status, never an error")
    func gateAFailedEnumeration() async throws {
        let context = try Self.context()

        let outcomes = try await ClaudeGateDiagnostics.keychainAddressOutcomes(context: context) {
            _ in KeychainEnumerationOutcome(status: -25_293, itemCount: 0)
        }

        #expect(outcomes.map(\.matched) == [false, false])
        #expect(outcomes.map(\.status) == [-25_293, -25_293])
    }

    @Test("Gate A lines carry only index, match, and status")
    func gateALineRedaction() {
        let lines = ClaudeGateDiagnostics.lines(for: [
            ClaudeKeychainAddressOutcome(profileIndex: 1, matched: true, status: 0),
            ClaudeKeychainAddressOutcome(profileIndex: 2, matched: false, status: -25_293),
        ])
        #expect(lines == ["profile=1 match=yes status=0", "profile=2 match=no status=-25293"])
    }

    // MARK: - Gate B: locator selection

    @Test("the claude-code leg enumerates only the selected root's derived namespace")
    func gateBClaudeCodeEnumeratesSelectedNamespaceOnly() async throws {
        let namespace = Self.firstRootNamespace()
        let reference = "cmVmZXJlbmNl"
        let descriptor = CredentialSlotDescriptor(
            slot: CredentialSlotID(source: "keychain:\(namespace.identifier)", opaqueID: "row"),
            locator: CredentialLocator(kind: .keychain, identifier: reference)
        )
        let expectedLocator = CredentialLocator(
            kind: .keychain,
            identifier: reference,
            path: ClaudeCredentialFile.secretPath
        )
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let credentials = SealedCredentialSource(
            secrets: [expectedLocator: Self.accessToken],
            slots: [namespace: [descriptor]]
        )
        let context = try Self.context(credentials: credentials, http: http)

        let result = try await ClaudeGateDiagnostics.usageResult(
            context: context,
            profileIndex: 1,
            source: .claudeCode
        )

        #expect(credentials.enumeratedNamespaces == [namespace])
        #expect(credentials.resolvedLocators == [expectedLocator])
        #expect(result.credential == .resolved)
        #expect(result.httpStatus == 200)
        #expect(result.sessionWindowDecoded == true)
        #expect(result.weeklyWindowDecoded == true)
        let request = try #require(http.recordedRequests.first)
        #expect(request.url == ClaudeProvider.usageURL)
        #expect(request.headerValue("Authorization") == "Bearer \(Self.accessToken)")
        #expect(request.headerValue("anthropic-beta") == ClaudeProvider.betaHeader)
        #expect(request.headerValue("User-Agent") == ClaudeProvider.userAgent)
    }

    @Test("a claude-code leg with no matching row sends nothing and reports unavailable")
    func gateBClaudeCodeUnavailable() async throws {
        let credentials = SealedCredentialSource()
        let context = try Self.context(credentials: credentials)

        let result = try await ClaudeGateDiagnostics.usageResult(
            context: context,
            profileIndex: 1,
            source: .claudeCode
        )

        #expect(result.credential == .unavailable)
        #expect(!result.requestSent)
        #expect(result.httpStatus == nil)
        #expect(credentials.resolvedLocators.isEmpty)
    }

    @Test("the setup-token leg resolves that row's Usage-owned locator")
    func gateBSetupTokenLocator() async throws {
        let collection = try Self.roots()
        let rootID = try #require(
            collection.profiles.first { $0.label == "Claude DDB" }?.id
        )
        let locator = ClaudeSetupTokenCredential.locator(for: rootID)
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let credentials = SealedCredentialSource(secrets: [locator: Self.accessToken])
        let context = ProviderContext.sealed(
            credentials: credentials,
            http: http,
            profileRoots: InMemoryProfileRootStore(
                homeDirectory: ProviderFixtures.home,
                profiles: collection
            )
        )

        let result = try await ClaudeGateDiagnostics.usageResult(
            context: context,
            profileIndex: 2,
            source: .setupToken
        )

        #expect(credentials.resolvedLocators == [locator])
        #expect(credentials.enumeratedNamespaces.isEmpty, "the setup-token leg enumerates nothing")
        #expect(result.credential == .resolved)
        #expect(result.httpStatus == 200)
    }

    // MARK: - Gate B: outcomes

    @Test("a local credential failure sends zero requests and is not an HTTP fact")
    func gateBLocalFailureSendsNothing() async throws {
        let context = try Self.context()

        let result = try await ClaudeGateDiagnostics.usageResult(
            context: context,
            profileIndex: 1,
            source: .setupToken
        )

        #expect(result.credential == .unavailable)
        #expect(!result.requestSent)
        #expect(result.httpStatus == nil)
        #expect(result.sessionWindowDecoded == nil)
        #expect(
            ClaudeGateDiagnostics.line(for: result)
                == "source=setup-token credential=unavailable"
        )
    }

    @Test("a refused interactive read reports interactionRequired, not an endpoint rejection")
    func gateBInteractionRequired() async throws {
        let collection = try Self.roots()
        let rootID = try #require(collection.profiles.first?.id)
        let locator = ClaudeSetupTokenCredential.locator(for: rootID)
        let credentials = SealedCredentialSource(
            secrets: [locator: Self.accessToken],
            interactiveOnly: [locator]
        )
        let context = ProviderContext.sealed(
            credentials: credentials,
            profileRoots: InMemoryProfileRootStore(
                homeDirectory: ProviderFixtures.home,
                profiles: collection
            )
        )

        let result = try await ClaudeGateDiagnostics.usageResult(
            context: context,
            profileIndex: 1,
            source: .setupToken
        )

        #expect(result.credential == .interactionRequired)
        #expect(!result.requestSent)
        #expect(
            ClaudeGateDiagnostics.line(for: result)
                == "source=setup-token credential=interactionRequired"
        )
    }

    @Test("a non-2xx status is reported verbatim with no window facts")
    func gateBNonSuccessStatus() async throws {
        let collection = try Self.roots()
        let rootID = try #require(collection.profiles.first?.id)
        let locator = ClaudeSetupTokenCredential.locator(for: rootID)
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-auth-expired", status: 401)
        )
        let context = ProviderContext.sealed(
            credentials: SealedCredentialSource(secrets: [locator: Self.accessToken]),
            http: http,
            profileRoots: InMemoryProfileRootStore(
                homeDirectory: ProviderFixtures.home,
                profiles: collection
            )
        )

        let result = try await ClaudeGateDiagnostics.usageResult(
            context: context,
            profileIndex: 1,
            source: .setupToken
        )

        #expect(result.credential == .resolved)
        #expect(result.httpStatus == 401)
        #expect(result.sessionWindowDecoded == nil)
        #expect(result.weeklyWindowDecoded == nil)
        #expect(
            ClaudeGateDiagnostics.line(for: result)
                == "source=setup-token credential=resolved http=401"
        )
    }

    @Test("a transport failure after resolution is distinct from every HTTP status")
    func gateBTransportFailure() async throws {
        let collection = try Self.roots()
        let rootID = try #require(collection.profiles.first?.id)
        let locator = ClaudeSetupTokenCredential.locator(for: rootID)
        let context = ProviderContext.sealed(
            credentials: SealedCredentialSource(secrets: [locator: Self.accessToken]),
            http: RefusingHTTPTransport(),
            profileRoots: InMemoryProfileRootStore(
                homeDirectory: ProviderFixtures.home,
                profiles: collection
            )
        )

        let result = try await ClaudeGateDiagnostics.usageResult(
            context: context,
            profileIndex: 1,
            source: .setupToken
        )

        #expect(result.credential == .resolved)
        #expect(result.requestSent)
        #expect(result.httpStatus == nil)
        #expect(
            ClaudeGateDiagnostics.line(for: result)
                == "source=setup-token credential=resolved http=transport-failure"
        )
    }

    @Test("a 2xx response missing a window reports it as undecoded rather than inventing one")
    func gateBIncompleteSuccess() async throws {
        let collection = try Self.roots()
        let rootID = try #require(collection.profiles.first?.id)
        let locator = ClaudeSetupTokenCredential.locator(for: rootID)
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: HTTPResponse(
                status: 200,
                body: Data(#"{"five_hour": {"utilization": 12.5}}"#.utf8)
            )
        )
        let context = ProviderContext.sealed(
            credentials: SealedCredentialSource(secrets: [locator: Self.accessToken]),
            http: http,
            profileRoots: InMemoryProfileRootStore(
                homeDirectory: ProviderFixtures.home,
                profiles: collection
            )
        )

        let result = try await ClaudeGateDiagnostics.usageResult(
            context: context,
            profileIndex: 1,
            source: .setupToken
        )

        #expect(result.sessionWindowDecoded == true)
        #expect(result.weeklyWindowDecoded == false)
        #expect(
            ClaudeGateDiagnostics.line(for: result)
                == "source=setup-token credential=resolved http=200 session=yes weekly=no"
        )
    }

    @Test("an out-of-range profile index is refused with the configured count")
    func gateBIndexOutOfRange() async throws {
        let context = try Self.context()

        await #expect(throws: ClaudeGateDiagnosticFailure.profileIndexOutOfRange(configured: 2)) {
            _ = try await ClaudeGateDiagnostics.usageResult(
                context: context,
                profileIndex: 3,
                source: .setupToken
            )
        }
    }
}

import Foundation
import Testing

@testable import UsageKit

/// Proves that credential material present in a fixture cannot reach anything Usage keeps or
/// renders — not the account descriptor, not the report, not the CLI envelope, not a history
/// record.
///
/// The fixtures deliberately carry token-shaped strings, so these assertions fail loudly if a
/// provider ever copies one into a display label, an identifier, or an error.
@Suite("Provider redaction")
struct ProviderRedactionTests {
    private func assertNoSecrets(in text: String, sourceLocation: SourceLocation = #_sourceLocation)
    {
        for secret in ProviderFixtures.secretShapedValues {
            #expect(
                !text.contains(secret),
                "rendered output contains fixture credential material",
                sourceLocation: sourceLocation
            )
        }
    }

    private func assertNoSecrets(
        in account: ProviderAccount,
        report: UsageReport,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let rendered = [
            account.displayName ?? "",
            account.slot.source,
            account.slot.opaqueID,
            account.locator.identifier,
            account.locator.path.joined(separator: "."),
            account.key.accountID.rawValue,
            try Fixtures.encodedString(report),
            try Fixtures.encodedString(UsageReportDTO(report)),
            try Fixtures.encodedString(
                UsageOutputV1(
                    generatedAt: report.capturedAt,
                    accounts: [
                        UsageOutputV1.Account(
                            label: account.displayName,
                            report: UsageReportDTO(report)
                        )
                    ],
                    failures: []
                )
            ),
            try Fixtures.encodedString(
                HistoryRecordV1(report: report, recordedAt: report.capturedAt)
            ),
        ].joined(separator: "\n")
        assertNoSecrets(in: rendered, sourceLocation: sourceLocation)
    }

    @Test("nothing Codex reads or renders carries token material")
    func codexKeepsNoSecrets() async throws {
        let authURL = CodexAuthFile.url(root: ProviderFixtures.codexRoot)
        let http = InMemoryHTTPTransport()
        http.stub(
            CodexProvider.usageURL,
            with: try ProviderFixtures.response("Codex", "codex-usage-happy")
        )
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [authURL: try ProviderFixtures.data("Codex", "codex-auth")]
            ),
            credentials: SealedCredentialSource(
                secrets: [CodexProvider.locator(at: authURL): "FAKE-access-token-0000"]
            ),
            http: http
        )

        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )
        let report = try await CodexProvider().fetchUsage(for: account, using: context)
        try assertNoSecrets(in: account, report: report)
    }

    @Test("nothing Claude reads or renders carries token material")
    func claudeKeepsNoSecrets() async throws {
        let credentialURL = ClaudeCredentialFile.url(root: ProviderFixtures.claudeRoot)
        let locator = CredentialLocator(
            kind: .file,
            identifier: credentialURL.standardizedFileURL.path(percentEncoded: false),
            path: ClaudeCredentialFile.secretPath
        )
        let http = InMemoryHTTPTransport()
        http.stub(
            ClaudeProvider.usageURL,
            with: try ProviderFixtures.response("Claude", "claude-usage-happy")
        )
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    credentialURL: try ProviderFixtures.data("Claude", "claude-credential-happy")
                ]
            ),
            credentials: SealedCredentialSource(
                secrets: [
                    locator: "sk-ant-oat01-FAKE-ACCESS-TOKEN-DO-NOT-USE-0000000000"
                ]
            ),
            http: http,
            clock: ManualClock(now: Date(timeIntervalSince1970: 1_784_000_000))
        )

        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        let report = try await ClaudeProvider().fetchUsage(for: account, using: context)
        try assertNoSecrets(in: account, report: report)
    }

    @Test("nothing Copilot reads or renders carries token material")
    func copilotKeepsNoSecrets() async throws {
        let appsURL = CopilotCredentialFiles.url(
            root: ProviderFixtures.copilotRoot,
            fileName: "apps.json"
        )
        let locator = CredentialLocator(
            kind: .file,
            identifier: appsURL.standardizedFileURL.path(percentEncoded: false),
            path: ["Iv1.b507a08c87ecfe98:github.com", "oauth_token"]
        )
        let http = InMemoryHTTPTransport()
        http.stub(
            try #require(CopilotProvider.usageURL(host: "github.com")),
            with: try ProviderFixtures.response("Copilot", "copilot-user-happy")
        )
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [appsURL: try ProviderFixtures.data("Copilot", "copilot-apps")]
            ),
            credentials: SealedCredentialSource(
                secrets: [locator: "gho_FIXTURE0000000000000000000000000001"]
            ),
            http: http
        )

        let account = try #require(
            try await CopilotProvider().discoverAccounts(using: context)
                .first { $0.locator.path.first == "Iv1.b507a08c87ecfe98:github.com" }
        )
        let report = try await CopilotProvider().fetchUsage(for: account, using: context)
        try assertNoSecrets(in: account, report: report)
    }

    @Test("the redaction list covers every token-shaped value any fixture carries")
    func everySecretShapedFixtureValueIsListed() throws {
        let listed = Set(ProviderFixtures.secretShapedValues)
        let missing = try ProviderFixtures.scannedSecretShapedValues().subtracting(listed)
        #expect(
            missing.isEmpty,
            "add these to ProviderFixtures.secretShapedValues: \(missing.sorted())"
        )
    }

    /// The paths the happy-path suites never reach: an expired Claude credential, a Codex file with
    /// only an API key, and a Copilot account on a secondary host. Each carries a token the happy
    /// path does not, and each renders through a different branch.
    @Test("an expired Claude credential leaks nothing through the unavailable path")
    func expiredClaudeAccountKeepsNoSecrets() async throws {
        let credentialURL = ClaudeCredentialFile.url(root: ProviderFixtures.claudeRoot)
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    credentialURL: try ProviderFixtures.data("Claude", "claude-credential-expired")
                ]
            ),
            clock: ManualClock(now: Date(timeIntervalSince1970: 1_784_000_000))
        )

        let account = try #require(
            try await ClaudeProvider().discoverAccounts(using: context).first
        )
        #expect(account.availability == .unavailable)
        assertNoSecrets(in: descriptorText(of: account))
    }

    @Test("a Codex file holding only an API key leaks nothing through its descriptor")
    func codexAPIKeyOnlyAccountKeepsNoSecrets() async throws {
        let authURL = CodexAuthFile.url(root: ProviderFixtures.codexRoot)
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [authURL: try ProviderFixtures.data("Codex", "codex-auth-apikey-only")]
            )
        )

        let account = try #require(
            try await CodexProvider().discoverAccounts(using: context).first
        )
        assertNoSecrets(in: descriptorText(of: account))
    }

    @Test("a Copilot account on a secondary host leaks nothing through its descriptor")
    func copilotSecondaryHostAccountsKeepNoSecrets() async throws {
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    CopilotCredentialFiles.url(
                        root: ProviderFixtures.copilotRoot,
                        fileName: "apps.json"
                    ): try ProviderFixtures.data("Copilot", "copilot-apps"),
                    CopilotCredentialFiles.url(
                        root: ProviderFixtures.copilotRoot,
                        fileName: "hosts.json"
                    ): try ProviderFixtures.data("Copilot", "copilot-hosts"),
                    CopilotCredentialFiles.url(
                        root: ProviderFixtures.copilotRoot,
                        fileName: "oauth.json"
                    ): try ProviderFixtures.data("Copilot", "copilot-oauth"),
                ]
            )
        )

        let accounts = try await CopilotProvider().discoverAccounts(using: context)
        #expect(accounts.count == 4)
        for account in accounts {
            assertNoSecrets(in: descriptorText(of: account))
        }
    }

    private func descriptorText(of account: ProviderAccount) -> String {
        [
            account.displayName ?? "",
            account.slot.source,
            account.slot.opaqueID,
            account.locator.identifier,
            account.locator.path.joined(separator: "."),
            account.key.accountID.rawValue,
        ]
        .joined(separator: "\n")
    }

    @Test("a resolved credential is only ever readable as a redacted placeholder")
    func credentialDescriptionIsRedacted() {
        let credential = Credential(secret: "FAKE-access-token-0000")
        assertNoSecrets(in: credential.description)
        assertNoSecrets(in: credential.debugDescription)
        assertNoSecrets(in: "\(credential)")
    }
}

import Foundation
import Testing

@testable import UsageKit

@Suite("Claude credential mirror")
struct ClaudeCredentialMirrorTests {
    private let rootID = ProfileRootID()

    @Test("the mirror payload keeps the access token and plan fields, and nothing else")
    func payloadIsRedacted() throws {
        let source = try ProviderFixtures.data("Claude", "claude-credential-happy")

        let payload = try #require(ClaudeCredentialMirror.payload(from: source))

        #expect(payload.contains("sk-ant-oat01-FAKE-ACCESS-TOKEN-DO-NOT-USE-0000000000"))
        #expect(payload.contains("default_claude_max_20x"))
        #expect(!payload.contains("refreshToken"))
        #expect(!payload.contains("sk-ant-ort01"), "the refresh token never reaches the mirror")
        #expect(!payload.contains("expiresAt"))
        #expect(!payload.contains("scopes"))
        #expect(!payload.contains("\n"), "the store accepts only single-line payloads")
    }

    @Test("the mirror reads back through the same document machinery as the original")
    func payloadRoundTrips() throws {
        let source = try ProviderFixtures.data("Claude", "claude-credential-happy")
        let payload = try #require(ClaudeCredentialMirror.payload(from: source))
        let data = Data(payload.utf8)

        let secret = try CredentialDocument.secret(
            in: data,
            at: ClaudeCredentialFile.secretPath,
            kind: .appKeychain
        )
        let metadata = try ClaudeCredentialFile.parse(data, kind: .appKeychain)

        #expect(secret == "sk-ant-oat01-FAKE-ACCESS-TOKEN-DO-NOT-USE-0000000000")
        #expect(metadata.planLabel == "Claude Max 20x")
    }

    @Test("a document without a subscription token mirrors nothing")
    func mcpOnlyDocumentIsNotMirrored() throws {
        let source = try ProviderFixtures.data("Claude", "claude-credential-mcp-only")
        #expect(ClaudeCredentialMirror.payload(from: source) == nil)
    }

    @Test("the mirror service is Usage-owned and unrelated to Claude Code's item")
    func serviceIsUsageOwned() {
        #expect(ClaudeCredentialMirror.service == "io.blacktop.Usage.claude-mirror")
        #expect(ClaudeCredentialMirror.service != KeychainProbe.claudeService)
        #expect(ClaudeCredentialMirror.service != ClaudeSetupTokenCredential.service)
    }

    @Test("the read locator addresses the token inside the stored row")
    func locatorsAgreeOnTheRow() {
        let read = ClaudeCredentialMirror.locator(for: rootID)
        let storage = ClaudeCredentialMirror.storageLocator(for: rootID)

        #expect(read.kind == .appKeychain)
        #expect(read.identifier == storage.identifier)
        #expect(read.path == [rootID.description] + ClaudeCredentialFile.secretPath)
        #expect(storage.path == [rootID.description])
    }
}

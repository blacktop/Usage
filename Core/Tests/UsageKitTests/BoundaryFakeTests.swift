import Foundation
import Testing

@testable import UsageKit

@Suite("Injected boundaries")
struct BoundaryFakeTests {
    @Test("The transport records requests and replays stubbed responses in order")
    func transportReplaysInOrder() async throws {
        let url = try #require(URL(string: "https://example.invalid/usage"))
        let transport = InMemoryHTTPTransport()
        transport.stub(url, with: HTTPResponse(status: 200, body: Data("first".utf8)))
        transport.stub(url, with: HTTPResponse(status: 500, body: Data("second".utf8)))

        let first = try await transport.send(HTTPRequest(url: url))
        let second = try await transport.send(HTTPRequest(url: url))
        let third = try await transport.send(HTTPRequest(url: url))
        #expect(first.status == 200)
        #expect(second.status == 500)
        #expect(third.status == 500)
        #expect(transport.recordedRequests.count == 3)
    }

    @Test("An unstubbed URL fails instead of reaching the network")
    func unstubbedURLFails() async throws {
        let transport = InMemoryHTTPTransport()
        let url = try #require(URL(string: "https://example.invalid/other"))
        await #expect(throws: UsageError.transportFailure()) {
            try await transport.send(HTTPRequest(url: url))
        }
    }

    @Test("Header lookup is case-insensitive on both requests and responses")
    func headerLookupIsCaseInsensitive() throws {
        let url = try #require(URL(string: "https://example.invalid/usage"))
        let request = HTTPRequest(url: url, headers: ["OpenAI-Beta": "codex-1"])
        #expect(request.headerValue("openai-beta") == "codex-1")
        let response = HTTPResponse(status: 429, headers: ["retry-after": "17"])
        #expect(response.headerValue("Retry-After") == "17")
        #expect(response.headerValue("missing") == nil)
    }

    @Test("The file system is read-only and records which paths were touched")
    func fileSystemIsReadOnlyAndAudited() throws {
        let home = URL(filePath: "/Users/tester")
        let auth = home.appending(path: ".codex/auth.json")
        let other = home.appending(path: ".codex/config.toml")
        let fileSystem = InMemoryFileSystem(
            homeDirectory: home,
            files: [auth: Data("{}".utf8), other: Data("".utf8)]
        )

        #expect(fileSystem.fileExists(at: auth))
        #expect(!fileSystem.fileExists(at: home.appending(path: ".codex/missing.json")))
        #expect(try fileSystem.read(contentsOf: auth) == Data("{}".utf8))
        #expect(fileSystem.recordedReads == [auth])
        #expect(
            try fileSystem.contentsOfDirectory(at: home.appending(path: ".codex"))
                == [auth, other]
        )
    }

    @Test("Reading a missing file reports a redacted credential error")
    func missingFileIsRedacted() throws {
        let fileSystem = InMemoryFileSystem()
        let missing = URL(filePath: "/Users/tester/.codex/auth.json")
        #expect(throws: UsageError.credentialUnavailable(kind: .file)) {
            try fileSystem.read(contentsOf: missing)
        }
    }

    @Test("The manual clock only moves when a test moves it")
    func manualClockIsDeterministic() async throws {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 1_000))
        #expect(clock.now == Date(timeIntervalSince1970: 1_000))
        clock.advance(by: .seconds(60))
        #expect(clock.now == Date(timeIntervalSince1970: 1_060))
        try await clock.sleep(for: .seconds(30))
        #expect(clock.now == Date(timeIntervalSince1970: 1_090))
        #expect(clock.recordedSleeps == [.seconds(30)])
    }

    @Test("Interaction policies state their capability explicitly")
    func interactionPoliciesAreExplicit() {
        #expect(!BackgroundInteractionPolicy().allowsCredentialUI)
        #expect(UserInitiatedInteractionPolicy().allowsCredentialUI)
    }

    @Test("The credential source records every locator it was asked to resolve")
    func credentialSourceAuditsResolution() async throws {
        let locator = CredentialLocator(kind: .file, identifier: "/Users/tester/.codex/auth.json")
        let source = InMemoryCredentialSource(secrets: [locator: "token"])
        let url = try #require(URL(string: "https://example.invalid/usage"))
        let transport = InMemoryHTTPTransport()
        transport.stub(url, with: HTTPResponse(status: 200))
        let response = try await source.withCredential(at: locator) { credential in
            try await transport.send(credential.authorizing(HTTPRequest(url: url), with: .bearer))
        }
        #expect(response.status == 200)
        #expect(source.resolvedLocators == [locator])
    }
}

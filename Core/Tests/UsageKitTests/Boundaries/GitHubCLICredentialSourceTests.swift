import Foundation
import Synchronization
import Testing

@testable import UsageKit

@Suite("GitHub CLI credential source")
struct GitHubCLICredentialSourceTests {
    private final class Runner: GitHubCLICommandRunning, Sendable {
        private let outputs: [[String]: Data]
        private let calls = Mutex([[String]]())

        init(outputs: [[String]: Data]) {
            self.outputs = outputs
        }

        var arguments: [[String]] { calls.withLock { $0 } }

        func run(arguments: [String]) throws(UsageError) -> Data {
            calls.withLock { $0.append(arguments) }
            guard let output = outputs[arguments] else {
                throw UsageError.credentialUnavailable(kind: .githubCLI)
            }
            return output
        }
    }

    @Test("a locator binds the GitHub host and discovered login without running gh")
    func locatorBindsAccountWithoutRunningCommand() throws {
        let runner = Runner(outputs: [:])
        _ = GitHubCLICredentialSource(runner: runner)

        let locator = try #require(
            GitHubCLICredentialSource.locator(login: " discovered-user ")
        )

        #expect(locator.kind == .githubCLI)
        #expect(locator.identifier == "github.com")
        #expect(locator.path == ["discovered-user"])
        #expect(runner.arguments.isEmpty)
    }

    @Test("fetch asks gh for its resolved token and keeps it operation-scoped")
    func resolvesTokenInsideTheOperation() async throws {
        let token = "gho_FIXTURE0000000000000000000000000002"
        let locator = try #require(GitHubCLICredentialSource.locator(login: "resolved-user"))
        let arguments = GitHubCLICredentialSource.tokenArguments(login: "resolved-user")
        let runner = Runner(outputs: [
            arguments: Data("\(token)\n".utf8)
        ])
        let source = GitHubCLICredentialSource(runner: runner)
        let request = HTTPRequest(url: StaticURL.make("https://example.invalid"))

        let response = try await source.withCredential(
            at: locator
        ) { credential in
            let authorized = credential.authorizing(request, with: .bearer)
            return HTTPResponse(
                status: 200,
                body: Data((authorized.headerValue("Authorization") ?? "").utf8)
            )
        }

        #expect(String(decoding: response.body, as: UTF8.self) == "Bearer \(token)")
        #expect(runner.arguments == [arguments])
    }

    @Test("changing the active gh account cannot change an already discovered locator")
    func tokenLookupNamesTheDiscoveredLogin() async throws {
        let locator = try #require(GitHubCLICredentialSource.locator(login: "original-user"))
        let arguments = GitHubCLICredentialSource.tokenArguments(login: "original-user")
        let runner = Runner(outputs: [arguments: Data("gho_FIXTURE_BOUND_ACCOUNT\n".utf8)])
        let source = GitHubCLICredentialSource(runner: runner)

        _ = try await source.withCredential(at: locator) { _ in HTTPResponse(status: 200) }

        #expect(arguments.suffix(2) == ["--user", "original-user"])
        #expect(runner.arguments == [arguments])
    }

    @Test("blank command output is not a credential")
    func rejectsBlankOutput() async throws {
        let locator = try #require(GitHubCLICredentialSource.locator(login: "fixture"))
        let arguments = GitHubCLICredentialSource.tokenArguments(login: "fixture")
        let runner = Runner(outputs: [arguments: Data(" \n".utf8)])
        let source = GitHubCLICredentialSource(runner: runner)

        await #expect(throws: UsageError.credentialUnavailable(kind: .githubCLI)) {
            try await source.withCredential(at: locator) { _ in
                HTTPResponse(status: 200)
            }
        }
    }

    @Test("host or login data with an ambiguous shape is rejected")
    func rejectsAmbiguousLocators() async throws {
        #expect(GitHubCLICredentialSource.locator(host: "ghe.example", login: "user") == nil)
        #expect(GitHubCLICredentialSource.locator(login: "first\nsecond") == nil)
    }
}

import Foundation
import Testing

@testable import UsageKit

/// Typechecks a standalone snippet against the built `UsageKit` module.
///
/// The credential boundary is a compile-time contract, so the only test that can observe it is one
/// that asks the compiler.
private struct SnippetCompiler {
    private let searchPath: URL

    init() throws {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = packageRoot.appending(path: ".build")
        let nested =
            (try? FileManager.default.contentsOfDirectory(
                at: build, includingPropertiesForKeys: nil))
            ?? []
        let candidates =
            [build.appending(path: "debug")] + nested.map { $0.appending(path: "debug") }
        guard
            let found = candidates.first(where: {
                FileManager.default.fileExists(
                    atPath: $0.appending(path: "UsageKit.swiftmodule").path)
            })
        else {
            throw SnippetCompilerError.moduleNotFound(build.path)
        }
        searchPath = found
    }

    func typechecks(_ source: String) throws -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "usage-credential-snippet-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-typecheck", "-swift-version", "6", "-I", searchPath.path, file.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        _ = try output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

private enum SnippetCompilerError: Error {
    case moduleNotFound(String)
}

private struct EscapeAttempt: Sendable, CustomStringConvertible {
    let what: String
    let source: String

    var description: String { what }
}

private enum Snippet {
    static func operation(returning result: String, body: String) -> String {
        """
        import Foundation
        import UsageKit

        func operation(
            source: any CredentialSource,
            transport: any HTTPTransport,
            locator: CredentialLocator,
            url: URL,
            accounts: [ProviderAccount]
        ) async throws -> \(result) {
            try await source.withCredential(at: locator) { credential in
                \(body)
            }
        }
        """
    }

    static let sendingAStampedRequest = operation(
        returning: "HTTPResponse",
        body:
            "try await transport.send(credential.authorizing(HTTPRequest(url: url), with: .bearer))"
    )

    static let returningDiscoveredAccounts = operation(
        returning: "[ProviderAccount]",
        body: "accounts"
    )

    static let escapes = [
        EscapeAttempt(
            what: "the raw secret",
            source: operation(returning: "String", body: "credential.secret")
        ),
        EscapeAttempt(
            what: "any string at all",
            source: operation(returning: "String", body: "\"anything\"")
        ),
        EscapeAttempt(
            what: "raw bytes",
            source: operation(returning: "Data", body: "Data()")
        ),
        EscapeAttempt(
            what: "the request the secret was stamped onto",
            source: operation(
                returning: "HTTPRequest",
                body: "credential.authorizing(HTTPRequest(url: url), with: .bearer)"
            )
        ),
        EscapeAttempt(
            what: "the credential itself",
            source: operation(returning: "Credential", body: "credential")
        ),
    ]
}

@Suite("Credential boundary")
struct CredentialBoundaryTests {
    private static let secret = "sk-proj-LIVE0000TOKEN0000SECRET"

    private func sentRequest(
        stamping scheme: AuthorizationScheme,
        onto base: HTTPRequest
    ) async throws -> HTTPRequest {
        let locator = CredentialLocator(kind: .file, identifier: "/Users/tester/.codex/auth.json")
        let source = InMemoryCredentialSource(secrets: [locator: Self.secret])
        let transport = InMemoryHTTPTransport()
        transport.stub(base.url, with: HTTPResponse(status: 200))
        let response = try await source.withCredential(at: locator) { credential in
            try await transport.send(credential.authorizing(base, with: scheme))
        }
        #expect(response.status == 200)
        return try #require(transport.recordedRequests.first)
    }

    @Test("Bearer authorization stamps the secret and leaves the rest of the request alone")
    func bearerAuthorizationStampsTheRequest() async throws {
        let url = try #require(URL(string: "https://example.invalid/usage"))
        let base = HTTPRequest(
            method: .post,
            url: url,
            headers: ["Accept": "application/json"],
            body: Data("{}".utf8)
        )
        let sent = try await sentRequest(stamping: .bearer, onto: base)

        #expect(sent.headerValue("Authorization") == "Bearer \(Self.secret)")
        #expect(sent.headerValue("Accept") == "application/json")
        #expect(sent.method == .post)
        #expect(sent.body == base.body)
        #expect(base.headerValue("Authorization") == nil)
    }

    @Test("A bare API-key header carries the secret verbatim")
    func headerAuthorizationStampsTheRequest() async throws {
        let url = try #require(URL(string: "https://example.invalid/usage"))
        let sent = try await sentRequest(
            stamping: .header("x-api-key"),
            onto: HTTPRequest(url: url)
        )

        #expect(sent.headerValue("x-api-key") == Self.secret)
        #expect(sent.headerValue("Authorization") == nil)
    }

    @Test("A credential never describes itself with its secret")
    func credentialDescriptionIsRedacted() {
        let credential = Credential(secret: Self.secret)
        #expect(String(describing: credential) == "Credential(redacted)")
        #expect(String(reflecting: credential) == "Credential(redacted)")
    }

    @Test("The shapes a provider actually needs still typecheck")
    func legitimateOperationsCompile() throws {
        let compiler = try SnippetCompiler()
        #expect(try compiler.typechecks(Snippet.sendingAStampedRequest))
        #expect(try compiler.typechecks(Snippet.returningDiscoveredAccounts))
    }

    @Test(
        "A credential-scoped operation cannot hand back secret-carrying values",
        arguments: Snippet.escapes
    )
    fileprivate func secretsCannotEscapeTheOperation(attempt: EscapeAttempt) throws {
        let compiler = try SnippetCompiler()
        #expect(try compiler.typechecks(attempt.source) == false)
    }
}

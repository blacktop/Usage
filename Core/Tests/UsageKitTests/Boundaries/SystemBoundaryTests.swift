import Foundation
import Security
import Testing

@testable import UsageKit

/// The production boundary implementations, exercised without touching a real credential.
///
/// The Keychain source is covered through its query builders and its no-UI policy only. Issuing a
/// real `SecItemCopyMatching` from a test is exactly the thing the plan gates behind explicit user
/// approval, so nothing here calls one.
@Suite("System boundaries")
struct SystemBoundaryTests {
    private static let home = URL(filePath: "/Users/fixture", directoryHint: .isDirectory)
    private static let authURL = home.appending(path: ".codex/auth.json")

    private func fileSystem(_ payload: String) -> InMemoryFileSystem {
        InMemoryFileSystem(homeDirectory: Self.home, files: [Self.authURL: Data(payload.utf8)])
    }

    private func locator(path: [String]) -> CredentialLocator {
        CredentialLocator(
            kind: .file,
            identifier: Self.authURL.path(percentEncoded: false),
            path: path
        )
    }

    /// Resolves `locator` and hands back the one thing a credential can produce: an authorized
    /// request. The header is carried out in a response body because `CredentialScopedResult`
    /// deliberately refuses to let a `String` or an `HTTPRequest` leave the scope.
    private func resolve(
        _ source: FileCredentialSource,
        _ locator: CredentialLocator
    ) async -> Result<HTTPResponse, UsageError> {
        let probe = HTTPRequest(url: StaticURL.make("https://example.invalid"))
        do {
            return .success(
                try await source.withCredential(at: locator) { credential in
                    let header = credential.authorizing(probe, with: .bearer)
                        .headerValue("Authorization")
                    return HTTPResponse(status: 200, body: Data((header ?? "").utf8))
                }
            )
        } catch {
            return .failure(UsageError.normalized(error))
        }
    }

    private func authorizationHeader(
        for locator: CredentialLocator,
        in fileSystem: InMemoryFileSystem
    ) async throws -> String {
        let outcome = await resolve(FileCredentialSource(fileSystem: fileSystem), locator)
        return String(decoding: try outcome.get().body, as: UTF8.self)
    }

    // MARK: - File credential source

    @Test("the locator path is what decides which field is the secret")
    func walksTheLocatorPath() async throws {
        let files = fileSystem(#"{"tokens":{"access_token":"FAKE-access-token-0000"}}"#)
        let header = try await authorizationHeader(
            for: locator(path: ["tokens", "access_token"]),
            in: files
        )
        #expect(header == "Bearer FAKE-access-token-0000")
    }

    @Test("an empty path means the whole payload is the secret")
    func treatsAnEmptyPathAsTheWholePayload() async throws {
        let files = fileSystem("  FAKE-access-token-0000\n")
        let header = try await authorizationHeader(for: locator(path: []), in: files)
        #expect(header == "Bearer FAKE-access-token-0000")
    }

    @Test(
        "a path that does not resolve to a non-empty string fails closed",
        arguments: [
            #"{"tokens":{}}"#,
            #"{"tokens":{"access_token":""}}"#,
            #"{"tokens":{"access_token":{"nested":"x"}}}"#,
            #"{"tokens":"not-an-object"}"#,
            "not json at all",
        ]
    )
    func failsClosedOnAnUnexpectedShape(payload: String) async throws {
        let outcome = await resolve(
            FileCredentialSource(fileSystem: fileSystem(payload)),
            locator(path: ["tokens", "access_token"])
        )
        #expect(throws: UsageError.credentialUnavailable(kind: .file)) { try outcome.get() }
    }

    @Test("a missing file is a missing credential, and its path never reaches the error")
    func reportsMissingFileWithoutItsPath() async throws {
        let outcome = await resolve(
            FileCredentialSource(fileSystem: InMemoryFileSystem(homeDirectory: Self.home)),
            locator(path: ["tokens", "access_token"])
        )
        let error = try #require(outcome.failureValue)
        #expect(error.category == .credentialUnavailable)
        #expect(!error.message.contains("auth.json"))
        #expect(!(try Fixtures.encodedString(error)).contains("auth.json"))
    }

    @Test("a file source refuses a Keychain locator rather than guessing at a file for it")
    func refusesForeignLocators() async throws {
        let outcome = await resolve(
            FileCredentialSource(fileSystem: fileSystem("{}")),
            CredentialLocator(kind: .keychain, identifier: "Codex Auth")
        )
        #expect(throws: UsageError.credentialUnavailable(kind: .keychain)) { try outcome.get() }
    }

    @Test("a file source enumerates nothing, so no directory is ever scanned for credentials")
    func fileSourceHasNoNamespace() async throws {
        let source = SystemCredentialSource(fileSystem: fileSystem("{}"))
        let slots = try await source.slots(
            in: CredentialLocator(kind: .file, identifier: "/Users/fixture/.codex")
        )
        #expect(slots.isEmpty)
    }

    // MARK: - System file system

    @Test("the real file system reads a file it was pointed at and nothing else")
    func readsRealFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "usage-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "payload.json")
        try Data(#"{"ok":true}"#.utf8).write(to: file)

        let files = SystemFileSystem(homeDirectory: directory)
        #expect(files.homeDirectory == directory)
        #expect(files.fileExists(at: file))
        #expect(!files.fileExists(at: directory.appending(path: "absent.json")))
        let contents = String(decoding: try files.read(contentsOf: file), as: UTF8.self)
        #expect(contents == #"{"ok":true}"#)
        let listed = try files.contentsOfDirectory(at: directory).map(\.lastPathComponent)
        #expect(listed == ["payload.json"])
    }

    @Test("an unreadable path is a redacted credential failure, not a Foundation error")
    func redactsFileSystemFailures() throws {
        let files = SystemFileSystem(homeDirectory: Self.home)
        let missing = Self.home.appending(path: ".codex/auth.json")
        #expect(throws: UsageError.credentialUnavailable(kind: .file)) {
            _ = try files.read(contentsOf: missing)
        }
        #expect(throws: UsageError.credentialUnavailable(kind: .file)) {
            _ = try files.contentsOfDirectory(at: Self.home.appending(path: ".codex"))
        }
    }

    // MARK: - Keychain queries

    @Test("an enumeration query can neither return a secret nor be answered with UI")
    func enumerationQueryIsAttributesOnly() {
        let source = KeychainCredentialSource(interaction: BackgroundInteractionPolicy())
        let query = source.policed(KeychainCredentialSource.enumerationQuery(service: "Codex Auth"))

        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == "Codex Auth")
        #expect(query[kSecUseAuthenticationContext as String] != nil)
        #expect(query[kSecUseAuthenticationUI as String] as? String == "u_AuthUIF")
    }

    @Test("a payload query addresses one row and still refuses to raise UI")
    func payloadQueryIsSingleRowAndSilent() {
        let reference = KeychainItemReference(data: Data([0x01, 0x02, 0x03]))
        let source = KeychainCredentialSource(interaction: BackgroundInteractionPolicy())
        let query = source.policed(KeychainCredentialSource.payloadQuery(reference: reference))

        #expect(query[kSecValuePersistentRef as String] as? Data == reference.data)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecUseAuthenticationUI as String] as? String == "u_AuthUIF")
    }

    /// The recovery path the `.interactionRequired` message points at. Without this the Settings
    /// retry would issue a byte-identical no-UI query and fail identically, forever.
    @Test("a user-initiated policy is the one construction that drops the no-UI markers")
    func userInitiatedPolicyPermitsCredentialUI() {
        let reference = KeychainItemReference(data: Data([0x01, 0x02, 0x03]))
        let source = KeychainCredentialSource(interaction: UserInitiatedInteractionPolicy())

        for query in [
            source.policed(KeychainCredentialSource.enumerationQuery(service: "Codex Auth")),
            source.policed(KeychainCredentialSource.payloadQuery(reference: reference)),
        ] {
            #expect(query[kSecUseAuthenticationUI as String] == nil)
            #expect(query[kSecUseAuthenticationContext as String] == nil)
        }
    }

    @Test("the system source's default and its background policy build the same query")
    func systemSourceDefaultsToFailingClosed() {
        let service = KeychainCredentialSource.enumerationQuery(service: "Codex Auth")
        let byDefault = KeychainCredentialSource().policed(service)
        #expect(byDefault[kSecUseAuthenticationUI as String] as? String == "u_AuthUIF")
        #expect(byDefault[kSecUseAuthenticationContext as String] != nil)
    }

    @Test("the legacy UI-fail marker resolves to the framework's own value")
    func resolvesTheLegacyUIFailValue() {
        #expect(KeychainNoUIPolicy().resolvedUIFailValue == "u_AuthUIF")
    }

    @Test("a row reference round-trips through a locator identifier")
    func referenceRoundTrips() throws {
        let reference = KeychainItemReference(data: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(KeychainItemReference(identifier: reference.identifier) == reference)
        #expect(KeychainItemReference(identifier: "not base64 ***") == nil)
        #expect(KeychainItemReference(identifier: "") == nil)
    }

    @Test("an enumerated row becomes a slot keyed by its service and account, not by its row id")
    func describesEnumeratedRows() throws {
        let attributes: [String: Any] = [
            kSecAttrAccount as String: "  codex-oauth  ",
            kSecValuePersistentRef as String: Data([0x01]),
            kSecAttrModificationDate as String: Date(timeIntervalSince1970: 1_700_000_000),
        ]
        let item = try #require(KeychainItem(attributes))
        let descriptor = item.descriptor(service: "Codex Auth")

        #expect(descriptor.slot.source == "keychain:Codex Auth")
        #expect(descriptor.slot.opaqueID == "codex-oauth")
        #expect(descriptor.displayName == "codex-oauth")
        #expect(descriptor.locator.kind == .keychain)
        #expect(
            descriptor.locator.identifier == KeychainItemReference(data: Data([0x01])).identifier)
    }

    @Test("a row without an account attribute or a reference is not a slot")
    func rejectsIncompleteRows() {
        #expect(KeychainItem([:]) == nil)
        #expect(
            KeychainItem([
                kSecAttrAccount as String: "   ",
                kSecValuePersistentRef as String: Data([0x01]),
            ]) == nil
        )
        #expect(
            KeychainItem([
                kSecAttrAccount as String: "codex-oauth",
                kSecValuePersistentRef as String: Data(),
            ]) == nil
        )
    }

    @Test("slots are ordered newest first, with a deterministic tie-break")
    func ordersSlotsNewestFirst() throws {
        func item(_ account: String, at seconds: TimeInterval) throws -> KeychainItem {
            try #require(
                KeychainItem([
                    kSecAttrAccount as String: account,
                    kSecValuePersistentRef as String: Data(account.utf8),
                    kSecAttrModificationDate as String: Date(timeIntervalSince1970: seconds),
                ])
            )
        }
        let items = [
            try item("old", at: 100), try item("new", at: 300),
            try item("b", at: 300), try item("a", at: 300),
        ]
        let ordered = items.sorted(by: KeychainItem.newestFirst)
        #expect(ordered.map(\.account) == ["a", "b", "new", "old"])
    }

    @Test("a row with no dates at all still sorts, at the back")
    func toleratesRowsWithoutDates() throws {
        let undated = try #require(
            KeychainItem([
                kSecAttrAccount as String: "undated",
                kSecValuePersistentRef as String: Data([0x02]),
            ])
        )
        #expect(undated.modifiedAt == .distantPast)
    }

    // MARK: - URLSession transport

    @Test("a request survives translation to URLRequest with its headers and method intact")
    func translatesRequests() throws {
        let request = CodexProvider.usageRequest(chatGPTAccountID: "acct_FAKE0000000000000001")
        let urlRequest = URLSessionTransport.urlRequest(from: request)

        #expect(urlRequest.httpMethod == "GET")
        #expect(urlRequest.url == request.url)
        #expect(urlRequest.httpBody == nil)
        #expect(urlRequest.httpShouldHandleCookies == false)
        #expect(
            urlRequest.value(forHTTPHeaderField: "ChatGPT-Account-Id")
                == "acct_FAKE0000000000000001"
        )
        #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("response headers are carried through, so Retry-After survives the boundary")
    func carriesResponseHeaders() throws {
        let response = try #require(
            HTTPURLResponse(
                url: CodexProvider.usageURL,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "120", "Content-Type": "application/json"]
            )
        )
        let headers = URLSessionTransport.headers(of: response)
        #expect(headers["Retry-After"] == "120")
        #expect(
            UsageError.from(HTTPResponse(status: 429, headers: headers)).retry?.delay
                == .seconds(120))
    }

    @Test("a cancelled request is cancelled, and everything else offline is a network failure")
    func classifiesTransportErrors() {
        #expect(URLSessionTransport.failure(from: URLError(.cancelled)).category == .cancelled)
        #expect(URLSessionTransport.failure(from: CancellationError()).category == .cancelled)
        #expect(
            URLSessionTransport.failure(from: URLError(.notConnectedToInternet)).category
                == .network
        )
        #expect(URLSessionTransport.failure(from: URLError(.timedOut)).reason == .transportFailure)
        #expect(
            URLSessionTransport.failure(from: UsageError.decodingFailure(field: "x")).category
                == .malformedResponse
        )
    }
}

extension Result {
    var failureValue: Failure? {
        switch self {
        case .success: nil
        case .failure(let error): error
        }
    }
}

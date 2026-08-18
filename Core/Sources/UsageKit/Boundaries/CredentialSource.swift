import Foundation

/// Where a credential lives, expressed without any secret material.
///
/// Not `Codable`: a locator names a file path or a Keychain service, and neither belongs in
/// history, the alias map, CLI output, or an error.
public struct CredentialLocator: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case file
        case keychain
        case appKeychain
        case githubCLI

        var noun: String {
            switch self {
            case .file: "file system"
            case .keychain: "keychain"
            case .appKeychain: "Usage keychain"
            case .githubCLI: "GitHub CLI"
            }
        }
    }

    public let kind: Kind
    /// A path, service name, or other non-secret address within `kind`.
    public let identifier: String
    /// Key path to the secret inside the document the address resolves to.
    ///
    /// Document-backed credentials store the bearer token below the root: Codex keeps it at
    /// `tokens.access_token`, Claude at `claudeAiOauth.accessToken`, and legacy Copilot files at
    /// `<clientID>:<host>.oauth_token`. Components are listed rather than joined so a key
    /// containing `.` or `:` stays unambiguous. Non-document sources may use it for a non-secret
    /// selector, such as the GitHub login passed to `gh auth token --user`.
    public let path: [String]

    public init(kind: Kind, identifier: String, path: [String] = []) {
        self.kind = kind
        self.identifier = identifier
        self.path = path
    }
}

/// A non-secret description of one credential slot a source can see.
///
/// Produced by enumeration, which must return attributes only. Nothing here is secret-derived:
/// `displayName` is the slot's own label, such as a Keychain item's account attribute.
public struct CredentialSlotDescriptor: Sendable, Hashable {
    public let slot: CredentialSlotID
    public let locator: CredentialLocator
    public let displayName: String?

    public init(slot: CredentialSlotID, locator: CredentialLocator, displayName: String? = nil) {
        self.slot = slot
        self.locator = locator
        self.displayName = displayName
    }
}

/// How a secret is presented on an outbound request.
public enum AuthorizationScheme: Sendable, Hashable {
    /// `Authorization: Bearer <secret>`.
    case bearer
    /// `Authorization: token <secret>`, GitHub's spelling.
    case token
    /// `<name>: <secret>`, for providers that authenticate with a bare API-key header.
    case header(String)
}

/// A resolved secret, valid for exactly one provider operation.
///
/// Neither `Sendable` nor `Codable`, and it does not vend the secret as a value: the only way to
/// use one is `authorizing(_:with:)`, which stamps it onto an outbound request. Combined with the
/// `CredentialScopedResult` constraint on `CredentialSource.withCredential(at:perform:)`, there is
/// no accidental path — no `$0.secret`, no returned `String`, no returned `HTTPRequest` — by which
/// a secret reaches `ProviderAccount`, the store, the coordinator, a detached task, or a cache.
/// Copying secret-derived bytes out of the operation still takes deliberate, reviewable work.
public struct Credential: CustomStringConvertible, CustomDebugStringConvertible {
    private let secret: String
    private let document: Data?

    public init(secret: String) {
        self.secret = secret
        document = nil
    }

    init(secret: String, document: Data) {
        self.secret = secret
        self.document = document
    }

    /// `request` with the secret stamped onto it according to `scheme`.
    public func authorizing(
        _ request: HTTPRequest,
        with scheme: AuthorizationScheme
    ) -> HTTPRequest {
        var headers = request.headers
        switch scheme {
        case .bearer: headers["Authorization"] = "Bearer \(secret)"
        case .token: headers["Authorization"] = "token \(secret)"
        case .header(let name): headers[name] = secret
        }
        return HTTPRequest(
            method: request.method,
            url: request.url,
            headers: headers,
            body: request.body
        )
    }

    public var description: String { "Credential(redacted)" }
    public var debugDescription: String { description }

    /// Hands a redacted derivation of the credential document to a Usage-owned store.
    ///
    /// This is the one deliberate, reviewed path by which secret-derived bytes leave a credential
    /// operation — and they leave it only into another credential store, never to the caller: the
    /// derivation travels straight from `redacting` into `store`, and the return is `Void`. It
    /// exists so a provider can keep a last-good copy of a credential another agent owns, whose
    /// item that agent recreates in ways that void Usage's read approval.
    ///
    /// Best-effort by design: a failed mirror write must not fail the successful fetch it rides
    /// on, and UsageKit deliberately has no logging surface to report it to, so the error is
    /// dropped and the next success retries.
    func persistRedactedCopy(
        into store: any ManagedCredentialStore,
        at locator: CredentialLocator,
        redacting: (Data) -> String?
    ) {
        guard let document, let payload = redacting(document) else { return }
        try? store.storeCredential(payload, at: locator)
    }

    /// Parses non-secret provider metadata while the credential document remains operation-scoped.
    ///
    /// The marker protocol is internal, so downstream code cannot add a secret-carrying result type
    /// and use this as a general document escape hatch.
    func metadata<Metadata: ProviderCredentialMetadata>(
        using parser: (Data) throws(UsageError) -> Metadata
    ) throws(UsageError) -> Metadata? {
        guard let document else { return nil }
        return try parser(document)
    }
}

protocol ProviderCredentialMetadata: Sendable {}

/// The only way parsed credential-document metadata leaves a credential-scoped operation.
/// Metadata conformances are package-internal and reviewed beside their parsers.
struct CredentialOperationResponse<Metadata: ProviderCredentialMetadata>: CredentialScopedResult {
    let response: HTTPResponse
    let metadata: Metadata?
}

/// A result that a credential-scoped operation is allowed to hand back.
///
/// The conforming set is enumerated immediately below and deliberately excludes `String`, `Data`,
/// and `HTTPRequest`, the three shapes a resolved secret would travel in. Adding a conformance is a
/// reviewable decision made in this file, not something a provider does in passing.
public protocol CredentialScopedResult: Sendable {}

extension UsageReport: CredentialScopedResult {}
extension ProviderAccount: CredentialScopedResult {}
extension HTTPResponse: CredentialScopedResult {}
extension Array: CredentialScopedResult where Element: CredentialScopedResult {}

/// Resolves a locator and scopes the resulting credential to one async operation.
public protocol CredentialSource: Sendable {
    func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T

    /// Slots visible under `namespace`, whose `path` is ignored.
    ///
    /// Discovery-only, so it must be answerable from attributes alone and must never issue a query
    /// that can raise credential UI. Sources with no enumerable namespace keep the default.
    func slots(in namespace: CredentialLocator) async throws -> [CredentialSlotDescriptor]
}

extension CredentialSource {
    public func slots(in namespace: CredentialLocator) async throws -> [CredentialSlotDescriptor] {
        []
    }
}

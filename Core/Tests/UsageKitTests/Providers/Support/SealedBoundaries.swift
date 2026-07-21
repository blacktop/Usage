import Foundation
import Synchronization

@testable import UsageKit

/// A file system that records every read and can prove nothing was mutated.
///
/// `ProviderFileSystem` has no write member, so a provider cannot rewrite a credential file even by
/// accident. This wrapper closes the remaining gap: it snapshots the seeded bytes and answers
/// whether they still match, so a test can assert the outcome rather than the absence of an API.
final class SealedFileSystem: ProviderFileSystem, Sendable {
    private struct State {
        var files: [URL: Data]
        var reads: [URL] = []
        var readsOutsideHome: [URL] = []
        var mutationAttempts: [URL] = []
    }

    private let seeded: [URL: Data]
    private let state: Mutex<State>

    let homeDirectory: URL

    init(homeDirectory: URL = ProviderFixtures.home, files: [URL: Data] = [:]) {
        self.homeDirectory = homeDirectory
        let standardized = Dictionary(
            uniqueKeysWithValues: files.map { ($0.key.standardizedFileURL, $0.value) }
        )
        seeded = standardized
        state = Mutex(State(files: standardized))
    }

    var recordedReads: [URL] { state.withLock { $0.reads } }

    /// Reads that escaped the fake home directory, which would mean the provider reached for a real
    /// credential path instead of the injected one.
    var readsOutsideHome: [URL] { state.withLock { $0.readsOutsideHome } }

    /// Calls to `write`, which no provider can make: `ProviderFileSystem` has no write member.
    /// Asserting on it keeps that structural guarantee under test rather than under review.
    var mutationAttempts: [URL] { state.withLock { $0.mutationAttempts } }

    /// True while every seeded file still holds the bytes it was seeded with.
    var isUnmodified: Bool { state.withLock { $0.files } == seeded }

    /// Deliberately not part of `ProviderFileSystem`. Reachable only from a test, and recorded so
    /// that a future widening of the boundary fails these assertions instead of passing silently.
    func write(_ data: Data, to url: URL) {
        state.withLock { state in
            state.mutationAttempts.append(url)
            state.files[url.standardizedFileURL] = data
        }
    }

    func fileExists(at url: URL) -> Bool {
        record(url)
        return state.withLock { $0.files[url.standardizedFileURL] } != nil
    }

    func read(contentsOf url: URL) throws -> Data {
        record(url)
        guard let data = state.withLock({ $0.files[url.standardizedFileURL] }) else {
            throw UsageError.credentialUnavailable(kind: .file)
        }
        return data
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        record(url)
        let directory = url.standardizedFileURL.path(percentEncoded: false)
        return state.withLock { $0.files.keys }
            .filter {
                $0.deletingLastPathComponent().path(percentEncoded: false) == directory
            }
            .sorted { $0.absoluteString < $1.absoluteString }
    }

    private func record(_ url: URL) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let home = homeDirectory.standardizedFileURL.path(percentEncoded: false)
        state.withLock { state in
            state.reads.append(url)
            if !path.hasPrefix(home) { state.readsOutsideHome.append(url) }
        }
    }
}

/// A credential source that fails loudly on anything a background refresh must not do.
///
/// Every resolution and every enumeration is recorded. When `allowsInteraction` is false — the
/// setting a scheduled refresh runs under — a locator marked as needing UI is refused rather than
/// resolved, and the refusal is recorded so a test can assert the provider neither retried nor
/// escalated.
final class SealedCredentialSource: CredentialSource, Sendable {
    private struct State {
        var resolved: [CredentialLocator] = []
        var enumerated: [CredentialLocator] = []
        var refusedInteractiveRequests: [CredentialLocator] = []
        var written: [CredentialLocator: String] = [:]
    }

    private let secrets: [CredentialLocator: String]
    private let documents: [CredentialLocator: Data]
    private let slotsByNamespace: [CredentialLocator: [CredentialSlotDescriptor]]
    private let interactiveOnly: Set<CredentialLocator>
    private let allowsInteraction: Bool
    private let state = Mutex(State())

    init(
        secrets: [CredentialLocator: String] = [:],
        documents: [CredentialLocator: Data] = [:],
        slots: [CredentialLocator: [CredentialSlotDescriptor]] = [:],
        interactiveOnly: Set<CredentialLocator> = [],
        allowsInteraction: Bool = false
    ) {
        self.secrets = secrets
        self.documents = documents
        slotsByNamespace = slots
        self.interactiveOnly = interactiveOnly
        self.allowsInteraction = allowsInteraction
    }

    var resolvedLocators: [CredentialLocator] { state.withLock { $0.resolved } }
    var enumeratedNamespaces: [CredentialLocator] { state.withLock { $0.enumerated } }
    var refusedInteractiveRequests: [CredentialLocator] {
        state.withLock { $0.refusedInteractiveRequests }
    }

    /// Locators a caller tried to write. `CredentialSource` has no writer, so this can only ever be
    /// non-empty if the boundary is widened — which is what these assertions are watching for.
    var mutationAttempts: [CredentialLocator] {
        state.withLock { Array($0.written.keys) }
    }

    /// True while no seeded credential has been replaced.
    var isUnmodified: Bool { state.withLock { $0.written.isEmpty } }

    /// Deliberately not part of `CredentialSource`. Reachable only from a test.
    func store(_ secret: String, at locator: CredentialLocator) {
        state.withLock { $0.written[locator] = secret }
    }

    func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T {
        let resolved = try state.withLock { state throws(UsageError) -> (String, Data?) in
            state.resolved.append(locator)
            if interactiveOnly.contains(locator), !allowsInteraction {
                state.refusedInteractiveRequests.append(locator)
                throw UsageError.interactionForbidden()
            }
            guard let secret = secrets[locator] else {
                throw UsageError.credentialUnavailable(kind: locator.kind)
            }
            return (secret, documents[locator])
        }
        let credential =
            resolved.1.map { Credential(secret: resolved.0, document: $0) }
            ?? Credential(secret: resolved.0)
        return try await operation(credential)
    }

    func slots(in namespace: CredentialLocator) async throws -> [CredentialSlotDescriptor] {
        state.withLock { state in
            state.enumerated.append(namespace)
            return slotsByNamespace[namespace] ?? []
        }
    }
}

/// An HTTP transport that refuses every request.
///
/// Discovery is a local operation for all three providers, so a test can install this and prove no
/// network call was attempted at all.
struct RefusingHTTPTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw UsageError.transportFailure()
    }
}

extension ProviderContext {
    static func sealed(
        fileSystem: SealedFileSystem = SealedFileSystem(),
        credentials: SealedCredentialSource = SealedCredentialSource(),
        http: any HTTPTransport = RefusingHTTPTransport(),
        clock: ManualClock = ManualClock(),
        interaction: any InteractionPolicy = BackgroundInteractionPolicy(),
        profileRoots: (any ProfileRootStore)? = nil
    ) -> ProviderContext {
        ProviderContext(
            http: http,
            credentials: credentials,
            fileSystem: fileSystem,
            clock: clock,
            interaction: interaction,
            profileRoots: profileRoots
        )
    }
}

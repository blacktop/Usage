import Foundation
import Synchronization

/// An in-memory Usage-owned credential store for Settings and refresher tests.
///
/// Stored payloads are observable only through `readCredential(at:)` — the same reviewed surface
/// production exposes for the Claude token refresher — so suites can prove storage, rotation, and
/// removal without adding any wider secret-shaped assertion surface.
public final class InMemoryManagedCredentialStore: ManagedCredentialStore, Sendable {
    private struct State {
        var payloads: [CredentialLocator: String]
        var storageCount = 0
        var removalCount = 0
        var removalFailure: ManagedCredentialStoreError?
    }

    private let state: Mutex<State>

    public init(
        payloads: [CredentialLocator: String] = [:],
        removalFailure: ManagedCredentialStoreError? = nil
    ) {
        state = Mutex(State(payloads: payloads, removalFailure: removalFailure))
    }

    public var storageCount: Int { state.withLock { $0.storageCount } }
    public var removalCount: Int { state.withLock { $0.removalCount } }

    public func setRemovalFailure(_ failure: ManagedCredentialStoreError?) {
        state.withLock { $0.removalFailure = failure }
    }

    public func containsCredential(at locator: CredentialLocator) -> Bool {
        guard Self.isRow(locator) else { return false }
        return state.withLock { $0.payloads.keys.contains(locator) }
    }

    public func readCredential(at locator: CredentialLocator) -> String? {
        guard Self.isRow(locator) else { return nil }
        return state.withLock { $0.payloads[locator] }
    }

    public func storeCredential(
        _ secret: String,
        at locator: CredentialLocator
    ) throws(ManagedCredentialStoreError) {
        guard Self.isRow(locator), secret.trimmedNonEmpty != nil,
            !secret.unicodeScalars.contains(where: CharacterSet.newlines.contains)
        else { throw .invalidCredential }
        state.withLock { state in
            state.payloads[locator] = secret
            state.storageCount += 1
        }
    }

    public func removeCredential(
        at locator: CredentialLocator
    ) throws(ManagedCredentialStoreError) {
        guard Self.isRow(locator) else { throw .invalidCredential }
        if let failure = state.withLock({ $0.removalFailure }) { throw failure }
        state.withLock { state in
            state.payloads.removeValue(forKey: locator)
            state.removalCount += 1
        }
    }

    /// The one whole-row rule, matching `AppKeychainCredentialStore.storageAddress`: storage
    /// operations address rows, and a document-path locator (more than one path component) is
    /// rejected here exactly as production rejects it, so a wrong-locator bug fails identically.
    private static func isRow(_ locator: CredentialLocator) -> Bool {
        locator.kind == .appKeychain && locator.path.count == 1
    }
}

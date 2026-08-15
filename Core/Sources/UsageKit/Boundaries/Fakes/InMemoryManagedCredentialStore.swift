import Foundation
import Synchronization

/// An in-memory Usage-owned credential store for Settings tests.
///
/// Only locator presence is observable. Secret bytes are deliberately not exposed back to a test;
/// suites can prove storage and removal without adding a secret-shaped assertion surface.
public final class InMemoryManagedCredentialStore: ManagedCredentialStore, Sendable {
    private struct State {
        var locators: Set<CredentialLocator>
        var storageCount = 0
        var removalCount = 0
        var removalFailure: ManagedCredentialStoreError?
    }

    private let state: Mutex<State>

    public init(
        locators: Set<CredentialLocator> = [],
        removalFailure: ManagedCredentialStoreError? = nil
    ) {
        state = Mutex(State(locators: locators, removalFailure: removalFailure))
    }

    public var storageCount: Int { state.withLock { $0.storageCount } }
    public var removalCount: Int { state.withLock { $0.removalCount } }

    public func setRemovalFailure(_ failure: ManagedCredentialStoreError?) {
        state.withLock { $0.removalFailure = failure }
    }

    public func containsCredential(at locator: CredentialLocator) -> Bool {
        state.withLock { $0.locators.contains(locator) }
    }

    public func storeCredential(
        _ secret: String,
        at locator: CredentialLocator
    ) throws(ManagedCredentialStoreError) {
        guard locator.kind == .appKeychain, secret.trimmedNonEmpty != nil,
            !secret.unicodeScalars.contains(where: CharacterSet.newlines.contains)
        else { throw .invalidCredential }
        state.withLock { state in
            state.locators.insert(locator)
            state.storageCount += 1
        }
    }

    public func removeCredential(
        at locator: CredentialLocator
    ) throws(ManagedCredentialStoreError) {
        guard locator.kind == .appKeychain else { throw .invalidCredential }
        if let failure = state.withLock({ $0.removalFailure }) { throw failure }
        state.withLock { state in
            state.locators.remove(locator)
            state.removalCount += 1
        }
    }
}

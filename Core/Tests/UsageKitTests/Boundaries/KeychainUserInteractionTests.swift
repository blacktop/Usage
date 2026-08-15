import Darwin
import Foundation
import Security
import Testing

@testable import UsageKit

/// These touch process-global Keychain interaction state only. No Keychain item is read, created,
/// or modified, and no query is issued, so nothing here can prompt.
@Suite("Keychain user interaction suppression", .serialized)
struct KeychainUserInteractionTests {
    private typealias GetAllowed = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus

    /// Reads the process setting through a separate runtime lookup, so the assertions do not go
    /// through the same accessor the implementation caches.
    private func interactionAllowed() throws -> Bool {
        let path = "/System/Library/Frameworks/Security.framework/Security"
        let handle = try #require(dlopen(path, RTLD_NOW))
        defer { dlclose(handle) }
        let symbol = try #require(dlsym(handle, "SecKeychainGetUserInteractionAllowed"))
        let get = unsafeBitCast(symbol, to: GetAllowed.self)
        var allowed = DarwinBoolean(true)
        #expect(get(&allowed) == errSecSuccess)
        return allowed.boolValue
    }

    @Test("The deprecated lever resolves on this host")
    func leverIsAvailable() {
        #expect(
            KeychainUserInteraction.isAvailable,
            "without it a scheduled refresh can raise a dialog the user never asked for"
        )
    }

    @Test("Interaction is disabled for the duration of the body")
    func suppressesDuringBody() throws {
        var observed: Bool?
        KeychainUserInteraction.suppressed { observed = try? interactionAllowed() }
        #expect(observed == false, "the file-based keychain dialog is off inside the scope")
    }

    @Test("The previous setting is restored afterwards")
    func restoresAfterwards() throws {
        let before = try interactionAllowed()
        KeychainUserInteraction.suppressed {}
        #expect(try interactionAllowed() == before)
    }

    /// The explicit approval action must still be able to prompt after any number of background
    /// reads; a leaked `false` would silently break the one recovery path the user has.
    @Test("Repeated suppression never leaves interaction disabled")
    func repeatedSuppressionDoesNotLeak() throws {
        for _ in 0..<8 {
            KeychainUserInteraction.suppressed {}
        }
        #expect(try interactionAllowed(), "approval must remain possible")
    }

    @Test("The body's value is returned unchanged")
    func returnsBodyValue() {
        #expect(KeychainUserInteraction.suppressed { 42 } == 42)
    }
}

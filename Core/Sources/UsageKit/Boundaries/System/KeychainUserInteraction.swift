import Darwin
import Foundation
import Security

/// The process-global lever that actually suppresses the file-based keychain's Allow/Deny dialog.
///
/// `kSecUseAuthenticationUI` and `LAContext.interactionNotAllowed` are data-protection-keychain
/// controls. Every agent credential Usage reads lives in the *file-based* login keychain, reached
/// through the SecItem shim, and those markers do not stop that keychain's dialog: a scheduled
/// refresh can raise an Allow/Deny panel nobody asked for. `SecKeychainSetUserInteractionAllowed`
/// is the control that does apply there, which is why it is used despite being deprecated.
///
/// The deprecated symbols are resolved at runtime rather than referenced at compile time, because
/// this package builds with warnings as errors — the same technique `KeychainNoUIPolicy` uses for
/// the legacy marker. A failed lookup leaves interaction untouched and the caller proceeds: the
/// query may then prompt, which is the pre-existing behaviour rather than a new failure.
enum KeychainUserInteraction {
    private typealias SetAllowed = @convention(c) (DarwinBoolean) -> OSStatus
    private typealias GetAllowed = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus

    private static let securityFrameworkPath =
        "/System/Library/Frameworks/Security.framework/Security"

    /// The suppression is process-wide, so two concurrent background reads must not interleave
    /// their save/restore and leave interaction disabled for the rest of the run.
    private static let lock = NSLock()

    private static let symbols: (set: SetAllowed, get: GetAllowed)? = resolveSymbols()

    /// Whether the lever is available on this host. False means background reads keep the
    /// pre-existing behaviour and may prompt.
    static var isAvailable: Bool { symbols != nil }

    /// Runs `body` with keychain user interaction disabled for this process, restoring the previous
    /// setting afterwards.
    ///
    /// `body` must be short and synchronous: it holds a process-wide setting and a lock, so an
    /// `await` inside it would suppress dialogs for unrelated work. Callers pass a single
    /// `SecItemCopyMatching`, never a provider fetch.
    static func suppressed<T>(_ body: () -> T) -> T {
        guard let symbols else { return body() }
        lock.lock()
        defer { lock.unlock() }
        var previous = DarwinBoolean(true)
        let read = symbols.get(&previous)
        _ = symbols.set(false)
        defer {
            // Restore only what was actually observed. A failed read means the prior state is
            // unknown, and re-enabling is the safer guess: leaving a process permanently unable to
            // prompt would break the explicit approval action too.
            _ = symbols.set(read == errSecSuccess ? previous : true)
        }
        return body()
    }

    private static func resolveSymbols() -> (set: SetAllowed, get: GetAllowed)? {
        guard let handle = dlopen(securityFrameworkPath, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let setSymbol = dlsym(handle, "SecKeychainSetUserInteractionAllowed"),
            let getSymbol = dlsym(handle, "SecKeychainGetUserInteractionAllowed")
        else { return nil }
        return (
            unsafeBitCast(setSymbol, to: SetAllowed.self),
            unsafeBitCast(getSymbol, to: GetAllowed.self)
        )
    }
}
